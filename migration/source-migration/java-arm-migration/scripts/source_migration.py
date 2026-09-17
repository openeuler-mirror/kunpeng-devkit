#!/usr/bin/env python3
"""Source adaptation stages for Java source ARM64 migration."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_SCRIPTS = SCRIPT_DIR

from migration_common import (
    EXIT_FAILED, EXIT_NEEDS_FIX, EXIT_OK, EXIT_WAITING, MigrationError,
    build_environment, cleanup_untracked_build_outputs,
    clear_current_error, config_path, database_route,
    inspect_ai_migration_source_csv_reports, load_json, now_iso, require_baseline_build_command, resolve_ai_migration, zh_csv_reports,
    git_worktree_tree, run_command, run_shell, sha256_file, write_git_patch_from_tree, write_json,
)

AI_MIGRATION_SOURCE_SUFFIXES = {
    ".java": "java",
    ".py": "python",
    ".scala": "scala",
}

def detect_ai_migration_source_types(work_source: Path) -> list[str]:
    """Detect only source language switches supported by this Java migration skill."""
    detected: set[str] = set()
    skipped_dirs = {".git", "target", "build", "dist", "out", ".gradle", "node_modules"}
    for root, dirs, files in os.walk(str(work_source)):
        dirs[:] = [name for name in dirs if name not in skipped_dirs]
        for name in files:
            source_type = AI_MIGRATION_SOURCE_SUFFIXES.get(Path(name).suffix.lower())
            if source_type:
                detected.add(source_type)
        if len(detected) == len(set(AI_MIGRATION_SOURCE_SUFFIXES.values())):
            break
    # This skill requires a Java source project. Keep java as a defensive default
    # so the scanner receives an explicit language even for unusual source layouts.
    if not detected:
        detected.add("java")
    return [item for item in ("java", "python", "scala") if item in detected]
def detect_build_command(work_source: Path) -> tuple[str, str]:
    mvnw = work_source / "mvnw"
    gradlew = work_source / "gradlew"
    if mvnw.is_file():
        prefix = "./mvnw" if os.access(str(mvnw), os.X_OK) else "bash mvnw"
        return prefix + " -B clean package", "maven-wrapper"
    if (work_source / "pom.xml").is_file():
        return "mvn -B clean package", "maven"
    if gradlew.is_file():
        prefix = "./gradlew" if os.access(str(gradlew), os.X_OK) else "bash gradlew"
        return prefix + " clean build --no-daemon", "gradle-wrapper"
    if (work_source / "build.gradle").is_file() or (work_source / "build.gradle.kts").is_file():
        return "gradle clean build --no-daemon", "gradle"
    if (work_source / "build.xml").is_file():
        return "ant", "ant"
    return "", "unknown"

def detect_project_profile(work_source: Path, build_command: str, build_kind: str) -> dict[str, Any]:
    files = []
    for name in (
        "pom.xml",
        "mvnw",
        "build.gradle",
        "build.gradle.kts",
        "gradlew",
        "settings.gradle",
        "settings.gradle.kts",
        "build.xml",
        "README.md",
        "README",
    ):
        if (work_source / name).exists():
            files.append(name)
    modules = []
    for pattern in ("*/pom.xml", "*/build.gradle", "*/build.gradle.kts"):
        for item in work_source.glob(pattern):
            modules.append(str(item.parent.relative_to(work_source)))
    return {
        "build_kind": build_kind,
        "build_command": build_command,
        "root_files": sorted(set(files)),
        "candidate_modules": sorted(set(modules)),
    }

def command_exists(command: str, cwd: Path) -> bool:
    parts = shlex.split(command)
    if not parts:
        return False
    executable = parts[0]
    if "/" in executable:
        path = Path(executable).expanduser()
        if not path.is_absolute():
            path = cwd / path
        return path.is_file()
    return shutil.which(executable) is not None

def git_worktree_fingerprint(work_source: Path) -> str:
    """Fingerprint tracked diffs plus non-ignored untracked files."""
    digest = hashlib.sha256()
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD", "--"],
        cwd=str(work_source),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    digest.update(diff.stdout or b"")
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd=str(work_source),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    raw = status.stdout or b""
    digest.update(raw)
    for record in raw.split(b"\0"):
        if not record.startswith(b"?? "):
            continue
        relative = record[3:].decode("utf-8", errors="surrogateescape")
        path = work_source / relative
        if path.is_file() and not path.is_symlink():
            digest.update(relative.encode("utf-8", errors="surrogateescape"))
            try:
                with path.open("rb") as fh:
                    while True:
                        chunk = fh.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
            except OSError:
                pass
        elif path.is_symlink():
            try:
                digest.update((relative + "->" + os.readlink(str(path))).encode("utf-8", errors="surrogateescape"))
            except OSError:
                pass
    return digest.hexdigest()

def sql_result_counts(data: dict[str, Any]) -> dict[str, int]:
    raw = data.get("counts") if isinstance(data.get("counts"), dict) else data
    counts = {}
    for key in ("compatible", "migrated", "todo", "pending_confirm", "manual_review"):
        try:
            counts[key] = int(raw.get(key) or 0)
        except (AttributeError, TypeError, ValueError):
            counts[key] = 0
    return counts

def apply_sql_patch(work_dir: Path, work_source: Path, result_file: Path, patch_file: Path) -> dict[str, Any]:
    state_path = work_dir / "sql-patch-state.json"
    result_hash = sha256_file(result_file)
    patch_hash = sha256_file(patch_file) if patch_file.is_file() else ""
    if state_path.is_file():
        state = load_json(state_path)
        if state.get("sql_result_sha256") == result_hash and state.get("source_patch_sha256") == patch_hash:
            return state
        raise MigrationError(
            "STALE_SQL_PATCH_STATE",
            "SQL result or patch changed after a previous patch was applied. Review the current worktree before continuing.",
            status="BLOCKED",
        )
    if not patch_file.is_file() or patch_file.stat().st_size == 0:
        state = {
            "status": "NO_CHANGES",
            "sql_result_sha256": result_hash,
            "source_patch_sha256": patch_hash,
            "applied_at": now_iso(),
        }
        write_json(state_path, state)
        return state
    check_proc = run_command(
        ["git", "apply", "--check", "--ignore-space-change", "--ignore-whitespace", str(patch_file)],
        cwd=work_source,
        log_path=work_dir / "logs" / "sql-patch.log",
        check=False,
    )
    if check_proc.returncode != 0:
        raise MigrationError("SQL_PATCH_CONFLICT", "SQL patch does not apply cleanly; see logs/sql-patch.log", status="NEEDS_AGENT_FIX")
    apply_proc = run_command(
        ["git", "apply", "--ignore-space-change", "--ignore-whitespace", str(patch_file)],
        cwd=work_source,
        log_path=work_dir / "logs" / "sql-patch.log",
        check=False,
    )
    if apply_proc.returncode != 0:
        raise MigrationError("SQL_PATCH_APPLY_FAILED", "Failed to apply SQL patch; see logs/sql-patch.log", status="NEEDS_AGENT_FIX")
    state = {
        "status": "APPLIED",
        "sql_result_sha256": result_hash,
        "source_patch_sha256": patch_hash,
        "applied_at": now_iso(),
    }
    write_json(state_path, state)
    return state

def valid_sql_decision(work_dir: Path, request: dict[str, Any]) -> bool:
    path = work_dir / "sql-migration-decision.json"
    if not path.is_file():
        return False
    try:
        decision = load_json(path)
    except MigrationError:
        return False
    return (
        str(decision.get("decision") or "").upper() == "CONTINUE_WITH_PENDING"
        and decision.get("sql_result_sha256") == request.get("sql_result_sha256")
        and decision.get("source_patch_sha256") == request.get("source_patch_sha256")
    )


def ensure_sql_continue_decision(work_dir: Path, request: dict[str, Any], task_id: str) -> dict[str, Any]:
    """Apply the fixed Java-side policy for SQL COMPLETED_WITH_ACTIONS.

    Pending/manual-review SQL items remain visible in the final completion
    actions, but they do not require a second user wake-up before Java build.
    The decision is bound to the exact SQL result and source patch hashes.
    """
    path = work_dir / "sql-migration-decision.json"
    if valid_sql_decision(work_dir, request):
        decision = load_json(path)
        decision.setdefault("task_id", task_id)
        decision.setdefault("decision_origin", "EXISTING_VALID_DECISION")
        return decision
    decision = {
        "schema_version": "1.0",
        "task_id": task_id,
        "decision": "CONTINUE_WITH_PENDING",
        "decision_origin": "AUTO_POLICY",
        "sql_result_sha256": request.get("sql_result_sha256") or "",
        "source_patch_sha256": request.get("source_patch_sha256") or "",
        "decided_at": now_iso(),
    }
    write_json(path, decision)
    return decision


def sql_handoff_path(work_dir: Path) -> Path:
    return work_dir / "sql-handoff.json"


def _sql_controller_alive(pid: int, handoff_path: Path) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    proc_cmdline = Path("/proc") / str(pid) / "cmdline"
    if proc_cmdline.is_file():
        try:
            cmdline = proc_cmdline.read_bytes().decode("utf-8", errors="ignore").replace("\x00", " ")
            return "sql_resume_controller.py" in cmdline and str(handoff_path) in cmdline
        except OSError:
            return True
    return True


def start_sql_resume_controller(work_dir: Path, handoff: dict[str, Any]) -> dict[str, Any]:
    """Start one detached SQL-result watcher for this Java migration task."""
    if os.environ.get("JAVA_ARM_MIGRATION_DISABLE_SQL_CONTROLLER") == "1":
        handoff["controller"] = {
            "status": "DISABLED_BY_ENV",
            "updated_at": now_iso(),
        }
        write_json(sql_handoff_path(work_dir), handoff)
        return handoff
    path = sql_handoff_path(work_dir)
    controller = handoff.get("controller") if isinstance(handoff.get("controller"), dict) else {}
    try:
        pid = int(controller.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if _sql_controller_alive(pid, path):
        return handoff
    script = ROOT_SCRIPTS / "sql_resume_controller.py"
    log_path = work_dir / "logs" / "sql-resume-controller.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fh = log_path.open("ab")
    try:
        proc = subprocess.Popen(
            [sys.executable, str(script), "--handoff", str(path)],
            cwd=str(ROOT_SCRIPTS.parent),
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        log_fh.close()
    handoff["controller"] = {
        "status": "WATCHING",
        "pid": proc.pid,
        "script": str(script),
        "log": str(log_path),
        "started_at": now_iso(),
    }
    handoff["updated_at"] = now_iso()
    write_json(path, handoff)
    return handoff


def _new_sql_task_id() -> str:
    return "sql-%s" % uuid.uuid4().hex[:16]


def load_or_create_sql_handoff(
    work_dir: Path,
    work_source: Path,
    source_db: str,
    target_db: str,
) -> dict[str, Any]:
    """Create/reuse a task-scoped SQL handoff.

    Each task gets its own SQL WORK_DIR, so a result from an older migration
    cannot accidentally wake a newer Java migration for the same project.
    """
    path = sql_handoff_path(work_dir)
    if path.is_file():
        try:
            existing = load_json(path)
        except MigrationError:
            existing = {}
        same_route = (
            str(existing.get("source_db") or "") == source_db
            and str(existing.get("target_db") or "") == target_db
            and str(existing.get("work_source") or "") == str(work_source)
        )
        task_id = str(existing.get("task_id") or "")
        if same_route and task_id:
            return existing

    workspace = load_json(work_dir / "workspace.json")
    source = str(workspace.get("source") or "")
    project_id = str(workspace.get("project_id") or work_dir.name)
    task_id = _new_sql_task_id()
    sql_work = work_dir / "sql-migration" / task_id
    report_file = sql_work / "reports" / "sql-migration-result.json"
    patch_file = sql_work / "reports" / "source_code.patch"
    resume_command = [
        sys.executable,
        str(ROOT_SCRIPTS / "run_migration.py"),
        "--source", source,
        "--source-db", source_db,
        "--target-db", target_db,
        "--stage", "build",
    ]
    handoff = {
        "schema_version": "1.0",
        "task_id": task_id,
        "parent_migration_id": project_id,
        "status": "WAITING_FOR_SQL",
        "source": source,
        "work_source": str(work_source),
        "source_db": source_db,
        "target_db": target_db,
        "sql_result_policy": "CONTINUE_WITH_PENDING",
        "sql_work_dir": str(sql_work),
        "result_file": str(report_file),
        "patch_file": str(patch_file),
        "resume_stage": "build",
        "resume_command": resume_command,
        "created_at": now_iso(),
        "updated_at": now_iso(),
    }
    write_json(path, handoff)
    sql_work.mkdir(parents=True, exist_ok=True)
    write_json(sql_work / "sql-task.json", {
        "schema_version": "1.0",
        "task_id": task_id,
        "parent_migration_id": project_id,
        "source_db": source_db,
        "target_db": target_db,
        "project_path": str(work_source),
        "handoff_file": str(path),
        "resume_stage": "build",
        "resume_command": resume_command,
        "created_at": handoff["created_at"],
    })
    return handoff


def update_sql_handoff(work_dir: Path, **changes: Any) -> dict[str, Any]:
    path = sql_handoff_path(work_dir)
    handoff = load_json(path) if path.is_file() else {}
    handoff.update(changes)
    handoff["updated_at"] = now_iso()
    write_json(path, handoff)
    return handoff


def reconcile_sql_handoff(work_dir: Path, result_path: Path) -> dict[str, Any] | None:
    """Reconcile a completed SQL result into Java's durable workflow state.

    This is the fallback when the detached watcher was lost.  It does not apply
    the patch itself; it makes the SQL stage resumable on the next controller
    iteration, where normal stage_sql validation remains authoritative.
    """
    path = sql_handoff_path(work_dir)
    if not path.is_file():
        return None
    handoff = load_json(path)
    report_file = Path(str(handoff.get("result_file") or ""))
    if not report_file.is_file():
        return handoff
    try:
        sql_result = load_json(report_file)
    except MigrationError:
        return handoff
    status = str(sql_result.get("status") or "").upper()
    if status not in {"SUCCESS", "COMPLETED_WITH_ACTIONS"}:
        return handoff
    if str(handoff.get("status") or "") not in {"SQL_APPLIED", "JAVA_RESUME_COMPLETED"}:
        handoff = update_sql_handoff(
            work_dir,
            status="SQL_COMPLETED",
            sql_status=status,
            sql_completed_at=now_iso(),
        )
    if result_path.is_file():
        result = load_json(result_path)
        state = result.get("workflow") if isinstance(result.get("workflow"), dict) else {}
        if str(result.get("stage") or "").upper() == "SQL" or str(result.get("status") or "").upper() == "WAITING_FOR_SQL":
            state["current_stage"] = "SQL"
            state["next_stage"] = "sql"
            state["waiting_for"] = ""
            result["workflow"] = state
            result["status"] = "IN_PROGRESS"
            result["reason_code"] = ""
            result["message"] = "SQL migration completed; Java migration is ready to resume."
            write_json(result_path, result)
    return handoff


def capture_source_compatibility_patch(work_dir: Path, work_source: Path, base_tree: str) -> dict[str, Any]:
    patch_path = work_dir / "reports" / "source-compatibility.patch"
    # Preserve the pre-SQL compatibility patch after SQL changes have already
    # been applied to the same worktree.
    sql_patch_state = work_dir / "sql-patch-state.json"
    if patch_path.is_file() and sql_patch_state.is_file():
        return {
            "path": str(patch_path),
            "sha256": sha256_file(patch_path),
            "size": patch_path.stat().st_size,
            "changed_files": [],
            "base_tree": base_tree,
        }
    return write_git_patch_from_tree(work_source, base_tree, patch_path)

def stage_prepare(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any]) -> int:
    metadata = load_json(work_dir / "workspace.json")
    clear_current_error(result)
    result.update({
        "status": "IN_PROGRESS",
        "stage": "PREPARE",
        "workspace": metadata,
    })
    write_json(result_path, result)
    return EXIT_OK

def stage_inspect(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    build_command = str(config.get("build_command") or "").strip()
    detected_kind = str(config.get("build_command_source") or "detected").strip() or "detected"
    if not build_command:
        build_command, detected_kind = detect_build_command(work_source)
        if build_command:
            config["build_command"] = build_command
            config["build_command_source"] = "detected"
            config["updated_at"] = now_iso()
            write_json(config_path(work_dir), config)
    if not build_command:
        result.update({
            "status": "BLOCKED",
            "stage": "INSPECT",
            "reason_code": "BUILD_COMMAND_NOT_DETECTED",
            "message": "Unable to detect a supported Maven, Gradle, or Ant build entry from the project.",
            "action_required": {
                "type": "FIX_OR_STANDARDIZE_BUILD_ENTRY",
                "work_source": str(work_source),
                "supported_builds": ["Maven", "Gradle", "Ant"],
            },
        })
        write_json(result_path, result)
        return EXIT_FAILED
    if not command_exists(build_command, work_source):
        first = shlex.split(build_command)[0]
        result.update({
            "status": "BLOCKED",
            "stage": "INSPECT",
            "reason_code": "BUILD_TOOL_NOT_FOUND",
            "message": "Detected build executable is unavailable: %s" % first,
        })
        write_json(result_path, result)
        return EXIT_FAILED
    profile = detect_project_profile(work_source, build_command, detected_kind)
    clear_current_error(result)
    result.update({"status": "IN_PROGRESS", "stage": "INSPECT", "project": profile})
    write_json(result_path, result)
    return EXIT_OK

def stage_baseline(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    build_command = str(config.get("build_command") or "").strip()
    if not build_command:
        raise MigrationError("BUILD_COMMAND_STATE_MISSING", "Inspect stage did not persist an auto-detected build command")

    existing = result.get("baseline") if isinstance(result.get("baseline"), dict) else {}
    attempt = int(existing.get("attempt") or 0) + 1
    log_path = work_dir / "logs" / ("baseline-build-attempt-%03d.log" % attempt)
    cleanup_untracked_build_outputs(work_source)
    proc = run_shell(build_command, cwd=work_source, log_path=log_path, env=build_environment(work_dir), check=False)
    cleaned_outputs = cleanup_untracked_build_outputs(work_source) if proc.returncode == 0 else []
    baseline = {
        "attempt": attempt,
        "command": build_command,
        "exit_code": proc.returncode,
        "log": str(log_path),
        "status": "SUCCESS" if proc.returncode == 0 else "FAILED",
        "cleaned_build_outputs": cleaned_outputs,
    }
    result["baseline"] = baseline
    if proc.returncode != 0:
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "BASELINE",
            "reason_code": "BASELINE_BUILD_FAILED",
            "message": "Baseline build failed. Fix the original project build environment before migration continues.",
            "action_required": {
                "type": "FIX_BASELINE_BUILD",
                "build_command": build_command,
                "log": str(log_path),
            },
        })
        write_json(result_path, result)
        return EXIT_NEEDS_FIX
    clear_current_error(result)
    result.update({"status": "IN_PROGRESS", "stage": "BASELINE", "baseline": baseline})
    write_json(result_path, result)
    return EXIT_OK

def stage_compatibility(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    compatibility = result.get("compatibility") if isinstance(result.get("compatibility"), dict) else {}
    ai_migration = resolve_ai_migration(work_dir)
    # Build validation is performed by baseline/final build stages.  The DevKit
    # source scan itself only receives dynamically detected source languages.
    require_baseline_build_command(result, config)
    compatibility_base_tree = str(compatibility.get("baseline_tree") or "").strip()
    if not compatibility_base_tree:
        compatibility_base_tree = git_worktree_tree(work_source)
        compatibility["baseline_tree"] = compatibility_base_tree
        result["compatibility"] = compatibility
        write_json(result_path, result)
    attempt = int(compatibility.get("attempt") or 0) + 1
    report_dir = work_dir / "reports" / "ai-migration-source" / ("attempt-%03d" % attempt)
    report_dir.mkdir(parents=True, exist_ok=True)
    log_path = work_dir / "logs" / "ai-migration-source.log"
    source_types = detect_ai_migration_source_types(work_source)
    command = ai_migration + ["porting", "src-mig", "-i", str(work_source)]
    for source_type in source_types:
        command += ["-s", source_type]
    command += ["-o", str(report_dir), "-r", "csv"]
    proc = run_command(command, cwd=work_source, log_path=log_path, env=build_environment(work_dir), check=False)
    cleanup_untracked_build_outputs(work_source)

    # DevKit source CSV exposes a documented ``修改级别`` column.  Parse the
    # Chinese CSV for advisory data even on returncode 0 so suggestions can be
    # surfaced in the final result.  The process return code still decides
    # whether a missing/invalid report can block execution.
    reports = zh_csv_reports(report_dir)
    if proc.returncode == 0:
        inspection = {
            "findings": [],
            "rule_items": [],
            "suggestion_items": [],
            "unclassified_items": [],
            "rule_count": 0,
            "suggestion_count": 0,
            "unclassified_count": 0,
            "summary_rule_count": None,
            "summary_suggestion_count": None,
            "classification_complete": True,
            "classification_reason": "",
            "analyzed_reports": [],
        }
        report_parse_warning = ""
        if reports:
            try:
                inspection = inspect_ai_migration_source_csv_reports(reports)
            except MigrationError as exc:
                # Preserve the established returncode==0 success contract.
                # The warning is recorded because advisory extraction failed.
                report_parse_warning = "%s: %s" % (exc.code, exc)
        source_patch = capture_source_compatibility_patch(work_dir, work_source, compatibility_base_tree)
        compatibility = {
            "attempt": attempt,
            "status": "SUCCESS",
            "exit_code": 0,
            "report_dir": str(report_dir),
            "reports": [str(x) for x in reports],
            "analyzed_reports": inspection.get("analyzed_reports") or [],
            "findings": [],
            "rule_items": [],
            "suggestion_items": inspection.get("suggestion_items") or [],
            "unclassified_items": inspection.get("unclassified_items") or [],
            "rule_count": 0,
            "suggestion_count": int(inspection.get("suggestion_count") or 0),
            "unclassified_count": int(inspection.get("unclassified_count") or 0),
            "summary_rule_count": inspection.get("summary_rule_count"),
            "summary_suggestion_count": inspection.get("summary_suggestion_count"),
            "report_parse_warning": report_parse_warning,
            "source_state_sha256": git_worktree_fingerprint(work_source),
            "baseline_tree": compatibility_base_tree,
            "source_patch": source_patch,
            "log": str(log_path),
        }
        result["compatibility"] = compatibility
        clear_current_error(result)
        result.update({"status": "IN_PROGRESS", "stage": "COMPATIBILITY"})
        write_json(result_path, result)
        return EXIT_OK

    # Non-zero source scans are classified only by the documented ``修改级别``
    # field in *_zh.csv.  Rule items block and require repair; suggestion items
    # are advisory-only and never enter action_required.
    if not reports:
        result.update({
            "status": "FAILED",
            "stage": "COMPATIBILITY",
            "reason_code": "AI_MIGRATION_SOURCE_ZH_CSV_REPORT_MISSING",
            "message": "ai-migration source scan returned %s but produced no *_zh.csv report; see %s" % (proc.returncode, log_path),
            "compatibility": {
                "attempt": attempt,
                "status": "FAILED",
                "exit_code": proc.returncode,
                "report_dir": str(report_dir),
                "reports": [],
                "baseline_tree": compatibility_base_tree,
                "log": str(log_path),
            },
        })
        write_json(result_path, result)
        return EXIT_FAILED

    try:
        inspection = inspect_ai_migration_source_csv_reports(reports)
    except MigrationError as exc:
        result.update({
            "status": "FAILED",
            "stage": "COMPATIBILITY",
            "reason_code": exc.code,
            "message": str(exc),
            "compatibility": {
                "attempt": attempt,
                "status": "FAILED",
                "exit_code": proc.returncode,
                "report_dir": str(report_dir),
                "reports": [str(x) for x in reports],
                "baseline_tree": compatibility_base_tree,
                "log": str(log_path),
            },
        })
        write_json(result_path, result)
        return EXIT_FAILED

    findings = inspection["findings"]
    rule_items = inspection.get("rule_items") or []
    suggestion_items = inspection.get("suggestion_items") or []
    unclassified_items = inspection.get("unclassified_items") or []
    if not bool(inspection.get("classification_complete")):
        result.update({
            "status": "FAILED",
            "stage": "COMPATIBILITY",
            "reason_code": "AI_MIGRATION_SOURCE_CSV_CLASSIFICATION_INCOMPLETE",
            "message": inspection.get("classification_reason") or "Unable to classify all DevKit source CSV items by modification level.",
            "compatibility": {
                "attempt": attempt,
                "status": "FAILED",
                "exit_code": proc.returncode,
                "report_dir": str(report_dir),
                "reports": [str(x) for x in reports],
                "analyzed_reports": inspection.get("analyzed_reports") or [],
                "rule_items": rule_items,
                "suggestion_items": suggestion_items,
                "unclassified_items": unclassified_items,
                "rule_count": int(inspection.get("rule_count") or 0),
                "suggestion_count": int(inspection.get("suggestion_count") or 0),
                "unclassified_count": int(inspection.get("unclassified_count") or 0),
                "summary_rule_count": inspection.get("summary_rule_count"),
                "summary_suggestion_count": inspection.get("summary_suggestion_count"),
                "baseline_tree": compatibility_base_tree,
                "log": str(log_path),
            },
        })
        write_json(result_path, result)
        return EXIT_FAILED

    if not rule_items:
        source_patch = capture_source_compatibility_patch(work_dir, work_source, compatibility_base_tree)
        compatibility = {
            "attempt": attempt,
            "status": "SUCCESS_WITH_SUGGESTIONS" if suggestion_items else "SUCCESS",
            "exit_code": proc.returncode,
            "report_dir": str(report_dir),
            "reports": [str(x) for x in reports],
            "analyzed_reports": inspection.get("analyzed_reports") or [],
            "findings": [],
            "rule_items": [],
            "suggestion_items": suggestion_items,
            "unclassified_items": [],
            "rule_count": 0,
            "suggestion_count": int(inspection.get("suggestion_count") or 0),
            "unclassified_count": 0,
            "summary_rule_count": inspection.get("summary_rule_count"),
            "summary_suggestion_count": inspection.get("summary_suggestion_count"),
            "source_state_sha256": git_worktree_fingerprint(work_source),
            "baseline_tree": compatibility_base_tree,
            "source_patch": source_patch,
            "log": str(log_path),
        }
        result["compatibility"] = compatibility
        clear_current_error(result)
        result.update({
            "status": "IN_PROGRESS",
            "stage": "COMPATIBILITY",
            "message": "DevKit source scan contains suggestion items only; no source repair is required.",
        })
        write_json(result_path, result)
        return EXIT_OK

    compatibility = {
        "attempt": attempt,
        "status": "NEEDS_FIX",
        "exit_code": proc.returncode,
        "report_dir": str(report_dir),
        "reports": [str(x) for x in reports],
        "analyzed_reports": inspection.get("analyzed_reports") or [],
        "findings": findings,
        "rule_items": rule_items,
        "suggestion_items": suggestion_items,
        "unclassified_items": [],
        "rule_count": int(inspection.get("rule_count") or 0),
        "suggestion_count": int(inspection.get("suggestion_count") or 0),
        "unclassified_count": 0,
        "summary_rule_count": inspection.get("summary_rule_count"),
        "summary_suggestion_count": inspection.get("summary_suggestion_count"),
        "source_state_sha256": git_worktree_fingerprint(work_source),
        "baseline_tree": compatibility_base_tree,
        "log": str(log_path),
    }
    result["compatibility"] = compatibility
    result.update({
        "status": "NEEDS_AGENT_FIX",
        "stage": "COMPATIBILITY",
        "reason_code": "SOURCE_COMPATIBILITY_RULE_FIX_REQUIRED",
        "message": "DevKit source scan contains mandatory rule items. Fix only the rule items in the Chinese CSV report, then rerun; suggestion items do not require repair.",
        "action_required": {
            "type": "FIX_SOURCE_COMPATIBILITY_RULES",
            "exit_code": proc.returncode,
            "reports": [str(x) for x in reports],
            "rule_count": len(rule_items),
            "findings": rule_items,
        },
    })
    write_json(result_path, result)
    return EXIT_NEEDS_FIX

def stage_sql(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    route, source_db, target_db = database_route(work_dir, config)
    if route == "REQUIRED":
        result.update({
            "status": "WAITING_FOR_USER",
            "stage": "SQL",
            "reason_code": "DATABASE_ROUTE_REQUIRED",
            "message": "SQL migration is a required workflow decision. Provide --source-db/--target-db to migrate, or explicitly choose --skip-sql when SQL adaptation is not required.",
            "action_required": {
                "type": "DATABASE_ROUTE_REQUIRED",
                "decision_file": str(work_dir / "database-route.json"),
                "choices": ["MIGRATE", "SKIP"],
                "required_inputs": ["SOURCE_DB", "TARGET_DB"],
            },
        })
        write_json(result_path, result)
        return EXIT_WAITING
    if route == "SKIP":
        result.pop("sql_skill", None)
        result["sql_migration"] = {
            "status": "NOT_APPLICABLE",
            "source_db": source_db,
            "target_db": target_db,
            "decision": "SKIP",
        }
        clear_current_error(result)
        result.update({"status": "IN_PROGRESS", "stage": "SQL"})
        write_json(result_path, result)
        return EXIT_OK

    handoff = load_or_create_sql_handoff(work_dir, work_source, source_db, target_db)
    task_id = str(handoff.get("task_id") or "")
    sql_work = Path(str(handoff.get("sql_work_dir") or ""))
    report_file = Path(str(handoff.get("result_file") or ""))
    patch_file = Path(str(handoff.get("patch_file") or ""))
    if not report_file.is_file():
        handoff = update_sql_handoff(work_dir, status="WAITING_FOR_SQL")
        handoff = start_sql_resume_controller(work_dir, handoff)
        result.update({
            "status": "WAITING_FOR_SQL",
            "stage": "SQL",
            "reason_code": "SQL_MIGRATION_REQUIRED",
            "message": "The independent sql-migration task is pending. A resume controller is watching the task and will invoke --stage build after SQL finalize completes.",
            "sql_skill": {
                "PROJECT_PATH": str(work_source),
                "WORK_DIR": str(sql_work),
                "SOURCE_DB": source_db,
                "TARGET_DB": target_db,
            },
            "action_required": {
                "type": "RUN_SQL_MIGRATION",
                "requires_action": True,
                "task_id": task_id,
                "skill": "sql-migration",
                "inputs": {
                    "PROJECT_PATH": str(work_source),
                    "WORK_DIR": str(sql_work),
                    "SOURCE_DB": source_db,
                    "TARGET_DB": target_db,
                },
                "handoff_file": str(sql_handoff_path(work_dir)),
                "result_file": str(report_file),
                "message": "Invoke the independent sql-migration Skill with exactly these inputs. The Java resume controller only watches for SQL finalize; it does not execute the SQL Skill itself.",
            },
            "sql_migration": {
                "task_id": task_id,
                "handoff_file": str(sql_handoff_path(work_dir)),
                "status": "WAITING_FOR_SQL",
                "source_db": source_db,
                "target_db": target_db,
                "work_dir": str(sql_work),
                "result_file": str(report_file),
                "patch_file": str(patch_file),
                "resume_stage": "build",
                "controller": handoff.get("controller") or {},
            },
        })
        write_json(result_path, result)
        return EXIT_WAITING

    sql_result = load_json(report_file)
    status = str(sql_result.get("status") or "").upper()
    counts = sql_result_counts(sql_result)
    # Keep a stable SQL source patch address in the Java final summary even
    # when the SQL task has no application-source changes.
    if not patch_file.is_file():
        patch_file.parent.mkdir(parents=True, exist_ok=True)
        patch_file.write_bytes(b"")
    result_hash = sha256_file(report_file)
    patch_hash = sha256_file(patch_file)
    sql_state = {
        "task_id": task_id,
        "handoff_file": str(sql_handoff_path(work_dir)),
        "status": status,
        "source_status": status,
        "source_db": source_db,
        "target_db": target_db,
        "counts": counts,
        "work_dir": str(sql_work),
        "result_file": str(report_file),
        "patch_file": str(patch_file),
        "sql_result_sha256": result_hash,
        "source_patch_sha256": patch_hash,
    }
    if status == "SUCCESS":
        sql_state["decision"] = "AUTO"
        sql_state["patch_state"] = apply_sql_patch(work_dir, work_source, report_file, patch_file)
        result["sql_migration"] = sql_state
        result.pop("sql_skill", None)
        update_sql_handoff(
            work_dir,
            status="SQL_APPLIED",
            sql_status=status,
            sql_result_sha256=result_hash,
            source_patch_sha256=patch_hash,
            patch_state=sql_state["patch_state"],
            sql_completed_at=now_iso(),
        )
        clear_current_error(result)
        result.update({"status": "IN_PROGRESS", "stage": "SQL"})
        write_json(result_path, result)
        return EXIT_OK
    if status == "COMPLETED_WITH_ACTIONS":
        request = {
            "reason": "SQL_MIGRATION_ACTION_REQUIRED",
            "source_status": status,
            "counts": counts,
            "result_file": str(report_file),
            "patch_file": str(patch_file),
            "sql_result_sha256": result_hash,
            "source_patch_sha256": patch_hash,
            "decision_file": str(work_dir / "sql-migration-decision.json"),
            "decision": "CONTINUE_WITH_PENDING",
        }
        decision = ensure_sql_continue_decision(work_dir, request, task_id)
        sql_state["decision"] = "CONTINUE_WITH_PENDING"
        sql_state["decision_origin"] = decision.get("decision_origin") or "AUTO_POLICY"
        sql_state["decision_file"] = str(work_dir / "sql-migration-decision.json")
        sql_state["patch_state"] = apply_sql_patch(work_dir, work_source, report_file, patch_file)
        result["sql_migration"] = sql_state
        result.pop("sql_skill", None)
        update_sql_handoff(
            work_dir,
            status="SQL_APPLIED",
            sql_status=status,
            sql_result_sha256=result_hash,
            source_patch_sha256=patch_hash,
            decision="CONTINUE_WITH_PENDING",
            decision_origin=sql_state["decision_origin"],
            patch_state=sql_state["patch_state"],
            sql_completed_at=now_iso(),
        )
        clear_current_error(result)
        result.update({"status": "IN_PROGRESS", "stage": "SQL"})
        write_json(result_path, result)
        return EXIT_OK
    update_sql_handoff(work_dir, status="SQL_FAILED", sql_status=status, sql_completed_at=now_iso())
    result["sql_migration"] = sql_state
    result.update({
        "status": "BLOCKED",
        "stage": "SQL",
        "reason_code": "SQL_MIGRATION_NOT_READY",
        "message": "SQL migration result status is %s." % (status or "<empty>"),
    })
    write_json(result_path, result)
    return EXIT_FAILED

SOURCE_STAGES = ["prepare", "inspect", "baseline", "compatibility", "sql"]


def run_stage(
    stage: str,
    work_dir: Path,
    work_source: Path,
    result_path: Path,
    result: dict[str, Any],
    config: dict[str, Any],
) -> int:
    if stage == "prepare":
        return stage_prepare(work_dir, work_source, result_path, result)
    if stage == "inspect":
        return stage_inspect(work_dir, work_source, result_path, result, config)
    if stage == "baseline":
        return stage_baseline(work_dir, work_source, result_path, result, config)
    if stage == "compatibility":
        return stage_compatibility(work_dir, work_source, result_path, result, config)
    if stage == "sql":
        return stage_sql(work_dir, work_source, result_path, result, config)
    raise MigrationError("INVALID_SOURCE_STAGE", "Unknown source-migration stage: %s" % stage)
