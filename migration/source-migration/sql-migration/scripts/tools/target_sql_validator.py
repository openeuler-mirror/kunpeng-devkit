#!/usr/bin/env python3
"""Deterministically validate converted SQL against the configured target database.

Validation is optional and only runs when target_db_conn.flag=true.  Items that
cannot be validated deterministically (missing JDK/driver/clean SQL) remain
pending_confirm rather than being guessed as successful.
"""
from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

# 本脚本位于 scripts/tools/，把 scripts/ 加入 sys.path 才能导入 common 包
SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from common.migration_common import load_json, write_json  # noqa: E402
from common.sql_context import resolve_jdk_for_target  # noqa: E402

JAVA_SOURCE = r'''
import java.sql.*;
public class SqlExplainValidator {
  public static void main(String[] args) throws Exception {
    String jdbcUrl = System.getenv("TARGET_SQL_JDBC_URL");
    String user = System.getenv("TARGET_SQL_USER");
    String password = System.getenv("TARGET_SQL_PASSWORD");
    String driverClass = System.getenv("TARGET_SQL_DRIVER_CLASS");
    if (jdbcUrl == null || driverClass == null) System.exit(2);
    Class.forName(driverClass);
    try (Connection c = DriverManager.getConnection(jdbcUrl, user == null ? "" : user, password == null ? "" : password);
         java.io.BufferedReader r = new java.io.BufferedReader(new java.io.InputStreamReader(System.in))) {
      String line;
      while ((line = r.readLine()) != null) {
        int tab = line.indexOf('\t');
        if (tab < 0) continue;
        String id = line.substring(0, tab);
        String sql = line.substring(tab + 1).replace("\\n", "\n");
        try (Statement s = c.createStatement()) {
          s.execute("EXPLAIN " + sql);
          System.out.println("PASS\t" + id);
        } catch (SQLException e) {
          System.out.println("FAIL\t" + id + "\t" + e.getSQLState() + "\t" + e.getErrorCode() + "\t" + String.valueOf(e.getMessage()).replace('\n',' '));
        }
      }
    }
  }
}
'''


def target_enabled(config: dict[str, Any]) -> bool:
    return bool((config.get("target_db_conn") or {}).get("flag"))


def _clean_sql(item: dict[str, Any]) -> str:
    # Prefer AI-provided pure SQL statement (written in workset item).
    # Fall back to validation_sql_after_ai (set by finalize), then target_sql.
    ai_target_sql = str(item.get("ai_target_sql") or "").strip()
    if ai_target_sql:
        sql = ai_target_sql
    elif "validation_sql_after_ai" in item:
        sql = str(item.get("validation_sql_after_ai") or "").strip()
    else:
        sql = str(item.get("target_sql") or "").strip()
    if not sql:
        return ""

    # Accept a single static MyBatis statement wrapper, but reject dynamic
    # template constructs whose runtime expansion cannot be reproduced safely.
    dynamic_tags = ("<if", "<foreach", "<choose", "<when", "<otherwise", "<include", "<where", "<set", "<trim")
    if any(token in sql.lower() for token in dynamic_tags) or "${" in sql:
        return ""
    match = re.match(
        r"(?is)^\s*<(select|insert|update|delete)\b[^>]*>(.*)</\1>\s*$",
        sql,
    )
    if match:
        sql = match.group(2).strip()
    if re.search(r"</?[A-Za-z][^>]*>", sql):
        return ""

    # MyBatis bound parameters are replaced with NULL only for EXPLAIN parsing.
    # No DML is executed, and raw ${...} substitutions remain unsupported.
    sql = re.sub(r"#\{[^{}]+\}", "NULL", sql)
    sql = html.unescape(sql)
    return sql.rstrip(";").strip()


def _resolve_javac(state: dict[str, Any], work_dir: Path, config: dict[str, Any]) -> Path | None:
    # 1. 从 state.sql_analysis.java_path 的同目录找 javac（DevKit 可能内嵌完整 JDK）
    java_raw = str(((state.get("sql_analysis") or {}).get("java_path")) or "")
    if java_raw:
        java = Path(java_raw)
        sibling = java.parent / "javac"
        if sibling.is_file():
            return sibling.resolve()
    # 2. 系统 PATH 中的 javac
    path = shutil.which("javac")
    if path:
        return Path(path).resolve()
    # 3. 读取入口脚本预置的 jdk_path.txt（由 sql_migration.sh 调 download_jdk.sh 准备）
    javac, _ = resolve_jdk_for_target(work_dir, config)
    return javac


