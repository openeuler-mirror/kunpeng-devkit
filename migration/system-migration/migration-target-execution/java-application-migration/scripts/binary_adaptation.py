from __future__ import annotations
import hashlib
import os
import shutil
import struct
from pathlib import Path
from typing import Any

from migration_common import (
    EXIT_NEEDS_AGENT_FIX, EXIT_OK,
    MigrationError,
)
from migration_common import load_json, write_json, run, java_tool


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sql_counts(sql_result: dict[str, Any]) -> dict[str, int]:
    raw = sql_result.get("counts") or {}
    result: dict[str, int] = {}
    for key in ("compatible", "migrated", "todo", "pending_confirm", "manual_review"):
        try:
            result[key] = int(raw.get(key) or 0)
        except (TypeError, ValueError):
            result[key] = 0
    return result


def ensure_sql_patch(
    input_data: dict[str, Any],
    patch_root: Path,
    patch_file: Path,
    work_dir: Path,
    log_dir: Path,
) -> dict[str, Any]:
    """Resolve SQL migration output without mutating the SQL Skill result.

    The component-local decision file records only the user's decision.  It is
    deliberately not coupled to result/Patch SHA256 signatures; the current SQL
    result status and Patch presence are checked when the decision is consumed.
    """
    config = input_data.get("sql_migration") or {}
    if not config.get("enabled", True) or str(config.get("mode", "AGENT_SKILL")).upper() == "DISABLED":
        return {"action": "READY", "source_status": "DISABLED", "counts": {}}
    mode = str(config.get("mode", "AGENT_SKILL")).upper()
    if mode != "AGENT_SKILL":
        raise MigrationError("UNSUPPORTED_SQL_MODE", f"sql migration mode must be 'AGENT_SKILL', got '{mode}'")
    sql_work_dir = Path(str(config.get("work_dir") or (work_dir / "sql-migration"))).expanduser().resolve()
    result_file = (sql_work_dir / "reports" / "sql-migration-result.json").resolve()
    source_patch = (sql_work_dir / "reports" / "source_code.patch").resolve()
    decision_file = work_dir / "sql-migration-decision.json"

    if not result_file.is_file():
        # A stale decision must never authorize a future SQL result.  Starting a
        # fresh SQL boundary clears only the component-local decision record.
        try:
            decision_file.unlink()
        except FileNotFoundError:
            pass
        return {
            "action": "CALL_SQL_SKILL",
            "result_file": str(result_file),
            "source_patch": str(source_patch),
            "decision_file": str(decision_file),
        }
    try:
        sql_result = load_json(result_file)
    except Exception as exc:
        raise MigrationError("INVALID_SQL_MIGRATION_RESULT", f"cannot read SQL migration result: {result_file}: {exc}") from exc

    status = str(sql_result.get("status") or "").strip().upper()
    counts = _sql_counts(sql_result)
    summary = {
        "source_status": status,
        "counts": counts,
        "result_file": str(result_file),
        "source_patch": str(source_patch),
        "decision_file": str(decision_file),
    }

    if status == "COMPLETED_WITH_ACTIONS":
        if not decision_file.is_file():
            return dict(summary, action="WAITING_FOR_DECISION")
        try:
            decision = load_json(decision_file)
        except Exception as exc:
            raise MigrationError("INVALID_SQL_MIGRATION_DECISION", f"cannot read SQL migration decision: {decision_file}: {exc}") from exc
        decision_source = str(decision.get("decision_source") or "").strip().upper()
        if decision_source != "USER":
            raise MigrationError(
                "SQL_MIGRATION_USER_CONFIRMATION_REQUIRED",
                "SQL migration continuation requires an explicit user decision; current decision source is '%s'"
                % (decision_source or "<empty>"),
                status="BLOCKED",
            )
        decision_value = str(decision.get("decision") or "").strip().upper()
        if decision_value != "CONTINUE_WITH_PENDING":
            raise MigrationError(
                "SQL_MIGRATION_PENDING_NOT_APPROVED",
                f"SQL migration has pending actions and decision is '{decision_value or '<empty>'}'",
                status="BLOCKED",
            )
        if not source_patch.is_file():
            raise MigrationError("SQL_PATCH_MISSING", f"sql-migration result has no source_code.patch: {source_patch}")
        patch_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_patch, patch_file)
        return dict(summary, action="READY", decision="CONTINUE_WITH_PENDING")

    if status != "SUCCESS":
        raise MigrationError(
            "SQL_MIGRATION_NOT_SUCCESS",
            f"sql-migration did not finish successfully: status={status or '<empty>'}; result={result_file}",
        )
    if not source_patch.is_file():
        raise MigrationError("SQL_PATCH_MISSING", f"sql-migration SUCCESS result has no source_code.patch: {source_patch}")
    # SUCCESS needs no user decision.  Remove an obsolete decision from an older
    # COMPLETED_WITH_ACTIONS result before consuming the current Patch.
    try:
        decision_file.unlink()
    except FileNotFoundError:
        pass
    patch_file.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_patch, patch_file)
    return dict(summary, action="READY", decision="AUTO")

