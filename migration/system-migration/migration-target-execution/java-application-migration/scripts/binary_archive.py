from __future__ import annotations
import io
import json
import os
import shutil
import stat
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

from migration_common import (
    MigrationError,
    java_tool, run, run_shell,
)


def safe_extract_zip(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            mode = (item.external_attr >> 16) & 0o170000
            if stat.S_ISLNK(mode):
                raise MigrationError("UNSAFE_ARCHIVE", f"Zip symlink is not allowed: {item.filename}")
            target = (destination / item.filename).resolve()
            if os.path.commonpath([str(root), str(target)]) != str(root):
                raise MigrationError("UNSAFE_ARCHIVE", f"Unsafe archive member: {item.filename}")
        zf.extractall(destination)

def rebuild_zip_with_replacement(data: bytes, path_parts: list[str], replacement: bytes) -> bytes:
    current = path_parts[0]
    source = io.BytesIO(data)
    target = io.BytesIO()
    found = False
    with zipfile.ZipFile(source, "r") as zin, zipfile.ZipFile(target, "w") as zout:
        for info in zin.infolist():
            item_data = zin.read(info.filename)
            if info.filename == current:
                found = True
                if len(path_parts) == 1:
                    item_data = replacement
                else:
                    item_data = rebuild_zip_with_replacement(item_data, path_parts[1:], replacement)
            zout.writestr(info, item_data)
    if not found:
        raise MigrationError("NATIVE_REPLACEMENT_NOT_FOUND", f"Archive entry not found: {'!/'.join(path_parts)}")
    return target.getvalue()

def rebuild_zip_with_mutation(
    data: bytes, path_parts: list[str], action: str, source_data: bytes | None
) -> bytes:
    current = path_parts[0]
    source = io.BytesIO(data)
    target = io.BytesIO()
    found = False
    with zipfile.ZipFile(source, "r") as zin, zipfile.ZipFile(target, "w") as zout:
        for info in zin.infolist():
            item_data = zin.read(info.filename)
            if info.filename == current:
                found = True
                if len(path_parts) == 1:
                    if action == "delete":
                        continue
                    if action in {"replace", "add"}:
                        if source_data is None:
                            raise MigrationError("INVALID_ARCHIVE_MUTATION", "source data is required")
                        item_data = source_data
                else:
                    item_data = rebuild_zip_with_mutation(item_data, path_parts[1:], action, source_data)
            zout.writestr(info, item_data)
        if not found and len(path_parts) == 1 and action == "add":
            if source_data is None:
                raise MigrationError("INVALID_ARCHIVE_MUTATION", "source data is required")
            zout.writestr(current, source_data)
            found = True
    if not found:
        raise MigrationError(
            "ARCHIVE_MUTATION_TARGET_NOT_FOUND",
            f"Archive entry not found for {action}: {'!/'.join(path_parts)}",
        )
    return target.getvalue()

def materialize_source(item: dict[str, Any], work_dir: Path, log_path: Path) -> Path:
    direct = item.get("source_file") or item.get("replacement_file")
    if direct:
        path = Path(str(direct)).expanduser().resolve()
        if not path.is_file():
            raise MigrationError("ARCHIVE_MUTATION_SOURCE_MISSING", f"File not found: {path}")
        return path
    url = item.get("download_url")
    if url:
        name = str(item.get("download_name") or Path(str(url).split("?", 1)[0]).name or "download.bin")
        target = work_dir / "downloads" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            urllib.request.urlretrieve(str(url), target)
        return target
    build_command = item.get("build_command")
    output_file = item.get("build_output")
    if build_command and output_file:
        run_shell(str(build_command), log_path, cwd=work_dir)
        path = Path(str(output_file)).expanduser()
        if not path.is_absolute():
            path = work_dir / path
        path = path.resolve()
        if not path.is_file():
            raise MigrationError("BUILD_OUTPUT_MISSING", f"Build output not found: {path}")
        return path
    raise MigrationError("INVALID_ARCHIVE_MUTATION", f"No source_file, download_url, or build_command: {item}")

def apply_archive_mutations(
    package: Path, mutations: list[dict[str, Any]], work_dir: Path, log_path: Path
) -> list[dict[str, str]]:
    if not mutations:
        return []
    data = package.read_bytes()
    applied: list[dict[str, str]] = []
    for item in mutations:
        action = str(item.get("action") or "replace").lower()
        archive_path = str(item.get("archive_path") or "")
        if action not in {"add", "replace", "delete"} or not archive_path:
            raise MigrationError("INVALID_ARCHIVE_MUTATION", f"Invalid archive mutation: {item}")
        source_data = None
        source_path = None
        if action != "delete":
            source_path = materialize_source(item, work_dir, log_path)
            source_data = source_path.read_bytes()
        data = rebuild_zip_with_mutation(data, archive_path.split("!/"), action, source_data)
        applied.append({
            "action": action,
            "archive_path": archive_path,
            "source_file": str(source_path) if source_path else "",
        })
    package.write_bytes(data)
    with log_path.open("a", encoding="utf-8") as fh:
        for item in applied:
            fh.write(json.dumps(item, ensure_ascii=False) + "\n")
    return applied

def detect_layout(unpacked: Path, package: Path) -> tuple[str, Path, Path]:
    if (unpacked / "WEB-INF/classes").is_dir():
        return "WAR", unpacked / "WEB-INF/classes", unpacked / "WEB-INF/lib"
    if (unpacked / "BOOT-INF/classes").is_dir():
        return "SPRING_BOOT_JAR", unpacked / "BOOT-INF/classes", unpacked / "BOOT-INF/lib"
    if package.suffix.lower() == ".jar":
        return "JAR", unpacked, unpacked / "lib"
    raise MigrationError(
        "UNSUPPORTED_PACKAGE_LAYOUT",
        "Only WAR, Spring Boot JAR, or a regular JAR with class files can be automatically rebuilt",
    )


def class_prefix(layout: str) -> Path:
    if layout == "WAR":
        return Path("WEB-INF/classes")
    if layout == "SPRING_BOOT_JAR":
        return Path("BOOT-INF/classes")
    return Path("")


def prepare_overlay(
    changes: list[dict[str, str]],
    patch_root: Path,
    compiled_dir: Path,
    overlay: Path,
    layout: str,
) -> list[str]:
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.mkdir(parents=True)
    prefix = class_prefix(layout)
    updated: list[str] = []
    for class_file in compiled_dir.rglob("*.class") if compiled_dir.exists() else []:
        rel = class_file.relative_to(compiled_dir)
        target = overlay / prefix / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(class_file, target)
        updated.append((prefix / rel).as_posix())
    for change in changes:
        path = change["path"]
        if change["status"] == "D":
            raise MigrationError("UNSUPPORTED_PATCH_DELETE", f"Deletion is not supported: {path}")
        if path.startswith("src/main/resources/"):
            rel = Path(path).relative_to("src/main/resources")
            source = patch_root / path
            target = overlay / prefix / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            updated.append((prefix / rel).as_posix())
        elif path.startswith("src/main/java/"):
            continue
        elif path in {"mapping.json", "compile-fixes.json"}:
            continue
        else:
            raise MigrationError("UNSUPPORTED_PATCH_PATH", f"Patch changed an unsupported path: {path}")
    return sorted(set(updated))

def update_archive(package: Path, output: Path, overlay: Path, jdk_home: str | None, log_dir: Path) -> None:
    shutil.copy2(package, output)
    if not any(overlay.rglob("*")):
        return
    jar = java_tool(jdk_home, "jar")
    run([jar, "--update", "--file", str(output), "-C", str(overlay), "."], log_dir / "jar-update.log")
    run([jar, "--list", "--file", str(output)], log_dir / "jar-list.log")



def prepare_nested_overlay(
    changes: list[dict[str, str]],
    patch_root: Path,
    module_id: str,
    compiled_dir: Path,
    overlay: Path,
) -> list[str]:
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.mkdir(parents=True, exist_ok=True)
    module_prefix = f"nested/{module_id}/"
    java_prefix = module_prefix + "src/main/java/"
    resources_prefix = module_prefix + "src/main/resources/"
    updated: list[str] = []
    if compiled_dir.exists():
        for class_file in compiled_dir.rglob("*.class"):
            rel = class_file.relative_to(compiled_dir)
            target = overlay / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(class_file, target)
            updated.append(rel.as_posix())
    for change in changes:
        path = change["path"]
        if not path.startswith(module_prefix):
            continue
        if change["status"] == "D":
            raise MigrationError("UNSUPPORTED_PATCH_DELETE", f"Deletion is not supported: {path}")
        if path.startswith(resources_prefix):
            rel = Path(path[len(resources_prefix):])
            source = patch_root / path
            target = overlay / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            updated.append(rel.as_posix())
        elif path.startswith(java_prefix):
            continue
        else:
            raise MigrationError("UNSUPPORTED_PATCH_PATH", f"Patch changed an unsupported nested path: {path}")
    return sorted(set(updated))
