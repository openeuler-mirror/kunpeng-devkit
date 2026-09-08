#!/usr/bin/env python3
"""Persistent local watcher that resumes Java migration after SQL finalize.

The controller is intentionally small: it watches one task-scoped handoff file,
waits for the independent sql-migration result to reach a terminal-success
state, and invokes the Java migration's durable --stage build resume point.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from migration_common import load_json, now_iso, write_json

SUCCESS_STATES = {"SUCCESS", "COMPLETED_WITH_ACTIONS"}
FAILURE_STATES = {"FAILED", "BLOCKED", "CANCELLED", "CANCELED"}
FINAL_HANDOFF_STATES = {"JAVA_RESUME_COMPLETED", "SQL_FAILED", "CANCELLED"}


def merge_handoff(path: Path, **changes: Any) -> dict[str, Any]:
    current = load_json(path)
    current.update(changes)
    current["updated_at"] = now_iso()
    write_json(path, current)
    return current


def controller_update(path: Path, **changes: Any) -> dict[str, Any]:
    current = load_json(path)
    controller = current.get("controller") if isinstance(current.get("controller"), dict) else {}
    controller.update(changes)
    controller["updated_at"] = now_iso()
    current["controller"] = controller
    current["updated_at"] = now_iso()
    write_json(path, current)
    return current


def wait_and_resume(handoff_path: Path, poll_seconds: float) -> int:
    controller_update(handoff_path, status="WATCHING")
    while True:
        handoff = load_json(handoff_path)
        handoff_status = str(handoff.get("status") or "").upper()
        if handoff_status in FINAL_HANDOFF_STATES:
            controller_update(handoff_path, status="STOPPED", stop_reason=handoff_status)
            return 0

        report_file = Path(str(handoff.get("result_file") or ""))
        if not report_file.is_file():
            time.sleep(poll_seconds)
            continue
        try:
            sql_result = load_json(report_file)
        except Exception:
            # The SQL skill may be in the middle of an atomic/streamed finalize.
            time.sleep(poll_seconds)
            continue
        sql_status = str(sql_result.get("status") or "").upper()
        if sql_status in FAILURE_STATES:
            merge_handoff(
                handoff_path,
                status="SQL_FAILED",
                sql_status=sql_status,
                sql_completed_at=now_iso(),
            )
            controller_update(handoff_path, status="STOPPED", stop_reason="SQL_FAILED")
            return 2
        if sql_status not in SUCCESS_STATES:
            time.sleep(poll_seconds)
            continue

        merge_handoff(
            handoff_path,
            status="SQL_COMPLETED",
            sql_status=sql_status,
            sql_completed_at=now_iso(),
        )
        command = handoff.get("resume_command")
        if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
            controller_update(handoff_path, status="FAILED", error="Invalid resume_command in sql-handoff.json")
            return 2

        controller_update(
            handoff_path,
            status="RESUMING_JAVA",
            resume_started_at=now_iso(),
            resume_command=command,
        )
        proc = subprocess.run(command, cwd=str(SCRIPT_DIR.parent), check=False)
        current = load_json(handoff_path)
        # stage_sql may have advanced the handoff to SQL_APPLIED while the
        # resume process was running. Preserve that state and only mark the
        # controller sub-state here.
        controller_update(
            handoff_path,
            status="RESUME_FINISHED" if proc.returncode == 0 else "RESUME_STOPPED",
            resume_exit_code=proc.returncode,
            resume_finished_at=now_iso(),
        )
        if proc.returncode == 0:
            latest = load_json(handoff_path)
            if str(latest.get("status") or "").upper() in {"SQL_APPLIED", "SQL_COMPLETED"}:
                merge_handoff(handoff_path, status="JAVA_RESUME_COMPLETED", java_resume_completed_at=now_iso())
        return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Resume Java migration after an independent SQL migration task completes.")
    parser.add_argument("--handoff", required=True, help="Absolute sql-handoff.json path")
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    args = parser.parse_args()
    handoff_path = Path(args.handoff).resolve()
    if not handoff_path.is_file():
        print(json.dumps({"status": "FAILED", "reason": "handoff missing", "handoff": str(handoff_path)}))
        return 2
    return wait_and_resume(handoff_path, max(1.0, args.poll_seconds))


if __name__ == "__main__":
    sys.exit(main())