def apply_patch(patch_root: Path, patch_file: Path, marker: Path, log_dir: Path) -> None:
    if not patch_file.is_file():
        return
    patch_sha256 = _sha256_file(patch_file)
    if marker.exists():
        state = load_json(marker)
        if str(state.get("source_patch_sha256") or "").lower() == patch_sha256.lower():
            return
        raise MigrationError(
            "STALE_SQL_PATCH_STATE",
            "SQL patch changed after it was applied; start a new component migration work directory before continuing",
            status="BLOCKED",
        )
    if patch_file.stat().st_size == 0:
        write_json(marker, {
            "applied": True, "empty": True, "patch_file": str(patch_file),
            "source_patch_sha256": patch_sha256,
        })
        return
    proc = run(["git", "apply", "--check", str(patch_file)], log_dir / "patch.log", cwd=patch_root, check=False)
    if proc.returncode != 0:
        raise MigrationError("FAILED_PATCH_CONFLICT", f"SQL patch cannot be applied; see {log_dir / 'patch.log'}", status="NEEDS_AGENT_FIX")
    run(["git", "apply", str(patch_file)], log_dir / "patch.log", cwd=patch_root)
    write_json(marker, {
        "applied": True, "empty": False, "patch_file": str(patch_file),
        "source_patch_sha256": patch_sha256,
    })

def git_changes(patch_root: Path, log_dir: Path) -> list[dict[str, str]]:
    # SQL patches may add new Java/resource files. Ask Git to enumerate
    # untracked files individually; the default collapses a new directory to
    # ``?? path/`` and incremental compilation would otherwise miss the files.
    proc = run(["git", "status", "--porcelain", "--untracked-files=all"], log_dir / "git.log", cwd=patch_root, check=False)
    changes: list[dict[str, str]] = []
    for line in (proc.stdout or "").splitlines():
        if len(line) < 4:
            continue
        status = line[:2].strip() or "M"
        path = line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        changes.append({"status": status, "path": path})
    return changes

def class_release(classes_dir: Path) -> int | None:
    releases: list[int] = []
    for path in classes_dir.rglob("*.class"):
        try:
            data = path.read_bytes()[:8]
            if len(data) == 8 and data[:4] == b"\xca\xfe\xba\xbe":
                major = struct.unpack(">H", data[6:8])[0]
                if major >= 45:
                    releases.append(major - 44)
        except OSError:
            continue
    return max(releases) if releases else None

def compile_changed_java(
    changes: list[dict[str, str]],
    patch_root: Path,
    classes_dir: Path,
    lib_dir: Path,
    compiled_dir: Path,
    input_data: dict[str, Any],
    log_dir: Path,
    work_dir: Path,
    *,
    source_prefix: str = "src/main/java",
    extra_classpath: list[Path] | None = None,
    module_id: str = "root",
) -> tuple[list[str], int]:
    prefix = source_prefix.rstrip("/") + "/"
    java_paths = [
        patch_root / c["path"]
        for c in changes
        if c["path"].startswith(prefix) and c["path"].endswith(".java") and c["status"] != "D"
    ]
    if not java_paths:
        return [], EXIT_OK
    for c in changes:
        if c["status"] == "D":
            raise MigrationError("UNSUPPORTED_PATCH_DELETE", f"Automatic package update does not allow deletion: {c['path']}")
    jdk_home = input_data.get("migration_jdk_home")
    javac = java_tool(jdk_home, "javac")
    compiled_dir.mkdir(parents=True, exist_ok=True)
    release = class_release(classes_dir)
    classpath_items = [str(classes_dir), str(compiled_dir)]
    for extra in extra_classpath or []:
        if extra.exists():
            classpath_items.append(str(extra))
    if lib_dir.is_dir():
        classpath_items.append(str(lib_dir / "*"))
    command = [
        javac,
        "-encoding", "UTF-8",
        "-proc:none",
        "-cp", os.pathsep.join(classpath_items),
        "-sourcepath", str(patch_root / source_prefix),
        "-d", str(compiled_dir),
    ]
    if release:
        command += ["--release", str(release)]
    command += [str(p) for p in java_paths]
    safe_module = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in module_id)
    javac_log = log_dir / ("javac.log" if module_id == "root" else f"javac-{safe_module}.log")
    proc = run(command, javac_log, check=False)
    if proc.returncode == 0:
        return [str(p.relative_to(patch_root)) for p in java_paths], EXIT_OK

    attempts_file = work_dir / ("compile-fix-attempts.json" if module_id == "root" else f"compile-fix-attempts-{safe_module}.json")
    attempts = load_json(attempts_file).get("attempts", 0) if attempts_file.exists() else 0
    max_attempts = 3
    if attempts >= max_attempts:
        raise MigrationError(
            "FAILED_DECOMPILED_SOURCE_RECOMPILE",
            f"javac still fails after {max_attempts} Agent repair attempts",
        )
    write_json(attempts_file, {"attempts": attempts + 1})
    return [str(p.relative_to(patch_root)) for p in java_paths], EXIT_NEEDS_AGENT_FIX
