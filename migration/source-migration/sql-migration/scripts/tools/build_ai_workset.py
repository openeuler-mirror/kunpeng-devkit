#!/usr/bin/env python3
"""Build the bounded AI workset from to_do-migrated_sql.json.

The script reads only files explicitly referenced by the to-do report and embeds
small source fragments plus relevant rule snippets into one JSON file.  The AI
migration phase can therefore work from this file without scanning the whole
project or the full SQL report directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Iterable


TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
RULE_HEADER_RE = re.compile(r"(?m)^##\s+[^\n]+$")
SQL_STOP_WORDS = {
    "select", "from", "where", "and", "or", "as", "on", "join", "left", "right", "inner", "outer",
    "insert", "into", "update", "delete", "values", "set", "when", "then", "else", "end", "case",
    "group", "order", "by", "having", "distinct", "null", "is", "not", "in", "like", "table", "column",
    "create", "time", "date", "string", "int", "varchar", "number", "true", "false",
}


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    with temp.open("w", encoding="utf-8") as fh:
        json.dump(value, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(str(temp), str(path))


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def safe_source_path(raw_path: str, source_root: Path) -> Path:
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        path = source_root / path
    resolved = path.resolve()
    root = source_root.resolve()
    try:
        common = os.path.commonpath([str(root), str(resolved)])
    except ValueError as exc:
        raise ValueError("SQL workset source path is outside source root: %s" % raw_path) from exc
    if common != str(root):
        raise ValueError("SQL workset source path is outside source root: %s" % raw_path)
    if not resolved.is_file():
        raise FileNotFoundError("SQL workset source file not found: %s" % resolved)
    return resolved


def sql_tokens(*values: str) -> set[str]:
    result: set[str] = set()
    for value in values:
        for token in TOKEN_RE.findall(value or ""):
            token = token.lower()
            if len(token) >= 3 and token not in SQL_STOP_WORDS:
                result.add(token)
    return result


def split_rule_blocks(text: str) -> list[str]:
    matches = list(RULE_HEADER_RE.finditer(text))
    if not matches:
        return []
    blocks: list[str] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        block = text[match.start():end].strip()
        if block:
            blocks.append(block)
    return blocks


def select_rule_candidates(blocks: Iterable[str], item_tokens: set[str], limit: int = 3) -> list[str]:
    if not item_tokens:
        return []
    scored: list[tuple[int, int, str]] = []
    for index, block in enumerate(blocks):
        block_tokens = sql_tokens(block)
        score = len(item_tokens.intersection(block_tokens))
        if score:
            scored.append((score, -index, block))
    scored.sort(reverse=True)
    return [block[:2400] for _, _, block in scored[:limit]]




def detect_source_dialect_issues(text: str, source_db: str, target_db: str) -> list[str]:
    """Identify source-dialect constructs that must disappear before `converted`.

    The check is intentionally narrow and deterministic.  It only declares issues
    for source/target pairs whose source constructs are explicitly known here; it
    does not attempt to infer arbitrary SQL compatibility.
    """
    value = text or ""
    source = str(source_db or "").strip().upper()
    target = str(target_db or "").strip().upper()
    issues: list[str] = []
    if source == "MYSQL" and target in {"DM", "DM8"}:
        checks = (
            ("MYSQL_DATABASE_FUNCTION", r"\bdatabase\s*\("),
            ("MYSQL_DATE_FORMAT_FUNCTION", r"\bdate_format\s*\("),
            ("MYSQL_REPLACE_INTO", r"\breplace\s+into\b"),
            ("MYSQL_FIND_IN_SET_FUNCTION", r"\bfind_in_set\s*\("),
            ("MYSQL_INFORMATION_SCHEMA", r"\binformation_schema\s*\."),
            ("MYSQL_LOGICAL_AND_OPERATOR", r"&&"),
        )
        for code, pattern in checks:
            if re.search(pattern, value, re.I):
                issues.append(code)
    return issues


def semantic_review_profile(text: str, identified_issues: list[str], source_db: str, target_db: str) -> dict[str, Any]:
    """Classify deterministic semantic risk without attempting arbitrary SQL proof.

    `manual_review_required` is deliberately narrow: only transformations whose
    source semantics cannot be safely inferred from syntax alone are forced to
    manual review. Other risky rewrites remain visible to the Agent but may
    continue through converted/pending validation.
    """
    value = text or ""
    source = str(source_db or "").strip().upper()
    target = str(target_db or "").strip().upper()
    issue_set = {str(v) for v in (identified_issues or []) if str(v)}
    reasons: list[str] = []
    required = False
    risk = "LOW"

    if source == "MYSQL" and target in {"DM", "DM8"}:
        if "MYSQL_REPLACE_INTO" in issue_set:
            reasons.append("UPSERT_SEMANTIC_REWRITE")
            required = True
            risk = "HIGH"
        if re.search(r"\btimestap\s*\(", value, re.I):
            reasons.append("SOURCE_SQL_SUSPECTED_INVALID_TIMESTAP")
            required = True
            risk = "HIGH"
        if "MYSQL_INFORMATION_SCHEMA" in issue_set and risk != "HIGH":
            reasons.append("SYSTEM_CATALOG_REWRITE")
            risk = "HIGH"
        elif "MYSQL_FIND_IN_SET_FUNCTION" in issue_set and risk == "LOW":
            reasons.append("FUNCTION_SEMANTIC_REWRITE")
            risk = "MEDIUM"

    return {
        "risk": risk,
        "manual_review_required": required,
        "reason_codes": reasons,
    }


def int_value(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def source_window(path: Path, start_line: int, end_line: int, context_lines: int, max_chars: int) -> dict[str, Any]:
    """Return a compact, edit-oriented source window.

    The exact target fragment is kept intact.  Surrounding context is split into
    before/after fields so an Agent can reason without rereading the whole file.
    A bounded fallback range is included for the rare case where the embedded
    context is insufficient.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    if not lines:
        return {
            "file_total_lines": 0,
            "context_start_line": 1,
            "context_end_line": 0,
            "source_fragment": "",
            "source_fragment_sha256": sha256_text(""),
            "context_before": "",
            "context_after": "",
            "context_truncated": False,
            "fallback_start_line": 1,
            "fallback_end_line": 0,
        }

    total_lines = len(lines)
    start = min(max(1, start_line), total_lines)
    end = min(max(start, end_line), total_lines)
    context_start = max(1, start - context_lines)
    context_end = min(total_lines, end + context_lines)
    source_fragment = "\n".join(lines[start - 1:end])
    before = "\n".join(lines[context_start - 1:start - 1])
    after = "\n".join(lines[end:context_end])

    # max_chars applies to the full embedded item. Never trim the exact target
    # fragment; only trim the optional surrounding context.
    surrounding_budget = max(0, max_chars - len(source_fragment) - 64)
    full_surrounding_len = len(before) + len(after)
    context_truncated = full_surrounding_len > surrounding_budget
    if context_truncated:
        before_budget = surrounding_budget // 2
        after_budget = surrounding_budget - before_budget
        before = before[-before_budget:] if before_budget else ""
        after = after[:after_budget] if after_budget else ""

    fallback_padding = max(context_lines * 4, 24)
    return {
        "file_total_lines": total_lines,
        "context_start_line": context_start,
        "context_end_line": context_end,
        "source_fragment": source_fragment,
        "source_fragment_sha256": sha256_text(source_fragment),
        "context_before": before,
        "context_after": after,
        "context_truncated": context_truncated,
        "fallback_start_line": max(1, start - fallback_padding),
        "fallback_end_line": min(total_lines, end + fallback_padding),
    }


