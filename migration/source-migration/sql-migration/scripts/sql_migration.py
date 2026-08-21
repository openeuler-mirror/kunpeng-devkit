#!/usr/bin/env python3
"""Primary controller for SQL migration.

The controller owns state, stage dispatch and resume. Concrete deterministic
work lives in stages/ and helper modules. AI only handles bounded semantic
transformation through reports/ai-workset.json.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
from common.migration_common import (
    MigrationError,
    load_json,
    now_local,
    reset_workdir,
    result_payload,
    save_state,
    stage_begin,
    stage_end,
    state_path,
)
from common.sql_context import load_db_config
from stages import analyze as analyze_stage
from stages import finalize as finalize_stage
from stages import prepare as prepare_stage

SCRIPT_DIR = Path(__file__).resolve().parent      # scripts/
SKILL_DIR = SCRIPT_DIR.parent                     # Skill 根目录


def resolve_work_dir(project_path: Path, raw: str | None) -> Path:
    if raw:
        return Path(raw).expanduser().resolve()
    return (project_path / ".devkit-sql-migration").resolve()


def initial_state(project_path: Path, work_dir: Path, source_db: str, target_db: str, *, reset_run: bool = False) -> dict[str, Any]:
    return {
        "schema_version": "2.0",
        "status": "RUNNING",
        "stage": "PREPARE",
        "reason_code": "",
        "project_path": str(project_path),
        "work_dir": str(work_dir),
        "input_source_db": source_db,
        "input_target_db": target_db,
        "source_db": source_db,
        "target_db": target_db,
        "route": "",
        "ai_completed": False,
        "reset_run": reset_run,
        "created_at": now_local(),
        "timings": {},
    }


def validate_resume_identity(state: dict[str, Any], project_path: Path, source_db: str, target_db: str) -> None:
    expected = (str(project_path), source_db, target_db)
    actual = (
        str(state.get("project_path") or ""),
        str(state.get("input_source_db") or ""),
        str(state.get("input_target_db") or ""),
    )
    if actual != expected:
        raise MigrationError(
            "RESUME_INPUT_MISMATCH",
            f"existing state belongs to different input: state={actual}, current={expected}; use a new WORK_DIR or clear the current SQL migration work directory",
        )


def context_from_state(state: dict[str, Any]) -> dict[str, Any]:
    sql_analysis = state.get("sql_analysis") or {}
    java_raw = str(sql_analysis.get("java_path") or "")
    jar_raw = str(sql_analysis.get("jar_path") or "")
    if not java_raw or not jar_raw:
        raise MigrationError("SQL_CONTEXT_INCOMPLETE", "prepared SQL Analysis runtime is missing from state")
    return {
        "project_path": Path(str(state["project_path"])).resolve(),
        "work_dir": Path(str(state["work_dir"])).resolve(),
        "input_source_db": str(state["input_source_db"]),
        "input_target_db": str(state["input_target_db"]),
        "source_db": str(state["source_db"]),
        "target_db": str(state["target_db"]),
        "java_path": Path(java_raw).resolve(),
        "jar_path": Path(jar_raw).resolve(),
        "route": str(state.get("route") or "B"),
        "route_info": state.get("route_info") or {},
        "db_config": load_db_config(),
    }


def waiting_for_ai_payload(state: dict[str, Any], work_dir: Path) -> dict[str, Any]:
    workset = work_dir / "reports" / "ai-workset.json"
    return result_payload(
        state,
        todo_report=str(work_dir / "reports" / "to_do-migrated_sql.json"),
        ai_workset=str(workset),
        source_root=str(work_dir / "source-code" / "b"),
        ai_reference=str(SKILL_DIR / "references" / "ai-sql-transformation.md"),
        ai_complete_marker=str(work_dir / "reports" / ".ai-completed"),
        ai_finalize={
            "entry": str(SCRIPT_DIR / "tools" / "finalize_ai_stage.py"),
            "work_dir": str(work_dir),
            "classification_key": "workset_id",
            "outcomes": ["compatible", "converted", "manual-review"],
        },
        resume={
            "entry": str(SCRIPT_DIR / "sql_migration.py"),
            "arguments": [
                "--project-path", str(state["project_path"]),
                "--work-dir", str(work_dir),
                "--source-db", str(state["input_source_db"]),
                "--target-db", str(state["input_target_db"]),
            ],
        },
    )


def waiting_for_user_decision_payload(state: dict[str, Any], work_dir: Path) -> dict[str, Any]:
    """迁移已完成时返回，由 Agent 询问用户是否重新迁移。"""
    final = load_json(work_dir / "reports" / "sql-migration-result.json", {})
    reset_args = [
        "--project-path", str(state["project_path"]),
        "--work-dir", str(work_dir),
        "--source-db", str(state["input_source_db"]),
        "--target-db", str(state["input_target_db"]),
        "--reset",
    ]
    return result_payload(
        state,
        result=final,
        previous_result=final,
        prompt="迁移已完成。是否重新迁移？选择重新迁移将清理工作目录并从阶段 1 重跑；选择查看已有结果则展示上次迁移结果。",
        reset_command=f'python3 "{str(SCRIPT_DIR / "sql_migration.py")}" ' + " ".join(f'"{a}"' for a in reset_args),
    )


def run(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    project_path = Path(args.project_path).expanduser().resolve()
    work_dir = resolve_work_dir(project_path, args.work_dir)
    source_db = args.source_db.strip()
    target_db = args.target_db.strip()
    if not project_path.is_dir():
        raise MigrationError("PROJECT_PATH_INVALID", f"project path is not a directory: {project_path}", 2)
    if not source_db or not target_db:
        raise MigrationError("DATABASE_TYPE_REQUIRED", "source-db and target-db are required", 2)

    existing = load_json(state_path(work_dir), None) if work_dir.exists() else None
    reset_requested = bool(getattr(args, "reset", False))
    internal_resume = bool(getattr(args, "internal_resume", False))

    if reset_requested:
        # --reset：用户选择重新迁移，清理工作目录并从阶段 1 重跑。
        # 仅在 stage=COMPLETE 时由 Agent 透传，其它阶段由 Agent 自行判断不附加。
        # reset_run=True 标记本次为重跑，到达 COMPLETE 时直接返回结果，不再触发二次迁移询问。
        reset_workdir(work_dir)
        state = initial_state(project_path, work_dir, source_db, target_db, reset_run=True)
        save_state(work_dir, state)
    elif not isinstance(existing, dict):
        reset_workdir(work_dir)
        state = initial_state(project_path, work_dir, source_db, target_db)
        save_state(work_dir, state)
    else:
        state = existing
        validate_resume_identity(state, project_path, source_db, target_db)

    while True:
        stage = str(state.get("stage") or "")

        if stage == "COMPLETE" and state.get("status") == "WAITING_FOR_USER_DECISION":
            # 用户尚未决策（未传 --reset）：继续返回 WAITING_FOR_USER_DECISION。
            # Agent 传 --reset 时，reset_requested 分支已清理并重置为 PREPARE，不会走到这里。
            return waiting_for_user_decision_payload(state, work_dir), 0

        if stage == "COMPLETE" and state.get("status") in {"SUCCESS", "COMPLETED_WITH_ACTIONS"}:
            # 到达 COMPLETE：建立 WAITING_FOR_USER_DECISION 门禁，防止后续误调用重跑丢失结果。
            # 但询问 payload 的返回分场景：
            #   - reset_run=True：本次由 --reset 触发的重跑，用户刚明确选择重新迁移，直接返回最终结果（不询问）。
            #   - internal_resume=True：finalize_ai_stage.py 接力调用，本次为内部续跑；
            #     询问交互应留给后续用户主动发起的入口调用，本处直接返回最终结果。
            #   - 其它（用户主动发起的首次入口调用）：返回询问 payload，由 Agent 询问用户。
            is_reset_run = bool(state.get("reset_run"))
            state["status"] = "WAITING_FOR_USER_DECISION"
            state["reason_code"] = "MIGRATION_ALREADY_COMPLETE"
            if is_reset_run:
                state["reset_run"] = False
            save_state(work_dir, state)
            final = load_json(work_dir / "reports" / "sql-migration-result.json", {})
            if is_reset_run or internal_resume:
                return result_payload(state, result=final, timings=state.get("timings", {})), 0
            return waiting_for_user_decision_payload(state, work_dir), 0

        if stage == "PREPARE":
            started = stage_begin(state, "PREPARE", work_dir)
            context = prepare_stage.run(project_path, work_dir, source_db, target_db)
            state.update({
                "route": context["route"],
                "route_info": context["route_info"],
                "source_db": context["source_db"],
                "target_db": context["target_db"],
                "sql_analysis": {
                    "java_path": str(context["java_path"]),
                    "jar_path": str(context["jar_path"]),
                },
            })
            stage_end(state, "PREPARE", started, work_dir)
            state["stage"] = "ANALYZE"
            save_state(work_dir, state)
            continue

        if stage == "ANALYZE":
            context = context_from_state(state)
            started = stage_begin(state, "ANALYZE", work_dir)
            analysis = analyze_stage.run(context)
            state["analysis"] = analysis
            stage_end(state, "ANALYZE", started, work_dir)
            if int(analysis.get("todo_count") or 0) > 0:
                state.update({
                    "status": "WAITING_FOR_AI",
                    "stage": "AI_TRANSFORMATION",
                    "reason_code": "AI_SQL_TRANSFORMATION_REQUIRED",
                    "ai_pending_count": int(analysis["todo_count"]),
                    "ai_workset": str(analysis["ai_workset"]),
                })
                save_state(work_dir, state)
                return waiting_for_ai_payload(state, work_dir), 0
            state.update({"status": "RUNNING", "stage": "FINALIZE", "reason_code": ""})
            save_state(work_dir, state)
            continue

        if stage == "AI_TRANSFORMATION":
            marker = work_dir / "reports" / ".ai-completed"
            if not marker.is_file():
                state.update({"status": "WAITING_FOR_AI", "reason_code": "AI_SQL_TRANSFORMATION_REQUIRED"})
                save_state(work_dir, state)
                return waiting_for_ai_payload(state, work_dir), 0
            state.update({"status": "RUNNING", "stage": "FINALIZE", "reason_code": "", "ai_completed": True})
            save_state(work_dir, state)
            continue

        if stage == "FINALIZE":
            started = stage_begin(state, "FINALIZE", work_dir)
            final = finalize_stage.run(work_dir, str(state["source_db"]), str(state["target_db"]))
            stage_end(state, "FINALIZE", started, work_dir)
            state["status"] = str(final.get("status") or "FAILED")
            state["stage"] = "COMPLETE"
            state["reason_code"] = "" if state["status"] == "SUCCESS" else "SQL_MIGRATION_ACTIONS_REQUIRED"
            save_state(work_dir, state)
            return result_payload(state, result=final, timings=state.get("timings", {})), 0

        raise MigrationError("INVALID_WORKFLOW_STATE", f"unsupported SQL migration stage: {stage}")


def main() -> int:
    parser = argparse.ArgumentParser(description="SQL migration primary execution entry")
    parser.add_argument("--project-path", required=True, help="source project directory containing SQL")
    parser.add_argument(
        "--work-dir",
        required=False,
        default=None,
        help="SQL migration work directory; if omitted, defaults to <PROJECT_PATH>/.devkit-sql-migration",
    )
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--target-db", required=True)
    parser.add_argument(
        "--reset",
        action="store_true",
        default=False,
        help="重新迁移：清理工作目录并从阶段 1 重跑。仅在迁移完成（stage=COMPLETE）后由 Agent 根据用户决策透传，其它阶段不应附加。",
    )
    parser.add_argument(
        "--internal-resume",
        action="store_true",
        default=False,
        help="内部接力调用：由 finalize_ai_stage.py 在 AI 阶段收敛后透传，标识本次为内部续跑而非用户主动发起。到达 COMPLETE 时仍建立 WAITING_FOR_USER_DECISION 门禁，但直接返回迁移结果（不带询问 payload），询问交互留给后续用户主动发起的入口调用。",
    )
    args = parser.parse_args()
    try:
        payload, rc = run(args)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return rc
    except MigrationError as exc:
        project_path = Path(args.project_path).expanduser().resolve()
        work_dir = resolve_work_dir(project_path, args.work_dir)
        state = load_json(state_path(work_dir), {}) if work_dir.exists() else {}
        if not isinstance(state, dict):
            state = {}
        state.update({
            "status": "BLOCKED",
            "reason_code": exc.reason,
            "stage": state.get("stage") or "UNKNOWN",
            "project_path": state.get("project_path") or str(project_path),
            "work_dir": str(work_dir),
            "input_source_db": state.get("input_source_db") or args.source_db,
            "input_target_db": state.get("input_target_db") or args.target_db,
            "source_db": state.get("source_db") or args.source_db,
            "target_db": state.get("target_db") or args.target_db,
            "error": str(exc),
        })
        try:
            work_dir.mkdir(parents=True, exist_ok=True)
            save_state(work_dir, state)
        except OSError:
            pass
        print(json.dumps(result_payload(state, error=str(exc)), ensure_ascii=False, indent=2))
        return exc.exit_code
    except Exception as exc:
        print(json.dumps({"status": "FAILED", "reason_code": "UNEXPECTED_ERROR", "error": str(exc)}, ensure_ascii=False, indent=2))
        return 30


if __name__ == "__main__":
    raise SystemExit(main())
