#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
parse_report.py
解析 DevKit 输出的 Sql_Analysis_Report_*.json 报告，提取所有 SQL 条目。

DevKit 报告为三层嵌套结构：
    外层数组 → 项目对象(results=文件列表) → 文件对象(results=SQL列表) → SQL 对象

本脚本提供两种模式：
    1. --parse-only      仅解析，输出 SQL 列表 JSON 到 stdout 或指定文件
    2. --generate-reports 解析并按 target_sql/compatibility 字段生成分类报告
                         (compatible_sql.json / migrated_sql.json / to_do-migrated_sql.json)

    可选 --merge 参数（配合 --generate-reports）：
        合并已有的 migrated_sql.json，保留路线 A 步骤 2.1 生成的 DevKit 转换记录。
        用于路线 A 步骤 4.1 场景：步骤 4 重新扫描后，步骤 2 中 DevKit 成功转换的 SQL
        变成 compatibility=0（已兼容），不会出现在当前解析结果中。
        --merge 按 path+sql_id 去重，将已有记录保留，新增记录追加。

用法：
    # 模式1：解析并输出到 stdout
    python3 parse_report.py --report <报告路径> --parse-only

    # 模式1：解析并输出到文件
    python3 parse_report.py --report <报告路径> --parse-only --output sql_list.json

    # 模式2：解析并生成分类报告（路线A用，按 target_sql/compatibility 分流）
    python3 parse_report.py --report <报告路径> --generate-reports --output-dir <输出目录>

    # 模式2 + --merge：路线 A 步骤 4.1 重新生成报告时保留步骤 2.1 的 DevKit 转换记录
    python3 parse_report.py --reports-dir <目录> --generate-reports --output-dir <输出目录> --merge

    # 可选：指定 reports 目录，自动查找最新的 Sql_Analysis_Report_*.json
    python3 parse_report.py --reports-dir <目录> --parse-only

退出码：
    0  成功
    1  参数错误或报告未找到
    2  JSON 解析错误
    3  输出失败

字段说明（SQL 级，即最内层 results 数组元素）：
    statement       提取的 SQL 语句（补全后）
    original_sql    源代码中原始 SQL 片段（含 MyBatis 标签等）
    start_line/end_line  SQL 在源文件中的行号区间
    sql_id          SQL 标识（MyBatis mapper 的 id 属性）
    tag             SQL 类型（select/insert/update/delete）
    compatibility   兼容性评估结果：0=已兼容、1=不兼容、2=待确认
    convert_result  转换结果对象（转换成功时含非空 target_sql；
                    转换失败时含 suggestions 建议、target_sql 为空、convert_status=2；
                    未尝试转换时为 null）
    target_sql      转换后的 SQL（parse_report.py 从 convert_result.target_sql 提取，
                    转换成功时非空，转换失败/未尝试时为空字符串）
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Any


# ---------------------------------------------------------------------------
# 核心解析逻辑
# ---------------------------------------------------------------------------

