#!/usr/bin/env python3
"""Resolve SQL migration configuration, tool runtime and database route."""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Iterable

from common.migration_common import MigrationError, load_json, run_command

# 模块不再持有 SKILL_DIR/DEFAULT_DB_CONFIG 常量：二进制封装后，db-connection.json
# 路径由调用方通过 --db-config 显式注入并写入 state，模块自身不依赖 SKILL 目录结构。
# references/ai-sql-transformation.md 与 scripts/sql_migration.sh 由 Agent 通过 SKILL
# 目录结构自行定位，不再通过参数注入二进制。


def _read_devkit_path_report(work_dir: Path) -> tuple[Path | None, Path | None, Path | None]:
    """读取 download_devkit.sh 写入的 devkit_path.txt。

    文件格式：
      DEVKIT_TOOL_PATH=<jar 所在目录>
      JAR_FILE=<jar 完整路径>
      CONFIG_DIR=<config 目录>
      CONFIG_COMPLETE=true/false
      MISSING_CONFIGS=...
      JAVA_HOME=<Java 根目录或 none>
      AI_MIGRATION=<ai-migration 二进制路径或 none>

    所有 DevKit 定位/下载/校验逻辑都在 download_devkit.sh 中完成，
    Python 侧只读取结果。返回 (jar, java, ai_migration_path) 三元组。
    """
    report = work_dir / "reports" / "devkit_path.txt"
    if not report.is_file():
        return None, None, None
    values: dict[str, str] = {}
    for line in report.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    jar_raw = values.get("JAR_FILE", "")
    java_home = values.get("JAVA_HOME", "")
    ai_migration_raw = values.get("AI_MIGRATION", "")
    jar = Path(jar_raw).expanduser().resolve() if jar_raw and Path(jar_raw).expanduser().is_file() else None
    java = None
    if java_home and java_home != "none":
        candidate = Path(java_home).expanduser() / "bin" / "java"
        if candidate.is_file():
            java = candidate.resolve()
    ai_migration = None
    if ai_migration_raw and ai_migration_raw != "none":
        candidate = Path(ai_migration_raw).expanduser()
        if candidate.is_file():
            ai_migration = candidate.resolve()
    return jar, java, ai_migration


def _read_jdk_path_report(report_path: Path) -> tuple[Path | None, Path | None]:
    """读取 jdk_path.txt，返回 (javac_path, java_home)。

    文件格式（由 download_jdk.sh 写入）：
      JAVA_HOME=<路径>
      JAVA_BIN=<java 可执行文件路径>
      JAVA_VERSION=<版本>
    """
    if not report_path.is_file():
        return None, None
    values: dict[str, str] = {}
    for line in report_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    java_home_raw = values.get("JAVA_HOME", "")
    java_home = Path(java_home_raw).expanduser().resolve() if java_home_raw else None
    javac = (java_home / "bin" / "javac") if java_home else None
    if javac and not javac.is_file():
        javac = None
    return javac, java_home


def resolve_jdk_for_target(work_dir: Path, db_config: dict[str, Any]) -> tuple[Path | None, str]:
    """读取入口脚本预置的 jdk_path.txt，返回 (javac, java_home)。

    JDK 的定位/下载由外层入口 sql_migration.sh 在 target_db_conn.flag=true 时
    调用 download_jdk.sh 完成，并写入 reports/jdk_path.txt。本函数只读取结果。
    """
    if not bool_value((db_config.get("target_db_conn") or {}).get("flag")):
        return None, "target validation disabled"

    javac, java_home = _read_jdk_path_report(work_dir / "reports" / "jdk_path.txt")
    if javac and javac.is_file():
        return javac, str(java_home)
    return None, "JDK not prepared by entry script (sql_migration.sh)"


def read_devkit_environment(work_dir: Path) -> tuple[Path, Path, Path | None]:
    """读取入口脚本预置的 devkit_path.txt，返回 (java_path, jar_path, ai_migration_path)。

    DevKit 的定位/下载由外层入口 sql_migration.sh 调用 download_devkit.sh 完成，
    并写入 reports/devkit_path.txt。本函数只读取结果，假设环境已就绪；
    读不到说明未通过入口脚本执行，直接报错。

    ai_migration_path 可能为 None（devkit_path.txt 未写入 AI_MIGRATION 字段，
    或字段值为 none）；调用方负责降级处理。
    """
    jar, java_path, ai_migration = _read_devkit_path_report(work_dir)
    if jar is None or not jar.is_file():
        raise MigrationError(
            "SQL_ANALYSIS_ENV_NOT_PREPARED",
            "DevKit 环境未就绪：未找到 reports/devkit_path.txt 或 jar 不可用，请通过 sql_migration.sh 入口执行",
            2,
        )
    if java_path is None or not java_path.is_file():
        raise MigrationError(
            "JAVA_PATH_REQUIRED",
            "Java 运行时未就绪：devkit_path.txt 中 JAVA_HOME 不可用，请通过 sql_migration.sh 入口执行",
            2,
        )
    return java_path.resolve(), jar.resolve(), ai_migration


