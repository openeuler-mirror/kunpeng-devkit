#!/usr/bin/env python3
"""FINALIZE stage: generate source patch, normalize report paths and build final report."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

from common.migration_common import MigrationError, load_json, run_command, write_json

SCRIPT_DIR = Path(__file__).resolve().parents[1]


def generate_patch(work_dir: Path) -> dict[str, Any]:
    source_root = work_dir / "source-code"
    a_dir = source_root / "a"
    b_dir = source_root / "b"
    reports = work_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    patch_path = reports / "source_code.patch"
    if not a_dir.is_dir() or not b_dir.is_dir():
        raise MigrationError("WORKSPACE_NOT_READY", "source-code/a and source-code/b are required")
    cmd = [
        "diff", "-ruN",
        "--exclude=.devkit-sql-migration", "--exclude=.git", "--exclude=.svn", "--exclude=.hg",
        "--exclude=*.log", "--exclude=*.json", "--exclude=*.patch", "a", "b",
    ]
    proc = subprocess.run(cmd, cwd=str(source_root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    patch_path.write_text(proc.stdout or "", encoding="utf-8")
    meta = {"status": "SUCCESS" if proc.returncode in (0, 1) else "FAILED", "diff_exit_code": proc.returncode,
            "patch_file": str(patch_path)}
    write_json(reports / "patch-generation.json", meta)
    if proc.returncode not in (0, 1):
        raise MigrationError("FINAL_PATCH_GENERATION_FAILED", proc.stderr or "diff failed")
    return meta


def _replace_paths(value: Any, replacements: list[tuple[str, str]]) -> Any:
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [_replace_paths(v, replacements) for v in value]
    if isinstance(value, dict):
        return {k: _replace_paths(v, replacements) for k, v in value.items()}
    return value


def convert_report_paths(work_dir: Path) -> dict[str, Any]:
    reports = work_dir / "reports"
    mapping = load_json(reports / "source_backup.json", {})
    if not isinstance(mapping, dict):
        raise MigrationError("REPORT_PATH_CONVERSION_FAILED", "source_backup.json is missing or invalid")
    path_map = mapping.get("path_mapping") or {}
    original = str(path_map.get("original_root") or mapping.get("original_source_path") or "")
    copy_root = str(path_map.get("copy_root") or mapping.get("source_copy_path") or "")
    a_path = str(mapping.get("initial_backup_path") or "")
    b_path = str(mapping.get("target_backup_path") or "")
    if not original or not copy_root:
        raise MigrationError("REPORT_PATH_CONVERSION_FAILED", "source backup path mapping is incomplete")
    replacements = [(b_path, original), (a_path, original), (copy_root, original)]
    converted = 0
    for path in reports.glob("*.json"):
        if path.name in {"source_backup.json", "path_conversion_result.json", "env_check_report.json"}:
            continue
        value = load_json(path, None)
        if value is None:
            continue
        new_value = _replace_paths(value, replacements)
        if new_value != value:
            write_json(path, new_value)
            converted += 1
    result = {"conversion_status": "success", "original_root": original, "converted_json_files": converted}
    write_json(reports / "path_conversion_result.json", result)
    return result


def run(work_dir: Path, source_db: str, target_db: str) -> dict[str, Any]:
    generate_patch(work_dir)
    convert_report_paths(work_dir)
    run_command([
        sys.executable, str(SCRIPT_DIR / "tools" / "generate_report.py"),
        "--reports-dir", str(work_dir / "reports"),
        "--output-dir", str(work_dir / "reports"),
        "--source-db", source_db,
        "--target-db", target_db,
    ], work_dir, reason="SQL_MIGRATION_REPORT_GENERATION_FAILED")
    result = load_json(work_dir / "reports" / "sql-migration-result.json", {})
    return result if isinstance(result, dict) else {}