def parse_devkit_report(report_path: str) -> list[dict[str, Any]]:
    """
    解析 DevKit 输出的 Sql_Analysis_Report_*.json，提取所有 SQL 条目。

    三层嵌套遍历：项目 → 文件 → SQL

    Args:
        report_path: DevKit 报告 JSON 文件路径

    Returns:
        SQL 条目列表，每条含 file_path / file_name / start_line / end_line /
        sql_id / tag / statement / original_sql / compatibility / convert_result /
        related_statement / source_compatible_type 等字段

    Raises:
        FileNotFoundError: 报告文件不存在
        json.JSONDecodeError: JSON 解析失败
        ValueError: 报告结构不符合预期
    """
    with open(report_path, "r", encoding="utf-8") as f:
        devkit_data = json.load(f)

    if not isinstance(devkit_data, list):
        raise ValueError(
            f"报告外层应为数组，实际为 {type(devkit_data).__name__}。"
            f"请确认这是 DevKit 输出的 Sql_Analysis_Report_*.json 文件。"
        )

    all_sqls: list[dict[str, Any]] = []

    # 三层嵌套：项目 → 文件 → SQL
    for _, project_entry in enumerate(devkit_data):
        if not isinstance(project_entry, dict):
            continue

        for file_entry in project_entry.get("results", []):
            if not isinstance(file_entry, dict):
                continue

            file_path = file_entry.get("path", "")
            file_name = os.path.basename(file_path) if file_path else ""

            for sql_entry in file_entry.get("results", []):
                if not isinstance(sql_entry, dict):
                    continue

                # 提取 SQL 级字段
                entry: dict[str, Any] = {
                    # 文件级信息（从文件级对象继承）
                    "file_path": file_path,
                    "file_name": file_name,
                    # SQL 级字段
                    "start_line": sql_entry.get("start_line", 0),
                    "end_line": sql_entry.get("end_line", 0),
                    "sql_id": sql_entry.get("sql_id", ""),
                    "tag": sql_entry.get("tag", ""),
                    "statement": sql_entry.get("statement", ""),
                    "original_sql": sql_entry.get("original_sql", ""),
                    "compatibility": sql_entry.get("compatibility"),
                    "convert_result": sql_entry.get("convert_result"),
                    "related_statement": sql_entry.get("related_statement"),
                    # 辅助字段
                    "uuid": sql_entry.get("uuid", ""),
                    "is_risky": sql_entry.get("is_risky", False),
                    "message_type": sql_entry.get("message_type", 0),
                    "source_compatible_type": sql_entry.get("source_compatible_type", 0),
                    # mapper_includes（MyBatis <sql> 片段，可能为 null）
                    "mapper_includes": sql_entry.get("mapper_includes"),
                    # quickfix_items（DevKit 生成的 patch 项）
                    # 非空列表表示 DevKit 已生成 patch；空列表表示虽有 target_sql
                    # 但因动态验证表/列缺失等原因未生成 patch，需 AI 二次转换
                    "quickfix_items": sql_entry.get("quickfix_items", []),
                    # explain_exec_result_before（DevKit 动态评估时对原始 SQL 执行 EXPLAIN 的结果）
                    # 用于阶段3路线A AI预筛：判断"对象缺失"vs"真实不兼容"
                    # 仅在 DevKit 启用 --enable-analysis-enhance 时有值
                    "explain_exec_result_before": sql_entry.get("explain_exec_result_before"),
                }

                # 若 convert_result 非空，提取 target_sql
                convert_result = sql_entry.get("convert_result")
                if isinstance(convert_result, dict):
                    entry["target_sql"] = convert_result.get("target_sql", "")
                else:
                    entry["target_sql"] = ""

                all_sqls.append(entry)

    return all_sqls


def classify_sqls(
    sqls: list[dict[str, Any]],
) -> tuple[list[dict], list[dict], list[dict]]:
    """
    按 compatibility / convert_result / target_sql / quickfix_items 字段将 SQL 分为三类（路线A用）。

    分类规则：
        target_sql 非空且 quickfix_items 非空 -> DevKit 已迁移（migrated_sql）
        target_sql 非空但 quickfix_items 为空 -> 待 AI 迁移（to_do-migrated_sql）
            （DevKit 给出转换建议但未生成 patch，需 AI 依据 target_sql 二次转换）
        target_sql 为空且 compatibility=0 -> 已兼容（compatible_sql）
        target_sql 为空且 compatibility=1/2 -> 待 AI 迁移（to_do-migrated_sql）

    注意：
        1. DevKit 转换失败但仍返回 convert_result（含 suggestions 建议、
           target_sql 为空、convert_status=2）的 SQL，应归入 to_do-migrated_sql，
           不应误判为已迁移。
        2. DevKit 转换成功（target_sql 非空）但因动态验证表/列缺失等原因
           未生成 patch（quickfix_items 为空列表）的 SQL，也应归入
           to_do-migrated_sql，由 AI 依据 target_sql 二次转换后标记 DevKit+AI。

    Args:
        sqls: parse_devkit_report 返回的 SQL 条目列表

    Returns:
        (compatible_sqls, migrated_sqls, to_do_sqls) 三元组
    """
    compatible_sqls: list[dict] = []
    migrated_sqls: list[dict] = []
    to_do_sqls: list[dict] = []

    for sql in sqls:
        compat = sql.get("compatibility")
        target_sql = sql.get("target_sql", "") or ""
        quickfix_items = sql.get("quickfix_items", []) or []

        if target_sql.strip() and quickfix_items:
            # DevKit 已成功转换且生成 patch（quickfix_items 非空）
            migrated_sqls.append(sql)
        elif target_sql.strip():
            # DevKit 给出转换建议但未生成 patch（quickfix_items 为空）
            # 需 AI 依据 target_sql 二次转换，最终标记 DevKit+AI
            to_do_sqls.append(sql)
        elif compat == 0:
            # 已兼容，无需转换
            compatible_sqls.append(sql)
        else:
            # compatibility=1（不兼容）或 2（待确认），需 AI 处理
            # 包括 convert_result 非 None 但 target_sql 为空的场景
            # （DevKit 转换失败仅给出建议）
            to_do_sqls.append(sql)

    return compatible_sqls, migrated_sqls, to_do_sqls


