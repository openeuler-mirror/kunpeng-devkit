#!/usr/bin/env python3
"""ANALYZE stage: run DevKit SQL analysis/conversion and build bounded AI workset when needed."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Any

from common.migration_common import MigrationError, json_list, run_command
from common.sql_context import DEFAULT_DB_CONFIG, db_env

SCRIPT_DIR = Path(__file__).resolve().parents[1]
SKILL_DIR = SCRIPT_DIR.parent


def preserve_latest_devkit_report(reports_dir: Path, label: str) -> None:
    reports = sorted(reports_dir.glob("Sql_Analysis_Report_*.json"), key=lambda p: p.stat().st_mtime)
    if reports:
        shutil.copy2(reports[-1], reports_dir / f"devkit-{label}-report.json")


def apply_devkit_patch(work_dir: Path) -> dict[str, Any]:
    patch_path = work_dir / "source-code" / "b" / "b-devkit-sql.patch"
    preserved = work_dir / "reports" / "devkit-pass-1.patch"
    if not patch_path.is_file():
        return {"status": "SKIPPED", "reason": "patch_not_generated"}
    shutil.copy2(patch_path, preserved)
    if patch_path.stat().st_size == 0:
        return {"status": "SKIPPED", "reason": "empty_patch", "patch": str(preserved)}
    run_command(
        ["patch", "-p1", "--forward", "--batch", "-i", str(patch_path)],
        work_dir,
        cwd=work_dir / "source-code" / "b",
        reason="DEVKIT_PATCH_APPLY_FAILED",
    )
    return {"status": "APPLIED", "patch": str(preserved)}


def run_devkit(context: dict[str, Any]) -> None:
    work_dir: Path = context["work_dir"]
    env = db_env(context["db_config"])
    env.update({
        "JAVA_PATH": str(context["java_path"]),
        "JAR_PATH": str(context["jar_path"]),
        "PROJECT_ROOT": str((work_dir / "source-code" / "b").resolve()),
        "WORK_DIR": str(work_dir),
        "SOURCE_DB": context["source_db"],
        "TARGET_DB": context["target_db"],
    })
    run_command(
        ["bash", str(SCRIPT_DIR / "tools" / "devkit-sql-migration.sh")],
        work_dir,
        env=env,
        reason="DEVKIT_SQL_MIGRATION_FAILED",
    )


def prepare_vastbase_transform(context: dict[str, Any]) -> dict[str, Any]:
    jar_path: Path = context["jar_path"]
    target_path = jar_path.parent / "vastbase-transform-1.2.jar"
    if target_path.is_file() and target_path.stat().st_size > 0:
        return {"status": "SKIPPED", "reason": "already_exists", "path": str(target_path)}
    url = "https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/vastbase-transform-1.2.jar"
    run_command(["curl", "-fsSL", "-o", str(target_path), url], context["work_dir"], cwd=jar_path.parent,
                reason="VASTBASE_TRANSFORM_DOWNLOAD_FAILED")
    return {"status": "DOWNLOADED", "path": str(target_path)}


def parse_reports(work_dir: Path, merge: bool) -> None:
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "tools" / "parse_report.py"),
        "--reports-dir", str(work_dir / "reports"),
        "--generate-reports",
        "--output-dir", str(work_dir / "reports"),
    ]
    if merge:
        cmd.append("--merge")
    run_command(cmd, work_dir, reason="DEVKIT_REPORT_PARSE_FAILED")


def build_ai_workset(context: dict[str, Any]) -> Path:
    work_dir: Path = context["work_dir"]
    workset_path = work_dir / "reports" / "ai-workset.json"
    if workset_path.is_file():
        return workset_path
    todo_path = work_dir / "reports" / "to_do-migrated_sql.json"
    source_root = work_dir / "source-code" / "b"
    if not todo_path.is_file():
        raise MigrationError("TODO_REPORT_MISSING", f"missing {todo_path}")
    rules_file = work_dir / "devkit-sql-migration-cache" / f"rulers_{context['source_db']}_to_{context['target_db']}.md"
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "tools" / "build_ai_workset.py"),
        "--todo", str(todo_path),
        "--source-root", str(source_root),
        "--output", str(workset_path),
        "--source-db", context["source_db"],
        "--target-db", context["target_db"],
        "--db-config", str(DEFAULT_DB_CONFIG),
    ]
    if rules_file.is_file():
        cmd.extend(["--rules-file", str(rules_file)])
    run_command(cmd, work_dir, reason="AI_WORKSET_BUILD_FAILED")
    return workset_path


def run(context: dict[str, Any]) -> dict[str, Any]:
    work_dir: Path = context["work_dir"]
    if context["route"] == "C":
        context["vastbase_transform"] = prepare_vastbase_transform(context)
    run_devkit(context)
    preserve_latest_devkit_report(work_dir / "reports", "pass-1")
    parse_reports(work_dir, merge=False)
    devkit_patch = None
    if context["route"] == "A":
        devkit_patch = apply_devkit_patch(work_dir)
        run_devkit(context)
        preserve_latest_devkit_report(work_dir / "reports", "pass-2")
        parse_reports(work_dir, merge=True)
    todo_count = len(json_list(work_dir / "reports" / "to_do-migrated_sql.json"))
    return {
        "todo_count": todo_count,
        "ai_workset": str(build_ai_workset(context)) if todo_count else "",
        "devkit_patch": devkit_patch,
        "vastbase_transform": context.get("vastbase_transform"),
    }
