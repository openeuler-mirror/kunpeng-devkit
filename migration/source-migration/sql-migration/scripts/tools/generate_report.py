#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generate_report.py
汇总各类 JSON 报告为 Excel 表格或 CSV 文件，确保中文无乱码。

用法：
    python3 generate_report.py \
        --reports-dir <报告目录> \
        --output-dir <输出目录>

输出：
    - 若 openpyxl 可用 → migration_summary.xlsx（5 个 Sheet）
    - 若 openpyxl 不可用 → migration_summary.csv（UTF-8 BOM，单文件含"分类"列区分来源）
"""

import argparse
import csv
import json
import os
import sys


# Sheet 名称、对应 JSON 文件、分类标签的映射
# 分类标签同时用于 CSV 的"分类"列和各类默认值的查找
SHEET_CONFIG = [
    ("已兼容SQL", "compatible_sql.json", "已兼容"),
    ("已迁移SQL", "migrated_sql.json", "DevKit已迁移"),
    ("待迁移SQL", "to_do-migrated_sql.json", "待迁移"),
    ("待确认SQL", "pending_confirm_sql.json", "待确认"),
    ("人工介入SQL", "manual_review_report.json", "需人工介入"),
]

# 各类别的字段默认值
# 不在此表中的字段由 JSON 条目自身的值决定
CATEGORY_DEFAULTS = {
    "已兼容": {
        "兼容性": "已兼容",
        "转换状态": "无需转换",    # 已兼容的SQL无需转换，不是"已兼容"（那是兼容性结果）
        "转换后SQL语句": "",      # 已兼容无需转换
        "转换建议": "",
        "patch状态": "无需转换",
    },
    "AI确认兼容": {
        "兼容性": "已兼容",
        "转换状态": "AI确认兼容",
        "转换后SQL语句": "",
        "转换建议": "AI语义判断无需转换",
        "patch状态": "无需转换",
    },
    "DevKit已迁移": {
        "兼容性": "不兼容",
        "转换状态": "DevKit已迁移",  # 默认值，有 conversion_source="AI" 时会被覆盖为 "AI已迁移"
        "patch状态": "已生成",
    },
    "待迁移": {
        "兼容性": "不兼容",
        "转换状态": "待迁移",
        "转换后SQL语句": "",      # 尚未转换
        "转换建议": "",
        "patch状态": "待生成",
    },
    "待确认": {
        "兼容性": "不兼容",
        "转换状态": "待确认",
        "patch状态": "待确认",
    },
    "AI待确认": {
        "兼容性": "不兼容",
        "转换状态": "AI待确认",
        "patch状态": "已生成",
    },
    "需人工介入": {
        "兼容性": "不兼容",
        "转换状态": "需人工介入",
        "patch状态": "已生成",
    },
}


def load_json_file(filepath):
    """读取 JSON 文件，返回列表"""
    if not os.path.exists(filepath):
        return []
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except (json.JSONDecodeError, IOError) as e:
        print(f"警告: 读取 {filepath} 失败 - {e}", file=sys.stderr)
        return []


def extract_report_fields(item, category):
    """从 JSON 条目提取标准字段，根据类别设置合理的默认值"""
    path = item.get("path", "")
    filename = os.path.basename(path) if path else ""
    source_sql = item.get("source_sql", "") or item.get("statement", "") or ""

    # 转换状态：优先用 conversion_source 字段，其次用默认值
    conversion_source = item.get("conversion_source", "")
    if conversion_source == "AI":
        transform_status = "AI已迁移"
    elif conversion_source == "DevKit+AI":
        transform_status = "DevKit+AI已迁移"
    elif conversion_source == "AI待确认":
        transform_status = "AI待确认"
    elif conversion_source == "DevKit":
        transform_status = "DevKit已迁移"
    elif conversion_source == "DevKit确认兼容":
        transform_status = "DevKit确认兼容(对象缺失)"
    elif conversion_source == "AI确认兼容":
        transform_status = "AI确认兼容"
    else:
        transform_status = CATEGORY_DEFAULTS.get(category, {}).get("转换状态", "")

    # 动态分类：根据 conversion_source 将条目重分类到更精确的类别
    # Excel 中仍在同一个"已迁移SQL" Sheet，通过"转换状态"列区分
    # CSV 中通过"分类"列动态区分，便于筛选
    if category == "DevKit已迁移" and transform_status in ("AI已迁移", "DevKit+AI已迁移"):
        # migrated_sql.json 中的 AI 条目（flag=true 时 EXPLAIN 验证通过）
        dynamic_category = transform_status
    elif category == "待确认" and transform_status == "AI待确认":
        # pending_confirm_sql.json 中的 AI 条目（flag=false 时未经验证）
        dynamic_category = "AI待确认"
    elif category == "已兼容" and transform_status == "DevKit确认兼容(对象缺失)":
        # 预筛移入 compatible_sql.json 的条目，CSV 分类单独标记
        dynamic_category = "DevKit确认兼容"
    elif category == "已兼容" and transform_status == "AI确认兼容":
        dynamic_category = "AI确认兼容"
    else:
        dynamic_category = category

    # 获取该类别的默认值（优先用动态分类，如 AI待确认 的 patch状态=已生成）
    defaults = CATEGORY_DEFAULTS.get(dynamic_category, CATEGORY_DEFAULTS.get(category, {}))

    # 转换后SQL：已兼容和待迁移默认为空，其他类别取 JSON 中的值
    target_sql = item.get("target_sql", "") or ""
    if not target_sql:
        target_sql = defaults.get("转换后SQL语句", "")

    # 转换建议：优先取 JSON 中的值，无则用默认值
    notes = item.get("transformation_notes", "") or item.get("last_error", "") or ""
    if not notes:
        notes = defaults.get("转换建议", "")

    # 兼容性：优先用默认值（基于类别），JSON 中的 compatibility 字段作为补充
    compatibility = defaults.get("兼容性", "")
    if not compatibility:
        compat = item.get("compatibility", "")
        if compat == 0 or str(compat) == "0":
            compatibility = "已兼容"
        elif compat == 1 or str(compat) == "1":
            compatibility = "不兼容"
        elif compat == 2 or str(compat) == "2":
            compatibility = "需确认"
        else:
            compatibility = ""

    # patch状态：优先用默认值
    patch_status = defaults.get("patch状态", "")
    if not patch_status:
        patch_status = item.get("patch_status", "") or "已生成"

    return {
        "分类": dynamic_category,
        "文件名": filename,
        "源路径": path,
        "SQL起始行": item.get("start_line", ""),
        "SQL结束行": item.get("end_line", ""),
        "源码SQL片段": source_sql,
        "兼容性": compatibility,
        "转换状态": transform_status,
        "转换后SQL语句": target_sql,
        "转换建议": notes,
        "patch状态": patch_status,
    }


# 报告表头（统一用于 Excel 和 CSV）
REPORT_HEADERS = [
    "文件名", "源路径", "SQL起始行", "SQL结束行",
    "源码SQL片段", "兼容性", "转换状态",
    "转换后SQL语句", "转换建议", "patch状态"
]


def make_dedup_key(item):
    """生成去重 key：path + start_line + end_line + sql_id + source_sql"""
    path = item.get("path", "") or item.get("file_path", "") or ""
    source_sql = item.get("source_sql", "") or item.get("statement", "") or ""
    return f"{path}::{item.get('start_line', 0)}::{item.get('end_line', 0)}::{item.get('sql_id', '')}::{source_sql}"


def load_all_rows(reports_dir):
    """加载所有 JSON 报告，提取字段并做跨文件去重。

    跨文件去重规则：同一条 SQL（path + start_line + end_line + sql_id + source_sql 相同）
    只保留第一次出现的条目，防止同一 SQL 同时出现在多个文件中导致重复计数。

    优先级：compatible > migrated > to_do > pending_confirm > manual_review
    （SHEET_CONFIG 中的顺序即为优先级，靠前的文件先加载）
    """
    all_rows = []
    seen_keys = set()
    duplicates = []

    for _, json_file, category in SHEET_CONFIG:
        filepath = os.path.join(reports_dir, json_file)
        data_list = load_json_file(filepath)
        for item in data_list:
            key = make_dedup_key(item)
            if key in seen_keys:
                duplicates.append({
                    "file": json_file,
                    "path": item.get("path", ""),
                    "start_line": item.get("start_line", 0),
                    "sql_id": item.get("sql_id", ""),
                })
                continue
            seen_keys.add(key)
            all_rows.append(extract_report_fields(item, category))

    if duplicates:
        print(f"警告: 检测到 {len(duplicates)} 条跨文件重复 SQL，已自动去重:", file=sys.stderr)
        for d in duplicates:
            print(f"  - {d['file']}: {d['path']}:{d['start_line']} (sql_id={d['sql_id']})", file=sys.stderr)

    return all_rows


def generate_excel(reports_dir, output_path):
    """生成 Excel 报告（UTF-8，中文无乱码）"""
    try:
        from openpyxl import Workbook
    except ImportError:
        return False

    # 跨文件去重后，按 category 分组到各 Sheet
    all_rows = load_all_rows(reports_dir)

    # 按 dynamic_category 分组
    category_order = ["已兼容", "DevKit确认兼容", "AI确认兼容", "DevKit已迁移", "AI已迁移", "DevKit+AI已迁移", "AI待确认", "待迁移", "待确认", "需人工介入"]
    rows_by_category = {}
    for row in all_rows:
        cat = row.get("分类", "")
        rows_by_category.setdefault(cat, []).append(row)

    wb = Workbook()
    default_sheet = wb.active
    wb.remove(default_sheet)

    for sheet_name, _, _ in SHEET_CONFIG:
        ws = wb.create_sheet(title=sheet_name)
        ws.append(REPORT_HEADERS)
        # 该 Sheet 对应的分类标签列表
        if sheet_name == "已兼容SQL":
            cats = ["已兼容", "DevKit确认兼容", "AI确认兼容"]
        elif sheet_name == "已迁移SQL":
            cats = ["DevKit已迁移", "AI已迁移", "DevKit+AI已迁移", "AI待确认"]
        elif sheet_name == "待迁移SQL":
            cats = ["待迁移"]
        elif sheet_name == "待确认SQL":
            cats = ["待确认"]
        elif sheet_name == "人工介入SQL":
            cats = ["需人工介入"]
        else:
            cats = []
        for cat in cats:
            for row in rows_by_category.get(cat, []):
                ws.append([row[h] for h in REPORT_HEADERS])

    wb.save(output_path)
    print(f"Excel 报告已生成: {output_path}")
    return True


def generate_csv(reports_dir, output_path):
    """生成 CSV 报告（UTF-8 BOM，中文无乱码）"""

    # CSV 是单文件，用"分类"列区分行属于哪个类别
    headers = ["分类"] + REPORT_HEADERS

    # 跨文件去重后统一输出
    all_rows = load_all_rows(reports_dir)

    # 使用 utf-8-sig 编码，自动添加 BOM 头，Excel 打开中文无乱码
    with open(output_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        for row in all_rows:
            writer.writerow([row["分类"]] + [row[h] for h in REPORT_HEADERS])

    print(f"CSV 报告已生成: {output_path} (UTF-8 BOM，中文无乱码)")
    return True



def write_completion_result(reports_dir, output_dir, source_db="", target_db=""):
    """Write a machine-readable SQL migration completion result."""
    file_map = {
        "compatible": "compatible_sql.json",
        "migrated": "migrated_sql.json",
        "todo": "to_do-migrated_sql.json",
        "pending_confirm": "pending_confirm_sql.json",
        "manual_review": "manual_review_report.json",
    }
    counts = {}
    for key, filename in file_map.items():
        counts[key] = len(load_json_file(os.path.join(reports_dir, filename)))
    remaining = counts.get("todo", 0) + counts.get("pending_confirm", 0) + counts.get("manual_review", 0)
    patch_path = os.path.join(output_dir, "source_code.patch")
    patch_generation_path = os.path.join(output_dir, "patch-generation.json")
    if not os.path.isfile(patch_generation_path):
        raise RuntimeError(
            f"missing patch-generation.json: FINALIZE must generate the source patch before generate_report.py: {patch_generation_path}"
        )
    with open(patch_generation_path, "r", encoding="utf-8") as stream:
        patch_generation = json.load(stream)
    if str(patch_generation.get("status") or "").upper() != "SUCCESS":
        raise RuntimeError(f"source patch generation failed: {patch_generation_path}")
    if not os.path.isfile(patch_path):
        raise RuntimeError(f"source_code.patch is missing after successful patch generation: {patch_path}")
    payload = {
        "status": "SUCCESS" if remaining == 0 else "COMPLETED_WITH_ACTIONS",
        "source_db": source_db or os.environ.get("SOURCE_DB", ""),
        "target_db": target_db or os.environ.get("TARGET_DB", ""),
        "source_code_patch": patch_path,
        "counts": counts,
    }
    result_path = os.path.join(output_dir, "sql-migration-result.json")
    with open(result_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"SQL迁移结果标记已生成: {result_path}")


def main():
    parser = argparse.ArgumentParser(description="生成迁移汇总报告")
    parser.add_argument("--reports-dir", required=True, help="报告 JSON 文件所在目录")
    parser.add_argument("--output-dir", required=True, help="输出目录")
    parser.add_argument("--source-db", default="", help="源数据库类型，用于结果标记")
    parser.add_argument("--target-db", default="", help="目标数据库类型，用于结果标记")
    args = parser.parse_args()

    reports_dir = args.reports_dir
    output_dir = args.output_dir

    if not os.path.isdir(reports_dir):
        print(f"错误: 报告目录不存在 - {reports_dir}", file=sys.stderr)
        return 1

    os.makedirs(output_dir, exist_ok=True)

    xlsx_path = os.path.join(output_dir, "migration_summary.xlsx")
    csv_path = os.path.join(output_dir, "migration_summary.csv")

    # 优先尝试生成 Excel
    success = generate_excel(reports_dir, xlsx_path)

    if success:
        print(f"成功: 已生成 Excel 报告")
    else:
        print("提示: openpyxl 不可用，降级为 CSV（UTF-8 BOM）")
        generate_csv(reports_dir, csv_path)
        print("注意: 因环境无 openpyxl，已降级为 CSV")

    write_completion_result(reports_dir, output_dir, args.source_db, args.target_db)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())