# ---------------------------------------------------------------------------
# 报告格式化（用于 --generate-reports 模式）
# ---------------------------------------------------------------------------

def format_report_entry(sql: dict[str, Any]) -> dict[str, Any]:
    """
    将 SQL 条目格式化为标准报告格式。

    输出字段与主 SKILL.md 路线 A 步骤 2.1 定义的报告格式一致：
        path / start_line / end_line / source_sql / target_sql / related_statement

    兼容两种输入格式：
        - parse_devkit_report 的原始输出（file_path / statement）
        - 已格式化的 JSON 报告条目（path / source_sql，如 --merge 读取的已有记录）

    conversion_source 标记规则：
        - target_sql 非空且 quickfix_items 非空 → "DevKit"（DevKit 已转换且生成 patch）
        - target_sql 非空但 quickfix_items 为空 → 不标记（DevKit 给出建议但未生成 patch，
          需 AI 依据 target_sql 二次转换，阶段 3 标记为 "DevKit+AI"）
        - target_sql 为空 → 不标记（待 AI 转换，阶段 3 标记为 "AI"）
        - 已有 conversion_source 的条目保留原值（避免 AI/DevKit+AI 条目被误覆盖）
    """
    # 从 convert_result.suggestions 提取 suggestion_cn 列表
    # 供阶段3预筛区分"DevKit分析类"（真实不兼容）和"EXPLAIN结果类"（对象缺失）
    suggestions_cn = sql.get("suggestions_cn")
    if suggestions_cn is None:
        convert_result = sql.get("convert_result")
        if isinstance(convert_result, dict):
            suggestions = convert_result.get("suggestions", []) or []
            suggestions_cn = [
                s.get("suggestion_cn", "") for s in suggestions if isinstance(s, dict)
            ]
        else:
            suggestions_cn = []
    entry = {
        "path": sql.get("file_path", "") or sql.get("path", ""),
        "start_line": sql.get("start_line", 0),
        "end_line": sql.get("end_line", 0),
        "sql_id": sql.get("sql_id", ""),
        "tag": sql.get("tag", ""),
        "source_sql": sql.get("statement", "") or sql.get("source_sql", ""),
        "target_sql": sql.get("target_sql", ""),
        "original_sql": sql.get("original_sql", ""),
        "related_statement": sql.get("related_statement"),
        # 保留 explain_exec_result_before，供阶段3路线A AI预筛使用
        "explain_exec_result_before": sql.get("explain_exec_result_before"),
        # 保留 suggestions_cn，供阶段3预筛区分 DevKit 分析类与 EXPLAIN 结果类
        "suggestions_cn": suggestions_cn,
    }
    # 保留已有的 conversion_source（如 AI / DevKit+AI），仅对新的 DevKit 条目添加标记
    existing_source = sql.get("conversion_source", "")
    if existing_source:
        entry["conversion_source"] = existing_source
    else:
        target_sql = (entry.get("target_sql", "") or "").strip()
        quickfix_items = sql.get("quickfix_items", []) or []
        if target_sql and quickfix_items:
            # DevKit 已成功转换且生成 patch
            entry["conversion_source"] = "DevKit"
        # target_sql 非空但 quickfix_items 为空时不标记，
        # 由阶段 3 AI 依据 target_sql 二次转换后标记为 "DevKit+AI"
    return entry


def write_report(
    output_dir: str, filename: str, entries: list[dict], indent: int = 2
) -> str:
    """将报告条目写入 JSON 文件，返回文件路径。"""
    os.makedirs(output_dir, exist_ok=True)
    filepath = os.path.join(output_dir, filename)
    formatted = [format_report_entry(sql) for sql in entries]
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(formatted, f, ensure_ascii=False, indent=indent)
    return filepath


# ---------------------------------------------------------------------------
# 报告查找
# ---------------------------------------------------------------------------

def find_latest_report(reports_dir: str) -> str | None:
    """
    在指定目录下查找最新的 Sql_Analysis_Report_*.json 文件。

    Args:
        reports_dir: 报告目录路径

    Returns:
        最新报告文件的完整路径，未找到返回 None
    """
    pattern = os.path.join(reports_dir, "Sql_Analysis_Report_*.json")
    report_files = glob.glob(pattern)
    if not report_files:
        return None
    # 按修改时间排序，取最新的
    report_files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return report_files[0]


