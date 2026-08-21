#!/usr/bin/env python3
"""Build and verification stages for Java source ARM64 migration."""
from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_SCRIPTS = SCRIPT_DIR.parent.parent / "scripts"
if str(ROOT_SCRIPTS) not in __import__("sys").path:
    __import__("sys").path.insert(0, str(ROOT_SCRIPTS))

from migration_common import (
    EXIT_FAILED, EXIT_NEEDS_FIX, EXIT_OK, EXIT_WAITING, MigrationError,
    analyze_devkit_reports, build_environment, cleanup_untracked_build_outputs,
    clear_current_error, database_route, json_reports,
    load_json, require_baseline_build_command, resolve_devkit, run_command,
    run_shell, sha256_file, write_json,
)

AUXILIARY_ARTIFACT_PATTERNS = (
    re.compile(r"(?:^|[-.])sources?[-.]?", re.I),
    re.compile(r"(?:^|[-.])javadoc[-.]?", re.I),
    re.compile(r"(?:^|[-.])tests?[-.]?", re.I),
    re.compile(r"^original-", re.I),
    re.compile(r"\.plain\.jar$", re.I),
)
def require_sql_route_consistency(work_dir: Path, result: dict[str, Any], config: dict[str, Any]) -> None:
    sql = result.get("sql_migration") if isinstance(result.get("sql_migration"), dict) else {}
    recorded_status = str(sql.get("status") or "").upper()
    if not recorded_status:
        raise MigrationError("SQL_STAGE_REQUIRED", "SQL stage has not produced a migration decision", status="BLOCKED")
    route, source_db, target_db = database_route(work_dir, config)
    if recorded_status == "NOT_APPLICABLE":
        if route != "SKIP":
            raise MigrationError(
                "SQL_ROUTE_CHANGED_AFTER_SQL_STAGE",
                "Database migration route changed after SQL was recorded as not applicable. Start a new workspace or restore the original route.",
                status="BLOCKED",
            )
        return
    recorded_source = str(sql.get("source_db") or "").strip().lower()
    recorded_target = str(sql.get("target_db") or "").strip().lower()
    if route != "MIGRATE" or source_db.lower() != recorded_source or target_db.lower() != recorded_target:
        raise MigrationError(
            "SQL_ROUTE_CHANGED_AFTER_SQL_STAGE",
            "Database migration route changed after the SQL stage. Start a new workspace or restore the original route before continuing.",
            status="BLOCKED",
        )

def is_auxiliary_artifact(path: Path) -> bool:
    name = path.name
    for pattern in AUXILIARY_ARTIFACT_PATTERNS:
        if pattern.search(name):
            return True
    return False

def discover_artifacts(work_source: Path) -> list[Path]:
    found = []
    patterns = (
        "**/target/*.jar", "**/target/*.war",
        "**/build/libs/*.jar", "**/build/libs/*.war",
        "**/dist/*.jar", "**/dist/*.war",
    )
    for pattern in patterns:
        for path in work_source.glob(pattern):
            if path.is_file() and not is_auxiliary_artifact(path):
                found.append(path.resolve())
    unique = []
    seen = set()
    for path in sorted(found):
        value = str(path)
        if value not in seen:
            seen.add(value)
            unique.append(path)
    return unique

def artifact_output_path(work_source: Path, output_root: Path, artifact: Path) -> Path:
    relative = artifact.relative_to(work_source)
    parts = list(relative.parts)
    module_parts = []
    if artifact.parent.name in {"target", "dist"}:
        module_parts = parts[:-2]
    elif artifact.parent.name == "libs" and artifact.parent.parent.name == "build":
        module_parts = parts[:-3]
    destination = output_root.joinpath(*module_parts, artifact.name)
    return destination

