#!/usr/bin/env python3
"""Consume Agent application-startup verification results deterministically.

The Agent owns target-environment observation and writes one bounded result file.
This module owns verification report generation and migration-result.json state
updates. It is an internal result handoff, not a migration/verify stage.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from migration_common import load_json, write_json

RESULT_NAME = "application-verification-result.json"
CONSUMED_NAME = "application-verification-result.consumed.json"
REPORT_NAME = "application-verification.md"
ALLOWED_STATUSES = {"SUCCESS", "NEEDS_AGENT_FIX", "BLOCKED"}


def _as_list(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def _pending_actions(result: dict[str, Any]) -> int:
    sql = result.get("sql_migration") or {}
    try:
        direct = int(sql.get("pending_actions") or 0)
    except (TypeError, ValueError):
        direct = 0
    if direct:
        return direct
    counts = sql.get("counts") or {}
    total = 0
    for key in ("todo", "pending_confirm", "manual_review"):
        try:
            total += int(counts.get(key) or 0)
        except (TypeError, ValueError):
            pass
    return total


def _render_evidence(value: Any) -> str:
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    except TypeError:
        return str(value)


def _write_report(report_path: Path, payload: dict[str, Any], result: dict[str, Any]) -> None:
    status = str(payload.get("status") or "").upper()
    summary = str(payload.get("summary") or "").strip()
    evidence = _as_list(payload.get("evidence"))
    missing = [str(v) for v in _as_list(payload.get("missing_dependencies")) if str(v)]
    failed = [str(v) for v in _as_list(payload.get("failed_checks")) if str(v)]
    unverified = [str(v) for v in _as_list(payload.get("unverified_checks")) if str(v)]
    lines = [
        "# 应用启动验证报告",
        "",
        "- 应用：`%s`" % str(result.get("application_id") or ""),
        "- 组件：`%s`" % str(result.get("package_id") or ""),
        "- 状态：`%s`" % status,
        "- 验证时间：%s" % time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "",
        "## 结论",
        "",
        summary or "Agent 已提交目标环境验证结果。",
    ]
    if evidence:
        lines.extend(["", "## 验证证据", ""])
        for item in evidence:
            lines.append("- " + _render_evidence(item))
    if missing:
        lines.extend(["", "## 缺失依赖", ""])
        lines.extend("- " + item for item in missing)
    if failed:
        lines.extend(["", "## 失败检查项", ""])
        lines.extend("- " + item for item in failed)
    if unverified:
        lines.extend(["", "## 未完成检查项", ""])
        lines.extend("- " + item for item in unverified)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def consume(result_path: Path, work_dir: Path) -> bool:
    """Consume the fixed Agent result file if present and update core state."""
    reports = work_dir / "reports"
    input_path = reports / RESULT_NAME
    if not input_path.is_file():
        return False

    payload = load_json(input_path)
    status = str(payload.get("status") or "").strip().upper()
    if status not in ALLOWED_STATUSES:
        raise ValueError("application verification status must be one of: %s" % ", ".join(sorted(ALLOWED_STATUSES)))
    summary = str(payload.get("summary") or "").strip()
    if not summary:
        raise ValueError("application verification result requires non-empty summary")

    result = load_json(result_path)
    current_status = str(result.get("status") or "").upper()
    if current_status not in {"WAITING_FOR_AGENT", "NEEDS_AGENT_FIX", "BLOCKED"}:
        raise ValueError("application verification result can only be consumed at the application verification boundary")
    if str(result.get("stage") or "").upper() != "APPLICATION_VERIFICATION":
        raise ValueError("application verification result requires stage=APPLICATION_VERIFICATION")

    previous_action = result.get("action_required") if isinstance(result.get("action_required"), dict) else {}
    resume = previous_action.get("resume") if isinstance(previous_action, dict) else None
    if not isinstance(resume, dict):
        resume = {}

    evidence = _as_list(payload.get("evidence"))
    missing = [str(v) for v in _as_list(payload.get("missing_dependencies")) if str(v)]
    failed = [str(v) for v in _as_list(payload.get("failed_checks")) if str(v)]
    unverified = [str(v) for v in _as_list(payload.get("unverified_checks")) if str(v)]
    now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    report_rel = "reports/%s" % REPORT_NAME
    report_path = reports / REPORT_NAME
    _write_report(report_path, payload, result)

    verification = {
        "status": status,
        "scope": "TARGET_APPLICATION_STARTUP",
        "summary": summary,
        "verified_at": now,
        "report": report_rel,
        "evidence": evidence,
        "missing_dependencies": missing,
        "failed_checks": failed,
        "unverified_checks": unverified,
    }
    result["verification"] = verification
    completion = result.get("migration_completion")
    if not isinstance(completion, dict):
        completion = {}
        result["migration_completion"] = completion

    workflow = result.get("workflow")
    if not isinstance(workflow, dict):
        workflow = {}
        result["workflow"] = workflow
    workflow.update({
        "current_stage": "verification",
        "last_completed_stage": "repackage",
        "next_stage": "",
        "resume": {},
    })

    if status == "SUCCESS":
        completion["target_environment_verification"] = {
            "status": "SUCCESS", "verified_at": now, "report": report_rel,
        }
        pending = _pending_actions(result)
        result["status"] = "COMPLETED_WITH_ACTIONS" if pending else "SUCCESS"
        result["stage"] = "COMPLETE"
        result["reason_code"] = "MIGRATION_COMPLETED_WITH_ACTIONS" if pending else ""
        workflow["last_completed_stage"] = "verification"
        workflow["waiting_for"] = ""
        if pending:
            result["action_required"] = {
                "type": "FOLLOW_UP_ACTIONS",
                "sql_pending_actions": pending,
                "reference": report_rel,
            }
        else:
            result.pop("action_required", None)
    elif status == "NEEDS_AGENT_FIX":
        completion["target_environment_verification"] = {
            "status": "NEEDS_AGENT_FIX", "verified_at": now, "report": report_rel,
        }
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "APPLICATION_VERIFICATION",
            "reason_code": "APPLICATION_STARTUP_FIX_REQUIRED",
            "action_required": {
                "type": "FIX_APPLICATION_STARTUP",
                "orchestrator": "AGENT",
                "summary": summary,
                "failed_checks": failed,
                "reference": report_rel,
                "verification_result_file": "reports/%s" % RESULT_NAME,
                "resume": resume,
            },
        })
        workflow["waiting_for"] = "AGENT_FIX"
        workflow["resume"] = resume
    else:
        completion["target_environment_verification"] = {
            "status": "BLOCKED", "verified_at": now, "report": report_rel,
            "missing_dependencies": missing,
        }
        result.update({
            "status": "BLOCKED",
            "stage": "APPLICATION_VERIFICATION",
            "reason_code": "VERIFY_APPLICATION_STARTUP_BLOCKED",
            "action_required": {
                "type": "RESOLVE_RUNTIME_DEPENDENCY" if missing else "RESOLVE_VERIFICATION_BLOCKER",
                "orchestrator": "AGENT",
                "summary": summary,
                "missing_dependencies": missing,
                "reference": report_rel,
                "verification_result_file": "reports/%s" % RESULT_NAME,
                "resume": resume,
            },
        })
        workflow["waiting_for"] = "RUNTIME_DEPENDENCY"
        workflow["resume"] = resume

    write_json(result_path, result)
    consumed = dict(payload)
    consumed["consumed_at"] = now
    write_json(reports / CONSUMED_NAME, consumed)
    try:
        input_path.unlink()
    except FileNotFoundError:
        pass
    return True