def load_existing_report(filepath: str) -> list[dict[str, Any]]:
    """
    读取已有的分类报告 JSON 文件。

    Args:
        filepath: 报告文件路径

    Returns:
        报告条目列表，文件不存在或解析失败时返回空列表
    """
    if not os.path.isfile(filepath):
        return []
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
    except (json.JSONDecodeError, OSError):
        pass
    return []


def make_dedup_key(entry: dict[str, Any]) -> str:
    """
    生成去重 key：path + start_line + end_line + sql_id。

    使用物理位置（path + 行号区间）作为唯一标识，避免以下问题：
    - sql_id 为空时碰撞（非 MyBatis 场景）
    - 同文件同 sql_id 但不同 SQL 的碰撞（如 JDBC 中同方法多 SQL）

    Args:
        entry: SQL 条目（支持 parse_devkit_report 原始输出和 format_report_entry 格式）

    Returns:
        去重 key 字符串
    """
    path = entry.get("file_path", "") or entry.get("path", "")
    return f"{path}::{entry.get('start_line', 0)}::{entry.get('end_line', 0)}::{entry.get('sql_id', '')}"


def merge_migrated_sqls(
    existing: list[dict[str, Any]],
    current: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """
    合并已有的 migrated_sql.json 和当前解析的 DevKit 已迁移 SQL。

    用于路线 A 步骤 4.1 场景：步骤 4 重新扫描后，步骤 2 中 DevKit 成功转换的 SQL
    变成 compatibility=0（已兼容），不会出现在当前解析结果中。
    通过 --merge 合并，保留步骤 2.1 生成的 DevKit 转换记录。

    去重规则：按 path + start_line + end_line + sql_id 去重。若同一条 SQL
    同时存在于已有和当前结果中，优先保留已有记录（保留 conversion_source 等附加字段）。

    Args:
        existing: 已有 migrated_sql.json 中的条目列表
        current: 当前解析出的 DevKit 已迁移条目列表

    Returns:
        合并后的条目列表（已有记录在前，新增记录在后）
    """
    existing_keys = {make_dedup_key(e) for e in existing}
    merged = list(existing)
    for entry in current:
        key = make_dedup_key(entry)
        if key not in existing_keys:
            merged.append(entry)
            existing_keys.add(key)
    return merged


def deduplicate_compatible_sqls(
    compatible_sqls: list[dict[str, Any]],
    migrated_sqls: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """
    从 compatible_sqls 中排除已存在于 migrated_sqls 的 SQL。

    用于 --merge 模式（路线 A 步骤 4.1）：步骤 4 重新扫描后，步骤 2.1 中
    DevKit 已转换的 SQL 因 patch 已应用，compatibility 变为 0，会被误分类
    到 compatible_sqls。这些 SQL 已在 migrated_sqls 中（通过 --merge 保留），
    需从 compatible_sqls 中排除，避免跨报告重复。

    Args:
        compatible_sqls: 当前解析出的已兼容 SQL 列表
        migrated_sqls: 合并后的 migrated SQL 列表

    Returns:
        排除重复后的 compatible_sqls 列表
    """
    migrated_keys = {make_dedup_key(e) for e in migrated_sqls}
    return [e for e in compatible_sqls if make_dedup_key(e) not in migrated_keys]


# ---------------------------------------------------------------------------
# CLI 主入口
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="解析 DevKit 输出的 Sql_Analysis_Report_*.json 报告",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # 报告来源（二选一）
    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument(
        "--report",
        help="DevKit 报告 JSON 文件路径",
    )
    source_group.add_argument(
        "--reports-dir",
        help="报告目录，自动查找最新的 Sql_Analysis_Report_*.json",
    )

    # 模式（二选一，必填）
    mode_group = parser.add_mutually_exclusive_group(required=True)
    mode_group.add_argument(
        "--parse-only",
        action="store_true",
        help="仅解析，输出 SQL 列表 JSON",
    )
    mode_group.add_argument(
        "--generate-reports",
        action="store_true",
        help="解析并生成分类报告（compatible_sql.json / migrated_sql.json / to_do-migrated_sql.json）",
    )

    # 输出
    parser.add_argument(
        "--output",
        help="--parse-only 模式下的输出文件路径（默认输出到 stdout）",
    )
    parser.add_argument(
        "--output-dir",
        help="--generate-reports 模式下的输出目录",
    )
    parser.add_argument(
        "--merge",
        action="store_true",
        help="合并已有的 migrated_sql.json（按 path+sql_id 去重，保留路线 A 步骤 2.1 的 DevKit 转换记录）",
    )

    args = parser.parse_args()

    # --- 确定报告路径 ---
    if args.report:
        report_path = args.report
        if not os.path.isfile(report_path):
            print(f"错误: 报告文件不存在: {report_path}", file=sys.stderr)
            return 1
    else:
        report_path = find_latest_report(args.reports_dir)
        if report_path is None:
            print(
                f"错误: 在 {args.reports_dir} 下未找到 Sql_Analysis_Report_*.json",
                file=sys.stderr,
            )
            return 1

    # --- 解析报告 ---
    try:
        sqls = parse_devkit_report(report_path)
    except FileNotFoundError:
        print(f"错误: 报告文件不存在: {report_path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"错误: JSON 解析失败: {e}", file=sys.stderr)
        return 2
    except ValueError as e:
        print(f"错误: 报告结构异常: {e}", file=sys.stderr)
        return 2

    print(f"已解析: {report_path}", file=sys.stderr)
    print(f"共提取 {len(sqls)} 条 SQL", file=sys.stderr)

    # --- 模式1：仅解析 ---
    if args.parse_only:
        output_json = json.dumps(sqls, ensure_ascii=False, indent=2)
        if args.output:
            try:
                with open(args.output, "w", encoding="utf-8") as f:
                    f.write(output_json)
                print(f"已输出到: {args.output}", file=sys.stderr)
            except IOError as e:
                print(f"错误: 写入文件失败: {e}", file=sys.stderr)
                return 3
        else:
            print(output_json)
        return 0

    # --- 模式2：生成分类报告 ---
    if args.generate_reports:
        if not args.output_dir:
            print("错误: --generate-reports 模式需要指定 --output-dir", file=sys.stderr)
            return 1

        compatible_sqls, migrated_sqls, to_do_sqls = classify_sqls(sqls)

        # --merge 模式：合并已有的 migrated_sql.json
        # 用于路线 A 步骤 4.1 场景，保留步骤 2.1 生成的 DevKit 转换记录
        # （步骤 4 重新扫描后这些 SQL 变成 compatibility=0，不会出现在当前结果中）
        merged_count = 0
        if args.merge:
            existing_path = os.path.join(args.output_dir, "migrated_sql.json")
            existing_migrated = load_existing_report(existing_path)
            if existing_migrated:
                before = len(migrated_sqls)
                migrated_sqls = merge_migrated_sqls(existing_migrated, migrated_sqls)
                merged_count = len(migrated_sqls) - before
                if merged_count > 0:
                    print(
                        f"--merge: 从已有 migrated_sql.json 保留了 {merged_count} 条 DevKit 转换记录",
                        file=sys.stderr,
                    )
            # 合并后，从 compatible_sqls 中排除已存在于 migrated_sqls 的 SQL
            # （步骤 2.1 已转换的 SQL 在步骤 4 重新扫描时变成 compatibility=0，
            #  会被误分类到 compatible_sqls，需排除避免跨报告重复）
            before_compat = len(compatible_sqls)
            compatible_sqls = deduplicate_compatible_sqls(compatible_sqls, migrated_sqls)
            removed = before_compat - len(compatible_sqls)
            if removed > 0:
                print(
                    f"--merge: 从 compatible_sqls 中排除了 {removed} 条已迁移 SQL（避免跨报告重复）",
                    file=sys.stderr,
                )

        written: list[str] = []

        # 已兼容
        if compatible_sqls:
            p = write_report(args.output_dir, "compatible_sql.json", compatible_sqls)
            written.append(f"  compatible_sql.json: {len(compatible_sqls)} 条")

        # DevKit 已迁移（仅路线A产生）
        # 注意：--merge 模式下即使当前解析无新增迁移，也写入合并后的结果
        if migrated_sqls:
            p = write_report(args.output_dir, "migrated_sql.json", migrated_sqls)
            written.append(f"  migrated_sql.json: {len(migrated_sqls)} 条")

        # 待 AI 迁移
        # 注意：即使 to_do_sqls 为空也写入空数组，便于下游判断
        p = write_report(args.output_dir, "to_do-migrated_sql.json", to_do_sqls)
        written.append(f"  to_do-migrated_sql.json: {len(to_do_sqls)} 条")

        print("已生成报告:", file=sys.stderr)
        for line in written:
            print(line, file=sys.stderr)
        print(f"输出目录: {args.output_dir}", file=sys.stderr)
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