def scan_package(devkit: list[str], artifact: Path, report_dir: Path, log_path: Path, work_source: Path) -> dict[str, Any]:
    report_dir.mkdir(parents=True, exist_ok=True)
    command = devkit + [
        "porting", "pkg-mig",
        "-i", str(artifact),
        "-o", str(report_dir),
        "-r", "json",
        "--set-timeout", "60",
    ]
    proc = run_command(command, cwd=work_source, log_path=log_path, check=False, timeout=3660)
    reports = json_reports(report_dir)
    findings = analyze_devkit_reports(reports)
    return {
        "status": "SUCCESS" if proc.returncode == 0 and not findings else ("NEEDS_FIX" if proc.returncode == 0 else "FAILED"),
        "exit_code": proc.returncode,
        "artifact": str(artifact),
        "report_dir": str(report_dir),
        "reports": [str(x) for x in reports],
        "findings": findings,
    }

def select_primary_artifact(work_dir: Path, artifacts: list[dict[str, Any]]) -> str:
    outputs = [str(item.get("output") or "") for item in artifacts if isinstance(item, dict) and item.get("output")]
    if len(outputs) == 1:
        return outputs[0]
    selection_path = work_dir / "artifact-selection.json"
    if not selection_path.is_file():
        return ""
    selection = load_json(selection_path)
    requested = str(selection.get("primary_artifact") or "").strip()
    if not requested:
        return ""
    requested_path = str(Path(requested).expanduser().resolve()) if Path(requested).is_absolute() else requested
    for output in outputs:
        output_path = str(Path(output).resolve())
        if requested == output or requested_path == output_path or requested == Path(output).name:
            same_name = [item for item in outputs if Path(item).name == requested]
            if requested == Path(output).name and len(same_name) != 1:
                continue
            return output
    return ""

def sql_completion_action(result: dict[str, Any]) -> dict[str, Any] | None:
    sql = result.get("sql_migration") if isinstance(result.get("sql_migration"), dict) else {}
    status = str(sql.get("source_status") or sql.get("status") or "").upper()
    counts = sql.get("counts") if isinstance(sql.get("counts"), dict) else {}
    pending = 0
    for key in ("todo", "pending_confirm", "manual_review"):
        try:
            pending += int(counts.get(key) or 0)
        except (TypeError, ValueError):
            pass
    if status == "COMPLETED_WITH_ACTIONS" or pending:
        return {
            "type": "SQL_MIGRATION_PENDING",
            "status": status,
            "decision": sql.get("decision"),
            "counts": counts,
        }
    return None

def stage_build(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    build_command = require_baseline_build_command(result, config)
    require_sql_route_consistency(work_dir, result, config)
    build_state = result.get("build") if isinstance(result.get("build"), dict) else {}
    attempt = int(build_state.get("attempt") or 0) + 1
    log_path = work_dir / "logs" / ("final-build-attempt-%03d.log" % attempt)
    cleanup_untracked_build_outputs(work_source)
    proc = run_shell(build_command, cwd=work_source, log_path=log_path, env=build_environment(work_dir), check=False)
    state = {
        "attempt": attempt,
        "command": build_command,
        "exit_code": proc.returncode,
        "log": str(log_path),
        "status": "SUCCESS" if proc.returncode == 0 else "FAILED",
    }
    result["build"] = state
    if proc.returncode != 0:
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "BUILD",
            "reason_code": "FINAL_BUILD_FAILED",
            "message": "Final build failed.",
            "action_required": {"type": "FIX_FINAL_BUILD", "build_command": build_command, "log": str(log_path)},
        })
        write_json(result_path, result)
        return EXIT_NEEDS_FIX
    clear_current_error(result)
    result.update({"status": "IN_PROGRESS", "stage": "BUILD", "build": state})
    write_json(result_path, result)
    return EXIT_OK

