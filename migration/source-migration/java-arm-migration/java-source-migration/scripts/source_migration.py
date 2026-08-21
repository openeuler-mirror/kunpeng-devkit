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
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_SCRIPTS = SCRIPT_DIR.parent.parent / "scripts"
if str(ROOT_SCRIPTS) not in __import__("sys").path:
    __import__("sys").path.insert(0, str(ROOT_SCRIPTS))

from migration_common import (
    EXIT_FAILED, EXIT_NEEDS_FIX, EXIT_OK, EXIT_WAITING, MigrationError,
    analyze_devkit_reports, build_environment, cleanup_untracked_build_outputs,
    clear_current_error, config_path, database_route,
    json_reports, load_json, now_iso, require_baseline_build_command, resolve_devkit,
    run_command, run_shell, sha256_file, write_json,
)

TEXT_HOTSPOT_SUFFIXES = {
    ".java", ".xml", ".gradle", ".kts", ".properties", ".yml", ".yaml",
    ".sh", ".bash", ".bat", ".cmd", ".conf", ".ini", ".toml",
}
HOTSPOT_PATTERN = re.compile(
    r"x86_64|amd64|(?<![A-Za-z0-9_])x86(?![A-Za-z0-9_])|aarch64|arm64|"
    r"os\.arch|System\.load(?:Library)?|\bJNI\b|\bJNA\b",
    re.I,
)
NATIVE_SUFFIXES = {".so", ".a", ".dll", ".dylib"}
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

def scan_architecture_hotspots(work_source: Path, limit: int = 300) -> dict[str, Any]:
    text_hits = []
    native_files = []
    skipped_dirs = {".git", "target", "build", "dist", "out", ".gradle", "node_modules"}
    for root, dirs, files in os.walk(str(work_source)):
        dirs[:] = [name for name in dirs if name not in skipped_dirs]
        root_path = Path(root)
        for name in files:
            path = root_path / name
            suffix = path.suffix.lower()
            try:
                relative = str(path.relative_to(work_source))
            except ValueError:
                continue
            if suffix in NATIVE_SUFFIXES:
                if len(native_files) < limit:
                    native_files.append(relative)
                continue
            if suffix not in TEXT_HOTSPOT_SUFFIXES and name not in {"pom.xml", "Dockerfile"}:
                continue
            try:
                if path.stat().st_size > 2 * 1024 * 1024:
                    continue
                with path.open("r", encoding="utf-8", errors="replace") as fh:
                    for line_number, line in enumerate(fh, 1):
                        if HOTSPOT_PATTERN.search(line):
                            text_hits.append({
                                "path": relative,
                                "line": line_number,
                                "text": line.strip()[:500],
                            })
                            if len(text_hits) >= limit:
                                break
            except OSError:
                continue
            if len(text_hits) >= limit:
                break
        if len(text_hits) >= limit:
            break
    return {
        "text_hits": text_hits,
        "native_files": native_files,
        "truncated": len(text_hits) >= limit or len(native_files) >= limit,
    }