def _runtime_ready(config: dict[str, Any], state: dict[str, Any], work_dir: Path) -> tuple[dict[str, str] | None, str]:
    target = config.get("target_db_conn") or {}
    required = ["jdbc_url", "driver_jar_path", "driver_class_name"]
    missing = [key for key in required if not str(target.get(key) or "").strip()]
    if missing:
        return None, "target_db_conn missing: " + ", ".join(missing)
    driver = Path(str(target["driver_jar_path"])).expanduser().resolve()
    if not driver.is_file():
        return None, f"target JDBC driver not found: {driver}"
    javac = _resolve_javac(state, work_dir, config)
    if javac is None:
        return None, "JDK javac not available for target SQL validation"
    java = javac.parent / "java"
    if not java.is_file():
        return None, f"java not found beside javac: {java}"
    return {
        "jdbc_url": str(target["jdbc_url"]),
        "user": str(target.get("user") or ""),
        "password": str(target.get("password") or ""),
        "driver": str(driver),
        "driver_class": str(target["driver_class_name"]),
        "javac": str(javac),
        "java": str(java),
    }, ""


def validate(
    work_dir: Path,
    work_items: list[dict[str, Any]],
    converted_ids: set[str],
    db_config_path: Path,
) -> dict[str, Any]:
    """对 converted_ids 项执行目标库 EXPLAIN 验证。

    db_config_path 必传：SKILL 中 db-connection.json 的路径，由调用方注入
    （main 从 --db-config 解析；finalize_ai_stage._run_target_validation 从 state 读取）。
    """
    config = load_json(db_config_path, {})
    state = load_json(work_dir / "sql-migration-state.json", {})
    result = {"enabled": target_enabled(config), "passed": [], "failed": {}, "pending": {}, "validated_sql": {}}
    if not result["enabled"]:
        for wid in converted_ids:
            result["pending"][wid] = "target database validation disabled"
        write_json(work_dir / "reports" / "target-sql-validation.json", result)
        return result

    runtime, reason = _runtime_ready(config, state if isinstance(state, dict) else {}, work_dir)
    if runtime is None:
        for wid in converted_ids:
            result["pending"][wid] = reason
        write_json(work_dir / "reports" / "target-sql-validation.json", result)
        return result

    by_id = {str(item.get("workset_id") or ""): item for item in work_items}
    candidates: dict[str, str] = {}
    for wid in converted_ids:
        sql = _clean_sql(by_id.get(wid, {}))
        if sql:
            candidates[wid] = sql
        else:
            result["pending"][wid] = "no deterministic clean target_sql available for EXPLAIN"
    if not candidates:
        write_json(work_dir / "reports" / "target-sql-validation.json", result)
        return result

    reports = work_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sql-validator-", dir=str(work_dir)) as tmp_raw:
        tmp = Path(tmp_raw)
        src = tmp / "SqlExplainValidator.java"
        src.write_text(JAVA_SOURCE, encoding="utf-8")
        compile_proc = subprocess.run([runtime["javac"], str(src)], cwd=str(tmp), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        if compile_proc.returncode != 0:
            for wid in candidates:
                result["pending"][wid] = "validator compile failed: " + (compile_proc.stdout or "")[-500:]
            write_json(reports / "target-sql-validation.json", result)
            return result
        escaped_nl = r"\\n"
        stdin = "\n".join(f"{wid}\t{sql.replace(chr(10), escaped_nl)}" for wid, sql in candidates.items()) + "\n"
        cp = str(tmp) + ":" + runtime["driver"]
        env = os.environ.copy()
        env.update({
            "TARGET_SQL_JDBC_URL": runtime["jdbc_url"],
            "TARGET_SQL_USER": runtime["user"],
            "TARGET_SQL_PASSWORD": runtime["password"],
            "TARGET_SQL_DRIVER_CLASS": runtime["driver_class"],
        })
        proc = subprocess.run(
            [runtime["java"], "-cp", cp, "SqlExplainValidator"],
            input=stdin, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        for line in (proc.stdout or "").splitlines():
            parts = line.split("\t", 4)
            if len(parts) >= 2 and parts[0] == "PASS":
                result["passed"].append(parts[1])
            elif len(parts) >= 2 and parts[0] == "FAIL":
                result["failed"][parts[1]] = parts[4] if len(parts) >= 5 else line
        seen = set(result["passed"]) | set(result["failed"]) | set(result["pending"])
        for wid in candidates:
            if wid not in seen:
                result["pending"][wid] = "validator did not return a result"
        result["validated_sql"] = {wid: candidates[wid] for wid in result["passed"] if wid in candidates}
        result["validator_rc"] = proc.returncode
    write_json(reports / "target-sql-validation.json", result)
    return result


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Validate converted SQL against configured target database")
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--workset", default="")
    parser.add_argument("--converted", default="")
    parser.add_argument(
        "--db-config",
        required=True,
        help="SKILL 中 assets/db-connection.json 的绝对路径",
    )
    args = parser.parse_args()
    work_dir = Path(args.work_dir).expanduser().resolve()
    db_config_path = Path(args.db_config).expanduser().resolve()
    workset_path = Path(args.workset).expanduser().resolve() if args.workset else work_dir / "reports" / "ai-workset.json"
    workset = load_json(workset_path, {})
    items = workset.get("items") if isinstance(workset, dict) else []
    converted = {v.strip() for v in args.converted.split(",") if v.strip()}
    output = validate(
        work_dir,
        [v for v in items or [] if isinstance(v, dict)],
        converted,
        db_config_path,
    )
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
