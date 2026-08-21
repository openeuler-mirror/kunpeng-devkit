from __future__ import annotations

import shutil
from pathlib import Path

from migration_common import EXIT_FAILED, EXIT_OK, MigrationError, TOP_LEVEL_SUFFIXES, java_tool, load_json, write_json
from component_context import env_paths, save


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        logs, input_dir, workspace, output_dir, reports, patches = [
            work_dir / n for n in ("logs", "input", "workspace", "output", "reports", "patches")
        ]
        for directory in (logs, input_dir, workspace, output_dir, reports, patches):
            directory.mkdir(parents=True, exist_ok=True)
        original = Path(str(input_data.get("input_package") or "")).expanduser().resolve()
        if not original.is_file() or original.suffix.lower() not in TOP_LEVEL_SUFFIXES:
            raise MigrationError("UNSUPPORTED_PACKAGE_TYPE", f"Only JAR and WAR packages are supported: {original}")
        target_arch = str((input_data.get("target_environment") or {}).get("architecture", "")).lower()
        if target_arch not in {"aarch64", "arm64"}:
            raise MigrationError("UNSUPPORTED_TARGET_ARCH", f"Target architecture is {target_arch}")
        migration_jdk_home = input_data.get("migration_jdk_home")
        if not migration_jdk_home:
            raise MigrationError("MISSING_MIGRATION_JDK", "migration_jdk_home is required")
        for tool_name in ("java", "javac", "jar"):
            java_tool(str(migration_jdk_home), tool_name)
        working_package = input_dir / original.name
        input_state_path = workspace / ".input-package-state.json"
        current_state = {
            "source_path": str(original),
            "size": original.stat().st_size,
            "mtime_ns": original.stat().st_mtime_ns,
        }
        if input_state_path.exists() and load_json(input_state_path) != current_state:
            raise MigrationError(
                "INPUT_PACKAGE_CHANGED_AFTER_START",
                "Input package changed after migration started; start a new migration_id/component work directory",
                status="BLOCKED",
            )
        if not working_package.exists():
            shutil.copy2(original, working_package)
            write_json(input_state_path, current_state)
        result["work_state"] = {
            "original": str(original),
            "working_package": str(working_package),
            "package_modified": False,
        }
        result.update({"status": "IN_PROGRESS", "stage": "PREPARE", "reason_code": "", "input_package": str(original)})
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "PREPARE", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "PREPARE", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
