#!/usr/bin/env python3
"""Deterministically consume AI classifications and resume SQL migration.

AI only edits bounded source regions and classifies each workset_id as
compatible / converted / manual-review. Target database validation, report
synchronization, completion marker creation and pipeline resume are deterministic.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# 本脚本位于 scripts/tools/，把 scripts/ 加入 sys.path 才能导入 common 包
SCRIPT_DIR = Path(__file__).resolve().parent      # scripts/tools/
SCRIPTS_DIR = SCRIPT_DIR.parent                   # scripts/
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from common.migration_common import load_json, write_json  # noqa: E402
from build_ai_workset import detect_source_dialect_issues  # noqa: E402
from target_sql_validator import validate as validate_target_sql  # noqa: E402
REPORT_FILES = {
    "compatible": "compatible_sql.json",
    "migrated": "migrated_sql.json",
    "todo": "to_do-migrated_sql.json",
    "pending_confirm": "pending_confirm_sql.json",
    "manual_review": "manual_review_report.json",
}


def parse_ids(values: list[str] | None) -> set[str]:
    result: set[str] = set()
    for raw in values or []:
        for item in raw.replace("\n", ",").split(","):
            item = item.strip()
            if item:
                result.add(item)
    return result


def canonical_path(value: Any) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        return str(Path(raw).expanduser().resolve())
    except Exception:
        return str(Path(raw).expanduser())


def int_value(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def report_key(item: dict[str, Any]) -> tuple[str, int, int, str]:
    return (
        canonical_path(item.get("path") or item.get("file_path")),
        int_value(item.get("start_line")),
        int_value(item.get("end_line")),
        str(item.get("sql_id") or item.get("id") or ""),
    )


def workset_key(item: dict[str, Any]) -> tuple[str, int, int, str]:
    return (
        canonical_path(item.get("path")),
        int_value(item.get("start_line")),
        int_value(item.get("end_line")),
        str(item.get("sql_id") or ""),
    )


def locate_todo(todo: list[dict[str, Any]], work_item: dict[str, Any]) -> dict[str, Any]:
    wanted = workset_key(work_item)
    for item in todo:
        if report_key(item) == wanted:
            return dict(item)
    rel = str(work_item.get("relative_path") or "").replace("\\", "/")
    sql_id = str(work_item.get("sql_id") or "")
    start = int_value(work_item.get("start_line"))
    end = int_value(work_item.get("end_line"))
    for item in todo:
        path = str(item.get("path") or item.get("file_path") or "").replace("\\", "/")
        is_match = (
            str(item.get("sql_id") or "") == sql_id and int_value(item.get("start_line")) == start and int_value(item.get("end_line")) == end
        )
        if (
            is_match
            and (not rel or path.endswith(rel))
        ):
            return dict(item)
    raise ValueError(f"workset item cannot be matched to to_do-migrated_sql.json: {work_item.get('workset_id')}")


def current_fragment(work_item: dict[str, Any]) -> str:
    path = Path(str(work_item.get("path") or "")).expanduser().resolve()
    if not path.is_file():
        return ""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines:
        return ""
    start = max(1, int_value(work_item.get("start_line")) or 1)
    end = max(start, int_value(work_item.get("end_line")) or start)
    start = min(start, len(lines))
    end = min(end, len(lines))

    # AI edits may change the statement line count. For a MyBatis CRUD element,
    # expand the original range to the current complete element so validation
    # and rule persistence use the actual post-AI SQL.
    if path.suffix.lower() == ".xml":
        sql_id = str(work_item.get("sql_id") or "").strip()
        open_re = (
            re.compile(
                r'<(select|insert|update|delete)\b[^>]*\bid=["\']'
                + re.escape(sql_id)
                + r'["\'][^>]*>',
                re.I,
            )
            if sql_id
            else None
        )
        open_idx = None
        lower = max(0, start - 1 - 80)
        upper = min(len(lines), end + 80)
        for idx in range(start - 1, lower - 1, -1):
            if open_re and open_re.search(lines[idx]):
                open_idx = idx
                break
        if open_idx is None and open_re:
            for idx in range(start - 1, upper):
                if open_re.search(lines[idx]):
                    open_idx = idx
                    break
        if open_idx is not None:
            tag_match = re.search(r'<(select|insert|update|delete)\b', lines[open_idx], re.I)
            if tag_match:
                close_re = re.compile(r'</' + tag_match.group(1) + r'>', re.I)
                for idx in range(open_idx, min(len(lines), open_idx + 300)):
                    if close_re.search(lines[idx]):
                        return "\n".join(lines[open_idx:idx + 1])

    return "\n".join(lines[start - 1:end])


def source_fragment_changed(work_item: dict[str, Any]) -> bool:
    """Return True only when the bounded original source fragment no longer exists.

    This tolerates line-number shifts caused by edits to earlier workset items in
    the same file while still requiring a real source change for `converted`.
    """
    original = str(work_item.get("source_fragment") or "")
    path = Path(str(work_item.get("path") or "")).expanduser().resolve()
    if not original or not path.is_file():
        return False
    current = path.read_text(encoding="utf-8", errors="replace")
    return original not in current


def load_report_lists(reports_dir: Path) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for key, name in REPORT_FILES.items():
        value = load_json(reports_dir / name, [])
        result[key] = [dict(v) for v in value if isinstance(v, dict)] if isinstance(value, list) else []
    return result


def _normalize_pattern_key(value: str) -> str:
    """归一化转换模式键：大写、非字母数字下划线转为下划线。"""
    return re.sub(r"[^A-Z0-9_]", "_", str(value or "").strip().upper()).strip("_")


def _rule_fingerprint(source_db: str, target_db: str, pattern_key: str) -> str:
    """指纹基于 source_db + target_db + 转换模式键，不含具体 SQL 文本。

    同一转换模式（如 DECODE → CASE WHEN）在不同表/列上只产生一个指纹，
    避免规则库因具体 SQL 差异而膨胀。
    """
    raw = "\n".join([
        source_db.strip().lower(),
        target_db.strip().lower(),
        pattern_key.strip().lower(),
    ])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def persist_validated_rules(
    work_dir: Path,
    workset: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
    passed_ids: set[str],
    validation: dict[str, Any],
) -> dict[str, Any]:
    """Append AI-converted + target-EXPLAIN-PASS examples to the existing rulers file.

    去重粒度：转换模式键（rule_pattern_key）。同一 source_db + target_db + pattern_key
    只沉淀一条规则，表名/列名不同的 SQL 不产生重复规则。

    AI 在 workset item 中写入：
      - rule_pattern_key：转换模式键（如 ORACLE_DECODE_TO_MYSQL_CASE_WHEN）
      - rule_summary：一句话转换说明（如 "Oracle DECODE 函数转 MySQL CASE WHEN 表达式"）
    未提供则跳过该条沉淀。

    source_sql 优先用 item.source_sql（纯 SQL），未提供时跳过；
    target_sql 优先用 item.ai_target_sql（AI 写入的纯 SQL），未提供时回退到 validated_sql。
    """
    db = workset.get("database_context") or {}
    source_db = str(db.get("source_db") or "").strip()
    target_db = str(db.get("target_db") or "").strip()
    validated_sql = validation.get("validated_sql") or {}
    result: dict[str, Any] = {
        "persisted": 0,
        "duplicates": 0,
        "skipped": 0,
        "rule_file": "",
        "items": {},
    }
    if not source_db or not target_db or not passed_ids:
        return result

    rule_file = work_dir / "devkit-sql-migration-cache" / f"rulers_{source_db}_to_{target_db}.md"
    rule_file.parent.mkdir(parents=True, exist_ok=True)
    existing = rule_file.read_text(encoding="utf-8", errors="replace") if rule_file.is_file() else ""
    result["rule_file"] = str(rule_file)
    rule_count = len(re.findall(r"(?m)^##\s+[^\n]+$", existing))
    additions: list[str] = []

    for wid in sorted(passed_ids):
        item = by_id.get(wid) or {}
        # source_sql 优先用纯 SQL，未提供时跳过（不用 source_fragment 兜底）
        source_sql = str(item.get("source_sql") or "").strip()
        # target_sql 优先用 AI 写入的纯 SQL，未提供时回退到 validator 清洗后的 SQL
        target_sql = str(item.get("ai_target_sql") or "").strip() or str(validated_sql.get(wid) or "").strip()
        # 转换模式键（去重依据）和摘要（规则标题）
        pattern_key = _normalize_pattern_key(str(item.get("rule_pattern_key") or ""))
        rule_summary = str(item.get("rule_summary") or "").strip()

        if not source_sql or not target_sql or not pattern_key:
            result["skipped"] += 1
            result["items"][wid] = {"status": "SKIPPED", "reason": "missing source_sql/target_sql/rule_pattern_key"}
            continue
        if not rule_summary:
            rule_summary = f"{source_db} → {target_db} 转换（{pattern_key}）"

        fingerprint = _rule_fingerprint(source_db, target_db, pattern_key)
        marker = f"<!-- rule_fingerprint: {fingerprint} -->"
        if marker in existing or any(marker in block for block in additions):
            result["duplicates"] += 1
            result["items"][wid] = {"status": "DUPLICATE", "fingerprint": fingerprint, "pattern_key": pattern_key}
            continue

        rule_count += 1
        sql_id = str(item.get("sql_id") or wid)
        lines = [
            f"## [规则 {rule_count:02d}] {rule_summary}",
            marker,
            f"<!-- rule_pattern_key: {pattern_key} -->",
            "### 1. 语法转换映射",
            f"- **转换模式：** {rule_summary}",
            f"- **源数据库（{source_db}）：** 见下方转换前 SQL",
            f"- **目标数据库（{target_db}）：** 见下方转换后 SQL；目标数据库动态 `EXPLAIN` 验证通过",
            "",
            "### 2. 核心差异说明",
            f"- 转换模式键：`{pattern_key}`",
            "- 验证：目标数据库动态连接 `EXPLAIN` PASS",
            "- 复用约束：作为相同转换模式的候选规则，后续仍需结合当前 SQL 上下文判断。",
            "",
            "### 3. 标准对照示例",
            f"#### 转换前 SQL（{source_db}，{sql_id}）",
            "```sql",
            source_sql,
            "```",
            f"#### 转换后 SQL（{target_db}）",
            "```sql",
            target_sql,
            "```",
        ]
        additions.append("\n".join(lines))
        result["persisted"] += 1
        result["items"][wid] = {
            "status": "PERSISTED",
            "fingerprint": fingerprint,
            "pattern_key": pattern_key,
            "rule_number": rule_count,
        }

    if additions:
        with rule_file.open("a", encoding="utf-8") as fh:
            if existing.strip():
                fh.write("\n\n")
            fh.write("\n\n".join(additions))
            fh.write("\n")
    return result


def synchronize_reports(
    work_dir: Path,
    compatible_ids: set[str],
    converted_ids: set[str],
    manual_ids: set[str],
) -> dict[str, Any]:
    reports_dir = work_dir / "reports"
    workset_path = reports_dir / "ai-workset.json"
    workset = load_json(workset_path, {})
    if not isinstance(workset, dict) or not isinstance(workset.get("items"), list):
        raise ValueError(f"invalid or missing ai-workset.json: {workset_path}")
    work_items = [v for v in workset["items"] if isinstance(v, dict)]
    by_id = {str(v.get("workset_id") or ""): v for v in work_items}
    if "" in by_id or len(by_id) != len(work_items):
        raise ValueError("ai-workset.json contains missing/duplicate workset_id values")

    all_ids = set(by_id)
    supplied = compatible_ids | converted_ids | manual_ids
    unknown = supplied - all_ids
    if unknown:
        raise ValueError("unknown workset_id(s): " + ", ".join(sorted(unknown)))
    overlaps = (compatible_ids & converted_ids) | (compatible_ids & manual_ids) | (converted_ids & manual_ids)
    if overlaps:
        raise ValueError("workset_id appears in more than one outcome: " + ", ".join(sorted(overlaps)))
    missing = all_ids - supplied
    if missing:
        raise ValueError("all AI workset items must be classified; missing: " + ", ".join(sorted(missing)))

    db = workset.get("database_context") or {}
    source_db = str(db.get("source_db") or "")
    target_db = str(db.get("target_db") or "")
    converted_integrity: dict[str, Any] = {}
    rejected_converted: set[str] = set()
    semantic_manual: set[str] = set()
    for wid in sorted(converted_ids):
        item = by_id[wid]
        changed = source_fragment_changed(item)
        after_fragment = current_fragment(item)
        after_sql = str(item.get("ai_target_sql") or "").strip() or after_fragment
        detected_after = detect_source_dialect_issues(after_sql, source_db, target_db)
        identified = [str(v) for v in (item.get("identified_issues") or []) if str(v)]
        residual = sorted(set(detected_after))
        semantic_review = item.get("semantic_review") or {}
        semantic_required = bool(semantic_review.get("manual_review_required"))
        semantic_reasons = [str(v) for v in (semantic_review.get("reason_codes") or []) if str(v)]
        status = "PASSED" if changed and not residual else "FAILED"
        converted_integrity[wid] = {
            "status": status,
            "source_changed": changed,
            "identified_issues": identified,
            "residual_issues": residual,
            "semantic_risk": str(semantic_review.get("risk") or "LOW"),
            "semantic_manual_review_required": semantic_required,
            "semantic_reason_codes": semantic_reasons,
        }
        item["converted_integrity"] = converted_integrity[wid]
        if status != "PASSED":
            rejected_converted.add(wid)
        if semantic_required:
            semantic_manual.add(wid)

    rejected_all = rejected_converted | semantic_manual
    accepted_converted = converted_ids - rejected_all
    effective_manual = manual_ids | rejected_all

    validation_items: list[dict[str, Any]] = []
    for item in work_items:
        prepared = dict(item)
        wid = str(item.get("workset_id") or "")
        if wid in accepted_converted:
            # 优先用 AI 写入的纯 SQL 作为验证输入；未提供时回退到 AI 修改后的当前源码片段。
            ai_target_sql = str(item.get("ai_target_sql") or "").strip()
            prepared["validation_sql_after_ai"] = ai_target_sql or current_fragment(item)
        validation_items.append(prepared)
    validation = validate_target_sql(work_dir, validation_items, accepted_converted)
    passed = set(validation.get("passed") or [])
    failed = set((validation.get("failed") or {}).keys())
    pending = set((validation.get("pending") or {}).keys())

    reports = load_report_lists(reports_dir)
    original_todo = list(reports["todo"])
    work_keys = {workset_key(item) for item in work_items}
    for key in reports:
        reports[key] = [item for item in reports[key] if report_key(item) not in work_keys]

    now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    for workset_id, work_item in by_id.items():
        base = locate_todo(original_todo, work_item)
        fragment = current_fragment(work_item)
        ai_target_sql = str(work_item.get("ai_target_sql") or "").strip()
        original_target = str(base.get("target_sql") or work_item.get("target_sql") or "").strip()

        if workset_id in compatible_ids:
            base.update({
                "compatibility": 0,
                "target_sql": "",
                "conversion_source": "AI确认兼容",
                "transformation_notes": "AI语义判断无需修改源码即可兼容目标数据库。",
            })
            reports["compatible"].append(base)
            outcome = "COMPATIBLE"
        elif workset_id in accepted_converted:
            base["compatibility"] = 1
            # target_sql 必须是纯 SQL 语句，优先用 AI 写入的 ai_target_sql；
            # 未提供时回退到 DevKit 原始建议（可能为空），不用源码块兜底
            base["target_sql"] = ai_target_sql or original_target
            origin = "DevKit+AI" if original_target else "AI"
            if workset_id in passed:
                base["conversion_source"] = origin
                base["transformation_notes"] = "AI完成源码改造并通过目标库确定性EXPLAIN验证。"
                reports["migrated"].append(base)
                outcome = "CONVERTED_VALIDATED"
            elif workset_id in failed:
                base["conversion_source"] = "AI验证失败"
                base["last_error"] = str((validation.get("failed") or {}).get(workset_id) or "target SQL validation failed")
                base["transformation_notes"] = base["last_error"]
                reports["manual_review"].append(base)
                outcome = "MANUAL_REVIEW"
            else:
                base["conversion_source"] = "AI待确认"
                base["transformation_notes"] = str((validation.get("pending") or {}).get(workset_id) or "等待目标环境验证。")
                reports["pending_confirm"].append(base)
                outcome = "CONVERTED_PENDING"
        else:
            base["compatibility"] = 1
            if workset_id in semantic_manual:
                detail = converted_integrity.get(workset_id) or {}
                reasons = detail.get("semantic_reason_codes") or []
                reason = "AI转换涉及必须人工确认的语义风险"
                if reasons:
                    reason += "：" + ", ".join(str(v) for v in reasons)
                base["last_error"] = reason
                base["reason_code"] = "MANUAL_REVIEW_SEMANTIC_RISK"
                base["transformation_notes"] = reason
                outcome = "MANUAL_REVIEW_SEMANTIC_RISK"
            elif workset_id in rejected_converted:
                detail = converted_integrity.get(workset_id) or {}
                residual = detail.get("residual_issues") or []
                reason = "AI converted 完整性检查失败"
                if not detail.get("source_changed"):
                    reason += "：指定源码范围未检测到实际修改"
                if residual:
                    reason += "；仍存在源数据库方言问题：" + ", ".join(str(v) for v in residual)
                base["last_error"] = reason
                base["reason_code"] = "MANUAL_REVIEW_INCOMPLETE_CONVERSION"
                base["transformation_notes"] = reason
                outcome = "MANUAL_REVIEW_INCOMPLETE_CONVERSION"
            else:
                base["last_error"] = base.get("last_error") or "AI处理后仍需人工介入。"
                base["transformation_notes"] = base.get("transformation_notes") or base["last_error"]
                outcome = "MANUAL_REVIEW"
            reports["manual_review"].append(base)

        work_item["ai_outcome"] = outcome
        work_item["ai_processed_at"] = now
        if fragment:
            work_item["final_source_fragment"] = fragment
        if workset_id in passed:
            work_item["target_validation"] = "SUCCESS"
        elif workset_id in failed:
            work_item["target_validation"] = "FAILED"
        elif workset_id in pending:
            work_item["target_validation"] = "PENDING"

    rule_persistence = persist_validated_rules(work_dir, workset, by_id, passed & accepted_converted, validation)
    for wid, detail in (rule_persistence.get("items") or {}).items():
        if wid in by_id:
            by_id[wid]["rule_persistence"] = detail

    for key, name in REPORT_FILES.items():
        write_json(reports_dir / name, reports[key])
    workset["ai_stage"] = {
        "status": "CLASSIFIED",
        "classified_at": now,
        "compatible": len(compatible_ids),
        "converted_requested": len(converted_ids),
        "converted": len(accepted_converted),
        "manual_review": len(effective_manual),
        "converted_integrity": {
            "passed": len(accepted_converted),
            "failed": len(rejected_converted),
            "failed_ids": sorted(rejected_converted),
        },
        "target_validation": {
            "enabled": bool(validation.get("enabled")),
            "passed": len(passed),
            "failed": len(failed),
            "pending": len(pending),
        },
        "rule_persistence": {
            "persisted": int(rule_persistence.get("persisted") or 0),
            "duplicates": int(rule_persistence.get("duplicates") or 0),
            "skipped": int(rule_persistence.get("skipped") or 0),
            "rule_file": rule_persistence.get("rule_file") or "",
        },
    }
    write_json(workset_path, workset)
    (reports_dir / ".ai-completed").touch()
    return {
        "workset": str(workset_path),
        "compatible": len(compatible_ids),
        "converted_requested": len(converted_ids),
        "converted": len(accepted_converted),
        "manual_review": len(effective_manual),
        "converted_integrity": {
            "passed": len(accepted_converted),
            "failed": len(rejected_converted),
            "failed_ids": sorted(rejected_converted),
            "semantic_manual_review": len(semantic_manual),
            "semantic_manual_ids": sorted(semantic_manual),
            "items": converted_integrity,
        },
        "target_validation": validation,
        "rule_persistence": rule_persistence,
    }


def run_sql_finalize(work_dir: Path) -> int:
    state = load_json(work_dir / "sql-migration-state.json", {})
    if not isinstance(state, dict):
        raise ValueError("invalid SQL migration state")
    project_path = str(state.get("project_path") or "")
    source_db = str(state.get("input_source_db") or state.get("source_db") or "")
    target_db = str(state.get("input_target_db") or state.get("target_db") or "")
    if not project_path or not source_db or not target_db:
        raise ValueError("SQL migration state is missing project/source/target identity")
    cmd = [
        sys.executable, str(SCRIPTS_DIR / "sql_migration.py"),
        "--project-path", project_path,
        "--work-dir", str(work_dir),
        "--source-db", source_db,
        "--target-db", target_db,
        # 标识本次为内部接力调用：sql_migration.py 到达 COMPLETE 时仍建立
        # WAITING_FOR_USER_DECISION 门禁，但直接返回迁移结果（不带询问 payload）。
        # 询问交互留给后续用户主动发起的入口调用，避免在 finalize_ai_stage.py
        # 的调用上下文里触发询问。
        "--internal-resume",
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.stdout:
        print(proc.stdout.rstrip())
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Finalize bounded AI SQL transformation")
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--compatible", action="append", default=[])
    parser.add_argument("--converted", action="append", default=[])
    parser.add_argument("--manual-review", action="append", default=[])
    args = parser.parse_args()
    work_dir = Path(args.work_dir).expanduser().resolve()
    summary = synchronize_reports(
        work_dir,
        parse_ids(args.compatible),
        parse_ids(args.converted),
        parse_ids(args.manual_review),
    )
    print(json.dumps({"status": "AI_STAGE_CLASSIFIED", **summary}, ensure_ascii=False, indent=2))
    return run_sql_finalize(work_dir)


if __name__ == "__main__":
    raise SystemExit(main())
