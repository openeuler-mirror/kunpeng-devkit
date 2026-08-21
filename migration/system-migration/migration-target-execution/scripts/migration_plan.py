#!/usr/bin/env python3
"""Target-execution migration-plan.json helper.

Owned by migration-target-execution. It validates the handoff for target use,
merges target facts/package readiness, reports execution issues, and provides
plan helpers used by Java migration. It has no runtime dependency on the source
collector implementation.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Iterable

ROOT_KEYS = {"source_environment", "target_environment", "route"}
ROUTE_KEYS = ("middleware", "database", "application")
CLASSIFICATIONS = {"primary", "likely", "candidate", "manual"}
COMPONENT_PACKAGE_TYPES = {"TARGET_COMPONENT"}
SOURCE_TYPES = {"SYSTEM_REPOSITORY", "OFFICIAL", "MANUAL"}
APPLICATION_PACKAGE_TYPES = {"SOURCE_COMPONENT"}
MIGRATION_TOOL_PACKAGE_TYPES = {"ARCHIVE", "FILE"}
PACKAGE_STATUSES = {
    "PENDING_DOWNLOAD", "PENDING_UPLOAD", "URL_REQUIRED", "READY", "NOT_REQUIRED", "MISSING"
}
MIGRATION_TOOL_STATUSES = {"PENDING_DOWNLOAD", "PENDING_UPLOAD", "URL_REQUIRED", "READY"}
NETWORK_STATUSES = {"ONLINE", "OFFLINE", "UNKNOWN"}
LEGACY_ROOT_FIELDS = {
    "schema_version", "skill_version", "plan_id", "status", "source", "application_migration",
    "licenses", "environment_gaps", "action_required", "created_at", "updated_at",
}
LEGACY_ROUTE_FIELDS = {"java_runtime", "migration_tools", "confirmed", "confirmed_at", "type"}
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SKILL_ROOT = Path(__file__).resolve().parent.parent
WORK_SUBDIRS = (
    "control", "precheck", "packages", "licenses", "tools", "tools/packages",
    "tools/unpacked", "tools/runtime", "tools/bin", "tools/lib",
    "database", "database/reports", "database/downloads", "database/build", "database/logs",
    "database/backup", "database/dts_work", "database/tmp",
    "middleware", "middleware/reports", "middleware/downloads", "middleware/state", "middleware/tmp",
    "applications", "tmp", "tmp/atomic",
)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"JSON object required: {path}")
    return value


def migration_work_dir(plan: dict[str, Any], *, create: bool = False) -> Path:
    """Resolve <target_environment.migration_work_dir>/<migration_id>."""
    target = plan.get("target_environment") or {}
    configured = str(target.get("migration_work_dir") or "").strip()
    if not configured:
        raise ValueError("target_environment.migration_work_dir is required")
    raw_base = Path(configured).expanduser()
    if not raw_base.is_absolute():
        raise ValueError("target_environment.migration_work_dir must be an absolute path")
    base = raw_base.resolve()
    tmp_root = Path("/tmp").resolve()
    home_root = Path.home().resolve()
    skill_root = SKILL_ROOT.resolve()
    if (
        base == Path("/").resolve()
        or base == tmp_root or tmp_root in base.parents
        or base == home_root or home_root in base.parents
        or base == skill_root or skill_root in base.parents
    ):
        raise ValueError(f"unsafe target_environment.migration_work_dir: {base}")

    migration_id = str(plan.get("migration_id") or "").strip()
    if not migration_id:
        raise ValueError("migration_id is required to determine the migration work directory")
    root = (base / migration_id).resolve()
    try:
        common = os.path.commonpath([str(base), str(root)])
    except ValueError as exc:
        raise ValueError(f"invalid migration work directory: {root}") from exc
    if common != str(base) or root == base:
        raise ValueError(f"migration_id resolves outside target_environment.migration_work_dir: {migration_id}")

    if create:
        for rel in WORK_SUBDIRS:
            (root / rel).mkdir(parents=True, exist_ok=True)
    runtime_tmp = root / "tmp"
    os.environ["MIGRATION_WORK_DIR"] = str(root)
    os.environ["TMPDIR"] = str(runtime_tmp)
    os.environ["TMP"] = str(runtime_tmp)
    os.environ["TEMP"] = str(runtime_tmp)
    return root


def _atomic_temp_dir(path: Path, value: Any) -> Path:
    if not isinstance(value, dict):
        raise ValueError("migration-plan.json object is required for atomic update")
    root = migration_work_dir(value, create=True)
    atomic_dir = root / "tmp" / "atomic"
    atomic_dir.mkdir(parents=True, exist_ok=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.stat(atomic_dir).st_dev != os.stat(path.parent).st_dev:
        raise ValueError("MIGRATION_WORK_DIR and migration-plan.json must be on the same filesystem")
    return atomic_dir


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_dir = _atomic_temp_dir(path, value)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=temp_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _object(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{label} must be an object")
        return {}
    return value


def _array(value: Any, label: str, errors: list[str]) -> list[Any]:
    if not isinstance(value, list):
        errors.append(f"{label} must be an array")
        return []
    return value


def _text(value: Any, label: str, errors: list[str], *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{label} must be a non-empty string" + (" or null" if nullable else ""))
        return None
    return value


def _id(value: Any, label: str, errors: list[str]) -> str:
    text = str(value or "")
    if not ID_RE.fullmatch(text):
        errors.append(f"{label} is invalid: {text!r}")
    return text


def _path(value: Any, base: Path) -> Path | None:
    if not value:
        return None
    path = Path(str(value)).expanduser()
    if not path.is_absolute():
        path = base / path
    try:
        return path.resolve()
    except OSError:
        return None


def component_packages(plan: dict[str, Any]) -> Iterable[tuple[str, str, dict[str, Any], dict[str, Any]]]:
    route = plan.get("route") or {}
    for group in ("middleware", "database"):
        for component in route.get(group) or []:
            if not isinstance(component, dict):
                continue
            for package in component.get("packages") or []:
                if isinstance(package, dict):
                    yield group, str(component.get("id") or ""), component, package


def package_ready(package: dict[str, Any], *, check_files: bool = False, base: Path | None = None) -> bool:
    # Source local_path is immutable plan input. Prepared runtime files are
    # validated from MIGRATION_WORK_DIR by execution_issues().
    return package.get("status") in {"READY", "NOT_REQUIRED"}

def license_upload_dir(plan: dict[str, Any], component_id: str, package_id: str) -> Path:
    """Return the controlled upload directory for one component license."""
    return migration_work_dir(plan) / "licenses" / component_id / package_id


def license_file_ready(package: dict[str, Any], expected_dir: Path, plan_base: Path) -> bool:
    path = _path(package.get("license_path"), plan_base)
    if not path:
        return False
    try:
        if os.path.commonpath([str(expected_dir.resolve()), str(path)]) != str(expected_dir.resolve()):
            return False
        return path.is_file() and os.access(path, os.R_OK) and path.stat().st_size > 0
    except (OSError, ValueError):
        return False


def set_verified_license_path(package: dict[str, Any], path: Path) -> None:
    """Insert license_path immediately after license_required in serialized JSON."""
    updated: dict[str, Any] = {}
    for key, value in package.items():
        if key == "license_path":
            continue
        updated[key] = value
        if key == "license_required":
            updated["license_path"] = str(path)
    package.clear()
    package.update(updated)


def application_sql_enabled(app: dict[str, Any]) -> bool:
    return (app.get("application_sql_migration") or {}).get("requires_sql_adaptation") is True


def application_source_package(app: dict[str, Any], plan_base: Path) -> Path | None:
    for package in app.get("packages") or []:
        if not isinstance(package, dict):
            continue
        path = _path(package.get("local_path"), plan_base)
        if path and path.is_file() and os.access(path, os.R_OK):
            return path
    return None


def validate_migration_plan(
    plan: Any,
    *,
    phase: str = "collector",
    plan_path: Path | None = None,
    check_files: bool = False,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(plan, dict):
        return ["migration-plan.json must contain an object"]
    unknown_legacy = sorted(LEGACY_ROOT_FIELDS.intersection(plan))
    if unknown_legacy:
        errors.append("legacy root fields are not supported: " + ", ".join(unknown_legacy))
    missing = sorted(ROOT_KEYS - set(plan))
    if missing:
        errors.append("missing root fields: " + ", ".join(missing))

    source = _object(plan.get("source_environment"), "source_environment", errors)
    if "collection_package" not in source:
        errors.append("source_environment.collection_package is required")
    if "details_archive" not in source:
        errors.append("source_environment.details_archive is required")
    elif not source.get("details_archive"):
        errors.append("source_environment.details_archive must be recorded")
    if phase in {"collector-final", "target", "execution"} and not source.get("collection_package"):
        errors.append("source_environment.collection_package must be recorded before handoff")
    if phase in {"target", "execution"} and check_files and source.get("collection_package"):
        collection_path = _path(source.get("collection_package"), plan_path.parent if plan_path else Path.cwd())
        if not (collection_path and collection_path.is_file() and os.access(collection_path, os.R_OK)):
            errors.append("source_environment.collection_package must be a readable file")

    target = _object(plan.get("target_environment"), "target_environment", errors)
    target_required = {
        "hostname", "primary_ip", "os", "architecture", "kernel", "glibc", "package_manager",
        "privilege", "java", "network", "migration_work_dir", "free_space_bytes", "migration_tools",
    }
    missing_target = sorted(target_required - set(target))
    if missing_target:
        errors.append("missing target_environment fields: " + ", ".join(missing_target))
    java = _object(target.get("java"), "target_environment.java", errors)
    for field in ("installed", "version", "command"):
        if field not in java:
            errors.append(f"target_environment.java.{field} is required")
    if "installed" in java and not isinstance(java.get("installed"), bool):
        errors.append("target_environment.java.installed must be boolean")
    network = _object(target.get("network"), "target_environment.network", errors)
    for field in ("status", "probe_url"):
        if field not in network:
            errors.append(f"target_environment.network.{field} is required")
    if network.get("status") not in NETWORK_STATUSES:
        errors.append(f"unsupported target_environment.network.status: {network.get('status')!r}")
    migration_tools = _array(target.get("migration_tools"), "target_environment.migration_tools", errors)
    migration_tool_ids: set[str] = set()
    declared_tool_names: set[str] = set()
    tool_package_fields = {
        "id", "package_name", "version", "type", "file_name", "download_url", "local_path", "status", "tools"
    }
    for index, tool in enumerate(migration_tools):
        label = f"target_environment.migration_tools[{index}]"
        tool = _object(tool, label, errors)
        tool_id = _id(tool.get("id"), f"{label}.id", errors)
        if tool_id in migration_tool_ids:
            errors.append(f"duplicate migration tool package id: {tool_id}")
        migration_tool_ids.add(tool_id)
        unsupported = sorted(set(tool) - tool_package_fields)
        if unsupported:
            errors.append(f"{label} contains unsupported fields: {', '.join(unsupported)}")
        for field in ("package_name", "version", "type", "file_name", "download_url", "local_path", "status", "tools"):
            if field not in tool:
                errors.append(f"{label}.{field} is required")
        _text(tool.get("package_name"), f"{label}.package_name", errors)
        _text(tool.get("version"), f"{label}.version", errors)
        if tool.get("type") not in MIGRATION_TOOL_PACKAGE_TYPES:
            errors.append(f"{label}.type must be ARCHIVE or FILE")
        _text(tool.get("file_name"), f"{label}.file_name", errors)
        download_url = tool.get("download_url")
        if download_url not in (None, "") and (
            not isinstance(download_url, str) or not download_url.startswith("https://")
        ):
            errors.append(f"{label}.download_url must be an HTTPS URL or empty")
        if tool.get("local_path") not in (None, "") and not isinstance(tool.get("local_path"), str):
            errors.append(f"{label}.local_path must be a string or empty")
        if tool.get("status") not in MIGRATION_TOOL_STATUSES:
            errors.append(f"{label}.status must be one of PENDING_DOWNLOAD, PENDING_UPLOAD, URL_REQUIRED, READY")
        included_tools = _array(tool.get("tools"), f"{label}.tools", errors)
        if not included_tools:
            errors.append(f"{label}.tools must contain at least one tool")
        for tool_index, included_tool in enumerate(included_tools):
            tool_label = f"{label}.tools[{tool_index}]"
            included_tool = _object(included_tool, tool_label, errors)
            unsupported_tool_fields = sorted(set(included_tool) - {"name"})
            if unsupported_tool_fields:
                errors.append(f"{tool_label} contains unsupported fields: {', '.join(unsupported_tool_fields)}")
            if "name" not in included_tool:
                errors.append(f"{tool_label}.name is required")
            else:
                name = _text(included_tool.get("name"), f"{tool_label}.name", errors)
                if name:
                    declared_tool_names.add(name.strip().lower())

    if phase in {"target", "execution"}:
        for field in ("hostname", "primary_ip", "os", "architecture", "kernel", "glibc", "package_manager", "privilege", "migration_work_dir"):
            _text(target.get(field), f"target_environment.{field}", errors)
        work_base = Path(str(target.get("migration_work_dir") or "")).expanduser()
        if not work_base.is_absolute():
            errors.append("target_environment.migration_work_dir must be an absolute path")
        if str(target.get("architecture") or "").lower() not in {"aarch64", "arm64"}:
            errors.append("target_environment.architecture must be aarch64/arm64")
        if not isinstance(target.get("free_space_bytes"), int) or target.get("free_space_bytes", 0) <= 0:
            errors.append("target_environment.free_space_bytes must be an integer > 0")
        if target.get("privilege") == "unprivileged":
            errors.append("target_environment.privilege must allow migration execution")

    route = _object(plan.get("route"), "route", errors)
    legacy_route = sorted(LEGACY_ROUTE_FIELDS.intersection(route))
    if legacy_route:
        errors.append("legacy route fields are not supported: " + ", ".join(legacy_route))
    for key in ROUTE_KEYS:
        _array(route.get(key), f"route.{key}", errors)

    component_ids: set[str] = set()
    package_ids: set[str] = set()
    for group in ("middleware", "database"):
        for index, component in enumerate(route.get(group) or []):
            label = f"route.{group}[{index}]"
            component = _object(component, label, errors)
            component_id = _id(component.get("id"), f"{label}.id", errors)
            if component_id in component_ids:
                errors.append(f"duplicate component id: {component_id}")
            component_ids.add(component_id)
            if component.get("classification") not in CLASSIFICATIONS:
                errors.append(f"{label}.classification is invalid")
            source_component = _object(component.get("source"), f"{label}.source", errors)
            target_component = _object(component.get("target"), f"{label}.target", errors)
            for field in ("product", "version", "location", "artifact_paths"):
                if field not in source_component:
                    errors.append(f"{label}.source.{field} is required")
            _text(source_component.get("product"), f"{label}.source.product", errors)
            if not isinstance(source_component.get("artifact_paths"), list):
                errors.append(f"{label}.source.artifact_paths must be an array")
            for field in ("product", "version"):
                if field not in target_component:
                    errors.append(f"{label}.target.{field} is required")
            _text(target_component.get("product"), f"{label}.target.product", errors)
            packages = _array(component.get("packages"), f"{label}.packages", errors)
            for p_index, package in enumerate(packages):
                p_label = f"{label}.packages[{p_index}]"
                package = _object(package, p_label, errors)
                package_id = _id(package.get("id"), f"{p_label}.id", errors)
                if package_id in package_ids:
                    errors.append(f"duplicate package id: {package_id}")
                package_ids.add(package_id)
                if package.get("type") not in COMPONENT_PACKAGE_TYPES:
                    errors.append(f"{p_label}.type must be TARGET_COMPONENT")
                for field in ("version", "file_name", "source_type", "download_url", "local_path", "status", "license_required"):
                    if field not in package:
                        errors.append(f"{p_label}.{field} is required")
                _text(package.get("file_name"), f"{p_label}.file_name", errors)
                if package.get("source_type") not in SOURCE_TYPES:
                    errors.append(f"{p_label}.source_type must be one of SYSTEM_REPOSITORY, OFFICIAL, MANUAL")
                if package.get("status") not in PACKAGE_STATUSES:
                    errors.append(f"{p_label}.status is invalid")
                if not isinstance(package.get("license_required"), bool):
                    errors.append(f"{p_label}.license_required must be boolean")
                if "license_path" in package and not isinstance(package.get("license_path"), str):
                    errors.append(f"{p_label}.license_path must be a string")
                if phase in {"target", "execution"} and not package_ready(package, check_files=check_files, base=(plan_path.parent if plan_path else Path.cwd())):
                    errors.append(f"{p_label} is not ready")

    app_ids: set[str] = set()
    for index, app in enumerate(route.get("application") or []):
        label = f"route.application[{index}]"
        app = _object(app, label, errors)
        allowed_app_fields = {
            "id", "classification", "product", "version", "install_location",
            "packages", "application_sql_migration",
        }
        unsupported_app_fields = sorted(set(app) - allowed_app_fields)
        if unsupported_app_fields:
            errors.append(f"{label} contains unsupported fields: {', '.join(unsupported_app_fields)}")
        app_id = _id(app.get("id"), f"{label}.id", errors)
        if app_id in app_ids:
            errors.append(f"duplicate application id: {app_id}")
        app_ids.add(app_id)
        if app.get("classification") not in CLASSIFICATIONS:
            errors.append(f"{label}.classification is invalid")
        for field in ("product", "version", "install_location", "packages", "application_sql_migration"):
            if field not in app:
                errors.append(f"{label}.{field} is required")
        _text(app.get("product"), f"{label}.product", errors)
        packages = _array(app.get("packages"), f"{label}.packages", errors)
        if not packages:
            errors.append(f"{label}.packages must contain at least one JAR or WAR")
        app_package_ids: set[str] = set()
        for p_index, package in enumerate(packages):
            p_label = f"{label}.packages[{p_index}]"
            package = _object(package, p_label, errors)
            package_id = _id(package.get("id"), f"{p_label}.id", errors)
            if package_id in app_package_ids:
                errors.append(f"duplicate application package id in {label}: {package_id}")
            app_package_ids.add(package_id)
            if package.get("type") not in APPLICATION_PACKAGE_TYPES:
                errors.append(f"{p_label}.type must be SOURCE_COMPONENT")
            for field in ("file_name", "local_path", "license_required"):
                if field not in package:
                    errors.append(f"{p_label}.{field} is required")
            file_name = str(package.get("file_name") or "").strip()
            if not file_name:
                errors.append(f"{p_label}.file_name must be a non-empty string")
            elif Path(file_name).suffix.lower() not in {".jar", ".war"}:
                errors.append(f"{p_label}.file_name must be a JAR or WAR")
            _text(package.get("local_path"), f"{p_label}.local_path", errors)
            if not isinstance(package.get("license_required"), bool):
                errors.append(f"{p_label}.license_required must be boolean")
        sql = _object(app.get("application_sql_migration"), f"{label}.application_sql_migration", errors)
        if not isinstance(sql.get("requires_sql_adaptation"), bool):
            errors.append(f"{label}.application_sql_migration.requires_sql_adaptation must be boolean")
        if sql.get("requires_sql_adaptation") is True:
            _text(sql.get("selected_route"), f"{label}.application_sql_migration.selected_route", errors)

        if phase in {"target", "execution"} and check_files:
            if not application_source_package(app, plan_path.parent if plan_path else Path.cwd()):
                # 组件也可能位于源端采集包中；Java 应用上下文负责最终定位。
                if not source.get("collection_package"):
                    errors.append(f"{label} application package is not readable")

    if "ai-migration" not in declared_tool_names:
        errors.append("target_environment.migration_tools must declare tool: ai-migration")
    sql_adaptation_required = any(
        isinstance(app, dict)
        and isinstance(app.get("application_sql_migration"), dict)
        and app["application_sql_migration"].get("requires_sql_adaptation") is True
        for app in (route.get("application") or [])
    )
    if sql_adaptation_required and not any(name.startswith("sql-analysis") for name in declared_tool_names):
        errors.append("SQL adaptation requires migration_tools to declare a tool name starting with: sql-analysis")
    if route.get("application") or []:
        if not any("vineflower" in name for name in declared_tool_names):
            errors.append("Java application migration requires a Vineflower tool entry")
        required_jdk_tools = {"java", "javac", "jar"}
        if not required_jdk_tools.issubset(declared_tool_names):
            missing = ", ".join(sorted(required_jdk_tools - declared_tool_names))
            errors.append(f"Java application migration requires a JDK tool package containing: {missing}")


    return errors


def require_valid_migration_plan(
    plan: Any,
    *,
    phase: str = "collector",
    plan_path: Path | None = None,
    check_files: bool = False,
) -> None:
    errors = validate_migration_plan(plan, phase=phase, plan_path=plan_path, check_files=check_files)
    if errors:
        raise ValueError("invalid migration-plan.json: " + "; ".join(errors))




def require_runtime_path(
    plan: dict[str, Any], path: Path, label: str, *, subtree: str | None = None
) -> Path:
    migration_root = migration_work_dir(plan, create=True)
    expected_root = (migration_root / subtree).resolve() if subtree else migration_root
    resolved = path.expanduser().resolve()
    try:
        common = os.path.commonpath([str(expected_root), str(resolved)])
    except ValueError as exc:
        raise ValueError(f"{label} must be under {expected_root}: {resolved}") from exc
    if common != str(expected_root):
        raise ValueError(f"{label} must be under {expected_root}: {resolved}")
    return resolved

def migration_plan_digest(plan: dict[str, Any]) -> str:
    serialized = json.dumps(plan, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()
def parse_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if not reader.fieldnames:
            raise ValueError(f"TSV header is missing: {path}")
        return list(reader)


def target_fact_map(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        key, sep, value = raw.partition("\t")
        if not sep:
            raise ValueError(f"invalid target fact line: {raw}")
        result[key] = value
    return result


def merge_target_facts(plan: dict[str, Any], facts: dict[str, str]) -> None:
    target = plan.setdefault("target_environment", {})
    target.update({
        "hostname": facts.get("hostname") or None,
        "primary_ip": facts.get("primary_ip") or None,
        "os": facts.get("os") or None,
        "architecture": facts.get("architecture") or None,
        "kernel": facts.get("kernel") or None,
        "glibc": facts.get("glibc") or None,
        "package_manager": facts.get("package_manager") or None,
        "privilege": facts.get("privilege") or None,
        "free_space_bytes": int(facts.get("free_space_bytes") or 0),
        "java": {
            "installed": str(facts.get("java_installed") or "false").lower() == "true",
            "version": facts.get("java_version") or None,
            "command": facts.get("java_command") or None,
        },
        "network": {
            "status": facts.get("network_status") or "UNKNOWN",
            "probe_url": facts.get("network_probe_url") or None,
        },
    })


def migration_tool_names(package: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for item in package.get("tools") or []:
        if isinstance(item, dict):
            name = str(item.get("name") or "").strip().lower()
            if name:
                names.add(name)
    return names


def migration_tool_packages(plan: dict[str, Any]) -> list[dict[str, Any]]:
    """Return every migration tool package declared in the plan.

    Declared tools are execution requirements. Route contents do not make a
    declared tool optional.
    """
    return [
        item for item in (plan.get("target_environment") or {}).get("migration_tools") or []
        if isinstance(item, dict)
    ]


def prepared_tool_package_path(plan: dict[str, Any], package: dict[str, Any]) -> Path:
    package_id = str(package.get("id") or "").strip()
    file_name = str(package.get("file_name") or "").strip()
    if not ID_RE.fullmatch(package_id) or not file_name:
        raise ValueError(f"invalid migration tool package identity: {package_id!r}/{file_name!r}")
    return migration_work_dir(plan) / "tools" / "packages" / package_id / file_name


def prepared_component_package_path(plan: dict[str, Any], component_id: str, package: dict[str, Any]) -> Path:
    file_name = str(package.get("file_name") or "").strip()
    if not ID_RE.fullmatch(component_id) or not file_name:
        raise ValueError(f"invalid component package identity: {component_id!r}/{file_name!r}")
    return migration_work_dir(plan) / "packages" / component_id / file_name

def package_manifest_rows(plan: dict[str, Any]) -> Iterable[list[str]]:
    for group, component_id, component, package in component_packages(plan):
        target = component.get("target") or {}
        source_type = str(package.get("source_type") or "OFFICIAL").upper()
        yield [
            str(package.get("id") or "-"), component_id or "-", "TARGET_PACKAGE",
            str(target.get("product") or "-"), str(target.get("version") or "-"),
            str(package.get("version") or "-"), str(package.get("file_name") or "-"),
            str(package.get("download_url") or "-"), source_type,
            str(package.get("local_path") or "-"),
            "true" if package.get("license_required") else "false",
        ]
    for index, tool in enumerate(migration_tool_packages(plan)):
        tool_id = str(tool.get("id") or f"tool-package-{index+1}")
        package_id = f"migration-tool-package-{tool_id}"
        file_name = str(tool.get("file_name") or package_id)
        yield [
            package_id, tool_id, "MIGRATION_TOOL",
            str(tool.get("package_name") or tool_id), str(tool.get("version") or "-"),
            str(tool.get("version") or "-"), file_name or package_id,
            str(tool.get("download_url") or "-"),
            "OFFICIAL" if tool.get("download_url") else "MANUAL",
            str(tool.get("local_path") or "-"), "false",
        ]


def _normalized_prepared_status(raw_status: str, *, migration_tool: bool) -> str:
    if raw_status in {"DOWNLOADED", "PRESENT"}:
        return "READY"
    if raw_status == "URL_REQUIRED":
        return "URL_REQUIRED"
    if not migration_tool and raw_status == "NOT_REQUIRED":
        return "NOT_REQUIRED"
    if migration_tool and raw_status in {"NOT_REQUIRED", "MISSING"}:
        raise ValueError(f"migration tool package status is not allowed: {raw_status}")
    return "PENDING_UPLOAD"


def _same_optional_text(left: Any, right: Any) -> bool:
    return (str(left).strip() if left not in (None, "") else "") == (str(right).strip() if right not in (None, "") else "")


def merge_package_status(plan: dict[str, Any], rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    """Merge preparation state without mutating collector-confirmed package sources.

    Execution may update only ``status``. ``source_type``, ``download_url`` and
    ``local_path`` remain the collector/user supplied source description.
    """
    index: dict[str, dict[str, Any]] = {}
    for _, _, _, package in component_packages(plan):
        package_id = str(package.get("id") or "")
        if package_id:
            index[package_id] = package
    tool_packages = {
        f"migration-tool-package-{str(tool.get('id') or '')}": tool
        for tool in migration_tool_packages(plan)
        if str(tool.get("id") or "")
    }
    actions: list[dict[str, Any]] = []
    for row in rows:
        package_id = str(row.get("package_id") or "")
        raw_status = str(row.get("status") or "")
        prepared_path = str(row.get("prepared_path") or row.get("local_path") or "") or None
        if package_id.startswith("migration-tool-package-"):
            tool = tool_packages.get(package_id)
            if tool is None:
                raise ValueError(f"unknown migration tool package id: {package_id}")
            if not _same_optional_text(row.get("download_url"), tool.get("download_url")):
                raise ValueError(f"execution must not modify migration_tools download_url: {package_id}")
            normalized = _normalized_prepared_status(raw_status, migration_tool=True)
            tool["status"] = normalized
            if normalized != "READY":
                actions.append({
                    "type": "MIGRATION_TOOL_PACKAGE_REQUIRED",
                    "package_id": package_id,
                    "expected_path": prepared_path,
                    "status": normalized,
                })
            continue

        package = index.get(package_id)
        if package is None:
            raise ValueError(f"package status refers to unknown package id: {package_id}")
        planned_source_type = str(package.get("source_type") or "").upper()
        row_source_type = str(row.get("source_type") or "").upper()
        if row_source_type != planned_source_type:
            raise ValueError(f"execution must not modify packages[].source_type: {package_id}")
        if not _same_optional_text(row.get("download_url"), package.get("download_url")):
            raise ValueError(f"execution must not modify packages[].download_url: {package_id}")
        normalized = _normalized_prepared_status(raw_status, migration_tool=False)
        package["status"] = normalized
        if normalized not in {"READY", "NOT_REQUIRED"}:
            actions.append({
                "type": "PACKAGE_URL_REQUIRED" if normalized == "URL_REQUIRED" else "PACKAGE_UPLOAD_REQUIRED",
                "package_id": package_id,
                "expected_path": prepared_path,
                "status": normalized,
            })
    return actions

def reconcile_licenses(plan: dict[str, Any], plan_path: Path) -> tuple[list[dict[str, Any]], bool]:
    """Detect uploaded licenses and record only verified file paths."""
    results: list[dict[str, Any]] = []
    changed = False
    for group, component_id, _, package in component_packages(plan):
        if package.get("license_required") is not True:
            continue
        package_id = str(package.get("id") or "")
        if not ID_RE.fullmatch(component_id) or not ID_RE.fullmatch(package_id):
            raise ValueError(f"invalid component/package id for license upload: {component_id}/{package_id}")
        expected_dir = license_upload_dir(plan, component_id, package_id)
        expected_dir.mkdir(parents=True, exist_ok=True)

        if license_file_ready(package, expected_dir, plan_path.parent):
            results.append({
                "group": group, "component_id": component_id, "package_id": package_id,
                "status": "UPLOADED", "blocking": False,
                "license_path": str(_path(package.get("license_path"), plan_path.parent)),
            })
            continue

        candidates: list[Path] = []
        for candidate in sorted(expected_dir.iterdir()):
            try:
                resolved = candidate.resolve()
                if (
                    os.path.commonpath([str(expected_dir.resolve()), str(resolved)]) == str(expected_dir.resolve())
                    and resolved.is_file() and os.access(resolved, os.R_OK) and resolved.stat().st_size > 0
                ):
                    candidates.append(resolved)
            except (OSError, ValueError):
                continue

        if len(candidates) == 1:
            set_verified_license_path(package, candidates[0])
            changed = True
            results.append({
                "group": group, "component_id": component_id, "package_id": package_id,
                "status": "UPLOADED", "blocking": False, "license_path": str(candidates[0]),
            })
        else:
            if "license_path" in package:
                package.pop("license_path")
                changed = True
            results.append({
                "group": group, "component_id": component_id, "package_id": package_id,
                "status": "PENDING_UPLOAD", "blocking": False,
                "expected_path": str(expected_dir),
                "description": (
                    "未检测到非空且可读的 License 文件，请上传后重新校验。"
                    if not candidates else "检测到多个 License 文件，请仅保留本组件要使用的一个文件后重新校验。"
                ),
            })
    return results, changed


def _tool_reference_ready(plan: dict[str, Any], relative: str, *, executable: bool = False) -> bool:
    try:
        tools_root = (migration_work_dir(plan) / "tools").resolve()
        path = (tools_root / relative).resolve()
    except ValueError:
        return False
    try:
        if os.path.commonpath([str(tools_root), str(path)]) != str(tools_root):
            return False
    except ValueError:
        return False
    return path.is_file() and os.access(path, os.X_OK if executable else os.R_OK)


def execution_issues(plan: dict[str, Any], plan_path: Path, *, check_files: bool = True) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    target = plan.get("target_environment") or {}
    if str(target.get("architecture") or "").lower() not in {"aarch64", "arm64"}:
        issues.append({"code": "INCOMPATIBLE_TARGET", "blocking": True, "description": "目标环境必须为 Linux aarch64/arm64。"})
    if target.get("privilege") == "unprivileged":
        issues.append({"code": "TARGET_PRIVILEGE_REQUIRED", "blocking": True, "description": "目标环境缺少 root 或免密 sudo 权限。"})

    for group, component_id, _, package in component_packages(plan):
        status = str(package.get("status") or "")
        source_type = str(package.get("source_type") or "").upper()
        prepared_path = prepared_component_package_path(plan, component_id, package)
        ready = status == "NOT_REQUIRED" if source_type == "SYSTEM_REPOSITORY" else status == "READY"
        if ready and check_files and source_type != "SYSTEM_REPOSITORY":
            ready = prepared_path.is_file() and os.access(prepared_path, os.R_OK) and prepared_path.stat().st_size > 0
        if not ready:
            issues.append({
                "code": "TARGET_PACKAGE_NOT_READY", "blocking": True, "component_id": component_id,
                "package_id": package.get("id"), "expected_path": str(prepared_path),
                "description": f"{group} 目标包尚未就绪：{package.get('file_name') or package.get('id')}。",
            })
        if package.get("license_required") is True:
            package_id = str(package.get("id") or "")
            expected_dir = license_upload_dir(plan, component_id, package_id)
            if not license_file_ready(package, expected_dir, plan_path.parent):
                issues.append({
                    "code": "LICENSE_UPLOAD_REQUIRED", "blocking": False, "component_id": component_id,
                    "package_id": package_id, "expected_path": str(expected_dir),
                    "description": f"目标组件需要 License，请上传一个文件到 {expected_dir} 后重新校验。",
                })

    declared_names: set[str] = set()
    for index, package in enumerate(migration_tool_packages(plan)):
        declared_names.update(migration_tool_names(package))
        prepared_path = prepared_tool_package_path(plan, package)
        ready = package.get("status") == "READY"
        if ready and check_files:
            ready = prepared_path.is_file() and os.access(prepared_path, os.R_OK) and prepared_path.stat().st_size > 0
        if not ready:
            issues.append({
                "code": "MIGRATION_TOOL_PACKAGE_NOT_READY", "blocking": True,
                "package_id": package.get("id"), "expected_path": str(prepared_path),
                "status": package.get("status"),
                "description": f"迁移工具包尚未就绪：{package.get('package_name') or index + 1}。",
            })

    if "ai-migration" in declared_names and not _tool_reference_ready(plan, "bin/ai-migration", executable=True):
        issues.append({
            "code": "DEVKIT_NOT_READY_UNDER_TOOLS", "blocking": True,
            "description": "migration_tools声明的DevKit尚未在tools目录解析完成。",
        })
    if any("vineflower" in name for name in declared_names):
        if not _tool_reference_ready(plan, "lib/vineflower-1.12.jar"):
            issues.append({
                "code": "VINEFLOWER_NOT_READY_UNDER_TOOLS", "blocking": True,
                "description": "migration_tools声明的Vineflower 1.12尚未在tools目录解析完成。",
            })
        if not _tool_reference_ready(plan, "bin/vineflower-java", executable=True):
            issues.append({
                "code": "VINEFLOWER_JAVA_NOT_READY_UNDER_TOOLS", "blocking": True,
                "description": "Vineflower运行Java尚未从migration_tools工具JDK解析完成。",
            })
    if {"java", "javac", "jar"}.issubset(declared_names):
        for tool_name in ("java", "javac", "jar"):
            if not _tool_reference_ready(plan, f"runtime/jdk/bin/{tool_name}", executable=True):
                issues.append({
                    "code": "MIGRATION_JDK_NOT_READY_UNDER_TOOLS", "blocking": True,
                    "tool": tool_name,
                    "description": f"迁移工具JDK缺少{tool_name}：tools/runtime/jdk/bin/{tool_name}。",
                })
    if any(name.startswith("sql-analysis") for name in declared_names) and not _tool_reference_ready(plan, "lib/sql-analysis.jar"):
        issues.append({
            "code": "SQL_ANALYSIS_NOT_READY_UNDER_TOOLS", "blocking": True,
            "description": "migration_tools声明的SQL Analysis尚未解析到tools/lib/sql-analysis.jar。",
        })

    apps = (plan.get("route") or {}).get("application") or []
    collection_package = (plan.get("source_environment") or {}).get("collection_package")
    if check_files and not collection_package:
        for app in apps:
            for package in app.get("packages") or []:
                if not isinstance(package, dict):
                    continue
                path = _path(package.get("local_path"), plan_path.parent)
                if not (path and path.is_file() and os.access(path, os.R_OK)):
                    issues.append({
                        "code": "APPLICATION_PACKAGE_REQUIRED",
                        "blocking": True,
                        "application_id": app.get("id"),
                        "package_id": package.get("id"),
                        "expected_path": package.get("local_path"),
                    })
    return issues

def report_text(plan: dict[str, Any], issues: list[dict[str, Any]]) -> str:
    target = plan.get("target_environment") or {}
    route = plan.get("route") or {}
    lines = [
        "# 鲲鹏目标环境预检报告", "",
        "## 1. 目标环境", "",
        f"- 主机：{target.get('hostname')}",
        f"- IP：{target.get('primary_ip')}",
        f"- 操作系统：{target.get('os')}",
        f"- 架构：{target.get('architecture')}",
        f"- 包管理器：{target.get('package_manager')}",
        f"- Java：{(target.get('java') or {}).get('version')}", "",
        "## 2. 迁移范围", "",
        f"- 数据库：{len(route.get('database') or [])}",
        f"- 中间件：{len(route.get('middleware') or [])}",
        f"- Java应用：{len(route.get('application') or [])}", "",
        "## 3. 待处理事项", "",
    ]
    if not issues:
        lines.append("无阻塞事项，迁移计划可进入目标变更确认。")
    else:
        for issue in issues:
            marker = "阻塞" if issue.get("blocking") else "提示"
            lines.append(f"- [{marker}] {issue.get('code')}：{issue.get('description') or issue.get('expected_path') or ''}")
    lines.append("")
    return "\n".join(lines)
def command_merge_target(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    facts_path = require_runtime_path(plan, Path(args.facts), "target facts", subtree="precheck")
    merge_target_facts(plan, target_fact_map(facts_path))
    write_json_atomic(path, plan)
    print(path)
    return 0


def command_manifest(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    output = require_runtime_path(plan, Path(args.output), "package manifest", subtree="precheck")
    output.parent.mkdir(parents=True, exist_ok=True)
    header = ["package_id", "component_id", "kind", "product", "target_version", "package_version", "file_name", "download_url", "source_type", "local_path", "license_required"]
    with output.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(header)
        writer.writerows(package_manifest_rows(plan))
    print(output)
    return 0


def command_merge_packages(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    status_path = require_runtime_path(plan, Path(args.status), "package status", subtree="precheck")
    actions = merge_package_status(plan, parse_tsv(status_path))
    write_json_atomic(path, plan)
    print(json.dumps({"plan": str(path), "action_required": actions}, ensure_ascii=False, indent=2))
    return 0


def command_check_licenses(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    results, changed = reconcile_licenses(plan, path)
    if changed:
        write_json_atomic(path, plan)
    pending = [item for item in results if item.get("status") != "UPLOADED"]
    print(json.dumps({
        "status": "READY" if not pending else "READY_WITH_ACTIONS",
        "blocking": False,
        "licenses": results,
    }, ensure_ascii=False, indent=2))
    return 0


def command_finalize(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    issues = execution_issues(plan, path, check_files=not args.no_file_check)
    blocking = [item for item in issues if item.get("blocking") is True]
    if args.report:
        report = require_runtime_path(plan, Path(args.report), "migration report", subtree="precheck")
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(report_text(plan, issues), encoding="utf-8")
    print(json.dumps({"status": "READY" if not blocking else "READY_WITH_ACTIONS", "issues": issues}, ensure_ascii=False, indent=2))
    return 0 if not blocking else 20


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="target execution migration-plan.json helper")
    commands = root.add_subparsers(dest="command", required=True)

    target = commands.add_parser("merge-target")
    target.add_argument("--plan", required=True)
    target.add_argument("--facts", required=True)
    target.set_defaults(handler=command_merge_target)

    manifest = commands.add_parser("manifest")
    manifest.add_argument("--plan", required=True)
    manifest.add_argument("--output", required=True)
    manifest.set_defaults(handler=command_manifest)

    packages = commands.add_parser("merge-packages")
    packages.add_argument("--plan", required=True)
    packages.add_argument("--status", required=True)
    packages.set_defaults(handler=command_merge_packages)

    licenses = commands.add_parser("check-licenses")
    licenses.add_argument("--plan", required=True)
    licenses.set_defaults(handler=command_check_licenses)

    finalize = commands.add_parser("finalize")
    finalize.add_argument("--plan", required=True)
    finalize.add_argument("--report")
    finalize.add_argument("--no-file-check", action="store_true")
    finalize.set_defaults(handler=command_finalize)

    work_dir = commands.add_parser("work-dir")
    work_dir.add_argument("--plan", required=True)
    work_dir.set_defaults(handler=command_work_dir)
    return root


def command_work_dir(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    require_valid_migration_plan(plan, phase="collector-final", plan_path=path)
    print(migration_work_dir(plan, create=True))
    return 0


def main() -> int:
    args = parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
