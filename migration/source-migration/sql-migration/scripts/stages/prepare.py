#!/usr/bin/env python3
"""PREPARE stage: initialize source copies and resolve SQL migration route/tool context."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from common.migration_common import MigrationError, now_local, write_json
from common.sql_context import build_context, validate_java_executable

# 调用外部可执行程序使用绝对路径（避免 PATH 投毒/环境差异导致的非预期执行）
_CP = shutil.which("cp") or "cp"


def _copy_item(src: Path, dst_dir: Path) -> str:
    reflink = subprocess.run(
        [_CP, "-a", "--reflink=always", str(src), str(dst_dir) + "/"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if reflink.returncode == 0:
        return "reflink"
    copied = subprocess.run(
        [_CP, "-a", str(src), str(dst_dir) + "/"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if copied.returncode != 0:
        raise MigrationError("SOURCE_BACKUP_FAILED", f"failed to copy source item: {src}")
    return "copy"


def backup_source(project_path: Path, work_dir: Path) -> dict[str, Any]:
    source_copy = work_dir / "source-code"
    if source_copy.exists():
        shutil.rmtree(source_copy)
    a_dir = source_copy / "a"
    b_dir = source_copy / "b"
    a_dir.mkdir(parents=True, exist_ok=True)

    project_path = project_path.resolve()
    work_dir = work_dir.resolve()
    excluded_top = ""
    excluded_path = ""
    try:
        rel = work_dir.relative_to(project_path)
        if rel.parts:
            excluded_top = rel.parts[0]
            excluded_path = rel.as_posix()
    except ValueError:
        pass

    copied = 0
    skipped = 0
    methods: set[str] = set()
    for item in project_path.iterdir():
        if item.name in {".git", ".svn", ".hg"} or (excluded_top and item.name == excluded_top):
            skipped += 1
            continue
        methods.add(_copy_item(item, a_dir))
        copied += 1
    if copied == 0:
        raise MigrationError("SOURCE_BACKUP_FAILED", "no source files copied into SQL migration workspace")

    for root, dirs, _ in os.walk(a_dir):
        for name in list(dirs):
            if name in {".git", ".svn", ".hg"}:
                shutil.rmtree(Path(root) / name, ignore_errors=True)
                dirs.remove(name)

    copied_ab = subprocess.run(
        [_CP, "-a", "--reflink=auto", str(a_dir), str(b_dir)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if copied_ab.returncode != 0:
        raise MigrationError("SOURCE_BACKUP_FAILED", "failed to create source-code/b working copy")
    source_copy = source_copy.resolve()
    payload = {
        "original_source_path": str(project_path),
        "source_copy_path": str(source_copy),
        "initial_backup_path": str(a_dir.resolve()),
        "target_backup_path": str(b_dir.resolve()),
        "backup_method": "reflink" if methods == {"reflink"} else "copy",
        "excluded_path": excluded_path,
        "excluded_top_dir": excluded_top,
        "copied_top_level_items": copied,
        "skipped_top_level_items": skipped,
        "path_mapping": {
            "original_root": str(project_path),
            "copy_root": str(source_copy),
            "replace_from": str(source_copy),
            "replace_to": str(project_path),
        },
    }
    write_json(work_dir / "reports" / "source_backup.json", payload)
    return payload


def run(
    project_path: Path,
    work_dir: Path,
    source_db: str,
    target_db: str,
    *,
    db_config_path: Path,
) -> dict[str, Any]:
    """PREPARE 阶段入口。

    db_config_path 由 sql_migration.py 透传，最终从入口脚本（sql_migration.sh）注入。
    本函数把它交给 build_context，进入 context 用于后续阶段。
    references/ai-sql-transformation.md 与 scripts/sql_migration.sh 由 Agent 通过
    SKILL 目录结构自行定位，不再透传到二进制内部。
    """
    context = build_context(project_path, work_dir, source_db, target_db, db_config_path)
    java_info = validate_java_executable(context["java_path"], work_dir)
    backup = backup_source(project_path, work_dir)
    config = context["db_config"]
    target_enabled = bool((config.get("target_db_conn") or {}).get("flag"))
    env_report = {
        "overall_status": "pass",
        "checked_at": now_local(),
        "project_path": str(project_path),
        "work_dir": str(work_dir),
        "route": context["route"],
        "route_info": context["route_info"],
        "sql_analysis_jar": str(context["jar_path"]),
        "sql_analysis_java": java_info,
        "db_config": str(context["db_config_path"]),
        "ai_migration_path": str(context.get("ai_migration_path") or "") if context.get("ai_migration_path") else "",
        "db_conn_config": {
            "source_enabled": bool((config.get("source_db_conn") or {}).get("flag")),
            "target_enabled": target_enabled,
        },
        "source_backup": backup,
    }
    write_json(work_dir / "reports" / "env_check_report.json", env_report)
    return context
