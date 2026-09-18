#!/usr/bin/env python3
"""Build and verification stages for Java source ARM64 migration."""
from __future__ import annotations

import re
import shutil
from pathlib import Path
from typing import Any

from migration_common import (
    EXIT_FAILED, EXIT_NEEDS_FIX, EXIT_OK, EXIT_WAITING, MigrationError,
    build_environment, cleanup_untracked_build_outputs,
    clear_current_error, database_route, inspect_ai_migration_csv_reports, zh_csv_reports,
    load_json, require_baseline_build_command, resolve_ai_migration, run_command,
    run_shell, sha256_file, write_git_worktree_patch, write_json,
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

def scan_package(ai_migration: list[str], artifact: Path, report_dir: Path, log_path: Path, work_source: Path) -> dict[str, Any]:
    report_dir.mkdir(parents=True, exist_ok=True)
    command = ai_migration + [
        "porting", "pkg-mig",
        "-i", str(artifact),
        "-o", str(report_dir),
        "-r", "csv",
        "--set-timeout", "60",
    ]
    proc = run_command(command, cwd=work_source, log_path=log_path, check=False, timeout=3660)

    # DevKit package scan status is determined strictly by returncode.
    # A zero exit code means the artifact scan passed; report files are not parsed.
    if proc.returncode == 0:
        success_reports = zh_csv_reports(report_dir)
        return {
            "status": "SUCCESS",
            "reason_code": "",
            "exit_code": 0,
            "artifact": str(artifact),
            "report_dir": str(report_dir),
            "reports": [str(x) for x in success_reports],
            "analyzed_reports": [],
            "findings": [],
        }

    # Non-zero means the package contains compatibility items. Only the Chinese
    # *_zh.csv result is authoritative; English reports are intentionally ignored.
    reports = zh_csv_reports(report_dir)
    if not reports:
        return {
            "status": "FAILED",
            "reason_code": "AI_MIGRATION_PACKAGE_ZH_CSV_REPORT_MISSING",
            "message": "ai-migration package scan returned %s but produced no *_zh.csv report." % proc.returncode,
            "exit_code": proc.returncode,
            "artifact": str(artifact),
            "report_dir": str(report_dir),
            "reports": [],
            "findings": [],
        }
    try:
        inspection = inspect_ai_migration_csv_reports(reports)
    except MigrationError as exc:
        return {
            "status": "FAILED",
            "reason_code": exc.code,
            "message": str(exc),
            "exit_code": proc.returncode,
            "artifact": str(artifact),
            "report_dir": str(report_dir),
            "reports": [str(x) for x in reports],
            "findings": [],
        }
    findings = inspection["findings"]
    return {
        "status": "NEEDS_FIX",
        "reason_code": "AI_MIGRATION_PACKAGE_FIX_REQUIRED",
        "exit_code": proc.returncode,
        "artifact": str(artifact),
        "report_dir": str(report_dir),
        "reports": [str(x) for x in reports],
        "analyzed_reports": inspection.get("analyzed_reports") or [],
        "findings": findings,
    }

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
        sql_work = Path(str(sql.get("work_dir") or "")) if str(sql.get("work_dir") or "") else None
        reports_dir = sql_work / "reports" if sql_work else None
        manual_review_report = reports_dir / "manual_review_report.json" if reports_dir else None
        pending_confirm_report = reports_dir / "pending_confirm_sql.json" if reports_dir else None
        action = {
            "type": "SQL_MIGRATION_PENDING",
            "requires_action": True,
            "status": status,
            "task_id": sql.get("task_id") or "",
            "decision": sql.get("decision"),
            "counts": counts,
            "result_file": sql.get("result_file") or "",
            "patch_file": sql.get("patch_file") or "",
            "message": "SQL migration completed with unresolved items. Review manual-review and pending-confirm SQL before production acceptance.",
        }
        if manual_review_report and manual_review_report.is_file():
            action["manual_review_report"] = str(manual_review_report)
        if pending_confirm_report and pending_confirm_report.is_file():
            action["pending_confirm_report"] = str(pending_confirm_report)
        return action
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
    ai_migration = resolve_ai_migration(work_dir)
    scan_attempt = int((result.get("package_scan") or {}).get("attempt") or 0) + 1 if isinstance(result.get("package_scan"), dict) else 1
    scan_results = []
    all_findings = []
    failure_reason_codes: list[str] = []
    failed = False
    needs_fix = False
    for index, item in enumerate(copied, 1):
        artifact = Path(item["output"])
        safe_name = re.sub(r"[^A-Za-z0-9._-]+", "-", artifact.stem) or ("artifact-%d" % index)
        report_dir = work_dir / "reports" / "ai-migration-package" / ("attempt-%03d" % scan_attempt) / ("%03d-%s" % (index, safe_name))
        scan = scan_package(ai_migration, artifact, report_dir, work_dir / "logs" / "ai-migration-package.log", work_source)
        scan_results.append(scan)
        all_findings.extend(scan.get("findings") or [])
        if scan.get("status") == "NEEDS_FIX":
            needs_fix = True
        if scan.get("status") == "FAILED":
            failed = True
            reason_code = str(scan.get("reason_code") or "AI_MIGRATION_PACKAGE_SCAN_FAILED")
            if reason_code not in failure_reason_codes:
                failure_reason_codes.append(reason_code)
    result["artifacts"] = copied
    result["package_scan"] = {
        "attempt": scan_attempt,
        "status": "FAILED" if failed else ("NEEDS_FIX" if needs_fix else "SUCCESS"),
        "results": scan_results,
        "findings": all_findings,
        "failure_reason_codes": failure_reason_codes,
    }
    if failed:
        if "AI_MIGRATION_PACKAGE_SCAN_FAILED" in failure_reason_codes:
            failure_reason = "AI_MIGRATION_PACKAGE_SCAN_FAILED"
            failure_message = "ai-migration package scan command failed; see logs/ai-migration-package.log."
        elif "AI_MIGRATION_PACKAGE_ZH_CSV_REPORT_MISSING" in failure_reason_codes:
            failure_reason = "AI_MIGRATION_PACKAGE_ZH_CSV_REPORT_MISSING"
            failure_message = "ai-migration package scan returned non-zero but did not produce a *_zh.csv report."
        elif "AI_MIGRATION_CSV_REPORT_INVALID" in failure_reason_codes:
            failure_reason = "AI_MIGRATION_CSV_REPORT_INVALID"
            failure_message = "ai-migration package scan produced an invalid CSV report."
        else:
            failure_reason = failure_reason_codes[0] if failure_reason_codes else "AI_MIGRATION_PACKAGE_SCAN_FAILED"
            failure_message = "ai-migration package scan failed; see package_scan.results for details."
        result.update({
            "status": "FAILED",
            "stage": "PACKAGE_SCAN",
            "reason_code": failure_reason,
            "message": failure_message,
        })
        write_json(result_path, result)
        return EXIT_FAILED
    if needs_fix:
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "PACKAGE_SCAN",
            "reason_code": "AI_MIGRATION_PACKAGE_FIX_REQUIRED",
            "message": "ai-migration package scan returned a non-zero code. Fix source code or dependencies according to the Chinese CSV package scan report, rebuild, and rerun.",
            "action_required": {
                "type": "FIX_PACKAGE_COMPATIBILITY",
                "resume_stage": "build",
                "artifacts": copied,
                "scan_results": [item for item in scan_results if item.get("status") == "NEEDS_FIX"],
                "findings": all_findings,
            },
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

    arch_command = "uname -m"
    arch_proc = run_shell(
        arch_command,
        cwd=work_source,
        log_path=work_dir / "logs" / "verification.log",
        check=False,
        timeout=300,
    )
    architecture = (arch_proc.stdout or "").strip().splitlines()
    architecture_value = architecture[-1].strip().lower() if architecture else ""
    architecture_status = (
        "SUCCESS"
        if arch_proc.returncode == 0 and architecture_value in {"aarch64", "arm64"}
        else "NOT_VERIFIED"
    )

    verification = {
        "architecture": {
            "status": architecture_status,
            "command": arch_command,
            "value": architecture_value,
            "exit_code": arch_proc.returncode,
        }
    }

    actions = []
    sql_action = sql_completion_action(result)
    if sql_action:
        actions.append(sql_action)
    if architecture_status != "SUCCESS":
        actions.append({
            "type": "ARM64_VERIFICATION_REQUIRED",
            "architecture": architecture_value,
            "message": "Run the Skill in an ARM64 environment and execute it again to complete architecture verification.",
        })

    compatibility = result.get("compatibility") if isinstance(result.get("compatibility"), dict) else {}
    compatibility_patch = compatibility.get("source_patch") if isinstance(compatibility.get("source_patch"), dict) else {}
    sql = result.get("sql_migration") if isinstance(result.get("sql_migration"), dict) else {}
    sql_patch_path = Path(str(sql.get("patch_file") or "")) if str(sql.get("patch_file") or "") else None
    final_patch = write_git_worktree_patch(work_source, work_dir / "reports" / "final-source-changes.patch")
    patches = {
        "source_compatibility": compatibility_patch or {
            "path": str(work_dir / "reports" / "source-compatibility.patch"),
            "sha256": "",
            "size": 0,
            "changed_files": [],
        },
        "sql_source_changes": {
            "path": str(sql_patch_path) if sql_patch_path else "",
            "sha256": sha256_file(sql_patch_path) if sql_patch_path and sql_patch_path.is_file() else "",
            "size": sql_patch_path.stat().st_size if sql_patch_path and sql_patch_path.is_file() else 0,
        },
        "final_source_changes": final_patch,
    }

    compatibility_suggestions = compatibility.get("suggestion_items") if isinstance(compatibility.get("suggestion_items"), list) else []
    source_scan_notice = {
        "rule_count": int(compatibility.get("rule_count") or 0),
        "suggestion_count": int(compatibility.get("suggestion_count") or 0),
        "suggestions_require_fix": False,
        "message": "DevKit suggestion items are informational only and do not require source repair.",
        "reports": compatibility.get("reports") or [],
        "suggestion_items": compatibility_suggestions,
    }

    # clear_current_error removes any stale action_required from earlier stages.
    # Rebuild the final action contract from completion_actions immediately
    # afterwards so COMPLETED_WITH_ACTIONS can never coexist with null actions.
    clear_current_error(result)
    result["verification"] = verification
    result["completion_actions"] = actions
    if not actions:
        result.pop("action_required", None)
    elif len(actions) == 1:
        result["action_required"] = actions[0]
    else:
        result["action_required"] = {
            "type": "MIGRATION_COMPLETION_ACTIONS_REQUIRED",
            "requires_action": True,
            "actions": actions,
        }
    result["patches"] = patches
    result["result_summary"] = {
        "source_compatibility_patch": patches["source_compatibility"].get("path") or "",
        "sql_source_patch": patches["sql_source_changes"].get("path") or "",
        "final_source_patch": patches["final_source_changes"].get("path") or "",
        "source_scan_advisories": source_scan_notice,
        "artifacts": [item.get("output") for item in artifacts if isinstance(item, dict) and item.get("output")],
    }
    result.update({
        "status": "SUCCESS" if not actions else "COMPLETED_WITH_ACTIONS",
        "stage": "COMPLETE",
        "reason_code": "" if not actions else "JAVA_SOURCE_MIGRATION_ACTIONS_REQUIRED",
        "message": "" if not actions else "Migration stages completed, but completion actions remain and are listed in action_required.",
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
