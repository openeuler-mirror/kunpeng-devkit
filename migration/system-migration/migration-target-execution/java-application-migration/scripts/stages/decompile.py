from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from binary_archive import class_prefix, detect_layout, safe_extract_zip
from migration_common import EXIT_FAILED, EXIT_OK, MigrationError, load_json, write_json, run as _run_command
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


def _state_ready(state_path: Path, package: Path, workspace: Path) -> bool:
    if not state_path.is_file():
        return False
    try:
        state = load_json(state_path)
    except Exception:
        return False
    if state.get("package") != _file_state(package):
        return False
    patch_root = workspace / "patch-root"
    unpacked = workspace / "unpacked"
    if not unpacked.is_dir() or not (patch_root / ".git").is_dir() or not (patch_root / "mapping.json").is_file():
        return False
    for module in state.get("nested_modules") or []:
        if module.get("decompile") and not Path(str(module.get("patch_module_root") or "")).is_dir():
            return False
    return True


def _run_kernel(
    unpacked: Path,
    patch_root: Path,
    classes_dir: Path,
    lib_dir: Path,
    logs: Path,
    work_dir: Path,
    devkit_cmd: str,
    tools_root: Path | None = None,
    vineflower_jar: str = "",
    vineflower_java: str = "",
) -> dict[str, Any]:
    """Invoke the decompile core via CLI subprocess."""
    temp_root = work_dir / "workspace" / "decompile-tmp"
    out_path = work_dir / "workspace" / "decompile-result.json"
    command = [
        devkit_cmd, "java-arm-migration", "migrate",
        "--classes-dir", str(classes_dir),
        "--lib-dir", str(lib_dir),
        "--unpacked", str(unpacked),
        "--patch-root", str(patch_root),
        "--logs", str(logs),
        "--out", str(out_path),
        "--temp", str(temp_root),
    ]
    if tools_root is not None:
        command.extend(["--tools-root", str(tools_root)])
    if vineflower_jar:
        command.extend(["--vineflower-jar", vineflower_jar])
    if vineflower_java:
        command.extend(["--vineflower-java", vineflower_java])
    proc = _run_command(command, logs / "decompiler-kernel.log", check=False)
    if proc.returncode != 0:
        raise MigrationError("DECOMPILER_KERNEL_FAILED", f"decompiler kernel exited {proc.returncode}; see {logs / 'decompiler-kernel.log'}")
    try:
        payload = load_json(out_path)
    except Exception as exc:
        raise MigrationError("DECOMPILER_KERNEL_OUTPUT_INVALID", f"cannot read kernel output: {exc}") from exc
    if payload.get("status") != "OK":
        raise MigrationError("DECOMPILER_KERNEL_FAILED", str(payload.get("reason") or "unknown error"))
    return payload


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
        patch_root = workspace / "patch-root"
        if _state_ready(state_path, package, workspace):
            try:
                mapping = load_json(patch_root / "mapping.json")
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
        patch_root.mkdir(parents=True, exist_ok=True)

        kernel = _run_kernel(
            unpacked,
            patch_root,
            classes_dir,
            lib_dir,
            logs,
            work_dir,
            str(input_data["tools"]["devkit_command"]),
            tools_root=work_dir.parent.parent / "tools" if (work_dir.parent.parent / "tools").is_dir() else None,
            vineflower_jar=str(input_data["tools"].get("vineflower_jar", "")),
            vineflower_java=str(input_data["tools"].get("vineflower_java", "")),
        )
        nested_modules = kernel.get("nested_modules") or []
        business_package_roots = kernel.get("business_package_roots") or []
        nested_summary = kernel.get("nested_classification_summary") or {}

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
