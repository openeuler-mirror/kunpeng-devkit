from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from binary_adaptation import git_baseline, run_vineflower
from binary_archive import (
    OPEN_SOURCE_WHITELIST_VERSION,
    class_prefix,
    copy_resources,
    detect_layout,
    infer_business_package_roots,
    nested_jar_candidates,
    safe_extract_zip,
)
from migration_common import EXIT_FAILED, EXIT_OK, MigrationError, load_json, write_json
from component_context import env_paths, require_context, save, sql_adaptation_enabled


def _file_state(path: Path) -> dict[str, Any]:
    stat_result = path.stat()
    return {
        "path": str(path.resolve()),
        "size": stat_result.st_size,
        "mtime_ns": stat_result.st_mtime_ns,
    }


def _safe_remove(path: Path, root: Path) -> None:
    try:
        resolved = path.resolve()
        root_resolved = root.resolve()
        if resolved == root_resolved or root_resolved not in resolved.parents:
            return
    except OSError:
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def _reset_workspace(work_dir: Path, input_data: dict[str, Any], result: dict[str, Any]) -> None:
    workspace = work_dir / "workspace"
    for path in (
        workspace / "unpacked",
        workspace / "patch-root",
        workspace / "decompile-tmp",
        workspace / "nested-jars",
        workspace / "compiled-classes",
        workspace / "nested-overlays",
        workspace / "nested-repacked",
        workspace / "overlay",
        workspace / ".sql-patch-applied",
        workspace / "decompile-state.json",
        work_dir / "patches" / "sql-migration.patch",
        work_dir / "patches" / "archive-mutations.json",
        work_dir / "sql-migration-decision.json",
        work_dir / "reports" / "artifact-change-report.json",
        work_dir / "reports" / "artifact-change-report.md",
    ):
        _safe_remove(path, work_dir)
    sql_cfg = input_data.get("sql_migration") or {}
    sql_work = str(sql_cfg.get("work_dir") or "").strip()
    if sql_work:
        _safe_remove(Path(sql_work), work_dir)
    for path in work_dir.glob("compile-fix-attempts*.json"):
        _safe_remove(path, work_dir)
    result.update({
        "sql_patch": "",
        "changed_files": [],
        "compiled_java_files": [],
        "compile_fixes": [],
        "updated_entries": [],
        "nested_modules": [],
        "nested_classification_summary": {},
        "artifact_change_report": {},
    })
    result.pop("sql_skill", None)
    result.pop("sql_migration", None)


def _state_ready(state_path: Path, package: Path, context: dict[str, Any], workspace: Path) -> bool:
    if not state_path.is_file():
        return False
    try:
        state = load_json(state_path)
    except Exception:
        return False
    if state.get("package") != _file_state(package):
        return False
    if state.get("open_source_whitelist_version") != OPEN_SOURCE_WHITELIST_VERSION:
        return False
    patch_root = workspace / "patch-root"
    unpacked = workspace / "unpacked"
    if not unpacked.is_dir() or not (patch_root / ".git").is_dir() or not (patch_root / "mapping.json").is_file():
        return False
    if not context.get("patch_root") or not context.get("classes_dir"):
        return False
    for module in context.get("nested_modules") or []:
        if module.get("decompile") and not Path(str(module.get("patch_module_root") or "")).is_dir():
            return False
    return True


