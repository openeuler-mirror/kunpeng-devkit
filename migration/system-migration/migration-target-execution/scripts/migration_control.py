#!/usr/bin/env python3
"""Prepare and verify minimal target-change approval artifacts from migration-plan.json.

This helper does not schedule child Skills, ingest result contracts, generate migration guidance,
or maintain a cross-module state machine. Execution guidance lives in the root SKILL.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent

from migration_plan import (
    execution_issues,
    load_json,
    migration_plan_digest,
    migration_work_dir,
    require_valid_migration_plan,
)


def ensure_plan_same_filesystem(plan_path: Path, work_dir: Path) -> None:
    atomic_dir = work_dir / "tmp" / "atomic"
    atomic_dir.mkdir(parents=True, exist_ok=True)
    if os.stat(atomic_dir).st_dev != os.stat(plan_path.parent).st_dev:
        raise ValueError(
            "MIGRATION_WORK_DIR and migration-plan.json must be on the same filesystem "
            "so migration-plan.json can be updated atomically without temporary files outside MIGRATION_WORK_DIR"
        )


def control_dir(work_dir: Path) -> Path:
    return work_dir / "control"


MODULES = (
    ("database", "route.database", "database-migration/database-migration.md", "数据库迁移"),
    ("middleware", "route.middleware", "middleware-migration/middleware-migration.md", "中间件迁移"),
    ("application", "route.application", "java-application-migration/java-application-migration.md", "Java应用迁移"),
)


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def write_json_atomic(path: Path, value: Any) -> None:
    write_text_atomic(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def load_plan(path: Path, *, execution: bool) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"migration-plan.json does not exist: {path}")
    plan = load_json(path)
    require_valid_migration_plan(
        plan,
        phase="execution" if execution else "collector-final",
        plan_path=path,
        check_files=execution,
    )
    if execution:
        issues = execution_issues(plan, path, check_files=True)
        blocking = [item for item in issues if item.get("blocking") is True]
        if blocking:
            details = "; ".join(f"{item.get('code')}: {item.get('description') or ''}" for item in blocking)
            raise ValueError("target precheck is not ready: " + details)
    return plan


def active_modules(plan: dict[str, Any]) -> list[dict[str, Any]]:
    route = plan.get("route") or {}
    result: list[dict[str, Any]] = []
    for name, route_key, skill, title in MODULES:
        key = route_key.split(".")[-1]
        items = [item for item in route.get(key) or [] if isinstance(item, dict)]
        if not items:
            continue
        result.append({
            "name": name,
            "title": title,
            "route_key": route_key,
            "count": len(items),
            "skill": skill,
        })
    return result


def operation_plan_digest(value: dict[str, Any]) -> str:
    normalized = {key: item for key, item in value.items() if key != "generated_at"}
    raw = json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def operation_object_name(item: dict[str, Any], module: str) -> str:
    """Return one human-readable migration object without deriving execution steps."""
    if module in {"database", "middleware"}:
        source = item.get("source") or {}
        target = item.get("target") or {}
        source_product = str(source.get("product") or "").strip()
        target_product = str(target.get("product") or "").strip()
        return source_product or target_product or str(item.get("id") or module)
    return str(item.get("product") or item.get("name") or item.get("id") or "Java application")


def operation_migration_route(item: dict[str, Any], module: str) -> str:
    """Return the confirmed object-level route without expanding stop/install/verify actions."""
    if module in {"database", "middleware"}:
        source = item.get("source") or {}
        target = item.get("target") or {}

        def endpoint(value: dict[str, Any], fallback: str) -> str:
            product = str(value.get("product") or fallback).strip()
            version = str(value.get("version") or "").strip()
            return " ".join(part for part in (product, version) if part)

        return f"{endpoint(source, '源组件')} → {endpoint(target, '目标组件')}"

    sql = item.get("application_sql_migration") or {}
    selected_route = str(sql.get("selected_route") or "").strip()
    if sql.get("requires_sql_adaptation") is True and selected_route:
        return f"Java应用迁移；SQL适配：{selected_route}"
    return "Java应用迁移"


def build_operations(plan: dict[str, Any]) -> list[dict[str, Any]]:
    """Build one user-confirmation entry per migration object.

    Do not infer deployment directories, package locations, ports, service names or other
    execution parameters. Child Skills obtain those values directly from migration-plan.json
    or from their own runtime interaction.
    """
    route = plan.get("route") or {}
    operations: list[dict[str, Any]] = []

    for item in route.get("database") or []:
        if not isinstance(item, dict):
            continue
        operations.append({
            "module": "database",
            "migration_content": operation_object_name(item, "database"),
            "migration_route": operation_migration_route(item, "database"),
        })

    for item in route.get("middleware") or []:
        if not isinstance(item, dict):
            continue
        operations.append({
            "module": "middleware",
            "migration_content": operation_object_name(item, "middleware"),
            "migration_route": operation_migration_route(item, "middleware"),
        })

    for item in route.get("application") or []:
        if not isinstance(item, dict):
            continue
        operations.append({
            "module": "application",
            "migration_content": operation_object_name(item, "application"),
            "migration_route": operation_migration_route(item, "application"),
        })

    return operations


def command_work_dir(args: argparse.Namespace) -> int:
    plan_path = Path(args.migration_plan).expanduser().resolve()
    plan = load_plan(plan_path, execution=False)
    work_dir = migration_work_dir(plan, create=True)
    ensure_plan_same_filesystem(plan_path, work_dir)
    print(str(work_dir))
    return 0


def command_inspect(args: argparse.Namespace) -> int:
    plan_path = Path(args.migration_plan).expanduser().resolve()
    plan = load_plan(plan_path, execution=False)
    work_dir = migration_work_dir(plan, create=True)
    ensure_plan_same_filesystem(plan_path, work_dir)
    result = {
        "migration_plan": str(plan_path),
        "migration_work_dir": str(work_dir),
        "migration_id": str(plan.get("migration_id") or ""),
        "migration_plan_digest": migration_plan_digest(plan),
        "modules": active_modules(plan),
        "next": "run migration-precheck/migration-precheck.md",
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def command_prepare(args: argparse.Namespace) -> int:
    plan_path = Path(args.migration_plan).expanduser().resolve()
    plan = load_plan(plan_path, execution=True)
    work_dir = migration_work_dir(plan, create=True)
    ensure_plan_same_filesystem(plan_path, work_dir)
    control = control_dir(work_dir)

    operation_plan = {
        "schema_version": "4.2",
        "migration_plan": str(plan_path),
        "migration_plan_digest": migration_plan_digest(plan),
        "generated_at": now(),
        "operations": build_operations(plan),
    }
    operation_path = control / "operation-plan.json"
    approval_path = control / "migration-approval.json"
    if approval_path.exists():
        approval_path.unlink()
    write_json_atomic(operation_path, operation_plan)
    print(json.dumps({
        "operation_plan": str(operation_path),
        "migration_work_dir": str(work_dir),
        "migration_plan_digest": operation_plan["migration_plan_digest"],
        "operation_count": len(operation_plan["operations"]),
        "next": "ask user to approve operation-plan.json, then run approve",
    }, ensure_ascii=False, indent=2))
    return 0


def command_approve(args: argparse.Namespace) -> int:
    plan_path = Path(args.migration_plan).expanduser().resolve()
    plan = load_plan(plan_path, execution=True)
    work_dir = migration_work_dir(plan, create=True)
    ensure_plan_same_filesystem(plan_path, work_dir)
    control = control_dir(work_dir)
    op_path = control / "operation-plan.json"
    if not op_path.is_file():
        raise ValueError(f"operation-plan.json does not exist: {op_path}")
    op = load_json(op_path)
    current_digest = migration_plan_digest(plan)
    if op.get("migration_plan_digest") != current_digest:
        raise ValueError("migration-plan.json changed after operation-plan generation; rerun prepare")
    approval = {
        "schema_version": "1.0",
        "decision": args.decision,
        "decided_at": now(),
        "migration_plan": str(plan_path),
        "migration_plan_digest": current_digest,
        "operation_plan": str(op_path),
        "operation_plan_digest": operation_plan_digest(op),
    }
    approval_path = control / "migration-approval.json"
    write_json_atomic(approval_path, approval)
    print(json.dumps({
        "approval": str(approval_path),
        "migration_work_dir": str(work_dir),
        "decision": args.decision,
        "next": "follow the root SKILL.md and execute required child Skills in fixed order" if args.decision == "approve" else "stop target mutations",
    }, ensure_ascii=False, indent=2))
    return 0


def command_verify(args: argparse.Namespace) -> int:
    plan_path = Path(args.migration_plan).expanduser().resolve()
    plan = load_plan(plan_path, execution=True)
    work_dir = migration_work_dir(plan, create=True)
    ensure_plan_same_filesystem(plan_path, work_dir)
    control = control_dir(work_dir)
    op_path = control / "operation-plan.json"
    approval_path = control / "migration-approval.json"
    if not op_path.is_file() or not approval_path.is_file():
        raise ValueError("operation-plan.json and migration-approval.json are required before target mutation")
    op = load_json(op_path)
    approval = load_json(approval_path)
    current_digest = migration_plan_digest(plan)
    if approval.get("decision") != "approve":
        raise ValueError("target changes were not approved")
    if op.get("migration_plan_digest") != current_digest or approval.get("migration_plan_digest") != current_digest:
        raise ValueError("migration-plan.json changed after approval; rerun prepare and obtain approval again")
    if approval.get("operation_plan_digest") != operation_plan_digest(op):
        raise ValueError("operation-plan.json changed after approval; obtain approval again")
    print(json.dumps({
        "status": "READY",
        "migration_plan": str(plan_path),
        "migration_work_dir": str(work_dir),
        "migration_plan_digest": current_digest,
    }, ensure_ascii=False, indent=2))
    return 0


def add_runtime_args(command: argparse.ArgumentParser) -> None:
    command.add_argument("--migration-plan", required=True)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Minimal approval helper for guidance-driven Kunpeng migration")
    commands = root.add_subparsers(dest="command", required=True)

    work_dir = commands.add_parser("work-dir", help="resolve and initialize MIGRATION_WORK_DIR")
    add_runtime_args(work_dir)
    work_dir.set_defaults(handler=command_work_dir)

    inspect = commands.add_parser("inspect", help="validate source handoff plan and show required modules")
    add_runtime_args(inspect)
    inspect.set_defaults(handler=command_inspect)

    prepare = commands.add_parser("prepare", help="after target precheck, generate operation plan")
    add_runtime_args(prepare)
    prepare.set_defaults(handler=command_prepare)

    approve = commands.add_parser("approve", help="record the user's explicit operation-plan decision")
    add_runtime_args(approve)
    approve.add_argument("--decision", choices=("approve", "reject"), required=True)
    approve.set_defaults(handler=command_approve)

    verify = commands.add_parser("verify", help="verify approval and plan digest before target mutation")
    add_runtime_args(verify)
    verify.set_defaults(handler=command_verify)
    return root

def main() -> int:
    args = parser().parse_args()
    try:
        return int(args.handler(args))
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
