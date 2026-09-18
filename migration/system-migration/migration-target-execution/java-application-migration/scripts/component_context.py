#!/usr/bin/env python3
"""Resolve Java application component context and execution state."""
from __future__ import annotations

import os
import re
import stat
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
TARGET_SCRIPTS_DIR = SCRIPT_DIR.parents[1] / "scripts"
if str(TARGET_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(TARGET_SCRIPTS_DIR))

from migration_plan import (
    application_sql_enabled,
    load_json as load_plan_json,
    migration_work_dir,
    require_valid_migration_plan,
)

from migration_common import MigrationError, load_json, write_json


def _safe_child(root: Path, name: str, error_code: str, *, create: bool = False) -> Path:
    root = root.resolve()
    path = (root / name).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"{error_code}: {name}") from exc
    if path == root:
        raise ValueError(f"{error_code}: {name}")
    if create:
        path.mkdir(parents=True, exist_ok=True)
    return path


def application_work_dir(plan: dict[str, Any], application_id: str, *, create: bool = False) -> Path:
    root = (migration_work_dir(plan, create=create) / "applications").resolve()
    if create:
        root.mkdir(parents=True, exist_ok=True)
    return _safe_child(root, application_id, "INVALID_APPLICATION_ID", create=create)


def package_work_dir(plan: dict[str, Any], application_id: str, package_id: str, *, create: bool = False) -> Path:
    root = (application_work_dir(plan, application_id, create=create) / "packages").resolve()
    if create:
        root.mkdir(parents=True, exist_ok=True)
    path = _safe_child(root, package_id, "INVALID_APPLICATION_PACKAGE_ID", create=create)
    if create:
        tmp_dir = path / "tmp"
        maven_repo = path / "cache" / "maven" / "repository"
        gradle_home = path / "cache" / "gradle"
        for directory in (tmp_dir, maven_repo, gradle_home):
            directory.mkdir(parents=True, exist_ok=True)
        os.environ.update({
            "TMPDIR": str(tmp_dir), "TMP": str(tmp_dir), "TEMP": str(tmp_dir),
            "GRADLE_USER_HOME": str(gradle_home),
        })
        java_tmp = f"-Djava.io.tmpdir={tmp_dir}"
        os.environ["JAVA_TOOL_OPTIONS"] = _append_opt(os.environ.get("JAVA_TOOL_OPTIONS", ""), java_tmp)
        maven_repo_opt = f"-Dmaven.repo.local={maven_repo}"
        opts = _append_opt(os.environ.get("MAVEN_OPTS", ""), maven_repo_opt)
        os.environ["MAVEN_OPTS"] = _append_opt(opts, java_tmp)
    return path


def _append_opt(current: str, value: str) -> str:
    current = current.strip()
    return current if value in current else (current + " " + value).strip()


def _existing_file(value: Any, base: Path | None = None) -> Path | None:
    if not value:
        return None
    path = Path(str(value)).expanduser()
    if not path.is_absolute() and base is not None:
        path = base / path
    try:
        path = path.resolve()
    except OSError:
        return None
    return path if path.is_file() and os.access(path, os.R_OK) else None


def _safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    lower = archive.name.lower()
    if lower.endswith((".zip", ".jar", ".war")):
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                mode = (info.external_attr >> 16) & 0o170000
                if stat.S_ISLNK(mode):
                    raise ValueError(f"Unsafe archive symlink: {info.filename}")
                target = (destination / info.filename).resolve()
                if root not in target.parents and target != root:
                    raise ValueError(f"Unsafe archive member: {info.filename}")
            zf.extractall(destination)
        return
    if lower.endswith((".tar.gz", ".tgz", ".tar", ".tar.bz2", ".tar.xz")):
        with tarfile.open(archive, "r:*") as tf:
            for member in tf.getmembers():
                target = (destination / member.name).resolve()
                if root not in target.parents and target != root:
                    raise ValueError(f"Unsafe archive member: {member.name}")
                if member.issym() or member.islnk() or member.isdev():
                    raise ValueError(f"Unsafe archive link/device: {member.name}")
            try:
                tf.extractall(destination, filter="data")
            except TypeError:
                tf.extractall(destination)
        return
    raise ValueError(f"Unsupported collection archive: {archive}")


