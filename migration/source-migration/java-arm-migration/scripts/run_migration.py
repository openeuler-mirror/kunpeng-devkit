#!/usr/bin/env python3
"""Top-level controller for Java source ARM64 migration."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent

from migration_common import (
    EXIT_FAILED, EXIT_NEEDS_FIX, EXIT_OK, MigrationError,
    config_path, load_config, load_json, now_iso, write_json,
)
from prepare_workspace import prepare
import source_migration
import build_verification

SOURCE_STAGES = ["prepare", "inspect", "baseline", "compatibility", "sql"]
BUILD_STAGES = ["build", "package_scan", "verify"]
STAGES = SOURCE_STAGES + BUILD_STAGES
AUTO_STAGE = "auto"

def base_result(source: Path, work_dir: Path, work_source: Path) -> dict[str, Any]:
    return {
        "source": str(source),
        "work_dir": str(work_dir),
        "work_source": str(work_source),
        "status": "IN_PROGRESS",
        "stage": "INIT",
        "reason_code": "",
        "message": "",
        "project": {},
        "baseline": {},
        "compatibility": {},
        "sql_migration": {},
        "build": {},
        "artifacts": [],
        "package_scan": {},
        "verification": {},
        "completion_actions": [],
        "workflow": {
            "phase": "SOURCE_MIGRATION",
            "current_stage": "INIT",
            "last_completed_stage": "",
            "next_stage": "prepare",
            "waiting_for": "",
        },
    }
def workflow(result: dict[str, Any]) -> dict[str, Any]:
    value = result.get("workflow")
    if not isinstance(value, dict):
        value = {}
        result["workflow"] = value
    value.setdefault("phase", "SOURCE_MIGRATION")
    value.setdefault("current_stage", "INIT")
    value.setdefault("last_completed_stage", "")
    value.setdefault("next_stage", "prepare")
    value.setdefault("waiting_for", "")
    return value
def stage_after(stage: str) -> str:
    try:
        index = STAGES.index(stage)
    except ValueError:
        return "prepare"
    if index + 1 >= len(STAGES):
        return ""
    return STAGES[index + 1]
def stage_phase(stage: str) -> str:
    if stage in SOURCE_STAGES:
        return "SOURCE_MIGRATION"
    if stage in BUILD_STAGES:
        return "BUILD_VERIFICATION"
    return ""


def save_workflow(
    result_path: Path,
    *,
    stage: str,
    next_stage: str,
    waiting_for: str = "",
    completed: bool = False,
) -> dict[str, Any]:
    result = load_json(result_path)
    state = workflow(result)
    state["phase"] = stage_phase(stage) or state.get("phase") or "SOURCE_MIGRATION"
    state["current_stage"] = stage
    state["next_stage"] = next_stage
    state["waiting_for"] = waiting_for
    if completed:
        state["last_completed_stage"] = stage
    write_json(result_path, result)
    return result

def resolve_paths(source_value: str) -> tuple[Path, Path, Path, dict[str, Any]]:
    metadata = prepare(source_value, emit=False)
    source = Path(str(metadata["source"])).resolve()
    work_dir = Path(str(metadata["work_dir"])).resolve()
    work_source = Path(str(metadata["work_source"])).resolve()
    result_path = work_dir / "migration-result.json"
    if result_path.is_file():
        result = load_json(result_path)
    else:
        result = base_result(source, work_dir, work_source)
        write_json(result_path, result)
    return work_dir, work_source, result_path, result
def update_config(work_dir: Path, args: argparse.Namespace) -> dict[str, Any]:
    """Persist explicit SQL-route inputs without silently inheriting legacy skip flags."""
    config = load_config(work_dir)

    # Remove legacy externally configurable values from earlier Skill versions.
    # build_command is retained only when it was auto-detected by the inspect stage.
    if str(config.get("build_command_source") or "").strip().lower() != "detected":
        config.pop("build_command", None)
        config.pop("build_command_source", None)
    for key in ("ai_migration_command", "verify_command", "architecture_command"):
        config.pop(key, None)

    # csv4/csv5 persisted skip_sql in migration-config.json.  That can silently
    # skip the mandatory SQL-route decision on a later invocation.  Route
    # decisions now live only in database-route.json or explicit CLI inputs.
    config.pop("skip_sql", None)
    config.pop("source_db", None)
    config.pop("target_db", None)
    route_file = work_dir / "database-route.json"

    if args.enable_sql and route_file.is_file():
        route = load_json(route_file)
        if str(route.get("decision") or "").upper() == "SKIP":
            route_file.unlink()

    if args.skip_sql:
        config.pop("source_db", None)
        config.pop("target_db", None)
        write_json(route_file, {
            "decision": "SKIP",
            "source_db": "",
            "target_db": "",
            "updated_at": now_iso(),
        })
    elif args.source_db and args.target_db:
        source_db = str(args.source_db).strip()
        target_db = str(args.target_db).strip()
        write_json(route_file, {
            "decision": "SKIP" if source_db.lower() == target_db.lower() else "MIGRATE",
            "source_db": source_db,
            "target_db": target_db,
            "updated_at": now_iso(),
        })

    config.setdefault("created_at", now_iso())
    config["updated_at"] = now_iso()
    write_json(config_path(work_dir), config)
    return config
def run_stage(
    stage: str,
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    config: dict[str, Any],
) -> int:
    result = load_json(result_path)
    save_workflow(result_path, stage=stage, next_stage=stage, waiting_for="")
    try:
        if stage in SOURCE_STAGES:
            code = source_migration.run_stage(
                stage, work_dir, work_source, result_path, result, config
            )
        elif stage in BUILD_STAGES:
            code = build_verification.run_stage(
                stage, work_dir, work_source, result_path, result, config
            )
        else:
            raise MigrationError("INVALID_STAGE", "Unknown stage: %s" % stage)
    except MigrationError as exc:
        result = load_json(result_path)
        result.update({
            "status": exc.status,
            "stage": stage.upper(),
            "reason_code": exc.code,
            "message": str(exc),
        })
        write_json(result_path, result)
        code = EXIT_NEEDS_FIX if exc.status == "NEEDS_AGENT_FIX" else EXIT_FAILED

    result = load_json(result_path)
    if code == EXIT_OK:
        if stage == "verify":
            verified = load_json(result_path)
            retry_verify = any(
                str(item.get("type") or "") in {
                    "ARM64_VERIFICATION_REQUIRED",
                }
                for item in (verified.get("completion_actions") or [])
                if isinstance(item, dict)
            )
            save_workflow(
                result_path,
                stage=stage,
                next_stage="verify" if retry_verify else "",
                waiting_for="",
                completed=True,
            )
        else:
            save_workflow(
                result_path,
                stage=stage,
                next_stage=stage_after(stage),
                waiting_for="",
                completed=True,
            )
    else:
        waiting_map = {
            "WAITING_FOR_SQL": "SQL_MIGRATION",
            "WAITING_FOR_USER": "USER_DECISION",
            "NEEDS_AGENT_FIX": "AGENT_FIX",
            "BLOCKED": "BLOCKED",
            "FAILED": "FAILED",
        }
        waiting_for = waiting_map.get(str(result.get("status") or "").upper(), "")
        next_stage = stage
        if stage == "package_scan" and str(result.get("status") or "").upper() == "NEEDS_AGENT_FIX":
            next_stage = "build"
        save_workflow(
            result_path,
            stage=stage,
            next_stage=next_stage,
            waiting_for=waiting_for,
            completed=False,
        )
    return code

def print_result(result_path: Path, *, final: bool = False) -> None:
    result = load_json(result_path)
    payload = {
        "status": result.get("status"),
        "stage": result.get("stage"),
        "reason_code": result.get("reason_code"),
        "result_file": str(result_path),
        "workflow": result.get("workflow") or {},
        "action_required": result.get("action_required"),
        "sql_migration": result.get("sql_migration") or {},
    }
    if result.get("sql_skill") is not None:
        payload["sql_skill"] = result.get("sql_skill")
    if final:
        payload.update({
            "artifacts": result.get("artifacts") or [],
            "verification": result.get("verification") or {},
            "completion_actions": result.get("completion_actions") or [],
            "patches": result.get("patches") or {},
            "result_summary": result.get("result_summary") or {},
        })
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def infer_resume_stage(result: dict[str, Any]) -> str:
    state = workflow(result)
    candidate = str(state.get("next_stage") or "").strip().lower()
    if candidate in STAGES:
        return candidate
    if str(result.get("stage") or "").upper() == "COMPLETE":
        return ""
    return "prepare"
def run_auto(
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    config: dict[str, Any],
) -> int:
    # Reconcile a completed task-scoped SQL result before choosing the next
    # auto stage. This is the durable fallback when the detached SQL watcher
    # was lost or the host interrupted it.
    source_migration.reconcile_sql_handoff(work_dir, result_path)
    result = load_json(result_path)
    stage = infer_resume_stage(result)
    if not stage:
        print_result(result_path, final=True)
        return EXIT_OK
    while stage:
        code = run_stage(stage, work_dir, work_source, result_path, config)
        result = load_json(result_path)
        if code != EXIT_OK:
            print_result(result_path)
            return code
        if stage == "verify":
            break
        stage = infer_resume_stage(result)
    print_result(result_path, final=True)
    return EXIT_OK


def _require_stage_prerequisite(condition: bool, code: str, message: str) -> None:
    if not condition:
        raise MigrationError(code, message, status="BLOCKED")


COMPATIBILITY_PASS_STATUSES = {"SUCCESS", "SUCCESS_WITH_SUGGESTIONS"}


def compatibility_stage_passed(compatibility: dict[str, Any]) -> bool:
    """Whether compatibility has no mandatory rule fixes."""
    return str(compatibility.get("status") or "").upper() in COMPATIBILITY_PASS_STATUSES


def validate_explicit_stage_entry(stage: str, work_dir: Path, result: dict[str, Any], config: dict[str, Any]) -> None:
    """Validate that an explicitly requested stage cannot bypass required predecessors."""
    if stage in {"prepare", "inspect"}:
        return

    project = result.get("project") if isinstance(result.get("project"), dict) else {}
    baseline = result.get("baseline") if isinstance(result.get("baseline"), dict) else {}
    compatibility = result.get("compatibility") if isinstance(result.get("compatibility"), dict) else {}
    build = result.get("build") if isinstance(result.get("build"), dict) else {}
    package_scan = result.get("package_scan") if isinstance(result.get("package_scan"), dict) else {}
    artifacts = result.get("artifacts") if isinstance(result.get("artifacts"), list) else []
    build_command = str(config.get("build_command") or "").strip()
    build_command_source = str(config.get("build_command_source") or "").strip().lower()

    if stage == "baseline":
        _require_stage_prerequisite(
            bool(project) and bool(build_command) and build_command_source == "detected",
            "STAGE_BASELINE_INSPECT_NOT_READY",
            "--stage baseline requires the inspect stage to have detected the project build entry first.",
        )
        return

    if stage in {"compatibility", "sql", "build", "package_scan", "verify"}:
        _require_stage_prerequisite(
            str(baseline.get("status") or "").upper() == "SUCCESS" and bool(build_command),
            "STAGE_BASELINE_NOT_READY",
            "--stage %s requires a successful baseline build from the same migration workspace." % stage,
        )

    if stage in {"sql", "build", "package_scan", "verify"}:
        _require_stage_prerequisite(
            compatibility_stage_passed(compatibility),
            "STAGE_COMPATIBILITY_NOT_READY",
            "--stage %s requires source compatibility scanning to have passed first." % stage,
        )

    if stage in {"package_scan", "verify"}:
        _require_stage_prerequisite(
            str(build.get("status") or "").upper() == "SUCCESS",
            "STAGE_BUILD_NOT_READY",
            "--stage %s requires a successful final build first." % stage,
        )
        # Prevent a stale build/artifact from being reused after the SQL route was changed.
        build_verification.require_sql_route_consistency(work_dir, result, config)

    if stage == "verify":
        _require_stage_prerequisite(
            str(package_scan.get("status") or "").upper() == "SUCCESS" and bool(artifacts),
            "STAGE_PACKAGE_SCAN_NOT_READY",
            "--stage verify requires a successful package scan and recorded final artifacts first.",
        )


def run_from_stage(
    start_stage: str,
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    config: dict[str, Any],
) -> int:
    """Start/resume from one explicit stage and continue through later stages.

    Explicit stages are guarded resume points, not unconditional jumps.  In
    particular, --stage build first executes the SQL handoff gate so that an
    external sql-migration result is validated and source_code.patch is applied
    before the final build starts.
    """
    result = load_json(result_path)
    try:
        validate_explicit_stage_entry(start_stage, work_dir, result, config)
    except MigrationError as exc:
        result.update({
            "status": exc.status,
            "stage": start_stage.upper(),
            "reason_code": exc.code,
            "message": str(exc),
        })
        write_json(result_path, result)
        print_result(result_path)
        return EXIT_FAILED

    # BUILD is a common resume point after the independent SQL Skill.  Re-enter
    # the SQL stage once as an idempotent handoff gate before actually building.
    if start_stage == "build":
        code = run_stage("sql", work_dir, work_source, result_path, config)
        if code != EXIT_OK:
            print_result(result_path)
            return code

    stage = start_stage
    while stage:
        code = run_stage(stage, work_dir, work_source, result_path, config)
        result = load_json(result_path)
        if code != EXIT_OK:
            print_result(result_path)
            return code
        if stage == "verify":
            break
        stage = infer_resume_stage(result)

    print_result(result_path, final=True)
    return EXIT_OK

def main() -> int:
    parser = argparse.ArgumentParser(description="Run or resume Java source ARM64 migration.")
    parser.add_argument("--source", required=True, help="Local Java project directory")
    parser.add_argument(
        "--stage",
        choices=[AUTO_STAGE] + STAGES,
        default=AUTO_STAGE,
        help="Start/resume from a workflow stage and continue automatically; default: auto",
    )
    parser.add_argument("--source-db", help="Source database type when SQL adaptation is required")
    parser.add_argument("--target-db", help="Target database type when SQL adaptation is required")
    parser.add_argument("--skip-sql", action="store_true", help="Record SQL adaptation as not applicable")
    parser.add_argument("--enable-sql", action="store_true", help="Clear a previously recorded skip-sql setting")
    args = parser.parse_args()

    if args.skip_sql and args.enable_sql:
        parser.error("--skip-sql and --enable-sql cannot be used together")
    if bool(args.source_db) != bool(args.target_db):
        parser.error("--source-db and --target-db must be provided together")
    if args.skip_sql and (args.source_db or args.target_db):
        parser.error("--skip-sql cannot be combined with --source-db/--target-db")

    work_dir, work_source, result_path, _result = resolve_paths(args.source)
    config = update_config(work_dir, args)
    if args.stage != AUTO_STAGE:
        return run_from_stage(args.stage, work_dir, work_source, result_path, config)
    return run_auto(work_dir, work_source, result_path, config)

if __name__ == "__main__":
    sys.exit(main())
