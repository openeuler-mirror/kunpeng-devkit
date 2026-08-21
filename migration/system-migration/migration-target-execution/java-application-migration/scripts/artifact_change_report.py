#!/usr/bin/env python3
"""Compare original and migrated JAR/WAR artifacts at ZIP-entry level.

The comparison is optimized for migration verification:
- unchanged entries are skipped by uncompressed size + CRC;
- SHA-256 is calculated only for changed entries;
- nested JAR/WAR files are opened recursively only when the container bytes changed;
- nested archives whose internal entry contents are unchanged are reported as
  REPACKAGED_ONLY rather than as business-content changes.
"""
from __future__ import annotations

import hashlib
import tempfile
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO

from migration_common import MigrationError, write_json

NESTED_ARCHIVE_SUFFIXES = (".jar", ".war")
MAX_NESTED_DEPTH = 6
SPOOL_MEMORY_LIMIT = 16 * 1024 * 1024


def _norm(value: str) -> str:
    return value.replace("\\", "/").lstrip("./")


def _is_nested_archive(name: str) -> bool:
    return name.lower().endswith(NESTED_ARCHIVE_SUFFIXES)


def _content_type(name: str, *, nested: bool = False) -> str:
    if nested:
        return "NESTED_ARCHIVE"
    lower = name.lower()
    if lower.endswith(".class"):
        return "CLASS"
    if lower.endswith((".xml", ".properties", ".yml", ".yaml", ".json", ".sql", ".conf", ".txt")):
        return "RESOURCE"
    return "FILE"


def _crc32(info: zipfile.ZipInfo | None) -> str:
    return f"{info.CRC & 0xFFFFFFFF:08x}" if info is not None else ""