def validate_java_executable(java_path: Path, work_dir: Path) -> dict[str, Any]:
    result = run_command([str(java_path), "-version"], work_dir, reason="JAVA_RUNTIME_INVALID")
    return {"java_path": str(java_path), "version_output": (result.stdout or "").strip()}


def load_db_config(path: Path) -> dict[str, Any]:
    """加载 db-connection.json。path 必传，由调用方注入（SKILL assets 路径）。"""
    value = load_json(path, {})
    return value if isinstance(value, dict) else {}


def db_env(config: dict[str, Any]) -> dict[str, str]:
    env: dict[str, str] = {}
    mapping = (("source_db_conn", "SOURCE_DB"), ("target_db_conn", "TARGET_DB"))
    fields = {
        "jdbc_url": "JDBC_URL",
        "user": "USER",
        "password": "PWD",
        "driver_jar_path": "DRIVER_JAR_PATH",
        "driver_class_name": "DRIVER_CLASS_NAME",
    }
    for section_name, prefix in mapping:
        section = config.get(section_name) or {}
        if not isinstance(section, dict) or not bool(section.get("flag")):
            continue
        for key, suffix in fields.items():
            value = str(section.get(key) or "")
            if value:
                env[f"{prefix}_{suffix}"] = value
    return env


def bool_value(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    return str(value or "").strip().lower() in {"1", "true", "yes", "y"}


def normalized_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())


def pick(obj: dict[str, Any], names: Iterable[str]) -> Any:
    normalized = {normalized_key(k): v for k, v in obj.items()}
    for name in names:
        key = normalized_key(name)
        if key in normalized:
            return normalized[key]
    return None


def route_config_path(jar_path: Path) -> Path | None:
    real = jar_path.resolve()
    for parent in [real.parent, *list(real.parents)[:3]]:
        candidate = parent / "config" / "sql_mig_route.json"
        if candidate.is_file():
            return candidate
    return None


def select_route(jar_path: Path, source_db: str, target_db: str) -> tuple[str, str, str, dict[str, Any]]:
    config_path = route_config_path(jar_path)
    fallback_source = re.sub(r"\s+", "", source_db)
    fallback_target = re.sub(r"\s+", "", target_db)
    if config_path is None:
        return "B", fallback_source, fallback_target, {"reason": "route_config_not_found"}
    raw = load_json(config_path, {})
    routes = raw.get("routes") if isinstance(raw, dict) else raw
    if not isinstance(routes, list):
        return "B", fallback_source, fallback_target, {"reason": "route_config_invalid", "config": str(config_path)}
    source_key = normalized_key(source_db)
    target_key = normalized_key(target_db)
    for route in routes:
        if not isinstance(route, dict):
            continue
        src = pick(route, ["source_db", "sourceDb", "sourceDbType", "dbSourceType", "source"])
        tgt = pick(route, ["target_db", "targetDb", "targetDbType", "dbTargetType", "target"])
        if normalized_key(src) != source_key or normalized_key(tgt) != target_key:
            continue
        canonical_source = str(src) if src else fallback_source
        canonical_target = str(tgt) if tgt else fallback_target
        need_convert = bool_value(pick(route, ["need_convert", "sqlConvert", "needConvert", "convert"]))
        need_patch = bool_value(pick(route, ["need_patch", "patchGenerate", "needPatch", "patch"]))
        is_mysql_to_vastbase = source_key == "mysql" and target_key == "vastbase"
        if need_convert and need_patch:
            route_name = "A"
        elif need_convert and not need_patch and is_mysql_to_vastbase:
            route_name = "C"
        else:
            route_name = "B"
        return route_name, canonical_source, canonical_target, {
            "config": str(config_path),
            "matched": route,
            "canonical_source_db": canonical_source,
            "canonical_target_db": canonical_target,
        }
    return "B", fallback_source, fallback_target, {"reason": "route_not_matched", "config": str(config_path)}


def build_context(
    project_path: Path,
    work_dir: Path,
    source_db: str,
    target_db: str,
    db_config_path: Path,
) -> dict[str, Any]:
    """构造 SQL 迁移上下文。

    db_config_path 必传：SKILL 中 db-connection.json 的路径，由入口脚本透传。
    ai_migration_path 来自 devkit_path.txt 的 AI_MIGRATION 字段；可能为 None，
    调用方（如 analyze.build_ai_workset）应做降级处理。
    """
    java_path, jar_path, ai_migration_path = read_devkit_environment(work_dir)
    config = load_db_config(db_config_path)
    route, canonical_source, canonical_target, route_info = select_route(jar_path, source_db, target_db)
    return {
        "project_path": project_path,
        "work_dir": work_dir,
        "input_source_db": source_db,
        "input_target_db": target_db,
        "source_db": canonical_source,
        "target_db": canonical_target,
        "java_path": java_path,
        "jar_path": jar_path,
        "ai_migration_path": ai_migration_path,
        "route": route,
        "route_info": route_info,
        "db_config": config,
        "db_config_path": db_config_path,
    }