def stage_package_scan(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    artifacts = discover_artifacts(work_source)
    if not artifacts:
        result.update({
            "status": "FAILED",
            "stage": "PACKAGE_SCAN",
            "reason_code": "DEPLOYABLE_ARTIFACT_NOT_FOUND",
            "message": "Final build succeeded but no JAR/WAR was found under target/, build/libs/, or dist/.",
        })
        write_json(result_path, result)
        return EXIT_FAILED
    output_root = work_dir / "output"
    if output_root.exists():
        shutil.rmtree(str(output_root))
    output_root.mkdir(parents=True, exist_ok=True)
    copied = []
    used_outputs: set[str] = set()
    for artifact in artifacts:
        destination = artifact_output_path(work_source, output_root, artifact)
        destination_key = str(destination.resolve())
        if destination_key in used_outputs:
            # Different build output trees may legitimately contain the same
            # artifact filename (for example target/app.jar and dist/app.jar).
            # Preserve the source-relative build path for collisions instead of
            # silently overwriting a previously copied artifact.
            destination = output_root / artifact.relative_to(work_source)
            destination_key = str(destination.resolve())
        if destination_key in used_outputs:
            raise MigrationError(
                "ARTIFACT_OUTPUT_COLLISION",
                "Multiple build artifacts resolve to the same output path: %s" % destination,
                status="BLOCKED",
            )
        used_outputs.add(destination_key)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(artifact), str(destination))
        copied.append({
            "source": str(artifact),
            "output": str(destination),
            "size": destination.stat().st_size,
            "sha256": sha256_file(destination),
        })
    devkit = resolve_devkit(config)
    scan_attempt = int((result.get("package_scan") or {}).get("attempt") or 0) + 1 if isinstance(result.get("package_scan"), dict) else 1
    scan_results = []
    all_findings = []
    failed = False
    for index, item in enumerate(copied, 1):
        artifact = Path(item["output"])
        safe_name = re.sub(r"[^A-Za-z0-9._-]+", "-", artifact.stem) or ("artifact-%d" % index)
        report_dir = work_dir / "reports" / "devkit-package" / ("attempt-%03d" % scan_attempt) / ("%03d-%s" % (index, safe_name))
        scan = scan_package(devkit, artifact, report_dir, work_dir / "logs" / "devkit-package.log", work_source)
        scan_results.append(scan)
        all_findings.extend(scan.get("findings") or [])
        if scan.get("status") == "FAILED":
            failed = True
    result["artifacts"] = copied
    result["package_scan"] = {
        "attempt": scan_attempt,
        "status": "FAILED" if failed else ("NEEDS_FIX" if all_findings else "SUCCESS"),
        "results": scan_results,
        "findings": all_findings,
    }
    if failed:
        result.update({
            "status": "FAILED",
            "stage": "PACKAGE_SCAN",
            "reason_code": "DEVKIT_PACKAGE_SCAN_FAILED",
            "message": "DevKit package scan failed; see logs/devkit-package.log.",
        })
        write_json(result_path, result)
        return EXIT_FAILED
    if all_findings:
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "PACKAGE_SCAN",
            "reason_code": "DEVKIT_PACKAGE_FINDINGS_REQUIRE_FIX",
            "message": "Final artifacts still contain ARM64 migration findings.",
            "action_required": {"type": "FIX_PACKAGE_FINDINGS", "artifacts": copied, "findings": all_findings},
        })
        write_json(result_path, result)
        return EXIT_NEEDS_FIX
    clear_current_error(result)
    result.update({"status": "IN_PROGRESS", "stage": "PACKAGE_SCAN"})
    write_json(result_path, result)
    return EXIT_OK