def _sha256_stream(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def _sha256_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> str:
    with archive.open(info, "r") as stream:
        return _sha256_stream(stream)


def _entry_map(archive: zipfile.ZipFile, warnings: list[str], archive_label: str) -> dict[str, zipfile.ZipInfo]:
    result: dict[str, zipfile.ZipInfo] = {}
    duplicates: set[str] = set()
    for info in archive.infolist():
        if info.is_dir():
            continue
        name = _norm(info.filename)
        if name in result:
            duplicates.add(name)
        result[name] = info
    for name in sorted(duplicates):
        warnings.append(f"Duplicate ZIP entry uses last occurrence: {archive_label}!/{name}")
    return result


def _expected(path: str, expected_entries: set[str]) -> bool:
    normalized = _norm(path)
    if normalized in expected_entries:
        return True
    # A nested archive itself is expected when a recorded child entry belongs to it.
    prefix = normalized + "!/"
    return any(item.startswith(prefix) for item in expected_entries)


def _spool_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> tuple[tempfile.SpooledTemporaryFile, str]:
    spool = tempfile.SpooledTemporaryFile(max_size=SPOOL_MEMORY_LIMIT, mode="w+b")
    digest = hashlib.sha256()
    with archive.open(info, "r") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            spool.write(chunk)
            digest.update(chunk)
    spool.seek(0)
    return spool, digest.hexdigest()


def _change_record(
    path: str,
    change_type: str,
    source_info: zipfile.ZipInfo | None,
    target_info: zipfile.ZipInfo | None,
    *,
    source_sha256: str = "",
    target_sha256: str = "",
    expected_entries: set[str],
    nested: bool = False,
    note: str = "",
) -> dict[str, Any]:
    return {
        "path": path,
        "change_type": change_type,
        "content_type": _content_type(path, nested=nested),
        "expected": _expected(path, expected_entries),
        "source_size": source_info.file_size if source_info is not None else None,
        "target_size": target_info.file_size if target_info is not None else None,
        "source_crc32": _crc32(source_info),
        "target_crc32": _crc32(target_info),
        "source_sha256": source_sha256,
        "target_sha256": target_sha256,
        "note": note,
    }


class ArtifactComparator:
    def __init__(self, expected_entries: list[str] | None = None, max_depth: int = MAX_NESTED_DEPTH) -> None:
        self.expected_entries = {_norm(str(item)) for item in (expected_entries or []) if str(item).strip()}
        self.max_depth = max_depth
        self.changes: list[dict[str, Any]] = []
        self.nested_archives: list[dict[str, Any]] = []
        self.warnings: list[str] = []
        self.metrics = {
            "entries_compared": 0,
            "entries_fast_skipped": 0,
            "entries_hashed": 0,
            "nested_archives_opened": 0,
        }

    def _hash_pair(
        self,
        source_zip: zipfile.ZipFile,
        source_info: zipfile.ZipInfo,
        target_zip: zipfile.ZipFile,
        target_info: zipfile.ZipInfo,
    ) -> tuple[str, str]:
        self.metrics["entries_hashed"] += 2
        return _sha256_entry(source_zip, source_info), _sha256_entry(target_zip, target_info)

    def _compare_zip(
        self,
        source_zip: zipfile.ZipFile,
        target_zip: zipfile.ZipFile,
        *,
        prefix: str,
        depth: int,
        source_label: str,
        target_label: str,
    ) -> None:
        source_entries = _entry_map(source_zip, self.warnings, source_label)
        target_entries = _entry_map(target_zip, self.warnings, target_label)

        for name in sorted(set(source_entries) | set(target_entries)):
            source_info = source_entries.get(name)
            target_info = target_entries.get(name)
            full_path = f"{prefix}{name}" if prefix else name
            self.metrics["entries_compared"] += 1

            if source_info is None:
                target_sha = _sha256_entry(target_zip, target_info) if target_info is not None else ""
                if target_info is not None:
                    self.metrics["entries_hashed"] += 1
                self.changes.append(_change_record(
                    full_path, "ADDED", None, target_info,
                    target_sha256=target_sha,
                    expected_entries=self.expected_entries,
                    nested=_is_nested_archive(name),
                ))
                continue

            if target_info is None:
                source_sha = _sha256_entry(source_zip, source_info)
                self.metrics["entries_hashed"] += 1
                self.changes.append(_change_record(
                    full_path, "DELETED", source_info, None,
                    source_sha256=source_sha,
                    expected_entries=self.expected_entries,
                    nested=_is_nested_archive(name),
                ))
                continue

            if source_info.file_size == target_info.file_size and source_info.CRC == target_info.CRC:
                self.metrics["entries_fast_skipped"] += 1
                continue

            if _is_nested_archive(name) and depth < self.max_depth:
                try:
                    source_spool, source_sha = _spool_entry(source_zip, source_info)
                    target_spool, target_sha = _spool_entry(target_zip, target_info)
                    self.metrics["entries_hashed"] += 2
                    self.metrics["nested_archives_opened"] += 1
                    change_start = len(self.changes)
                    nested_start = len(self.nested_archives)
                    try:
                        with source_spool, target_spool:
                            with zipfile.ZipFile(source_spool, "r") as child_source, zipfile.ZipFile(target_spool, "r") as child_target:
                                self._compare_zip(
                                    child_source,
                                    child_target,
                                    prefix=full_path + "!/",
                                    depth=depth + 1,
                                    source_label=source_label + "!/" + name,
                                    target_label=target_label + "!/" + name,
                                )
                    except (zipfile.BadZipFile, OSError) as exc:
                        self.changes.append(_change_record(
                            full_path, "MODIFIED", source_info, target_info,
                            source_sha256=source_sha,
                            target_sha256=target_sha,
                            expected_entries=self.expected_entries,
                            nested=True,
                            note=f"Nested archive could not be opened; compared as binary: {exc}",
                        ))
                        continue

                    leaf_change_count = len(self.changes) - change_start
                    child_archive_records = self.nested_archives[nested_start:]
                    child_content_changed = any(
                        str(item.get("change_type")) != "REPACKAGED_ONLY" for item in child_archive_records
                    )
                    container_change_type = "CONTENT_CHANGED" if leaf_change_count > 0 or child_content_changed else "REPACKAGED_ONLY"
                    self.nested_archives.append({
                        "path": full_path,
                        "change_type": container_change_type,
                        "expected": _expected(full_path, self.expected_entries),
                        "source_size": source_info.file_size,
                        "target_size": target_info.file_size,
                        "source_crc32": _crc32(source_info),
                        "target_crc32": _crc32(target_info),
                        "source_sha256": source_sha,
                        "target_sha256": target_sha,
                        "direct_or_descendant_change_count": leaf_change_count,
                    })
                    continue
                except Exception as exc:
                    # Fall back to normal binary comparison without losing the report.
                    source_sha, target_sha = self._hash_pair(source_zip, source_info, target_zip, target_info)
                    self.changes.append(_change_record(
                        full_path, "MODIFIED", source_info, target_info,
                        source_sha256=source_sha,
                        target_sha256=target_sha,
                        expected_entries=self.expected_entries,
                        nested=True,
                        note=f"Nested archive comparison failed; compared as binary: {exc}",
                    ))
                    continue

            source_sha, target_sha = self._hash_pair(source_zip, source_info, target_zip, target_info)
            if source_sha == target_sha:
                # CRC/size disagreement is unusual but SHA-256 is authoritative for content.
                self.metrics["entries_fast_skipped"] += 1
                continue
            self.changes.append(_change_record(
                full_path, "MODIFIED", source_info, target_info,
                source_sha256=source_sha,
                target_sha256=target_sha,
                expected_entries=self.expected_entries,
                nested=_is_nested_archive(name),
                note="Nested comparison depth limit reached" if _is_nested_archive(name) and depth >= self.max_depth else "",
            ))

    def compare(self, source: Path, target: Path) -> dict[str, Any]:
        started = time.monotonic()
        try:
            with zipfile.ZipFile(source, "r") as source_zip, zipfile.ZipFile(target, "r") as target_zip:
                self._compare_zip(
                    source_zip,
                    target_zip,
                    prefix="",
                    depth=0,
                    source_label=source.name,
                    target_label=target.name,
                )
        except zipfile.BadZipFile as exc:
            raise MigrationError("ARTIFACT_CHANGE_REPORT_INVALID_ARCHIVE", f"Invalid JAR/WAR archive: {exc}")

        counts = {"ADDED": 0, "MODIFIED": 0, "DELETED": 0}
        expected_count = 0
        unexpected_count = 0
        for item in self.changes:
            change_type = str(item.get("change_type") or "")
            if change_type in counts:
                counts[change_type] += 1
            if item.get("expected"):
                expected_count += 1
            else:
                unexpected_count += 1

        content_changed_nested = sum(1 for item in self.nested_archives if item.get("change_type") == "CONTENT_CHANGED")
        repackaged_only_nested = sum(1 for item in self.nested_archives if item.get("change_type") == "REPACKAGED_ONLY")
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {
            "status": "SUCCESS",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "source_artifact": str(source.resolve()),
            "target_artifact": str(target.resolve()),
            "comparison_strategy": {
                "fast_skip": "entry uncompressed size + CRC32",
                "deep_compare": "SHA-256 only for changed entries",
                "nested_archives": "recursive only when nested JAR/WAR container bytes differ",
                "max_nested_depth": self.max_depth,
            },
            "summary": {
                "changed_files": len(self.changes),
                "added_files": counts["ADDED"],
                "modified_files": counts["MODIFIED"],
                "deleted_files": counts["DELETED"],
                "changed_nested_archives": content_changed_nested,
                "repackaged_only_nested_archives": repackaged_only_nested,
                "expected_changes": expected_count,
                "unexpected_changes": unexpected_count,
                **self.metrics,
                "elapsed_ms": elapsed_ms,
            },
            "changes": self.changes,
            "nested_archives": self.nested_archives,
            "warnings": self.warnings,
        }


def _md_escape(value: Any) -> str:
    return str(value if value is not None else "").replace("|", "\\|").replace("\n", " ")


def write_markdown(report: dict[str, Any], path: Path) -> None:
    summary = report.get("summary") or {}
    lines = [
        "# Java 应用迁移制品变更报告",
        "",
        "## 基本信息",
        "",
        f"- 原始制品：`{report.get('source_artifact', '')}`",
        f"- 迁移制品：`{report.get('target_artifact', '')}`",
        f"- 变化文件：**{summary.get('changed_files', 0)}**",
        f"- 内容变化子归档：**{summary.get('changed_nested_archives', 0)}**",
        f"- 仅重打包子归档：**{summary.get('repackaged_only_nested_archives', 0)}**",
        f"- 预期变化：**{summary.get('expected_changes', 0)}**",
        f"- 非预期变化：**{summary.get('unexpected_changes', 0)}**",
        f"- 比较耗时：**{summary.get('elapsed_ms', 0)} ms**",
        "",
        "## 文件变化",
        "",
    ]
    changes = report.get("changes") or []
    if changes:
        lines += [
            "| 类型 | 文件 | 内容类型 | 预期变化 | 原大小 | 新大小 | 原SHA256 | 新SHA256 |",
            "|---|---|---|---|---:|---:|---|---|",
        ]
        for item in changes:
            lines.append(
                "| {change_type} | `{path}` | {content_type} | {expected} | {source_size} | {target_size} | `{source_sha}` | `{target_sha}` |".format(
                    change_type=_md_escape(item.get("change_type")),
                    path=_md_escape(item.get("path")),
                    content_type=_md_escape(item.get("content_type")),
                    expected="是" if item.get("expected") else "否",
                    source_size="" if item.get("source_size") is None else item.get("source_size"),
                    target_size="" if item.get("target_size") is None else item.get("target_size"),
                    source_sha=_md_escape(str(item.get("source_sha256") or "")[:16]),
                    target_sha=_md_escape(str(item.get("target_sha256") or "")[:16]),
                )
            )
    else:
        lines.append("未发现文件内容变化。")

    lines += ["", "## 子 JAR/WAR 变化", ""]
    nested = report.get("nested_archives") or []
    if nested:
        lines += [
            "| 子归档 | 状态 | 预期变化 | 内部变化文件数 |",
            "|---|---|---|---:|",
        ]
        for item in nested:
            lines.append(
                "| `{path}` | {change_type} | {expected} | {count} |".format(
                    path=_md_escape(item.get("path")),
                    change_type=_md_escape(item.get("change_type")),
                    expected="是" if item.get("expected") else "否",
                    count=item.get("direct_or_descendant_change_count", 0),
                )
            )
    else:
        lines.append("未发现发生变化的子 JAR/WAR。")

    lines += [
        "",
        "## 比较策略",
        "",
        "- 未变化 Entry 通过未压缩大小和 CRC32 快速跳过。",
        "- SHA256 仅对疑似变化 Entry 计算。",
        "- 子 JAR/WAR 仅在容器内容变化时递归比较内部 Entry。",
        "- 子归档字节变化但内部文件内容一致时标记为 `REPACKAGED_ONLY`。",
        "",
    ]
    warnings = report.get("warnings") or []
    if warnings:
        lines += ["## 警告", ""] + [f"- {_md_escape(item)}" for item in warnings] + [""]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def generate_artifact_change_report(
    source: Path,
    target: Path,
    reports_dir: Path,
    *,
    expected_entries: list[str] | None = None,
) -> dict[str, Any]:
    if not source.is_file():
        raise MigrationError("ARTIFACT_CHANGE_REPORT_SOURCE_MISSING", f"Original artifact not found: {source}")
    if not target.is_file():
        raise MigrationError("ARTIFACT_CHANGE_REPORT_TARGET_MISSING", f"Migrated artifact not found: {target}")
    comparator = ArtifactComparator(expected_entries=expected_entries)
    report = comparator.compare(source, target)
    reports_dir.mkdir(parents=True, exist_ok=True)
    json_path = reports_dir / "artifact-change-report.json"
    md_path = reports_dir / "artifact-change-report.md"
    write_json(json_path, report)
    write_markdown(report, md_path)
    report["report_json"] = str(json_path.resolve())
    report["report_markdown"] = str(md_path.resolve())
    return report
