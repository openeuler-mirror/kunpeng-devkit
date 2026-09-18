from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path
from typing import Any

from binary_archive import apply_archive_mutations
from migration_common import EXIT_FAILED, EXIT_NEEDS_AGENT_FIX, EXIT_OK, MigrationError, load_json_value, run as run_command
from component_context import env_paths, require_context, save


def analyze_devkit_reports(report_paths: list[str]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []

    def walk(value: Any, path: str, report: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                key_norm = re.sub(r"[^a-z0-9]+", "_", str(key).lower()).strip("_")
                child_path = f"{path}.{key}" if path else str(key)
                if key_norm in {"source_need_migrated", "need_migrated", "migration_required"}:
                    if child is True or str(child).strip().lower() in {"yes", "true", "need migrated", "required"}:
                        findings.append({"report": report, "path": child_path, "value": child, "type": "MIGRATION_REQUIRED"})
                elif key_norm in {"compatible", "is_compatible", "arm_compatible", "kunpeng_compatible"}:
                    if child is False or str(child).strip().lower() in {"false", "no", "incompatible", "not compatible"}:
                        findings.append({"report": report, "path": child_path, "value": child, "type": "INCOMPATIBLE"})
                elif any(token in key_norm for token in {"incompatible_count", "to_be_verified", "need_migrate_count", "unresolved_count"}):
                    try:
                        if float(child) > 0:
                            findings.append({"report": report, "path": child_path, "value": child, "type": "NONZERO_FINDING_COUNT"})
                    except (TypeError, ValueError):
                        pass
                walk(child, child_path, report)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, f"{path}[{index}]", report)

    for item in report_paths:
        path = Path(item)
        if path.suffix.lower() != ".json" or not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        walk(data, "", str(path))
    return findings


def run_devkit(package: Path, config: dict[str, Any], tools: dict[str, Any], output_dir: Path, log_dir: Path) -> dict[str, Any]:
    """Run the one compatibility analysis performed before package adaptation."""
    required = bool(config.get("required", True))
    command_value = str(tools.get("devkit_command") or "").strip()
    if not command_value:
        if required:
            raise MigrationError("MISSING_DEVKIT", "tools.devkit_command is required")
        return {"status": "SKIPPED", "reason": "devkit command unavailable", "reports": [], "findings": []}

    executable = Path(command_value).expanduser()
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
        if required:
            raise MigrationError("MISSING_DEVKIT", f"devkit command not found: {command_value}")
        return {"status": "SKIPPED", "reason": "devkit command unavailable", "reports": [], "findings": []}

    args = [
        str(executable),
        "porting", "pkg-mig",
        "-i", str(package),
        "-o", str(output_dir),
        "-r", "json",
        "--set-timeout", str(config.get("timeout_minutes", 60)),
    ]
    if config.get("kp_compatibility", False):
        args.append("--kp-compatibility")
    args += [str(x) for x in config.get("extra_args", [])]

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    proc = run_command(args, log_dir / "devkit.log", check=False, timeout=int(config.get("timeout_minutes", 60)) * 60 + 60)
    reports = [str(p) for p in output_dir.rglob("*.json")]
    if proc.returncode != 0:
        if required:
            raise MigrationError("DEVKIT_SCAN_FAILED", f"ai-migration porting pkg-mig failed; see {log_dir / 'devkit.log'}")
        return {
            "status": "FAILED_OPTIONAL",
            "reports": reports,
            "findings": analyze_devkit_reports(reports),
            "log": str(log_dir / "devkit.log"),
        }
    return {
        "status": "SUCCESS",
        "reports": reports,
        "findings": analyze_devkit_reports(reports),
        "log": str(log_dir / "devkit.log"),
    }


def _load_mutations(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    value = load_json_value(path)
    if isinstance(value, dict):
        value = value.get("mutations") or []
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        raise MigrationError("INVALID_ARCHIVE_MUTATION_FILE", f"Invalid mutation file: {path}")
    return value


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        context = require_context(result)
        package = Path(context["working_package"])
        logs, reports = work_dir / "logs", work_dir / "reports"
        result["stage"] = "COMPATIBILITY"
        mutation_file = work_dir / "patches" / "compatibility-archive-mutations.json"
        mutations = _load_mutations(mutation_file)
        result["archive_mutations"] = apply_archive_mutations(
            package, mutations, work_dir, logs / "archive-mutations.log"
        )
        context["package_modified"] = bool(context.get("package_modified") or mutations)
        result["devkit"] = run_devkit(
            package,
            input_data.get("devkit") or {},
            input_data.get("tools") or {},
            reports / "devkit-initial",
            logs,
        )
        findings = result["devkit"].get("findings") or []
        if findings and (input_data.get("devkit") or {}).get("fail_on_findings", True):
            result.update({
                "status": "NEEDS_AGENT_FIX",
                "reason_code": "DEVKIT_PACKAGE_FINDINGS_REQUIRE_RESOLUTION",
                "action_required": {
                    "type": "FIX_PACKAGE_COMPATIBILITY",
                    "package": str(package),
                    "findings": findings,
                    "reports": result["devkit"].get("reports") or [],
                    "archive_mutations": str(mutation_file.resolve()),
                },
            })
            save(result_path, result)
            return EXIT_NEEDS_AGENT_FIX
        result.update({"status": "IN_PROGRESS", "reason_code": ""})
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "COMPATIBILITY", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "COMPATIBILITY", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
