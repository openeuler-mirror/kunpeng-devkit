#!/usr/bin/env python3
"""Expand declared tool packages and resolve DevKit strictly from tools/."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any

# Reuse the top-level migration plan implementation as the single source of
# truth for migration tool dependency decisions.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from migration_plan import load_json, migration_tool_packages, prepared_tool_package_path

ARCHIVE_SUFFIXES = (".tar.gz", ".tgz", ".tar", ".tar.bz2", ".tar.xz", ".zip")


def within(root: Path, path: Path) -> bool:
    try:
        return os.path.commonpath([str(root.resolve()), str(path.resolve())]) == str(root.resolve())
    except (OSError, ValueError):
        return False


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_extract_tar(archive: Path, destination: Path) -> None:
    root = destination.resolve()
    with tarfile.open(archive, "r:*") as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if not within(root, target):
                raise ValueError(f"unsafe tar member: {member.name}")
            if member.isdev() or member.isfifo():
                raise ValueError(f"unsupported tar member: {member.name}")
            if member.issym() and not within(root, target.parent / member.linkname):
                raise ValueError(f"unsafe tar symlink: {member.name}")
            if member.islnk() and not within(root, destination / member.linkname):
                raise ValueError(f"unsafe tar hardlink: {member.name}")
        try:
            bundle.extractall(destination, filter="data")
        except TypeError:
            bundle.extractall(destination)


def safe_extract_zip(archive: Path, destination: Path) -> None:
    root = destination.resolve()
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            mode = (member.external_attr >> 16) & 0o170000
            if stat.S_ISLNK(mode):
                raise ValueError(f"unsupported zip symlink: {member.filename}")
            if not within(root, destination / member.filename):
                raise ValueError(f"unsafe zip member: {member.filename}")
        bundle.extractall(destination)


def extract_archive(archive: Path, destination: Path) -> None:
    lower = archive.name.lower()
    if lower.endswith((".tar.gz", ".tgz", ".tar", ".tar.bz2", ".tar.xz")):
        safe_extract_tar(archive, destination)
    elif lower.endswith(".zip"):
        safe_extract_zip(archive, destination)
    else:
        raise ValueError(f"unsupported tool package archive: {archive.name}")


def is_archive(path: Path) -> bool:
    return path.name.lower().endswith(ARCHIVE_SUFFIXES)


def expand_package(archive: Path, package_root: Path) -> Path:
    expanded = package_root / "expanded"
    marker = expanded / ".package-source.sha256"
    archive_hash = file_sha256(archive)
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == archive_hash:
        return expanded.resolve()
    package_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="expanded-", dir=package_root))
    moved = False
    try:
        extract_archive(archive, staging)
        (staging / ".package-source.sha256").write_text(archive_hash + "\n", encoding="utf-8")
        if expanded.exists():
            shutil.rmtree(expanded)
        staging.replace(expanded)
        moved = True
        return expanded.resolve()
    finally:
        if not moved and staging.exists():
            shutil.rmtree(staging)


def expand_nested_archives(expanded: Path, package_root: Path) -> list[Path]:
    """Expand nested archives without searching outside the declared package."""
    roots = [expanded.resolve()]
    frontier = [expanded.resolve()]
    nested_root = package_root / "nested"
    if nested_root.exists():
        shutil.rmtree(nested_root)
    nested_root.mkdir(parents=True, exist_ok=True)
    seen_hashes: set[str] = set()
    while frontier:
        next_frontier: list[Path] = []
        for root in frontier:
            for archive in sorted((p for p in root.rglob("*") if p.is_file() and is_archive(p)), key=str):
                archive_hash = file_sha256(archive)
                if archive_hash in seen_hashes:
                    continue
                seen_hashes.add(archive_hash)
                key = hashlib.sha256((str(archive.resolve()) + "\0" + archive_hash).encode("utf-8")).hexdigest()[:16]
                target = nested_root / key
                marker = target / ".nested-source.sha256"
                if not (marker.is_file() and marker.read_text(encoding="utf-8").strip() == archive_hash):
                    staging = Path(tempfile.mkdtemp(prefix=f"{key}-", dir=nested_root))
                    moved = False
                    try:
                        extract_archive(archive, staging)
                        (staging / ".nested-source.sha256").write_text(archive_hash + "\n", encoding="utf-8")
                        if target.exists():
                            shutil.rmtree(target)
                        staging.replace(target)
                        moved = True
                    finally:
                        if not moved and staging.exists():
                            shutil.rmtree(staging)
                target = target.resolve()
                if target not in roots:
                    roots.append(target)
                    next_frontier.append(target)
        frontier = next_frontier
    return roots


def declared_tool_names(package: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for item in package.get("tools") or []:
        if isinstance(item, dict):
            name = str(item.get("name") or "").strip().lower()
            if name:
                names.add(name)
    return names


def find_declared_tool(search_roots: list[Path], tool_name: str) -> tuple[Path | None, list[str]]:
    """Resolve an executable by the exact name declared in migration_tools[].tools[]."""
    candidates: list[Path] = []
    seen: set[Path] = set()
    expected = tool_name.strip().lower()
    for root in search_roots:
        for path in root.rglob("*"):
            if path.name.lower() != expected or not path.is_file() or path.is_symlink() or not os.access(path, os.X_OK):
                continue
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            candidates.append(resolved)
    candidates.sort(key=lambda path: (len(path.parts), str(path)))
    if not candidates:
        return None, []
    return candidates[0], [str(path) for path in candidates[:10]]

def install_reference(source: Path, reference: Path) -> None:
    reference.parent.mkdir(parents=True, exist_ok=True)
    if reference.is_symlink() or reference.exists():
        reference.unlink()
    reference.symlink_to(source.resolve())


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare declared tool packages and resolve DevKit")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--work-dir", required=True)
    args = parser.parse_args()

    plan_path = Path(args.plan).expanduser().resolve()
    plan = load_json(plan_path)
    migration_root = Path(args.work_dir).expanduser().resolve()
    migration_root.mkdir(parents=True, exist_ok=True)
    tools_root = (migration_root / "tools").resolve()
    packages_root = (tools_root / "packages").resolve()
    packages = migration_tool_packages(plan)
    results: list[dict[str, Any]] = []
    tool_search_roots: dict[str, list[Path]] = {}
    blocked = False

    for index, package in enumerate(packages):
        package_id = str(package.get("id") or f"tool-package-{index + 1}") if isinstance(package, dict) else f"tool-package-{index + 1}"
        if not isinstance(package, dict):
            results.append({"id": package_id, "status": "BLOCKED", "reason": "INVALID_TOOL_PACKAGE"})
            blocked = True
            continue
        if package.get("status") != "READY":
            results.append({
                "id": package_id,
                "status": "BLOCKED",
                "reason": "TOOL_PACKAGE_STATUS_NOT_READY",
                "plan_status": package.get("status"),
            })
            blocked = True
            continue
        try:
            archive = prepared_tool_package_path(plan, package).resolve()
        except ValueError as exc:
            results.append({"id": package_id, "status": "BLOCKED", "reason": "INVALID_TOOL_PACKAGE", "message": str(exc)})
            blocked = True
            continue
        if not within(packages_root, archive) or not archive.is_file() or archive.stat().st_size <= 0:
            results.append({"id": package_id, "status": "BLOCKED", "reason": "TOOL_PACKAGE_NOT_READY", "expected_path": str(archive)})
            blocked = True
            continue
        package_type = str(package.get("type") or "").upper()
        if package_type == "FILE":
            # FILE entries are standalone tool files. Do not extract them.
            package_roots = [archive.parent.resolve()]
            for tool_name in declared_tool_names(package):
                tool_search_roots.setdefault(tool_name, []).extend(package_roots)
            results.append({
                "id": package_id,
                "status": "READY",
                "type": "FILE",
                "file": str(archive),
                "search_roots": [str(path) for path in package_roots],
            })
            continue
        if package_type != "ARCHIVE":
            results.append({
                "id": package_id,
                "status": "BLOCKED",
                "reason": "INVALID_TOOL_PACKAGE_TYPE",
                "message": f"unsupported migration tool package type: {package_type or '<empty>'}",
            })
            blocked = True
            continue

        unpacked_root = (tools_root / "unpacked").resolve()
        package_root = (unpacked_root / package_id).resolve()
        if not within(unpacked_root, package_root) or package_root == unpacked_root:
            results.append({"id": package_id, "status": "BLOCKED", "reason": "INVALID_TOOL_PACKAGE_ID"})
            blocked = True
            continue
        try:
            expanded = expand_package(archive, package_root)
            package_roots = expand_nested_archives(expanded, package_root)
            for tool_name in declared_tool_names(package):
                tool_search_roots.setdefault(tool_name, []).extend(package_roots)
            results.append({
                "id": package_id,
                "status": "READY",
                "type": "ARCHIVE",
                "archive": str(archive),
                "expanded": str(expanded),
                "search_roots": [str(path) for path in package_roots],
            })
        except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as exc:
            results.append({"id": package_id, "status": "BLOCKED", "reason": "TOOL_PACKAGE_INVALID", "message": str(exc)})
            blocked = True

    if not blocked:
        devkit_roots = tool_search_roots.get("ai-migration") or []
        if not devkit_roots:
            results.append({
                "tool": "ai-migration",
                "status": "BLOCKED",
                "reason": "AI_MIGRATION_TOOL_NOT_DECLARED",
                "message": "migration_tools must declare tools[].name=ai-migration",
            })
            blocked = True
        else:
            devkit, candidates = find_declared_tool(devkit_roots, "ai-migration")
            if devkit is None:
                results.append({
                    "tool": "ai-migration",
                    "status": "BLOCKED",
                    "reason": "DEVKIT_NOT_FOUND_UNDER_DECLARED_PACKAGE",
                    "message": "declared ai-migration executable was not found in its migration tool package",
                    "candidates": candidates,
                })
                blocked = True
            else:
                reference = tools_root / "bin" / "ai-migration"
                install_reference(devkit, reference)
                results.append({
                    "tool": "ai-migration",
                    "status": "READY",
                    "path": str(reference),
                    "resolved_path": str(devkit),
                })

    output = {"status": "BLOCKED" if blocked else "READY", "tool_packages": results}
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 20 if blocked else 0


if __name__ == "__main__":
    raise SystemExit(main())
