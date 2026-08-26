#!/usr/bin/env python3
"""ANALYZE stage: run DevKit SQL analysis/conversion and build bounded AI workset when needed."""
from __future__ import annotations

import shutil
import sys
from pathlib import Path
from typing import Any

from common.migration_common import MigrationError, json_list, run_command
from common.sql_context import db_env
from stages import devkit_call


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
    devkit_call.run(env, work_dir, reason="DEVKIT_SQL_MIGRATION_FAILED")


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
    """解析 DevKit 报告并生成分类报告。

    通过修改 sys.argv 后 in-process 调用 parse_report.main，等价于原 subprocess
    调用但不依赖 sys.executable（ai-migration launcher + .pyc 架构下，launcher
    启动 Python 解释器执行对应 .pyc，in-process 调用避免再起子进程）。
    """
    sys.argv = [
        "parse_report.py",
        "--reports-dir", str(work_dir / "reports"),
        "--generate-reports",
        "--output-dir", str(work_dir / "reports"),
    ]
    if merge:
        sys.argv.append("--merge")
    from tools.parse_report import main as parse_report_main
    rc = parse_report_main()
    if rc != 0:
        raise MigrationError("DEVKIT_REPORT_PARSE_FAILED", f"parse_report exited with code {rc}", rc)


def build_ai_workset(context: dict[str, Any]) -> Path:
    """构造 AI workset（in-process 调用 build_ai_workset.main）。

    db_config_path / ai_migration_path 从 context 取，透传给 build_ai_workset.main
    写入 ai-workset.json 的 finalize.entry 子命令前缀。references/ai-sql-transformation.md
    与 scripts/sql_migration.sh 由 Agent 通过 SKILL 目录结构自行定位，不再透传。
    """
    work_dir: Path = context["work_dir"]
    workset_path = work_dir / "reports" / "ai-workset.json"
    if workset_path.is_file():
        return workset_path
    todo_path = work_dir / "reports" / "to_do-migrated_sql.json"
    source_root = work_dir / "source-code" / "b"
    if not todo_path.is_file():
        raise MigrationError("TODO_REPORT_MISSING", f"missing {todo_path}")
    rules_file = work_dir / "devkit-sql-migration-cache" / f"rulers_{context['source_db']}_to_{context['target_db']}.md"
    sys.argv = [
        "build_ai_workset.py",
        "--todo", str(todo_path),
        "--source-root", str(source_root),
        "--output", str(workset_path),
        "--source-db", context["source_db"],
        "--target-db", context["target_db"],
        "--db-config", str(context["db_config_path"]),
    ]
    ai_migration_path = context.get("ai_migration_path")
    if ai_migration_path:
        sys.argv.extend(["--ai-migration-path", str(ai_migration_path)])
    if rules_file.is_file():
        sys.argv.extend(["--rules-file", str(rules_file)])
    from tools.build_ai_workset import main as build_ai_workset_main
    rc = build_ai_workset_main()
    if rc != 0:
        raise MigrationError("AI_WORKSET_BUILD_FAILED", f"build_ai_workset exited with code {rc}", rc)
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
