#!/usr/bin/env python3
"""Top-level controller for Java source ARM64 migration.

The controller keeps one durable workflow and delegates implementation to two
sub-Skills:
- java-source-migration: prepare/inspect/baseline/compatibility/sql
- java-build-verification: build/package_scan/verify
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
SOURCE_SCRIPTS = SKILL_DIR / "java-source-migration" / "scripts"
BUILD_SCRIPTS = SKILL_DIR / "java-build-verification" / "scripts"
for path in (SCRIPT_DIR, SOURCE_SCRIPTS, BUILD_SCRIPTS):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

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

def resolve_paths(source_value: str, work_base_value: str | None) -> tuple[Path, Path, Path, Path, dict[str, Any]]:
    metadata = prepare(source_value, work_base_value, emit=False)
    source = Path(str(metadata["source"])).resolve()
    work_dir = Path(str(metadata["work_dir"])).resolve()
    work_source = Path(str(metadata["work_source"])).resolve()
    result_path = work_dir / "migration-result.json"
    if result_path.is_file():
        result = load_json(result_path)
    else:
        result = base_result(source, work_dir, work_source)
        write_json(result_path, result)
    return source, work_dir, work_source, result_path, result
def update_config(work_dir: Path, args: argparse.Namespace) -> dict[str, Any]:
    config = load_config(work_dir)
    pairs = {
        "build_command": args.build_command,
        "devkit_command": args.devkit_command,
        "source_db": args.source_db,
        "target_db": args.target_db,
        "verify_command": args.verify_command,
        "architecture_command": args.architecture_command,
    }
    for key, value in pairs.items():
        if value is not None and str(value).strip():
            config[key] = str(value).strip()
    if args.skip_sql:
        config["skip_sql"] = True
        config.pop("source_db", None)
        config.pop("target_db", None)
    if args.enable_sql:
        config["skip_sql"] = False
    config.setdefault("created_at", now_iso())
    config["updated_at"] = now_iso()
    write_json(config_path(work_dir), config)
    return config
def run_stage(
    stage: str,
    source: Path,
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
                    "RUNTIME_VERIFICATION_REQUIRED",
                    "RUNTIME_VERIFICATION_FAILED",
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
            "WAITING_FOR_SKILL": "SQL_SKILL",
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

def infer_resume_stage(result: dict[str, Any]) -> str:
    state = workflow(result)
    candidate = str(state.get("next_stage") or "").strip().lower()
    if candidate in STAGES:
        return candidate
    if str(result.get("stage") or "").upper() == "COMPLETE":
        return ""
    return "prepare"
def run_auto(
    source: Path,
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    config: dict[str, Any],
) -> int:
    result = load_json(result_path)
    stage = infer_resume_stage(result)
    if not stage:
        print(json.dumps({
            "status": result.get("status"),
            "stage": result.get("stage"),
            "result_file": str(result_path),
            "workflow": result.get("workflow") or {},
        }, ensure_ascii=False, indent=2))
        return EXIT_OK
    while stage:
        code = run_stage(stage, source, work_dir, work_source, result_path, config)
        result = load_json(result_path)
        if code != EXIT_OK:
            print(json.dumps({
                "status": result.get("status"),
                "stage": result.get("stage"),
                "reason_code": result.get("reason_code"),
                "result_file": str(result_path),
                "workflow": result.get("workflow") or {},
                "action_required": result.get("action_required"),
                "sql_skill": result.get("sql_skill"),
            }, ensure_ascii=False, indent=2))
            return code
        if stage == "verify":
            break
        stage = infer_resume_stage(result)
    result = load_json(result_path)
    print(json.dumps({
        "status": result.get("status"),
        "stage": result.get("stage"),
        "result_file": str(result_path),
        "workflow": result.get("workflow") or {},
        "artifacts": result.get("artifacts") or [],
        "verification": result.get("verification") or {},
        "completion_actions": result.get("completion_actions") or [],
    }, ensure_ascii=False, indent=2))
    return EXIT_OK
def main() -> int:
    parser = argparse.ArgumentParser(description="Run or resume Java source ARM64 migration.")
    parser.add_argument("--source", required=True, help="Local Java project directory")
    parser.add_argument("--work-base", help="Workspace root")
    parser.add_argument("--stage", choices=STAGES + [AUTO_STAGE], default=AUTO_STAGE)
    parser.add_argument("--build-command", help="Project baseline/final build command")
    parser.add_argument("--devkit-command", help="DevKit CLI command/path")
    parser.add_argument("--source-db", help="Source database type when SQL adaptation is required")
    parser.add_argument("--target-db", help="Target database type when SQL adaptation is required")
    parser.add_argument("--skip-sql", action="store_true", help="Record SQL adaptation as not applicable")
    parser.add_argument("--enable-sql", action="store_true", help="Clear a previously recorded skip-sql setting")
    parser.add_argument("--verify-command", help="Runtime/acceptance verification command on ARM64")
    parser.add_argument("--architecture-command", help="Architecture check command; defaults to uname -m")
    args = parser.parse_args()

    source, work_dir, work_source, result_path, _result = resolve_paths(args.source, args.work_base)
    config = update_config(work_dir, args)
    if args.stage == AUTO_STAGE:
        return run_auto(source, work_dir, work_source, result_path, config)
    code = run_stage(args.stage, source, work_dir, work_source, result_path, config)
    result = load_json(result_path)
    print(json.dumps({
        "status": result.get("status"),
        "stage": result.get("stage"),
        "reason_code": result.get("reason_code"),
        "result_file": str(result_path),
        "workflow": result.get("workflow") or {},
    }, ensure_ascii=False, indent=2))
    return code

if __name__ == "__main__":
    sys.exit(main())