def _collection_roots(plan: dict[str, Any], plan_dir: Path, app_root: Path) -> list[Path]:
    roots = [plan_dir]
    source = plan.get("source_environment") or {}
    collection = _existing_file(source.get("collection_package"), plan_dir)
    collection_root: Path | None = None
    if collection:
        collection_root = app_root / "collection"
        marker = collection_root / ".source"
        signature = f"{collection.resolve()}|{collection.stat().st_size}|{collection.stat().st_mtime_ns}"
        if not marker.is_file() or marker.read_text(encoding="utf-8", errors="ignore") != signature:
            if collection_root.exists():
                import shutil
                shutil.rmtree(collection_root)
            _safe_extract(collection, collection_root)
            marker.write_text(signature, encoding="utf-8")
        roots.append(collection_root)
    details_value = source.get("details_archive")
    if details_value:
        details = None
        for base in [collection_root, plan_dir]:
            if base:
                details = _existing_file(details_value, base)
                if details:
                    break
        if details:
            details_root = app_root / "details"
            marker = details_root / ".source"
            signature = f"{details.resolve()}|{details.stat().st_size}|{details.stat().st_mtime_ns}"
            if not marker.is_file() or marker.read_text(encoding="utf-8", errors="ignore") != signature:
                if details_root.exists():
                    import shutil
                    shutil.rmtree(details_root)
                _safe_extract(details, details_root)
                marker.write_text(signature, encoding="utf-8")
            roots.append(details_root)
    return roots


def _supported_package(path: Path) -> Path:
    if path.suffix.lower() not in {".jar", ".war"}:
        raise ValueError(f"UNSUPPORTED_PACKAGE_TYPE: only JAR/WAR are supported: {path.name}")
    return path


def _locate_package(meta: dict[str, Any], plan: dict[str, Any], plan_dir: Path, app_root: Path) -> Path:
    value = str(meta.get("local_path") or "").strip()
    direct = _existing_file(value, plan_dir)
    if direct:
        return _supported_package(direct)
    if not value:
        raise FileNotFoundError("INPUT_INCOMPLETE: application package local_path is empty")
    for root in _collection_roots(plan, plan_dir, app_root):
        for candidate in (value, value[len("details/"):] if value.startswith("details/") else ""):
            found = _existing_file(candidate, root) if candidate else None
            if found:
                return _supported_package(found)
    raise FileNotFoundError(f"INPUT_INCOMPLETE: application package not found: {value}")


def _tool_under(root: Path, relative: str, *, executable: bool = False) -> Path:
    ref = root / relative
    try:
        resolved = ref.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"INPUT_INCOMPLETE: required migration tool is missing: {ref}") from exc
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"INPUT_INCOMPLETE: migration tool resolves outside tools: {resolved}") from exc
    if not resolved.is_file() or not os.access(resolved, os.X_OK if executable else os.R_OK):
        raise ValueError(f"INPUT_INCOMPLETE: migration tool is not ready: {ref}")
    return ref


def _selected_route(value: Any) -> tuple[str, str]:
    text = str(value or "").strip()
    for sep in ("→", "->", "=>"):
        if sep in text:
            left, right = text.split(sep, 1)
            clean = lambda v: re.sub(r"\s+(?:v?\d)[0-9A-Za-z._+\-]*.*$", "", v.strip(), flags=re.I).strip() or v.strip()
            source, target = clean(left), clean(right)
            if source and target:
                return source, target
    raise ValueError("INPUT_INCOMPLETE: selected_route must contain source and target database")


