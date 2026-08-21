from __future__ import annotations

from pathlib import Path

from binary_adaptation import compile_changed_java, git_changes
from migration_common import EXIT_FAILED, EXIT_NEEDS_AGENT_FIX, EXIT_OK, MigrationError, load_json
from component_context import env_paths, require_context, require_sql_stage_ready, save, sql_adaptation_enabled


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        context = require_context(result)
        require_sql_stage_ready(input_data, result)
        if not sql_adaptation_enabled(input_data):
            result.update({"status": "IN_PROGRESS", "stage": "COMPILE", "reason_code": ""})
            save(result_path, result)
            return EXIT_OK

        patch_root = Path(context["patch_root"])
        classes_dir = Path(context["classes_dir"])
        lib_dir = Path(context["lib_dir"])
        logs, workspace = work_dir / "logs", work_dir / "workspace"
        changes = git_changes(patch_root, logs)
        result["changed_files"] = changes
        compiled_root = workspace / "compiled-classes"
        compiled_root.mkdir(parents=True, exist_ok=True)
        all_compiled: list[str] = []
        root_compiled = compiled_root / "root"
        compiled_files, code = compile_changed_java(
            changes,
            patch_root,
            classes_dir,
            lib_dir,
            root_compiled,
            input_data,
            logs,
            work_dir,
            module_id="root",
        )
        all_compiled.extend(compiled_files)
        if code == EXIT_NEEDS_AGENT_FIX:
            result.update({
                "compiled_java_files": all_compiled,
                "status": "NEEDS_AGENT_FIX",
                "stage": "COMPILE",
                "reason_code": "FAILED_DECOMPILED_SOURCE_RECOMPILE",
                "action_required": {"type": "FIX_DECOMPILED_SOURCE_COMPILE", "logs": str(logs)},
            })
            save(result_path, result)
            return EXIT_NEEDS_AGENT_FIX

        compiled_modules: dict[str, str] = {"root": str(root_compiled)}
        for module in context.get("nested_modules") or []:
            if not module.get("decompile"):
                continue
            module_id = str(module["module_id"])
            module_compiled = compiled_root / "nested" / module_id
            module_files, code = compile_changed_java(
                changes,
                patch_root,
                Path(str(module["classes_dir"])),
                lib_dir,
                module_compiled,
                input_data,
                logs,
                work_dir,
                source_prefix=f"nested/{module_id}/src/main/java",
                extra_classpath=[classes_dir],
                module_id=module_id,
            )
            all_compiled.extend(module_files)
            compiled_modules[module_id] = str(module_compiled)
            if code == EXIT_NEEDS_AGENT_FIX:
                result.update({
                    "compiled_java_files": all_compiled,
                    "status": "NEEDS_AGENT_FIX",
                    "stage": "COMPILE",
                    "reason_code": "FAILED_DECOMPILED_SOURCE_RECOMPILE",
                    "action_required": {"type": "FIX_DECOMPILED_SOURCE_COMPILE", "logs": str(logs)},
                })
                save(result_path, result)
                return EXIT_NEEDS_AGENT_FIX

        result["compiled_java_files"] = all_compiled
        fixes_file = patch_root / "compile-fixes.json"
        if fixes_file.is_file():
            try:
                result["compile_fixes"] = load_json(fixes_file).get("fixes", [])
            except Exception:
                result["compile_fixes"] = []
        context["package_modified"] = bool(context.get("package_modified") or changes)
        context["compiled_dir"] = str(root_compiled)
        context["compiled_modules"] = compiled_modules
        result.update({"status": "IN_PROGRESS", "stage": "COMPILE", "reason_code": ""})
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "COMPILE", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "COMPILE", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
