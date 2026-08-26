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


def resolve_work_dir(project_path: Path, raw: str | None) -> Path:
    if raw:
        return Path(raw).expanduser().resolve()
    return (project_path / ".devkit-sql-migration").resolve()


def initial_state(
    project_path: Path,
    work_dir: Path,
    source_db: str,
    target_db: str,
    *,
    db_config_path: Path,
    reset_run: bool = False,
) -> dict[str, Any]:
    return {
        "schema_version": "2.1",
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
        "db_config_path": str(db_config_path),
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
    db_config_path_raw = str(state.get("db_config_path") or "")
    if not db_config_path_raw:
        raise MigrationError("SQL_CONTEXT_INCOMPLETE", "db_config_path missing from state")
    ai_migration_raw = str(sql_analysis.get("ai_migration_path") or "")
    db_config_path = Path(db_config_path_raw).resolve()
    return {
        "project_path": Path(str(state["project_path"])).resolve(),
        "work_dir": Path(str(state["work_dir"])).resolve(),
        "input_source_db": str(state["input_source_db"]),
        "input_target_db": str(state["input_target_db"]),
        "source_db": str(state["source_db"]),
        "target_db": str(state["target_db"]),
        "java_path": Path(java_raw).resolve(),
        "jar_path": Path(jar_raw).resolve(),
        "ai_migration_path": Path(ai_migration_raw).resolve() if ai_migration_raw else None,
        "route": str(state.get("route") or "B"),
        "route_info": state.get("route_info") or {},
        "db_config_path": db_config_path,
        # db_config 字典：ANALYZE 阶段 run_devkit 通过 db_env(context["db_config"])
        # 构造 DevKit 子进程环境变量，断点恢复到 ANALYZE 时必须从此处加载，
        # 否则会抛 KeyError("db_config")。db_config_path 已校验存在。
        "db_config": load_db_config(db_config_path),
    }


def waiting_for_ai_payload(state: dict[str, Any], work_dir: Path) -> dict[str, Any]:
    workset = work_dir / "reports" / "ai-workset.json"
    sql_analysis = state.get("sql_analysis") or {}
    ai_migration_raw = str(sql_analysis.get("ai_migration_path") or "")
    db_config_path = str(state.get("db_config_path") or "")

    # 构造 finalize 入口命令前缀：Agent 在末尾追加 --work-dir / --compatible 等。
    # ai-migration 二进制路径由 download_devkit.sh 写入 devkit_path.txt 的 AI_MIGRATION 字段，
    # 若缺失说明 DevKit 不完整，整个流程无法继续，直接报错而非回退 .py 文件
    # （.pyc 模式下 .py 源文件不存在于文件系统，回退路径不可用）。
    if not (ai_migration_raw and Path(ai_migration_raw).is_file()):
        raise MigrationError(
            "AI_MIGRATION_NOT_FOUND",
            "devkit_path.txt 缺失 AI_MIGRATION 字段或二进制不可访问，无法构造 finalize 入口",
        )
    finalize_entry = (
        f'"{ai_migration_raw}" sql-migration finalize'
        f' --db-config "{db_config_path}"'
    )
    entry_mode = "SUBCOMMAND"
    resume_entry = f'"{ai_migration_raw}" sql-migration migrate'

    return result_payload(
        state,
        todo_report=str(work_dir / "reports" / "to_do-migrated_sql.json"),
        ai_workset=str(workset),
        source_root=str(work_dir / "source-code" / "b"),
        ai_complete_marker=str(work_dir / "reports" / ".ai-completed"),
        ai_finalize={
            "entry": finalize_entry,
            "entry_mode": entry_mode,
            "work_dir": str(work_dir),
            "classification_key": "workset_id",
            "outcomes": ["compatible", "converted", "manual-review"],
        },
        resume={
            "entry": resume_entry,
            "arguments": [
                "--project-path", str(state["project_path"]),
                "--work-dir", str(work_dir),
                "--source-db", str(state["input_source_db"]),
                "--target-db", str(state["input_target_db"]),
                "--db-config", db_config_path,
            ],
        },
    )


def waiting_for_user_decision_payload(state: dict[str, Any], work_dir: Path) -> dict[str, Any]:
    """迁移已完成时返回，由 Agent 询问用户是否重新迁移。"""
    final = load_json(work_dir / "reports" / "sql-migration-result.json", {})
    sql_analysis = state.get("sql_analysis") or {}
    ai_migration_raw = str(sql_analysis.get("ai_migration_path") or "")
    db_config_path = str(state.get("db_config_path") or "")
    reset_args = [
        "--project-path", str(state["project_path"]),
        "--work-dir", str(work_dir),
        "--source-db", str(state["input_source_db"]),
        "--target-db", str(state["input_target_db"]),
        "--db-config", db_config_path,
        "--reset",
    ]
    # reset_command 直接调 ai-migration sql-migration migrate --reset：
    # PREPARE 阶段会从 reports/devkit_path.txt 复用已就绪的 DevKit/JDK 缓存，
    # 跳过 download_devkit.sh / download_jdk.sh 的定位/下载步骤。
    # 若缓存已被清理，PREPARE 会失败，由 Agent 引导用户重新调 sql_migration.sh 走完整环境准备。
    if not (ai_migration_raw and Path(ai_migration_raw).is_file()):
        raise MigrationError(
            "AI_MIGRATION_NOT_FOUND",
            "devkit_path.txt 缺失 AI_MIGRATION 字段或二进制不可访问，无法构造 reset_command",
        )
    reset_command = f'"{ai_migration_raw}" sql-migration migrate ' + " ".join(f'"{a}"' for a in reset_args)
    return result_payload(
        state,
        result=final,
        previous_result=final,
        prompt="迁移已完成。是否重新迁移？选择重新迁移将清理工作目录并从阶段 1 重跑；选择查看已有结果则展示上次迁移结果。",
        reset_command=reset_command,
    )


def run(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    project_path = Path(args.project_path).expanduser().resolve()
    work_dir = resolve_work_dir(project_path, args.work_dir)
    source_db = args.source_db.strip()
    target_db = args.target_db.strip()
    db_config_path = Path(args.db_config).expanduser().resolve()
    if not project_path.is_dir():
        raise MigrationError("PROJECT_PATH_INVALID", f"project path is not a directory: {project_path}", 2)
    if not source_db or not target_db:
        raise MigrationError("DATABASE_TYPE_REQUIRED", "source-db and target-db are required", 2)
    if not db_config_path.is_file():
        raise MigrationError("SKILL_PATH_INVALID", f"--db-config 不是有效文件：{db_config_path}", 2)

    existing = load_json(state_path(work_dir), None) if work_dir.exists() else None
    reset_requested = bool(getattr(args, "reset", False))
    internal_resume = bool(getattr(args, "internal_resume", False))

    if reset_requested:
        # --reset：用户选择重新迁移，清理工作目录并从阶段 1 重跑。
        # 仅在 stage=COMPLETE 时由 Agent 透传，其它阶段由 Agent 自行判断不附加。
        # reset_run=True 标记本次为重跑，到达 COMPLETE 时直接返回结果，不再触发二次迁移询问。
        reset_workdir(work_dir)
        state = initial_state(
            project_path, work_dir, source_db, target_db,
            db_config_path=db_config_path,
            reset_run=True,
        )
        save_state(work_dir, state)
    elif not isinstance(existing, dict):
        reset_workdir(work_dir)
        state = initial_state(
            project_path, work_dir, source_db, target_db,
            db_config_path=db_config_path,
        )
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
            context = prepare_stage.run(
                project_path, work_dir, source_db, target_db,
                db_config_path=db_config_path,
            )
            state.update({
                "route": context["route"],
                "route_info": context["route_info"],
                "source_db": context["source_db"],
                "target_db": context["target_db"],
                "source_validation_enabled": bool((context["db_config"].get("source_db_conn") or {}).get("flag")),
                "target_validation_enabled": bool((context["db_config"].get("target_db_conn") or {}).get("flag")),
                "sql_analysis": {
                    "java_path": str(context["java_path"]),
                    "jar_path": str(context["jar_path"]),
                    "ai_migration_path": str(context.get("ai_migration_path") or "") if context.get("ai_migration_path") else "",
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


def _add_common_args(p: argparse.ArgumentParser) -> None:
    """注册共享参数 --db-config（SKILL 资源路径注入）。两种模式均需 --db-config，
    references / sql_migration.sh 由 Agent 通过 SKILL 目录结构自行定位，二进制无需感知。"""
    p.add_argument(
        "--db-config",
        required=True,
        help="SKILL 中 assets/db-connection.json 的绝对路径（含数据库连接信息）",
    )


def main() -> int:
    """ai-migration sql-migration 统一入口。

    ai-migration 二进制 launcher 只透传 --xxx 选项参数到本 pyc；migrate/finalize
    位置子命令由 launcher 自行识别并消费，不会传到 pyc。因此本入口不能用
    argparse subparsers 要求位置子命令，改为根据到达的 --xxx 参数自动判定模式：
      - --project-path 存在 → migrate 模式（迁移主流程，migrate 必带 --project-path）
      - --project-path 缺省 → finalize 模式（AI 阶段收敛，finalize 不带 --project-path）
    """
    parser = argparse.ArgumentParser(
        prog="ai-migration sql-migration",
        description="SQL migration unified entry: 根据 --project-path 自动判定 migrate/finalize 模式",
    )
    _add_common_args(parser)

    # --- 迁移主流程参数（migrate 模式）---
    parser.add_argument(
        "--project-path",
        default=None,
        help="source project directory containing SQL（migrate 模式必填；存在即判定为 migrate 模式）",
    )
    parser.add_argument(
        "--work-dir",
        default=None,
        help="SQL migration work directory; if omitted, defaults to <PROJECT_PATH>/.devkit-sql-migration（两种模式均可用，finalize 模式必填）",
    )
    parser.add_argument("--source-db", default=None, help="源数据库类型（migrate 模式必填）")
    parser.add_argument("--target-db", default=None, help="目标数据库类型（migrate 模式必填）")
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
        help="内部接力调用：由 finalize 模式在 AI 阶段收敛后透传，标识本次为内部续跑而非用户主动发起。到达 COMPLETE 时仍建立 WAITING_FOR_USER_DECISION 门禁，但直接返回迁移结果（不带询问 payload），询问交互留给后续用户主动发起的入口调用。",
    )

    # --- AI 阶段收敛参数（finalize 模式）---
    parser.add_argument("--compatible", action="append", default=[], help="compatible workset_id 列表，可多次传入（finalize 模式）")
    parser.add_argument("--converted", action="append", default=[], help="converted workset_id 列表，可多次传入（finalize 模式）")
    parser.add_argument("--manual-review", action="append", default=[], help="manual-review workset_id 列表，可多次传入（finalize 模式）")

    args = parser.parse_args()

    # 模式自动判定：launcher 消费 migrate/finalize 位置子命令后只透传 --xxx。
    # migrate 必带 --project-path，finalize 不带，故以 --project-path 是否存在区分。
    if not args.project_path:
        # finalize 模式：校验 --work-dir 后委托 finalize_ai_stage.run_from_args 执行收敛 + 接力续跑。
        # 错误处理与 payload 打印由 finalize_ai_stage 自行负责，保持与 migrate 模式一致。
        if not args.work_dir:
            parser.error("--work-dir is required in finalize mode（migrate 模式需提供 --project-path）")
        from tools.finalize_ai_stage import run_from_args as finalize_run
        return finalize_run(args)

    # migrate 模式：校验 --source-db / --target-db 后执行迁移主流程。
    if not args.source_db:
        parser.error("--source-db is required in migrate mode")
    if not args.target_db:
        parser.error("--target-db is required in migrate mode")

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