def binary_execution_context(plan_path: Path, application_id: str, package_id: str) -> dict[str, Any]:
    plan = load_plan_json(plan_path)
    require_valid_migration_plan(plan, phase="execution", plan_path=plan_path, check_files=False)
    apps = [x for x in (plan.get("route") or {}).get("application") or [] if isinstance(x, dict)]
    app = next((x for x in apps if str(x.get("id")) == application_id), None)
    if app is None:
        raise ValueError(f"APPLICATION_NOT_FOUND: {application_id}")
    packages = [x for x in app.get("packages") or [] if isinstance(x, dict)]
    package = next((x for x in packages if str(x.get("id")) == package_id), None)
    if package is None:
        raise ValueError(f"APPLICATION_PACKAGE_NOT_FOUND: {package_id}")

    app_root = application_work_dir(plan, application_id, create=True)
    work_dir = package_work_dir(plan, application_id, package_id, create=True)
    input_package = _locate_package(package, plan, plan_path.parent, app_root)
    tools_root = (migration_work_dir(plan) / "tools").resolve()
    devkit = _tool_under(tools_root, "bin/ai-migration", executable=True)
    jdk = (tools_root / "runtime/jdk").resolve()
    for name in ("java", "javac", "jar"):
        _tool_under(tools_root, f"runtime/jdk/bin/{name}", executable=True)

    sql_enabled = application_sql_enabled(app)
    sql: dict[str, Any] = {"enabled": sql_enabled, "mode": "AGENT_SKILL" if sql_enabled else "DISABLED"}
    tools: dict[str, Any] = {"devkit_command": str(devkit)}

    vineflower_jar = tools_root / "lib" / "vineflower-1.12.jar"
    vineflower_java = tools_root / "bin" / "vineflower-java"
    java_fallback = jdk / "bin" / "java"
    if vineflower_jar.is_file():
        tools["vineflower_jar"] = str(vineflower_jar)
    if vineflower_java.is_file():
        tools["vineflower_java"] = str(vineflower_java)
    elif java_fallback.is_file():
        tools["vineflower_java"] = str(java_fallback)
    if sql_enabled:
        selected = app.get("application_sql_migration") or {}
        source_db, target_db = _selected_route(selected.get("selected_route"))
        sql.update({
            "selected_route": selected.get("selected_route"),
            "source_db": source_db,
            "target_db": target_db,
            "work_dir": str((work_dir / "sql-migration").resolve()),
        })

    return {
        "application_id": application_id,
        "package_id": package_id,
        "work_dir": str(work_dir),
        "input_package": str(input_package),
        "target_environment": dict(plan.get("target_environment") or {}),
        "migration_jdk_home": str(jdk),
        "tools": tools,
        "application": {
            "product": app.get("product"),
            "version": app.get("version"),
            "install_location": app.get("install_location"),
        },
        "devkit": {"required": True, "fail_on_findings": True},
        "sql_migration": sql,
    }



# Component execution state helpers
def base_result(input_data: dict[str, Any], package: Path | None = None) -> dict[str, Any]:
    return {
        "application_id": input_data.get("application_id"),
        "package_id": input_data.get("package_id"),
        "status": "IN_PROGRESS",
        "stage": "INIT",
        "reason_code": "",
        "input_package": str(package) if package else str(input_data.get("input_package") or ""),
        "devkit": {},
        "archive_mutations": [],
        "sql_patch": "",
        "changed_files": [],
        "compiled_java_files": [],
        "compile_fixes": [],
        "updated_entries": [],
        "nested_modules": [],
        "nested_classification_summary": {},
        "output_package": "",
        "artifact_change_report": {},
        "verification": {},
        "migration_completion": {
            "static_migration": {"status": "IN_PROGRESS"},
            "target_environment_verification": {"status": "NOT_VERIFIED"},
        },
        "workflow": {
            "current_stage": "INIT",
            "last_completed_stage": "",
            "next_stage": "prepare",
            "waiting_for": "",
            "resume": {},
        },
    }


def env_paths(
    plan_path: Path, application_id: str, package_id: str
) -> tuple[dict[str, Any], Path, Path, dict[str, Any]]:
    input_data = binary_execution_context(plan_path, application_id, package_id)
    work_dir = Path(str(input_data["work_dir"])).expanduser().resolve()
    result_path = work_dir / "migration-result.json"
    result = load_json(result_path) if result_path.is_file() else base_result(input_data)
    return input_data, work_dir, result_path, result


def save(path: Path, result: dict[str, Any]) -> None:
    write_json(path, result)


def require_context(result: dict[str, Any]) -> dict[str, Any]:
    context = result.get("work_state")
    if not isinstance(context, dict) or not context.get("working_package"):
        raise MigrationError("PREPARE_STAGE_REQUIRED", "Run --stage prepare first")
    return context


def sql_adaptation_enabled(input_data: dict[str, Any]) -> bool:
    sql_cfg = input_data.get("sql_migration") or {}
    return bool(sql_cfg.get("enabled", True)) and str(sql_cfg.get("mode", "AGENT_SKILL")).upper() != "DISABLED"


def sql_stage_ready(input_data: dict[str, Any], result: dict[str, Any]) -> bool:
    if not sql_adaptation_enabled(input_data):
        return True
    sql_state = result.get("sql_migration") or {}
    source_status = str(sql_state.get("source_status") or "").upper()
    decision = str(sql_state.get("decision") or "").upper()
    if source_status == "SUCCESS" and decision == "AUTO":
        return True
    if source_status == "COMPLETED_WITH_ACTIONS" and decision == "CONTINUE_WITH_PENDING":
        return True
    return False


def require_sql_stage_ready(input_data: dict[str, Any], result: dict[str, Any]) -> None:
    if not sql_stage_ready(input_data, result):
        raise MigrationError(
            "SQL_STAGE_REQUIRED",
            "SQL stage has not completed or pending SQL actions have not been explicitly approved",
            status="BLOCKED",
        )
