#!/usr/bin/env python3
"""Resolve Vineflower 1.12 and the application-migration JDK strictly from tools/."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path
from typing import Any

# Reuse the top-level migration plan implementation as the single source of
# truth for migration tool dependency decisions.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from migration_plan import load_json, migration_tool_packages

RUNTIME_ARCHIVE_SUFFIXES = (".tar.gz", ".tgz", ".tar", ".tar.bz2", ".tar.xz", ".zip")


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


def java_major_version(java_command: Path) -> tuple[int | None, str]:
    try:
        result = subprocess.run(
            [str(java_command), "-version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            check=False,
        )
    except Exception as exc:
        return None, repr(exc)
    output = result.stdout or ""
    if result.returncode != 0:
        return None, output
    match = re.search(r'version\s+"([^"]+)"', output)
    if not match:
        return None, output
    parts = match.group(1).split(".")
    try:
        return int(parts[1] if parts[0] == "1" and len(parts) > 1 else parts[0]), output
    except ValueError:
        return None, output


def validate_vineflower_jar(path: Path) -> bool:
    if not path.is_file() or not os.access(path, os.R_OK) or path.stat().st_size <= 0:
        return False
    return zipfile.is_zipfile(path)


def declared_tool_roots(plan: dict[str, Any], tools_root: Path) -> list[Path]:
    unpacked_root = (tools_root / "unpacked").resolve()
    packages_root = (tools_root / "packages").resolve()
    roots: list[Path] = []
    for index, package in enumerate(migration_tool_packages(plan)):
        if package.get("status") != "READY":
            continue
        package_id = str(package.get("id") or f"tool-package-{index + 1}")
        package_type = str(package.get("type") or "").upper()
        if package_type == "ARCHIVE":
            package_root = (unpacked_root / package_id).resolve()
            if within(unpacked_root, package_root) and package_root.is_dir():
                roots.append(package_root)
        elif package_type == "FILE":
            package_root = (packages_root / package_id).resolve()
            if within(packages_root, package_root) and package_root.is_dir():
                roots.append(package_root)
    return roots




def declared_jdk_roots(plan: dict[str, Any], tools_root: Path) -> list[Path]:
    unpacked_root = (tools_root / "unpacked").resolve()
    roots: list[Path] = []
    for index, package in enumerate(migration_tool_packages(plan)):
        if not isinstance(package, dict) or package.get("status") != "READY":
            continue
        names = {
            str(item.get("name") or "").strip().lower()
            for item in package.get("tools") or []
            if isinstance(item, dict)
        }
        package_id = str(package.get("id") or f"tool-package-{index + 1}").strip().lower()
        package_name = str(package.get("package_name") or "").strip().lower()
        is_jdk = package_id == "jdk" or package_name == "jdk" or {"java", "javac", "jar"}.issubset(names)
        if not is_jdk or str(package.get("type") or "").upper() != "ARCHIVE":
            continue
        package_root = (unpacked_root / str(package.get("id") or f"tool-package-{index + 1}")).resolve()
        if within(unpacked_root, package_root) and package_root.is_dir():
            roots.append(package_root)
    return roots

def find_vineflower_jar(search_roots: list[Path]) -> Path | None:
    pattern = re.compile(r"^vineflower[-_.]?1\.12(?:\.\d+)?(?:[-_.].*)?\.jar$", re.IGNORECASE)
    candidates: set[Path] = set()
    for root in search_roots:
        candidates.update(
            path.resolve()
            for path in root.rglob("*.jar")
            if path.is_file() and pattern.match(path.name) and validate_vineflower_jar(path)
        )
    return sorted(candidates, key=lambda path: (len(path.parts), str(path)))[0] if candidates else None


def ensure_archive_target(root: Path, target: Path, name: str) -> None:
    if not within(root, target):
        raise ValueError(f"unsafe Java runtime archive entry: {name}")


def extract_runtime_archive(archive: Path, destination: Path) -> None:
    destination = destination.resolve()
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive, "r:*") as bundle:
            members = bundle.getmembers()
            for member in members:
                target = (destination / member.name).resolve()
                ensure_archive_target(destination, target, member.name)
                if member.isdev() or member.isfifo():
                    raise ValueError(f"unsupported Java runtime archive entry: {member.name}")
                if member.issym():
                    ensure_archive_target(destination, (target.parent / member.linkname).resolve(), member.name)
                elif member.islnk():
                    ensure_archive_target(destination, (destination / member.linkname).resolve(), member.name)
            if sys.version_info >= (3, 12):
                bundle.extractall(destination, members=members, filter="fully_trusted")
            else:
                bundle.extractall(destination, members=members)
        return
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                ensure_archive_target(destination, destination / member.filename, member.filename)
                mode = (member.external_attr >> 16) & 0o170000
                if stat.S_ISLNK(mode):
                    raise ValueError(f"unsupported Java runtime ZIP symlink: {member.filename}")
            bundle.extractall(destination)
        return
    raise ValueError(f"unsupported Java runtime archive: {archive}")


def runtime_archive_candidates(search_roots: list[Path]) -> list[Path]:
    candidates: list[Path] = []
    for root in search_roots:
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            name = path.name.lower()
            if ("jre" in name or "jdk" in name) and name.endswith(RUNTIME_ARCHIVE_SUFFIXES):
                candidates.append(path.resolve())
    return sorted(set(candidates), key=str)


def expand_runtime_archives(search_roots: list[Path], tools_root: Path) -> tuple[list[dict[str, str]], list[Path]]:
    expanded: list[dict[str, str]] = []
    runtime_roots: list[Path] = []
    runtime_root = tools_root / "runtime"
    runtime_root.mkdir(parents=True, exist_ok=True)
    for archive in runtime_archive_candidates(search_roots):
        key = hashlib.sha256(str(archive).encode("utf-8")).hexdigest()[:12]
        target = runtime_root / key
        marker = target / ".runtime-source.sha256"
        archive_hash = file_sha256(archive)
        if marker.is_file() and marker.read_text(encoding="utf-8").strip() == archive_hash:
            expanded.append({"archive": str(archive), "directory": str(target)})
            runtime_roots.append(target.resolve())
            continue
        staging = Path(tempfile.mkdtemp(prefix=f"{key}-", dir=runtime_root))
        moved = False
        try:
            extract_runtime_archive(archive, staging)
            (staging / ".runtime-source.sha256").write_text(archive_hash + "\n", encoding="utf-8")
            if target.exists():
                shutil.rmtree(target)
            staging.replace(target)
            moved = True
            expanded.append({"archive": str(archive), "directory": str(target)})
            runtime_roots.append(target.resolve())
        finally:
            if not moved and staging.exists():
                shutil.rmtree(staging)
    return expanded, runtime_roots


def find_compatible_jdk(search_roots: list[Path]) -> tuple[Path | None, int | None, list[dict[str, Any]]]:
    checked: list[dict[str, Any]] = []
    compatible: list[tuple[int, Path]] = []
    candidates: set[Path] = set()
    for root in search_roots:
        candidates.update(path.parent.parent.resolve() for path in root.rglob("bin/java") if path.is_file())
    for home in sorted(candidates, key=str):
        if not any(within(root, home) for root in search_roots):
            continue
        required = {name: home / "bin" / name for name in ("java", "javac", "jar")}
        missing = [name for name, path in required.items() if not path.is_file() or not os.access(path, os.X_OK)]
        major, output = java_major_version(required["java"]) if "java" not in missing else (None, "")
        checked.append({"home": str(home), "major": major, "missing_tools": missing, "output": output[-500:]})
        if not missing and major is not None and major >= 17:
            compatible.append((major, home))
    compatible.sort(key=lambda item: (item[0] != 17, item[0], len(item[1].parts), str(item[1])))
    if not compatible:
        return None, None, checked
    major, home = compatible[0]
    return home, major, checked


def install_reference(source: Path, reference: Path) -> None:
    reference.parent.mkdir(parents=True, exist_ok=True)
    if reference.is_symlink() or reference.is_file():
        reference.unlink()
    elif reference.is_dir():
        shutil.rmtree(reference)
    reference.symlink_to(source.resolve(), target_is_directory=source.resolve().is_dir())


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve Vineflower 1.12 and migration JDK from tools")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--work-dir", required=True)
    args = parser.parse_args()

    plan_path = Path(args.plan).expanduser().resolve()
    plan = load_json(plan_path)
    migration_root = Path(args.work_dir).expanduser().resolve()
    migration_root.mkdir(parents=True, exist_ok=True)
    tools_root = (migration_root / "tools").resolve()
    declared = migration_tool_packages(plan)
    declared_names = {
        str(item.get("name") or "").strip().lower()
        for package in declared
        for item in (package.get("tools") or [])
        if isinstance(item, dict) and str(item.get("name") or "").strip()
    }
    vineflower_declared = any("vineflower" in name for name in declared_names)
    jdk_declared = {"java", "javac", "jar"}.issubset(declared_names)
    if not vineflower_declared and not jdk_declared:
        print(json.dumps({"status": "READY", "resolved": []}, ensure_ascii=False))
        return 0
    if vineflower_declared and not jdk_declared:
        print(json.dumps({"status": "BLOCKED", "reason": "MIGRATION_JDK_NOT_DECLARED"}, ensure_ascii=False, indent=2))
        return 20

    jar_reference = tools_root / "lib" / "vineflower-1.12.jar"
    java_reference = tools_root / "bin" / "vineflower-java"
    jdk_reference = tools_root / "runtime" / "jdk"
    for reference in (jar_reference, java_reference, jdk_reference):
        if reference.is_symlink():
            reference.unlink()

    search_roots = declared_tool_roots(plan, tools_root)
    jar = find_vineflower_jar(search_roots)
    if jar is None:
        print(json.dumps({
            "status": "BLOCKED",
            "reason": "VINEFLOWER_1_12_NOT_FOUND_UNDER_TOOLS",
            "tools_root": str(tools_root),
            "action": "ensure a declared migration tool package contains Vineflower 1.12",
        }, ensure_ascii=False, indent=2))
        return 20

    jdk_roots = declared_jdk_roots(plan, tools_root)
    jdk_home, major, checked = find_compatible_jdk(jdk_roots)
    expanded: list[dict[str, str]] = []
    if jdk_home is None:
        try:
            expanded, runtime_roots = expand_runtime_archives(jdk_roots, tools_root)
        except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as exc:
            print(json.dumps({
                "status": "BLOCKED",
                "reason": "VINEFLOWER_JAVA_ARCHIVE_INVALID",
                "message": str(exc),
            }, ensure_ascii=False, indent=2))
            return 20
        jdk_home, major, checked = find_compatible_jdk(jdk_roots + runtime_roots)
    if jdk_home is None:
        print(json.dumps({
            "status": "BLOCKED",
            "reason": "COMPLETE_JDK_17_PLUS_NOT_FOUND_UNDER_TOOLS",
            "tools_root": str(tools_root),
            "jdk_roots": [str(path) for path in jdk_roots],
            "checked": checked,
            "expanded_runtime_archives": expanded,
            "action": "ensure the declared JDK migration tool package contains executable java, javac and jar from JDK 17+",
        }, ensure_ascii=False, indent=2))
        return 20

    try:
        probe = subprocess.run(
            [str(jdk_home / "bin" / "java"), "-jar", str(jar), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
            check=False,
        )
    except Exception as exc:
        print(json.dumps({"status": "BLOCKED", "reason": "VINEFLOWER_RUNTIME_PROBE_FAILED", "message": repr(exc)}, ensure_ascii=False, indent=2))
        return 20
    if probe.returncode != 0:
        print(json.dumps({
            "status": "BLOCKED",
            "reason": "VINEFLOWER_RUNTIME_INCOMPATIBLE",
            "java": str(jdk_home / "bin" / "java"),
            "jar": str(jar),
            "output": (probe.stdout or "")[-4000:],
        }, ensure_ascii=False, indent=2))
        return 20

    install_reference(jar, jar_reference)
    install_reference(jdk_home, jdk_reference)
    install_reference(jdk_reference / "bin" / "java", java_reference)
    print(json.dumps({
        "status": "READY",
        "jar": str(jar_reference),
        "java": str(java_reference),
        "migration_jdk": str(jdk_reference),
        "java_major": major,
        "resolved_jar": str(jar),
        "resolved_jdk": str(jdk_home),
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
