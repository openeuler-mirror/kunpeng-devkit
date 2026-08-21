from __future__ import annotations

import shutil
from pathlib import Path

from artifact_change_report import generate_artifact_change_report
from binary_adaptation import git_changes
from binary_archive import prepare_nested_overlay, prepare_overlay, update_archive
from migration_common import EXIT_FAILED, EXIT_OK, MigrationError, load_json
from component_context import env_paths, require_context, require_sql_stage_ready, save, sql_adaptation_enabled


def _source_change_summary(changes):
    paths = sorted({str(item.get("path") or "") for item in changes if str(item.get("path") or "")})
    return {
        "changed_files": len(paths),
        "changed_paths": paths,
        "scope": "PATCH_ROOT_SOURCE_FILES",
    }


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        context = require_context(result)
        require_sql_stage_ready(input_data, result)
        package = Path(context["working_package"])
        output = work_dir / "output" / f"{package.stem}-kunpeng-arm64{package.suffix}"
        output.parent.mkdir(parents=True, exist_ok=True)

        source_changes = []
        if not sql_adaptation_enabled(input_data):
            shutil.copy2(package, output)
            result["updated_entries"] = []
        else:
            patch_root = Path(context["patch_root"])
            workspace = work_dir / "workspace"
            compiled_modules = context.get("compiled_modules") or {}
            compiled_dir = Path(str(compiled_modules.get("root") or context.get("compiled_dir") or (workspace / "compiled-classes" / "root")))
            overlay = workspace / "overlay"
            changes = git_changes(patch_root, work_dir / "logs")
            source_changes = changes
            root_changes = [item for item in changes if not item["path"].startswith("nested/")]
            updated = prepare_overlay(root_changes, patch_root, compiled_dir, overlay, context["layout"])

            nested_overlay_root = workspace / "nested-overlays"
            nested_repacked_root = workspace / "nested-repacked"
            for module in context.get("nested_modules") or []:
                if not module.get("decompile"):
                    continue
                module_id = str(module["module_id"])
                module_prefix = f"nested/{module_id}/"
                module_changes = [item for item in changes if item["path"].startswith(module_prefix)]
                if not module_changes:
                    continue
                module_compiled = Path(str(compiled_modules.get(module_id) or (workspace / "compiled-classes" / "nested" / module_id)))
                nested_overlay = nested_overlay_root / module_id
                nested_entries = prepare_nested_overlay(module_changes, patch_root, module_id, module_compiled, nested_overlay)
                source_jar = Path(str(module["jar_path"]))
                nested_output = nested_repacked_root / f"{module_id}.jar"
                nested_output.parent.mkdir(parents=True, exist_ok=True)
                update_archive(source_jar, nested_output, nested_overlay, input_data.get("migration_jdk_home"), work_dir / "logs")
                archive_path = Path(str(module["archive_path"]))
                target = overlay / archive_path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(nested_output, target)
                updated.append(archive_path.as_posix())
                updated.extend(f"{archive_path.as_posix()}!/{entry}" for entry in nested_entries)

            result["updated_entries"] = sorted(set(updated))
            update_archive(package, output, overlay, input_data.get("migration_jdk_home"), work_dir / "logs")

        original = Path(str(context.get("original") or result.get("input_package") or "")).expanduser().resolve()
        input_state_path = work_dir / "workspace" / ".input-package-state.json"
        if input_state_path.is_file():
            initial_state = load_json(input_state_path)
            current_state = {
                "source_path": str(original),
                "size": original.stat().st_size,
                "mtime_ns": original.stat().st_mtime_ns,
            }
            if initial_state != current_state:
                raise MigrationError(
                    "INPUT_PACKAGE_CHANGED_AFTER_START",
                    "Input package changed after migration started; artifact change report baseline is no longer valid",
                    status="BLOCKED",
                )

        expected_entries = list(result.get("updated_entries") or [])
        for mutation in result.get("archive_mutations") or []:
            archive_path = str((mutation or {}).get("archive_path") or "").strip()
            if archive_path:
                expected_entries.append(archive_path)
        artifact_report = generate_artifact_change_report(
            original,
            output,
            work_dir / "reports",
            expected_entries=sorted(set(expected_entries)),
        )
        result["artifact_change_report"] = {
            "status": artifact_report.get("status"),
            "report_json": artifact_report.get("report_json"),
            "report_markdown": artifact_report.get("report_markdown"),
            "summary": artifact_report.get("summary") or {},
        }
        result["source_change_summary"] = _source_change_summary(source_changes)
        context["output_package"] = str(output)
        result.update({
            "status": "IN_PROGRESS",
            "stage": "REPACKAGE",
            "reason_code": "",
            "output_package": str(output),
            "migration_completion": {
                "static_migration": {
                    "status": "SUCCESS" if str(artifact_report.get("status") or "").upper() in {"SUCCESS", "SKIPPED"} else "FAILED",
                    "artifact_ready": True,
                    "compatibility_analysis_status": str((result.get("devkit") or {}).get("status") or ""),
                    "artifact_change_report_status": str(artifact_report.get("status") or ""),
                },
                "target_environment_verification": {"status": "NOT_VERIFIED"},
            },
        })
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "REPACKAGE", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "REPACKAGE", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
