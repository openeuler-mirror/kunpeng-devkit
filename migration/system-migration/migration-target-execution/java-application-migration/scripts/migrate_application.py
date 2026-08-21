#!/usr/bin/env python3
"""Java JAR/WAR application migration controller.

The controller owns workflow state, deterministic stage dispatch, wait boundaries and resume routing. Concrete migration stages live under ``scripts/stages``.
Application startup verification is intentionally not a script stage: after
repackage the component waits for Agent-level verification defined in java-application-migration.md.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from component_context import binary_execution_context
from migration_common import (
    EXIT_FAILED,
    EXIT_NEEDS_AGENT_FIX,
    EXIT_OK,
    EXIT_WAITING_FOR_AGENT,
    EXIT_WAITING_FOR_SKILL,
    EXIT_WAITING_FOR_USER,
    MigrationError,
    load_json,
)
from component_context import base_result, save
from stages import compile as compile_stage
from stages import compatibility as compatibility_stage
from stages import decompile as decompile_stage
from stages import prepare as prepare_stage
from stages import repackage as repackage_stage
from stages import sql as sql_stage
from verification_result import consume as consume_verification_result

STAGES = ["prepare", "compatibility", "decompile", "sql", "compile", "repackage"]
AUTO_STAGE = "auto"


def _stage_after(stage: str) -> str:
    try:
        index = STAGES.index(stage)
    except ValueError:
        return "prepare"
    return STAGES[index + 1] if index + 1 < len(STAGES) else ""


def _workflow(result: dict[str, Any]) -> dict[str, Any]:
    value = result.get("workflow")
    if not isinstance(value, dict):
        value = {}
        result["workflow"] = value
    value.setdefault("current_stage", "INIT")
    value.setdefault("last_completed_stage", "")
    value.setdefault("next_stage", "")
    value.setdefault("waiting_for", "")
    value.setdefault("resume", {})
    return value


def _infer_resume_stage(result: dict[str, Any]) -> str:
    if str(result.get("status") or "").upper() == "WAITING_FOR_AGENT":
        return ""
    workflow = _workflow(result)
    next_stage = str(workflow.get("next_stage") or "").strip().lower()
    if next_stage in STAGES:
        return next_stage
    if str(result.get("stage") or "").upper() == "COMPLETE":
        return ""
    stage_map = {
        "PREPARE": "compatibility",
        "COMPATIBILITY": "decompile",
        "DECOMPILE": "sql",
        "SQL_MIGRATION": "sql" if str(result.get("status") or "").upper().startswith("WAITING") else "compile",
        "SQL_MIGRATION_CONFIRMATION": "sql",
        "COMPILE": "repackage",
        "REPACKAGE": "",
        "APPLICATION_VERIFICATION": "",
    }
    return stage_map.get(str(result.get("stage") or "").upper(), "prepare")


def _resume_context(plan_path: Path, application_id: str, package_id: str, resume_stage: str) -> dict[str, Any]:
    return {
        "skill": "java-application-migration",
        "entry": "java-application-migration/scripts/migrate_application.py",
        "mode": "auto",
        "resume_stage": resume_stage,
        "arguments": {
            "plan": str(plan_path.resolve()),
            "application_id": application_id,
            "package_id": package_id,
            "stage": "auto",
        },
        "routing": "RESUME_CURRENT_COMPONENT",
    }


def _save_workflow(
    result_path: Path,
    *,
    current_stage: str,
    next_stage: str,
    waiting_for: str = "",
    completed: bool = False,
    resume: dict[str, Any] | None = None,
) -> dict[str, Any]:
    result = load_json(result_path) if result_path.is_file() else {}
    workflow = _workflow(result)
    workflow["current_stage"] = current_stage
    workflow["next_stage"] = next_stage
    workflow["waiting_for"] = waiting_for
    workflow["resume"] = dict(resume or {})
    if completed:
        workflow["last_completed_stage"] = current_stage
    save(result_path, result)
    return result


STAGE_FUNCTIONS = {
    "prepare": prepare_stage.run,
    "compatibility": compatibility_stage.run,
    "decompile": decompile_stage.run,
    "sql": sql_stage.run,
    "compile": compile_stage.run,
    "repackage": repackage_stage.run,
}


def _mark_agent_verification_boundary(
    plan_path: Path,
    application_id: str,
    package_id: str,
    result_path: Path,
) -> None:
    input_data = binary_execution_context(plan_path, application_id, package_id)
    result = load_json(result_path)
    output_package = str(result.get("output_package") or "")
    artifact_report = result.get("artifact_change_report") or {}
    app_context = input_data.get("application") or {}
    result.update({
        "status": "WAITING_FOR_AGENT",
        "stage": "APPLICATION_VERIFICATION",
        "reason_code": "VERIFY_APPLICATION_STARTUP",
        "verification": {
            "status": "WAITING_FOR_AGENT",
            "scope": "TARGET_APPLICATION_STARTUP",
            "evidence": [],
        },
        "action_required": {
            "type": "VERIFY_APPLICATION_STARTUP",
            "orchestrator": "AGENT",
            "instruction_source": "java-application-migration/java-application-migration.md#应用启动验证agent编排",
            "plan": str(plan_path.resolve()),
            "application_id": application_id,
            "package_id": package_id,
            "output_package": output_package,
            "artifact_change_report": artifact_report,
            "deployment_reference": {
                "product": app_context.get("product"),
                "version": app_context.get("version"),
                "install_location": app_context.get("install_location"),
            },
            "required_checks": [
                "TARGET_ARCHITECTURE",
                "DEPLOYMENT_METHOD",
                "APPLICATION_STARTUP",
                "PROCESS_OR_SERVICE",
                "PORT_OR_HEALTH",
                "STARTUP_LOG",
            ],
            "conditional_checks": ["DATABASE_CONNECTIVITY_OR_SQL_SMOKE"],
            "success_condition": "Application starts successfully on the target ARM64 environment and startup evidence is recorded.",
            "verification_result_file": "reports/application-verification-result.json",
            "verification_result_statuses": ["SUCCESS", "NEEDS_AGENT_FIX", "BLOCKED"],
            "verification_result_required_fields": ["status", "summary"],
            "stop_conditions": [
                "REQUIRED_RUNTIME_MISSING_AFTER_AUTHORITATIVE_CONTEXT_AND_ONE_TARGETED_PROBE",
                "APPLICATION_STARTUP_FAILURE_IDENTIFIED",
                "DEPLOYMENT_METHOD_UNKNOWN_AFTER_BOUNDED_DISCOVERY",
                "SUFFICIENT_EVIDENCE_FOR_FINAL_STATUS",
            ],
            "max_runtime_dependency_probe_rounds": 1,
            "after_verification_result": "RESUME_CURRENT_COMPONENT",
        },
    })
    completion = result.get("migration_completion")
    if not isinstance(completion, dict):
        completion = {}
        result["migration_completion"] = completion
    completion.setdefault("static_migration", {"status": "SUCCESS", "artifact_ready": bool(output_package)})
    completion["target_environment_verification"] = {"status": "NOT_VERIFIED"}
    save(result_path, result)


def _normalized_exit_code(code: int, result: dict[str, Any]) -> int:
    status = str(result.get("status") or "").upper()
    if status == "WAITING_FOR_SKILL":
        return EXIT_WAITING_FOR_SKILL
    if status == "WAITING_FOR_USER":
        return EXIT_WAITING_FOR_USER
    if status == "WAITING_FOR_AGENT":
        return EXIT_WAITING_FOR_AGENT
    if status == "NEEDS_AGENT_FIX":
        return EXIT_NEEDS_AGENT_FIX
    return code


def _waiting_for_result(code: int, result: dict[str, Any]) -> str:
    status = str(result.get("status") or "").upper()
    reason = str(result.get("reason_code") or "")
    if status == "WAITING_FOR_SKILL":
        return "SQL_SKILL"
    if status == "WAITING_FOR_USER":
        return "USER_DECISION"
    if status == "WAITING_FOR_AGENT":
        return "AGENT_VERIFICATION"
    if status == "NEEDS_AGENT_FIX":
        return "AGENT_FIX"
    if status == "BLOCKED":
        return "BLOCKED"
    if code == EXIT_WAITING_FOR_SKILL:
        return "SQL_SKILL"
    if code == EXIT_WAITING_FOR_USER:
        return "USER_DECISION"
    if code == EXIT_WAITING_FOR_AGENT:
        return "AGENT_VERIFICATION"
    if code == EXIT_NEEDS_AGENT_FIX:
        return "AGENT_FIX"
    return "FAILED"


def run_stage(stage: str, plan_path: Path, application_id: str, package_id: str) -> int:
    input_data = binary_execution_context(plan_path, application_id, package_id)
    work_dir = Path(str(input_data["work_dir"])).expanduser().resolve()
    result_path = work_dir / "migration-result.json"
    if not result_path.is_file():
        save(result_path, base_result(input_data))
    _save_workflow(result_path, current_stage=stage, next_stage=stage, waiting_for="")
    current = load_json(result_path)
    current.pop("action_required", None)
    save(result_path, current)

    code = STAGE_FUNCTIONS[stage](plan_path, application_id, package_id)
    if stage == "repackage" and code == EXIT_OK:
        _mark_agent_verification_boundary(plan_path, application_id, package_id, result_path)
        code = EXIT_WAITING_FOR_AGENT

    result = load_json(result_path) if result_path.is_file() else {}
    code = _normalized_exit_code(code, result)
    if code == EXIT_OK:
        _save_workflow(
            result_path,
            current_stage=stage,
            next_stage=_stage_after(stage),
            waiting_for="",
            completed=True,
            resume=None,
        )
        return code

    waiting_for = _waiting_for_result(code, result)
    resume = None
    if waiting_for in {"SQL_SKILL", "USER_DECISION", "AGENT_FIX", "AGENT_VERIFICATION"}:
        resume = _resume_context(plan_path, application_id, package_id, stage)
        waiting_result = load_json(result_path) if result_path.is_file() else {}
        action_required = waiting_result.get("action_required")
        if not isinstance(action_required, dict):
            action_required = {"type": "EXTERNAL_ACTION_REQUIRED"}
        action_required["resume"] = resume
        waiting_result["action_required"] = action_required
        save(result_path, waiting_result)

    _save_workflow(
        result_path,
        current_stage=stage,
        next_stage="" if waiting_for == "AGENT_VERIFICATION" else stage,
        waiting_for=waiting_for,
        completed=waiting_for == "AGENT_VERIFICATION",
        resume=resume,
    )
    return code


def _result_summary(result: dict[str, Any], result_path: Path) -> dict[str, Any]:
    return {
        "status": result.get("status"),
        "stage": result.get("stage"),
        "reason_code": result.get("reason_code"),
        "workflow": result.get("workflow") or {},
        "sql_skill": result.get("sql_skill"),
        "action_required": result.get("action_required"),
        "output_package": result.get("output_package"),
        "artifact_change_report": result.get("artifact_change_report") or {},
        "source_change_summary": result.get("source_change_summary") or {},
        "migration_completion": result.get("migration_completion") or {},
        "result_file": str(result_path),
    }


def run_auto(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data = binary_execution_context(plan_path, application_id, package_id)
    work_dir = Path(str(input_data["work_dir"])).expanduser().resolve()
    result_path = work_dir / "migration-result.json"
    result = load_json(result_path) if result_path.is_file() else base_result(input_data)
    if not result_path.is_file():
        save(result_path, result)
    if (
        str(result.get("stage") or "").upper() == "APPLICATION_VERIFICATION"
        and str(result.get("status") or "").upper() in {"WAITING_FOR_AGENT", "NEEDS_AGENT_FIX", "BLOCKED"}
    ):
        if consume_verification_result(result_path, work_dir):
            result = load_json(result_path)
    stage = _infer_resume_stage(result)
    if not stage:
        print(json.dumps(_result_summary(result, result_path), ensure_ascii=False, indent=2))
        status = str(result.get("status") or "").upper()
        if status == "WAITING_FOR_AGENT":
            return EXIT_WAITING_FOR_AGENT
        if status == "WAITING_FOR_USER":
            return EXIT_WAITING_FOR_USER
        if status == "NEEDS_AGENT_FIX":
            return EXIT_NEEDS_AGENT_FIX
        if status in {"FAILED", "BLOCKED"}:
            return EXIT_FAILED
        return EXIT_OK

    while stage:
        code = run_stage(stage, plan_path, application_id, package_id)
        result = load_json(result_path) if result_path.is_file() else {}
        workflow = result.get("workflow") or {}
        if code == EXIT_OK:
            stage = str(workflow.get("next_stage") or "").strip().lower()
            continue
        print(json.dumps(_result_summary(result, result_path), ensure_ascii=False, indent=2))
        return code

    result = load_json(result_path) if result_path.is_file() else {}
    print(json.dumps(_result_summary(result, result_path), ensure_ascii=False, indent=2))
    return EXIT_OK


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--application-id", required=True)
    parser.add_argument("--package-id", required=True)
    parser.add_argument("--stage", choices=[AUTO_STAGE] + STAGES, default=AUTO_STAGE)
    args = parser.parse_args()
    plan_path = Path(args.plan).expanduser().resolve()
    try:
        if args.stage == AUTO_STAGE:
            return run_auto(plan_path, args.application_id, args.package_id)
        return run_stage(args.stage, plan_path, args.application_id, args.package_id)
    except (MigrationError, ValueError, FileNotFoundError) as exc:
        print(json.dumps({"status": "FAILED", "reason_code": getattr(exc, "code", "INVALID_INPUT"), "message": str(exc)}, ensure_ascii=False, indent=2))
        return EXIT_FAILED


if __name__ == "__main__":
    raise SystemExit(main())
