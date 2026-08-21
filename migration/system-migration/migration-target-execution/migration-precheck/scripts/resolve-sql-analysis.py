#!/usr/bin/env python3
"""Resolve the declared SQL Analysis JAR strictly from its migration_tools package."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

# Reuse the top-level migration plan implementation as the single source of
# truth for application SQL enablement and tool dependency decisions.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from migration_plan import load_json

TOOL_NAME_PREFIX = "sql-analysis"
JAR_PATTERN = "sql-analysis*.jar"


def declared_names(package: dict[str, Any]) -> set[str]:
    return {
        str(item.get("name") or "").strip().lower()
        for item in package.get("tools") or []
        if isinstance(item, dict) and str(item.get("name") or "").strip()
    }


def install_reference(source: Path, reference: Path) -> None:
    reference.parent.mkdir(parents=True, exist_ok=True)
    if reference.is_symlink() or reference.exists():
        reference.unlink()
    reference.symlink_to(source.resolve())


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve SQL Analysis from declared migration tool package")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--work-dir", required=True)
    args = parser.parse_args()

    plan_path = Path(args.plan).expanduser().resolve()
    plan = load_json(plan_path)
    packages = [
        item for item in (plan.get("target_environment") or {}).get("migration_tools") or []
        if isinstance(item, dict) and any(name.startswith(TOOL_NAME_PREFIX) for name in declared_names(item))
    ]
    if not packages:
        print(json.dumps({"status": "READY", "tool": TOOL_NAME_PREFIX, "declared": False}, ensure_ascii=False, indent=2))
        return 0
    if len(packages) != 1:
        print(json.dumps({
            "status": "BLOCKED",
            "reason": "SQL_ANALYSIS_TOOL_PACKAGE_NOT_UNIQUE",
            "message": f"exactly one migration_tools package may declare a tool name starting with {TOOL_NAME_PREFIX}",
            "package_count": len(packages),
        }, ensure_ascii=False, indent=2))
        return 20

    package = packages[0]
    if package.get("status") != "READY":
        print(json.dumps({
            "status": "BLOCKED", "reason": "SQL_ANALYSIS_PACKAGE_STATUS_NOT_READY",
            "package_id": package.get("id"), "plan_status": package.get("status")
        }, ensure_ascii=False, indent=2))
        return 20
    package_id = str(package.get("id") or "").strip()
    migration_root = Path(args.work_dir).expanduser().resolve()
    migration_root.mkdir(parents=True, exist_ok=True)
    tools_root = (migration_root / "tools").resolve()
    package_type = str(package.get("type") or "").upper()
    if package_type == "ARCHIVE":
        search_root = (tools_root / "unpacked" / package_id).resolve()
        allowed_root = (tools_root / "unpacked").resolve()
    elif package_type == "FILE":
        search_root = (tools_root / "packages" / package_id).resolve()
        allowed_root = (tools_root / "packages").resolve()
    else:
        print(json.dumps({"status": "BLOCKED", "reason": "INVALID_TOOL_PACKAGE_TYPE", "package_id": package_id}, ensure_ascii=False, indent=2))
        return 20
    try:
        if os.path.commonpath([str(allowed_root), str(search_root)]) != str(allowed_root):
            raise ValueError("package id resolves outside controlled tools directory")
    except ValueError as exc:
        print(json.dumps({"status": "BLOCKED", "reason": "INVALID_TOOL_PACKAGE_ID", "message": str(exc)}, ensure_ascii=False, indent=2))
        return 20

    candidates = sorted(
        (path.resolve() for path in search_root.rglob("*")
         if path.is_file() and path.name.lower().startswith(TOOL_NAME_PREFIX) and path.suffix.lower() == ".jar"),
        key=lambda path: (len(path.parts), str(path)),
    ) if search_root.is_dir() else []
    if not candidates:
        print(json.dumps({
            "status": "BLOCKED",
            "reason": "SQL_ANALYSIS_NOT_FOUND_UNDER_DECLARED_PACKAGE",
            "package_id": package_id,
            "expected_pattern": JAR_PATTERN,
            "search_root": str(search_root),
        }, ensure_ascii=False, indent=2))
        return 20

    selected = candidates[0]
    reference = tools_root / "lib" / "sql-analysis.jar"
    install_reference(selected, reference)
    print(json.dumps({
        "status": "READY",
        "tool": TOOL_NAME_PREFIX,
        "path": str(reference),
        "resolved_path": str(selected),
        "package_id": package_id,
        "candidates": [str(path) for path in candidates[:10]],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
