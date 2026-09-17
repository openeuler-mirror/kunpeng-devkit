from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from binary_adaptation import apply_patch, ensure_sql_patch, git_changes
from binary_archive import apply_archive_mutations, detect_layout, safe_extract_zip
from component_context import env_paths, require_context, save, sql_adaptation_enabled
from migration_common import (
    EXIT_FAILED,
    EXIT_OK,
    EXIT_WAITING_FOR_SKILL,
    EXIT_WAITING_FOR_USER,
    MigrationError,
    load_json_value,
)

def _sql_confirmation_message(counts: dict[str, Any]) -> str:
    def n(key: str) -> int:
        try:
            return int(counts.get(key) or 0)
        except (TypeError, ValueError):
            return 0

    return (
        "SQL迁移阶段已完成，但仍存在需要确认的结果："
        f"兼容 {n('compatible')} 条、已迁移 {n('migrated')} 条、"
        f"待确认 {n('pending_confirm')} 条、待迁移 {n('todo')} 条、"
        f"人工处理 {n('manual_review')} 条。"
        "如果继续，应用迁移将消费当前 SQL Patch，并继续执行 compile → repackage → "
        "artifact-change-report；生成候选制品后转入 Agent 应用启动验证。是否继续执行？"
    )


def run(plan_path: Path, application_id: str, package_id: str) -> int:
    input_data, work_dir, result_path, result = env_paths(plan_path, application_id, package_id)
    try:
        context = require_context(result)
        if not sql_adaptation_enabled(input_data):
            result.update({"status": "IN_PROGRESS", "stage": "SQL_MIGRATION", "reason_code": ""})
            result["sql_migration"] = {"source_status": "DISABLED", "decision": "NOT_REQUIRED", "counts": {}}
            result.pop("sql_skill", None)
            result.pop("action_required", None)
            result.pop("message", None)
            save(result_path, result)
            return EXIT_OK

        package = Path(context["working_package"])
        patch_root = Path(context["patch_root"])
        logs, patches, workspace = work_dir / "logs", work_dir / "patches", work_dir / "workspace"
        result["stage"] = "SQL_MIGRATION"
        sql_cfg = input_data.get("sql_migration") or {}
        patch_file = patches / "sql-migration.patch"
        result["sql_patch"] = str(patch_file)
        sql_outcome = ensure_sql_patch(input_data, patch_root, patch_file, work_dir, logs)
        action = str(sql_outcome.get("action") or "")

        if action == "CALL_SQL_SKILL":
            skill_input = {
                "PROJECT_PATH": str(patch_root.resolve()),
                "WORK_DIR": str(Path(str(sql_cfg.get("work_dir"))).resolve()),
                "SOURCE_DB": str(sql_cfg.get("source_db") or ""),
                "TARGET_DB": str(sql_cfg.get("target_db") or ""),
            }
            result.update({
                "status": "WAITING_FOR_SKILL",
                "reason_code": "CALL_SQL_MIGRATION",
                "sql_skill": skill_input,
                "action_required": {
                    "type": "RUN_SQL_MIGRATION",
                    "skill": "sql-migration",
                    "entry": "sql-migration/scripts/sql_migration.py",
                    "input": skill_input,
                    "after_completion": "RESUME_CURRENT_COMPONENT",
                    "resume_must_check_sql_result": True,
                    "resume_before_user_interaction": True,
                    "when_completed_with_actions": "WAIT_FOR_USER_CONFIRMATION",
                    "completion_contract": {
                        "terminal_sql_statuses": ["SUCCESS", "COMPLETED_WITH_ACTIONS"],
                        "required_action": "RESUME_CALLER_ONCE",
                        "must_update_caller_state_before_user_interaction": True,
                    },
                },
            })
            save(result_path, result)
            return EXIT_WAITING_FOR_SKILL

        if action == "WAITING_FOR_DECISION":
            counts = sql_outcome.get("counts") or {}
            prompt = _sql_confirmation_message(counts)
            decision_request = {
                "type": "CONFIRM_SQL_MIGRATION_RESULT",
                "requires_user_confirmation": True,
                "message": prompt,
                "question": "请选择是否使用当前 SQL Patch 继续生成候选制品。",
                "allowed_decisions": ["continue", "reject"],
                "decision_options": [
                    {"value": "continue", "label": "继续生成候选制品（保留待确认 SQL）"},
                    {"value": "reject", "label": "停止当前应用迁移"},
                ],
                "recommendation_policy": "NEUTRAL_NO_DEFAULT",
                "stop_execution": True,
                "auto_continue_allowed": False,
                "decision_source_required": "USER",
                "continue_effect": [
                    "APPLY_SQL_PATCH",
                    "COMPILE",
                    "REPACKAGE",
                    "ARTIFACT_CHANGE_REPORT",
                    "AGENT_APPLICATION_VERIFICATION",
                ],
                "reject_effect": "STOP_CURRENT_APPLICATION_COMPONENT",
                "decision_file": sql_outcome.get("decision_file"),
                "sql_result_status": sql_outcome.get("source_status"),
                "sql_result_file": sql_outcome.get("result_file"),
                "source_patch": sql_outcome.get("source_patch"),
                "counts": counts,
                "after_decision": "RESUME_CURRENT_COMPONENT",
            }
            result.update({
                "status": "WAITING_FOR_USER",
                "stage": "SQL_MIGRATION_CONFIRMATION",
                "reason_code": "SQL_MIGRATION_RESULT_CONFIRMATION_REQUIRED",
                "message": prompt,
                "sql_migration": {
                    "source_status": sql_outcome.get("source_status"),
                    "counts": counts,
                    "result_file": sql_outcome.get("result_file"),
                    "decision": "PENDING",
                },
                "action_required": decision_request,
            })
            result.pop("sql_skill", None)
            save(result_path, result)
            return EXIT_WAITING_FOR_USER

        if action != "READY":
            raise MigrationError("INVALID_SQL_MIGRATION_OUTCOME", f"unsupported SQL outcome: {action or '<empty>'}")

        counts = sql_outcome.get("counts") or {}
        result["sql_migration"] = {
            "source_status": sql_outcome.get("source_status"),
            "counts": counts,
            "result_file": sql_outcome.get("result_file"),
            "decision": sql_outcome.get("decision"),
            "pending_actions": sum(int(counts.get(key) or 0) for key in ("todo", "pending_confirm", "manual_review")),
        }
        result.pop("sql_skill", None)
        result.pop("action_required", None)
        apply_patch(patch_root, patch_file, workspace / ".sql-patch-applied", logs)

        mutation_file = patches / "archive-mutations.json"
        if mutation_file.is_file():
            value = load_json_value(mutation_file)
            mutations = value.get("mutations", []) if isinstance(value, dict) else value if isinstance(value, list) else []
            if mutations:
                applied = apply_archive_mutations(package, mutations, work_dir, logs / "archive-mutations.log")
                result.setdefault("archive_mutations", []).extend(applied)
                context["package_modified"] = True
                unpacked = Path(context["unpacked"])
                if unpacked.exists():
                    shutil.rmtree(unpacked)
                safe_extract_zip(package, unpacked)
                layout, classes_dir, lib_dir = detect_layout(unpacked, package)
                context.update({"layout": layout, "classes_dir": str(classes_dir), "lib_dir": str(lib_dir)})

        result["changed_files"] = git_changes(patch_root, logs)
        result.update({"status": "IN_PROGRESS", "reason_code": ""})
        result.pop("message", None)
        save(result_path, result)
        return EXIT_OK
    except MigrationError as exc:
        result.update({"status": exc.status, "stage": "SQL_MIGRATION", "reason_code": exc.code, "message": str(exc)})
        save(result_path, result)
        return EXIT_FAILED
    except Exception as exc:
        result.update({"status": "FAILED", "stage": "SQL_MIGRATION", "reason_code": "UNEXPECTED_ERROR", "message": repr(exc)})
        save(result_path, result)
        return EXIT_FAILED