def stage_verify(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), list) else []
    if not artifacts:
        raise MigrationError("PACKAGE_SCAN_REQUIRED", "No final artifact is available for verification")
    arch_command = str(config.get("architecture_command") or "uname -m").strip()
    arch_proc = run_shell(arch_command, cwd=work_source, log_path=work_dir / "logs" / "verification.log", check=False, timeout=300)
    architecture = (arch_proc.stdout or "").strip().splitlines()
    architecture_value = architecture[-1].strip().lower() if architecture else ""
    architecture_status = "SUCCESS" if arch_proc.returncode == 0 and architecture_value in {"aarch64", "arm64"} else "NOT_VERIFIED"
    verify_command = str(config.get("verify_command") or "").strip()
    primary_artifact = select_primary_artifact(work_dir, artifacts)
    if verify_command and "{artifact}" in verify_command and not primary_artifact:
        result.update({
            "status": "WAITING_FOR_USER",
            "stage": "VERIFY",
            "reason_code": "PRIMARY_ARTIFACT_REQUIRED",
            "message": "Primary artifact selection is required for runtime verification.",
            "action_required": {
                "type": "SELECT_PRIMARY_ARTIFACT",
                "artifacts": artifacts,
                "decision_file": str(work_dir / "artifact-selection.json"),
            },
        })
        write_json(result_path, result)
        return EXIT_WAITING

    runtime_status = "NOT_VERIFIED"
    runtime_evidence = []
    verify_output = ""
    verify_exit = None
    if architecture_status == "SUCCESS" and verify_command:
        mapping = {
            "work_source": str(work_source),
            "work_dir": str(work_dir),
            "output_dir": str(work_dir / "output"),
            "artifact": primary_artifact,
        }
        try:
            rendered = verify_command.format(**mapping)
        except KeyError as exc:
            raise MigrationError("INVALID_VERIFY_COMMAND", "Unknown verification placeholder: %s" % exc)
        proc = run_shell(rendered, cwd=work_source, log_path=work_dir / "logs" / "verification.log", check=False, timeout=1800)
        verify_exit = proc.returncode
        verify_output = (proc.stdout or "")[-4000:]
        if proc.returncode == 0:
            runtime_status = "SUCCESS"
            runtime_evidence.append("verification.command")
        else:
            runtime_status = "FAILED"
    verification = {
        "primary_artifact": primary_artifact or None,
        "architecture": {
            "status": architecture_status,
            "command": arch_command,
            "value": architecture_value,
            "exit_code": arch_proc.returncode,
        },
        "runtime": {
            "status": runtime_status,
            "command": verify_command or None,
            "exit_code": verify_exit,
            "evidence": runtime_evidence,
            "output": verify_output,
        },
    }
    actions = []
    sql_action = sql_completion_action(result)
    if sql_action:
        actions.append(sql_action)
    if architecture_status != "SUCCESS":
        actions.append({
            "type": "ARM64_VERIFICATION_REQUIRED",
            "architecture": architecture_value,
            "message": "Run verification on an ARM64 environment and rerun the verify stage.",
        })
    elif runtime_status != "SUCCESS":
        actions.append({
            "type": "RUNTIME_VERIFICATION_REQUIRED" if runtime_status == "NOT_VERIFIED" else "RUNTIME_VERIFICATION_FAILED",
            "message": "Provide and pass a project runtime/acceptance verification command on ARM64.",
        })
    result["verification"] = verification
    result["completion_actions"] = actions
    clear_current_error(result)
    result.update({
        "status": "SUCCESS" if not actions else "COMPLETED_WITH_ACTIONS",
        "stage": "COMPLETE",
        "reason_code": "" if not actions else "JAVA_SOURCE_MIGRATION_ACTIONS_REQUIRED",
    })
    write_json(result_path, result)
    return EXIT_OK

BUILD_STAGES = ["build", "package_scan", "verify"]


def run_stage(
    stage: str,
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    result: dict[str, Any],
    config: dict[str, Any],
) -> int:
    if stage == "build":
        return stage_build(work_dir, work_source, result_path, result, config)
    if stage == "package_scan":
        return stage_package_scan(work_dir, work_source, result_path, result, config)
    if stage == "verify":
        return stage_verify(work_dir, work_source, result_path, result, config)
    raise MigrationError("INVALID_BUILD_STAGE", "Unknown build-verification stage: %s" % stage)