def compatibility_review_hash(reports: list[Path], hotspots: dict[str, Any]) -> str:
    payload = {
        "reports": sorted(sha256_file(path) for path in reports),
        "hotspots": hotspots,
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

def compatibility_review_decision(work_dir: Path, review_sha256: str) -> str:
    path = work_dir / "compatibility-review.json"
    if not path.is_file():
        return ""
    try:
        data = load_json(path)
    except MigrationError:
        return ""
    if str(data.get("review_sha256") or "") != review_sha256:
        return ""
    return "PASS_REVIEW" if str(data.get("decision") or "").upper() == "PASS_REVIEW" else ""

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
        ["git", "apply", "--check", str(patch_file)],
        cwd=work_source,
        log_path=work_dir / "logs" / "sql-patch.log",
        check=False,
    )
    if check_proc.returncode != 0:
        raise MigrationError("SQL_PATCH_CONFLICT", "SQL patch does not apply cleanly; see logs/sql-patch.log", status="NEEDS_AGENT_FIX")
    apply_proc = run_command(
        ["git", "apply", str(patch_file)],
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
    detected_kind = "configured"
    if not build_command:
        build_command, detected_kind = detect_build_command(work_source)
        if build_command:
            config["build_command"] = build_command
            config["build_command_source"] = "detected"
            config["updated_at"] = now_iso()
            write_json(config_path(work_dir), config)
    if not build_command:
        result.update({
            "status": "WAITING_FOR_USER",
            "stage": "INSPECT",
            "reason_code": "BUILD_COMMAND_REQUIRED",
            "message": "Build command is required.",
            "action_required": {
                "type": "PROVIDE_BUILD_COMMAND",
                "work_source": str(work_source),
                "resume": "python3 scripts/run_migration.py --source <project> --stage auto --build-command '<command>'",
            },
        })
        write_json(result_path, result)
        return EXIT_WAITING
    if not command_exists(build_command, work_source):
        first = shlex.split(build_command)[0]
        result.update({
            "status": "BLOCKED",
            "stage": "INSPECT",
            "reason_code": "BUILD_TOOL_NOT_FOUND",
            "message": "Build command is configured but its executable is unavailable: %s" % first,
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
        raise MigrationError("BUILD_COMMAND_REQUIRED", "Inspect stage did not resolve build command")

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
    prior_review_hash = str(compatibility.get("review_sha256") or "")
    prior_source_state = str(compatibility.get("source_state_sha256") or "")
    current_source_state = git_worktree_fingerprint(work_source)
    if prior_review_hash and prior_source_state == current_source_state:
        prior_decision = compatibility_review_decision(work_dir, prior_review_hash)
        prior_findings = compatibility.get("findings") if isinstance(compatibility.get("findings"), list) else []
        if prior_decision == "PASS_REVIEW" and not prior_findings:
            compatibility["status"] = "SUCCESS"
            compatibility["review_decision"] = prior_decision
            result["compatibility"] = compatibility
            clear_current_error(result)
            result.update({"status": "IN_PROGRESS", "stage": "COMPATIBILITY"})
            write_json(result_path, result)
            return EXIT_OK
    devkit = resolve_devkit(config)
    build_command = require_baseline_build_command(result, config)
    attempt = int(compatibility.get("attempt") or 0) + 1
    report_dir = work_dir / "reports" / "devkit-source" / ("attempt-%03d" % attempt)
    report_dir.mkdir(parents=True, exist_ok=True)
    log_path = work_dir / "logs" / "devkit-source.log"
    source_types = ["java", "python", "scala"]
    interpreted_only = all(t in {"java", "python", "scala"} for t in source_types)
    command = devkit + ["porting", "src-mig", "-i", str(work_source)]
    for source_type in source_types:
        command += ["-s", source_type]
    # DevKit rejects -c/--cmd when only interpreted (Java/Python/Scala) sources are scanned.
    if not interpreted_only:
        command += ["-c", build_command]
    command += ["-o", str(report_dir), "-r", "json"]
    proc = run_command(command, cwd=work_source, log_path=log_path, env=build_environment(work_dir), check=False)
    cleanup_untracked_build_outputs(work_source)
    if proc.returncode != 0:
        result.update({
            "status": "FAILED",
            "stage": "COMPATIBILITY",
            "reason_code": "DEVKIT_SOURCE_SCAN_FAILED",
            "message": "DevKit source scan failed; see %s" % log_path,
            "compatibility": {"attempt": attempt, "status": "FAILED", "report_dir": str(report_dir), "log": str(log_path)},
        })
        write_json(result_path, result)
        return EXIT_FAILED
    reports = json_reports(report_dir)
    if not reports:
        result.update({
            "status": "FAILED",
            "stage": "COMPATIBILITY",
            "reason_code": "DEVKIT_SOURCE_REPORT_MISSING",
            "message": "DevKit source scan produced no JSON report.",
        })
        write_json(result_path, result)
        return EXIT_FAILED

    findings = analyze_devkit_reports(reports)
    hotspots = scan_architecture_hotspots(work_source)
    hotspot_path = work_dir / "reports" / "source-architecture-hotspots.json"
    write_json(hotspot_path, hotspots)
    review_sha256 = compatibility_review_hash(reports, hotspots)
    review_decision = compatibility_review_decision(work_dir, review_sha256)
    has_hotspots = bool(hotspots.get("text_hits") or hotspots.get("native_files"))
    review_passed = review_decision == "PASS_REVIEW" and not findings

    compatibility = {
        "attempt": attempt,
        "status": "SUCCESS" if not findings and (not has_hotspots or review_passed) else "NEEDS_REVIEW",
        "report_dir": str(report_dir),
        "reports": [str(x) for x in reports],
        "findings": findings,
        "hotspots": str(hotspot_path),
        "hotspot_counts": {
            "text": len(hotspots.get("text_hits") or []),
            "native_files": len(hotspots.get("native_files") or []),
        },
        "review_sha256": review_sha256,
        "source_state_sha256": git_worktree_fingerprint(work_source),
        "review_decision": review_decision,
        "log": str(log_path),
    }
    result["compatibility"] = compatibility

    if findings or (has_hotspots and not review_passed):
        result.update({
            "status": "NEEDS_AGENT_FIX",
            "stage": "COMPATIBILITY",
            "reason_code": "SOURCE_COMPATIBILITY_REVIEW_REQUIRED",
            "message": "Fix DevKit findings or review architecture-sensitive items, then rerun auto.",
            "action_required": {
                "type": "FIX_OR_REVIEW_COMPATIBILITY",
                "report_dir": str(report_dir),
                "findings": findings,
                "hotspots": str(hotspot_path),
                "hotspot_counts": compatibility["hotspot_counts"],
                "review_sha256": review_sha256,
                "review_file": str(work_dir / "compatibility-review.json"),
                "review_decision": "PASS_REVIEW",
            },
        })
        write_json(result_path, result)
        return EXIT_NEEDS_FIX

    clear_current_error(result)
    result.update({"status": "IN_PROGRESS", "stage": "COMPATIBILITY", "compatibility": compatibility})
    write_json(result_path, result)
    return EXIT_OK

def stage_sql(work_dir: Path, work_source: Path, result_path: Path, result: dict[str, Any], config: dict[str, Any]) -> int:
    route, source_db, target_db = database_route(work_dir, config)
    if route == "REQUIRED":
        result.update({
            "status": "WAITING_FOR_USER",
            "stage": "SQL",
            "reason_code": "DATABASE_ROUTE_REQUIRED",
            "message": "Database migration route has not been provided.",
            "action_required": {
                "type": "DATABASE_ROUTE_REQUIRED",
                "decision_file": str(work_dir / "database-route.json"),
                "choices": ["MIGRATE", "SKIP"],
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

    sql_work = work_dir / "sql-migration"
    report_file = sql_work / "reports" / "sql-migration-result.json"
    patch_file = sql_work / "reports" / "source_code.patch"
    if not report_file.is_file():
        result.update({
            "status": "WAITING_FOR_SKILL",
            "stage": "SQL",
            "reason_code": "CALL_SQL_MIGRATION",
            "message": "Execute the independent sql-migration Skill directly in the current main Agent, then rerun auto.",
            "sql_skill": {
                "PROJECT_PATH": str(work_source),
                "WORK_DIR": str(sql_work),
                "SOURCE_DB": source_db,
                "TARGET_DB": target_db,
            },
            "sql_migration": {
                "status": "WAITING_FOR_SKILL",
                "source_db": source_db,
                "target_db": target_db,
                "result_file": str(report_file),
                "patch_file": str(patch_file),
            },
        })
        write_json(result_path, result)
        return EXIT_WAITING

    sql_result = load_json(report_file)
    status = str(sql_result.get("status") or "").upper()
    counts = sql_result_counts(sql_result)
    result_hash = sha256_file(report_file)
    patch_hash = sha256_file(patch_file) if patch_file.is_file() else ""
    sql_state = {
        "status": status,
        "source_status": status,
        "source_db": source_db,
        "target_db": target_db,
        "counts": counts,
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
        if not valid_sql_decision(work_dir, request):
            sql_state["decision"] = "WAITING"
            result["sql_migration"] = sql_state
            result.update({
                "status": "WAITING_FOR_USER",
                "stage": "SQL",
                "reason_code": "SQL_MIGRATION_ACTION_REQUIRED",
                "message": "SQL migration contains pending actions. The SQL result is kept unchanged; record an application-side continue decision to proceed.",
                "action_required": {"type": "SQL_MIGRATION_ACTION_REQUIRED", **request},
            })
            write_json(result_path, result)
            return EXIT_WAITING
        sql_state["decision"] = "CONTINUE_WITH_PENDING"
        sql_state["patch_state"] = apply_sql_patch(work_dir, work_source, report_file, patch_file)
        result["sql_migration"] = sql_state
        result.pop("sql_skill", None)
        clear_current_error(result)
        result.update({"status": "IN_PROGRESS", "stage": "SQL"})
        write_json(result_path, result)
        return EXIT_OK
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
