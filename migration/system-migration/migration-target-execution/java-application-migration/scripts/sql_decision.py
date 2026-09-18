#!/usr/bin/env python3
"""Write the component-local decision for a completed SQL migration.

The tool records the user's decision only.  It intentionally does not bind the
approval to SHA256 digests; the SQL result and patch remain read-only inputs and
are validated for presence/status when the decision is written and consumed.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any

from component_context import binary_execution_context
from migration_common import load_json, write_json


def sql_counts(result: dict[str, Any]) -> dict[str, int]:
    raw = result.get("counts") or {}
    counts: dict[str, int] = {}
    for key in ("compatible", "migrated", "todo", "pending_confirm", "manual_review"):
        try:
            counts[key] = int(raw.get(key) or 0)
        except (TypeError, ValueError):
            counts[key] = 0
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description="Record SQL migration continue/reject decision for one application package")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--application-id", required=True)
    parser.add_argument("--package-id", required=True)
    parser.add_argument("--decision", required=True, choices=("continue", "reject"))
    parser.add_argument("--decision-source", required=True, choices=("USER",), help="Decision source; must be explicit user confirmation")
    args = parser.parse_args()

    plan_path = Path(args.plan).expanduser().resolve()
    context = binary_execution_context(plan_path, args.application_id, args.package_id)
    work_dir = Path(str(context["work_dir"])).expanduser().resolve()
    sql_cfg = context.get("sql_migration") or {}
    sql_work_dir = Path(str(sql_cfg.get("work_dir") or (work_dir / "sql-migration"))).expanduser().resolve()
    result_file = sql_work_dir / "reports" / "sql-migration-result.json"
    source_patch = sql_work_dir / "reports" / "source_code.patch"
    decision_file = work_dir / "sql-migration-decision.json"

    if not result_file.is_file():
        raise SystemExit("SQL migration result does not exist: %s" % result_file)
    result = load_json(result_file)
    if not isinstance(result, dict):
        raise SystemExit("SQL migration result must be a JSON object: %s" % result_file)
    status = str(result.get("status") or "").upper()
    if status != "COMPLETED_WITH_ACTIONS":
        raise SystemExit("SQL decision is only required for COMPLETED_WITH_ACTIONS; current status=%s" % (status or "<empty>"))
    if args.decision == "continue" and not source_patch.is_file():
        raise SystemExit("SQL migration patch does not exist: %s" % source_patch)

    payload = {
        "decision": "CONTINUE_WITH_PENDING" if args.decision == "continue" else "REJECT",
        "source_status": status,
        "decision_source": args.decision_source,
        "counts": sql_counts(result),
        "decided_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    write_json(decision_file, payload)
    print(json.dumps({
        "status": "RECORDED",
        "decision_file": str(decision_file),
        "decision": payload["decision"],
        "counts": payload["counts"],
        "next_action": "RESUME_CURRENT_COMPONENT" if args.decision == "continue" else "STOP_CURRENT_APPLICATION_COMPONENT",
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
