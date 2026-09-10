#!/usr/bin/env python3
"""Source-collector migration-plan.json helper.

Owned by migration-source-collector. It initializes the handoff plan, validates
collector-side contract structure, and records source package metadata. It has
no runtime dependency on migration-target-execution.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

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
URL_RE = re.compile(r"https://[^\s`|]+")
PRODUCT_ALIASES = {"dm8": "dm", "达梦": "dm"}


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"JSON object required: {path}")
    return value


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
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


def validate_migration_plan(plan: Any, *, phase: str = "collector") -> list[str]:
    """Validate the collector-owned handoff contract without target runtime checks."""
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
    if phase == "collector-final" and not source.get("collection_package"):
        errors.append("source_environment.collection_package must be recorded before handoff")

    # Collector validates the shape of target placeholders/tools because they are
    # part of the handoff contract, but it does not inspect target runtime facts.
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
    migration_work_dir_value = _text(
        target.get("migration_work_dir"), "target_environment.migration_work_dir", errors
    )
    if migration_work_dir_value and not Path(migration_work_dir_value).expanduser().is_absolute():
        errors.append("target_environment.migration_work_dir must be an absolute path")

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


def require_valid_migration_plan(plan: Any, *, phase: str = "collector") -> None:
    errors = validate_migration_plan(plan, phase=phase)
    if errors:
        raise ValueError("invalid migration-plan.json: " + "; ".join(errors))
def initialize_plan(init_data: dict[str, Any]) -> dict[str, Any]:
    plan = deepcopy(init_data)
    plan["migration_id"] = str(uuid.uuid4())
    source = plan.setdefault("source_environment", {})
    source["collection_package"] = None
    source["details_archive"] = None
    target = plan.setdefault("target_environment", {})
    for field in ("hostname", "primary_ip", "os", "architecture", "kernel", "glibc", "package_manager", "privilege"):
        target[field] = None
    target["free_space_bytes"] = 0
    target["java"] = {"installed": False, "version": None, "command": None}
    probe_url = (target.get("network") or {}).get("probe_url") or None
    target["network"] = {"status": "UNKNOWN", "probe_url": probe_url}
    tools = deepcopy(target.get("migration_tools") or [])
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        tool["local_path"] = None
        tool["status"] = "PENDING_DOWNLOAD" if tool.get("download_url") else "PENDING_UPLOAD"
    target["migration_tools"] = tools
    plan["route"] = {"middleware": [], "database": [], "application": []}
    return plan


def command_init(args: argparse.Namespace) -> int:
    init_file = Path(args.init_file).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    plan = initialize_plan(load_json(init_file))
    if args.details_archive:
        plan["source_environment"]["details_archive"] = args.details_archive
    if args.collection_package:
        plan["source_environment"]["collection_package"] = args.collection_package
    require_valid_migration_plan(plan, phase="collector")
    write_json_atomic(output, plan)
    print(output)
    return 0


def command_validate(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    require_valid_migration_plan(plan, phase=args.phase)
    print(path)
    return 0


def command_set_source(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    plan = load_json(path)
    source = plan.setdefault("source_environment", {})
    if args.collection_package is not None:
        source["collection_package"] = args.collection_package
    if args.details_archive is not None:
        source["details_archive"] = args.details_archive
    write_json_atomic(path, plan)
    print(path)
    return 0


def normalize_product(value: Any) -> str:
    product = re.sub(r"\s+", "", str(value or "")).lower()
    return PRODUCT_ALIASES.get(product, product)


def route_version_key(value: str) -> tuple[int, ...]:
    """Sort concrete route versions numerically for SYSTEM_REPOSITORY fallback."""
    numbers = tuple(int(part) for part in re.findall(r"\d+", value))
    return numbers or (-1,)


def load_route_urls(path: Path) -> list[tuple[str, str, str]]:
    routes: list[tuple[str, str, str]] = []
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    for line in lines:
        if not line.lstrip().startswith("|"):
            continue
        cells = [cell.strip().strip("`") for cell in line.strip().strip("|").split("|")]
        if len(cells) == 5:
            product, version, url_cell = cells[0], cells[1], cells[3]
        elif len(cells) == 7:
            product, version, url_cell = cells[2], cells[3], cells[5]
        else:
            continue
        match = URL_RE.fullmatch(url_cell)
        if match and not re.search(r"[{}*]", match.group(0)):
            routes.append((normalize_product(product), version, match.group(0)))
    return routes


def command_resolve_urls(args: argparse.Namespace) -> int:
    path = Path(args.plan).expanduser().resolve()
    reference = Path(args.reference).expanduser().resolve()
    plan = load_json(path)
    routes = load_route_urls(reference)
    resolved = 0
    for group in ("middleware", "database"):
        for component in (plan.get("route") or {}).get(group) or []:
            target = component.get("target") or {}
            product = normalize_product(target.get("product"))
            for package in component.get("packages") or []:
                source_type = package.get("source_type")
                official_url_required = source_type == "OFFICIAL" and package.get("status") == "URL_REQUIRED"
                system_repository = group == "middleware" and source_type == "SYSTEM_REPOSITORY"
                if not official_url_required and not system_repository:
                    continue
                version = str(target.get("version") or package.get("version") or "").strip()
                product_candidates = list(dict.fromkeys(
                    (route_version, url) for route_product, route_version, url in routes
                    if route_product == product
                ))
                exact_candidates = [item for item in product_candidates if item[0] == version]
                candidates = exact_candidates or (product_candidates if system_repository or not version else [])
                file_name = str(package.get("file_name") or "").strip()
                matches = [item for item in candidates if Path(urlparse(item[1]).path).name == file_name]
                if not matches and len(candidates) == 1:
                    matches = candidates
                elif not matches and system_repository and candidates:
                    matches = [max(candidates, key=lambda item: route_version_key(item[0]))]
                if len(matches) == 1:
                    selected_version, selected_url = matches[0]
                    package["download_url"] = selected_url
                    if official_url_required:
                        package["file_name"] = Path(urlparse(selected_url).path).name
                        package["status"] = "PENDING_DOWNLOAD"
                    else:
                        package["version"] = selected_version
                    resolved += 1
    require_valid_migration_plan(plan, phase="collector")
    write_json_atomic(path, plan)
    print(f"resolved={resolved}")
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="source collector migration-plan.json helper")
    commands = root.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init")
    init.add_argument("--init-file", required=True)
    init.add_argument("--output", required=True)
    init.add_argument("--collection-package")
    init.add_argument("--details-archive")
    init.set_defaults(handler=command_init)

    validate = commands.add_parser("validate")
    validate.add_argument("--plan", required=True)
    validate.add_argument("--phase", choices=("collector", "collector-final"), default="collector")
    validate.set_defaults(handler=command_validate)

    source = commands.add_parser("set-source")
    source.add_argument("--plan", required=True)
    source.add_argument("--collection-package")
    source.add_argument("--details-archive")
    source.set_defaults(handler=command_set_source)

    resolve = commands.add_parser("resolve-urls")
    resolve.add_argument("--plan", required=True)
    resolve.add_argument("--reference", required=True)
    resolve.set_defaults(handler=command_resolve_urls)
    return root


def main() -> int:
    args = parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