def build_workset(
    todo_path: Path,
    source_root: Path,
    output_path: Path,
    rules_file: Path | None,
    context_lines: int,
    max_context_chars: int,
    source_db: str = "",
    target_db: str = "",
    db_config: Path | None = None,
) -> dict[str, Any]:
    raw = load_json(todo_path)
    if not isinstance(raw, list):
        raise ValueError("to_do-migrated_sql.json must contain a JSON array")

    rule_blocks: list[str] = []
    if rules_file and rules_file.is_file():
        rule_blocks = split_rule_blocks(rules_file.read_text(encoding="utf-8", errors="replace"))

    db_cfg: dict[str, Any] = {}
    if db_config and db_config.is_file():
        loaded = load_json(db_config)
        if isinstance(loaded, dict):
            db_cfg = loaded
    source_validation_enabled = bool((db_cfg.get("source_db_conn") or {}).get("flag"))
    target_validation_enabled = bool((db_cfg.get("target_db_conn") or {}).get("flag"))

    items: list[dict[str, Any]] = []
    files: set[str] = set()
    for index, item in enumerate(raw, start=1):
        if not isinstance(item, dict):
            continue
        raw_path = str(item.get("path") or "").strip()
        if not raw_path:
            raise ValueError("to-do item %d has no path" % index)
        source_path = safe_source_path(raw_path, source_root)
        files.add(str(source_path))
        start_line = int_value(item.get("start_line"), 1)
        end_line = int_value(item.get("end_line"), start_line)
        window = source_window(source_path, start_line, end_line, context_lines, max_context_chars)
        source_sql = str(item.get("source_sql") or item.get("statement") or "")
        target_sql = str(item.get("target_sql") or "")
        suggestions = item.get("suggestions_cn") or item.get("suggestions") or []
        if not isinstance(suggestions, list):
            suggestions = [str(suggestions)]
        tokens = sql_tokens(source_sql, target_sql, " ".join(str(v) for v in suggestions))
        item_id = str(item.get("sql_id") or item.get("id") or "sql-%04d" % index)
        source_scope = "\n".join([source_sql, str(window["source_fragment"])])
        identified_issues = detect_source_dialect_issues(source_scope, source_db, target_db)
        semantic_review = semantic_review_profile(source_scope, identified_issues, source_db, target_db)
        items.append({
            "workset_id": "%04d:%s" % (index, item_id),
            "sql_id": item_id,
            "tag": item.get("tag"),
            "path": str(source_path),
            "relative_path": source_path.relative_to(source_root.resolve()).as_posix(),
            "start_line": start_line,
            "end_line": end_line,
            "source_sql": source_sql,
            "target_sql": target_sql,
            "suggestions_cn": suggestions,
            "explain_exec_result_before": item.get("explain_exec_result_before"),
            "compatibility": item.get("compatibility"),
            "identified_issues": identified_issues,
            "semantic_review": semantic_review,
            "source_fragment": window["source_fragment"],
            "source_fragment_sha256": window["source_fragment_sha256"],
            "file_total_lines": window["file_total_lines"],
            "context_start_line": window["context_start_line"],
            "context_end_line": window["context_end_line"],
            "context_before": window["context_before"],
            "context_after": window["context_after"],
            "context_truncated": window["context_truncated"],
            "fallback_read": {
                "path": str(source_path),
                "start_line": window["fallback_start_line"],
                "end_line": window["fallback_end_line"],
                "condition": "ONLY_IF_EMBEDDED_CONTEXT_IS_INSUFFICIENT",
            },
            "rule_candidates": select_rule_candidates(rule_blocks, tokens),
        })

    result = {
        "schema_version": "1.1",
        "source": str(todo_path.resolve()),
        "source_root": str(source_root.resolve()),
        "item_count": len(items),
        "file_count": len(files),
        "database_context": {
            "source_db": source_db,
            "target_db": target_db,
            "source_validation_enabled": source_validation_enabled,
            "target_validation_enabled": target_validation_enabled,
            "converted_result_when_target_validation_disabled": "pending_confirm",
        },
        "rules_source": str(rules_file.resolve()) if rules_file and rules_file.is_file() else "",
        "instruction": (
            "Treat this file as the complete Phase-3 input. Use source_sql/target_sql, source_fragment, "
            "context_before/context_after, database_context and rule_candidates first. Do not scan the project tree, "
            "glob for files, reread db-connection.json, or perform external web research. Only when one item's embedded "
            "context is insufficient may you read that item's fallback_read path and bounded line range. Limit edits to "
            "the listed path and SQL scope. Items whose semantic_review.manual_review_required=true must be classified "
            "as manual-review. Other items may be converted only after the source is actually modified and every "
            "identified_issues marker is eliminated; finalize_ai_stage.py enforces both rules. Then classify every "
            "workset_id using the absolute finalize.entry below; do not reconstruct its path from the current directory."
        ),
        "finalize": {
            "entry": str((Path(__file__).resolve().parent / "finalize_ai_stage.py").resolve()),
            "work_dir": str(output_path.resolve().parent.parent),
            "entry_mode": "ABSOLUTE",
        },
        "items": items,
    }
    write_json(output_path, result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a bounded AI SQL migration workset.")
    parser.add_argument("--todo", required=True, help="to_do-migrated_sql.json")
    parser.add_argument("--source-root", required=True, help="SQL working copy root, normally $WORK_DIR/source-code/b")
    parser.add_argument("--output", required=True, help="ai-workset.json output path")
    parser.add_argument("--rules-file", default="", help="Optional rulers_<SOURCE>_to_<TARGET>.md")
    parser.add_argument("--source-db", default="", help="Canonical source database name")
    parser.add_argument("--target-db", default="", help="Canonical target database name")
    parser.add_argument("--db-config", default="", help="Optional db-connection.json used only to embed validation flags")
    parser.add_argument("--context-lines", type=int, default=8)
    parser.add_argument("--max-context-chars", type=int, default=8000)
    args = parser.parse_args()

    todo = Path(args.todo).expanduser().resolve()
    source_root = Path(args.source_root).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    rules_file = Path(args.rules_file).expanduser().resolve() if args.rules_file else None
    db_config = Path(args.db_config).expanduser().resolve() if args.db_config else None
    result = build_workset(
        todo, source_root, output, rules_file,
        max(0, args.context_lines), max(1000, args.max_context_chars),
        source_db=args.source_db, target_db=args.target_db, db_config=db_config,
    )
    print(json.dumps({
        "output": str(output),
        "item_count": result["item_count"],
        "file_count": result["file_count"],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