def _prepare_nested_modules(
    unpacked: Path,
    layout: str,
    lib_dir: Path,
    patch_root: Path,
    workspace: Path,
    sql_cfg: dict[str, Any],
    tools: dict[str, Any],
    logs: Path,
    business_package_roots: list[str],
) -> list[dict[str, Any]]:
    modules: list[dict[str, Any]] = []
    nested_root = workspace / "nested-jars"
    temp_root = workspace / "decompile-tmp" / "nested"
    for candidate in nested_jar_candidates(unpacked, layout, lib_dir, business_package_roots):
        module = dict(candidate)
        module_id = str(candidate["module_id"])
        module["decompile"] = not bool(candidate.get("third_party"))
        if not module["decompile"]:
            modules.append(module)
            continue
        jar_path = Path(str(candidate["jar_path"]))
        module_workspace = nested_root / module_id
        nested_unpacked = module_workspace / "unpacked"
        module_patch_root = patch_root / "nested" / module_id
        safe_extract_zip(jar_path, nested_unpacked)
        copy_resources(nested_unpacked, module_patch_root / "src/main/resources", exclude_meta_inf_maven=True)
        run_vineflower(
            nested_unpacked,
            module_patch_root,
            sql_cfg,
            tools,
            logs,
            temp_dir=temp_root / module_id,
            log_name=f"vineflower-{module_id}.log",
        )
        module.update({
            "unpacked": str(nested_unpacked.resolve()),
            "classes_dir": str(nested_unpacked.resolve()),
            "patch_module_root": str(module_patch_root.resolve()),
            "java_root": f"nested/{module_id}/src/main/java",
            "resources_root": f"nested/{module_id}/src/main/resources",
        })
        modules.append(module)
    return modules


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        context = require_context(result)
        if not sql_adaptation_enabled(input_data):
            result.update({"status": "IN_PROGRESS", "stage": "DECOMPILE", "reason_code": ""})
            save(result_path, result)
            return EXIT_OK
        package = Path(context["working_package"])
        logs, workspace = work_dir / "logs", work_dir / "workspace"
        state_path = workspace / "decompile-state.json"
        if _state_ready(state_path, package, context, workspace):
            try:
                mapping = load_json(workspace / "patch-root" / "mapping.json")
                result["nested_modules"] = mapping.get("nested_modules", [])
                result["nested_classification_summary"] = mapping.get("nested_classification_summary", {})
            except Exception:
                pass
            result.update({"status": "IN_PROGRESS", "stage": "DECOMPILE", "reason_code": ""})
            save(result_path, result)
            return EXIT_OK

        _reset_workspace(work_dir, input_data, result)
        unpacked = workspace / "unpacked"
        safe_extract_zip(package, unpacked)
        layout, classes_dir, lib_dir = detect_layout(unpacked, package)
        patch_root = workspace / "patch-root"
        resources_root = patch_root / "src/main/resources"
        patch_root.mkdir(parents=True, exist_ok=True)
        copy_resources(classes_dir, resources_root)
        sql_cfg = input_data.get("sql_migration") or {}
        run_vineflower(
            classes_dir,
            patch_root,
            sql_cfg,
            input_data.get("tools") or {},
            logs,
            temp_dir=workspace / "decompile-tmp" / "root",
        )
        business_package_roots = infer_business_package_roots(classes_dir)
        nested_modules = _prepare_nested_modules(
            unpacked,
            layout,
            lib_dir,
            patch_root,
            workspace,
            sql_cfg,
            input_data.get("tools") or {},
            logs,
            business_package_roots,
        )
        nested_summary = {
            "total": len(nested_modules),
            "business": sum(1 for item in nested_modules if item.get("classification") == "BUSINESS"),
            "business_candidate": sum(1 for item in nested_modules if item.get("classification") == "BUSINESS_CANDIDATE"),
            "third_party_skipped": sum(1 for item in nested_modules if item.get("classification") == "THIRD_PARTY"),
            "decompiled": sum(1 for item in nested_modules if item.get("decompile")),
        }
        mapping = {
            "layout": layout,
            "classes_archive_prefix": class_prefix(layout).as_posix(),
            "java_root": "src/main/java",
            "resources_root": "src/main/resources",
            "business_package_roots": business_package_roots,
            "nested_classification_summary": nested_summary,
            "nested_modules": [
                {
                    "module_id": item.get("module_id"),
                    "archive_path": item.get("archive_path"),
                    "file_name": item.get("file_name"),
                    "group_id": item.get("group_id"),
                    "artifact_id": item.get("artifact_id"),
                    "classification": item.get("classification"),
                    "open_source": item.get("open_source"),
                    "third_party": item.get("third_party"),
                    "whitelist_reason": item.get("reason"),
                    "decompile": item.get("decompile"),
                    "java_root": item.get("java_root", ""),
                    "resources_root": item.get("resources_root", ""),
                }
                for item in nested_modules
            ],
        }
        write_json(patch_root / "mapping.json", mapping)
        git_baseline(patch_root, logs)
        context.update({
            "unpacked": str(unpacked),
            "layout": layout,
            "classes_dir": str(classes_dir),
            "lib_dir": str(lib_dir),
            "patch_root": str(patch_root),
            "nested_modules": nested_modules,
        })
        write_json(state_path, {
            "package": _file_state(package),
            "layout": layout,
            "open_source_whitelist_version": OPEN_SOURCE_WHITELIST_VERSION,
            "nested_modules": nested_modules,
        })
        result.update({
            "status": "IN_PROGRESS",
            "stage": "DECOMPILE",
            "reason_code": "",
            "nested_modules": mapping["nested_modules"],
            "nested_classification_summary": nested_summary,
        })
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "DECOMPILE", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "DECOMPILE", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
