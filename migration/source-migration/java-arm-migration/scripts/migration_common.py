#!/usr/bin/env python3
"""Shared runtime helpers for Java source ARM64 migration."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

EXIT_OK = 0
EXIT_FAILED = 2
EXIT_WAITING = 20
EXIT_NEEDS_FIX = 21

class MigrationError(RuntimeError):
    def __init__(self, code: str, message: str, status: str = "FAILED") -> None:
        RuntimeError.__init__(self, message)
        self.code = code
        self.status = status

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)

def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MigrationError("INVALID_JSON", "%s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise MigrationError("INVALID_JSON", "JSON root must be an object: %s" % path)
    return data

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()

def shell_join(args: list[str]) -> str:
    return " ".join(shlex.quote(str(x)) for x in args)

def append_command_log(log_path: Path, command: str, output: str, returncode: int) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write("$ %s\n" % command)
        fh.write(output or "")
        if output and not output.endswith("\n"):
            fh.write("\n")
        fh.write("[exit=%s]\n" % returncode)

def run_shell(
    command: str,
    *,
    cwd: Path,
    log_path: Path,
    env: dict[str, str] | None = None,
    timeout: int = 3600,
    check: bool = False,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        ["bash", "-lc", command],
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    append_command_log(log_path, command, proc.stdout or "", proc.returncode)
    if check and proc.returncode != 0:
        raise MigrationError("COMMAND_FAILED", "Command failed (%s): %s" % (proc.returncode, command))
    return proc

def run_command(
    args: list[str],
    *,
    cwd: Path,
    log_path: Path,
    env: dict[str, str] | None = None,
    timeout: int = 3600,
    check: bool = False,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    append_command_log(log_path, shell_join(args), proc.stdout or "", proc.returncode)
    if check and proc.returncode != 0:
        raise MigrationError("COMMAND_FAILED", "Command failed (%s): %s" % (proc.returncode, args[0]))
    return proc

def clear_current_error(result: dict[str, Any]) -> None:
    result["reason_code"] = ""
    result["message"] = ""
    result.pop("action_required", None)

def config_path(work_dir: Path) -> Path:
    return work_dir / "migration-config.json"

def load_config(work_dir: Path) -> dict[str, Any]:
    path = config_path(work_dir)
    return load_json(path) if path.is_file() else {}

def build_environment(work_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    tmp_dir = work_dir / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    env["TMPDIR"] = str(tmp_dir)
    env["TMP"] = str(tmp_dir)
    env["TEMP"] = str(tmp_dir)

    # Preserve the project's normal Maven/Gradle configuration by default.
    # Cache isolation is opt-in because ~/.m2/settings.xml, ~/.gradle/init.d,
    # credentials, and existing dependency caches may be part of a valid
    # baseline build environment.
    if os.environ.get("JAVA_ARM_MIGRATION_ISOLATE_CACHE") == "1":
        gradle_home = work_dir / "cache" / "gradle"
        maven_repo = work_dir / "cache" / "maven" / "repository"
        gradle_home.mkdir(parents=True, exist_ok=True)
        maven_repo.mkdir(parents=True, exist_ok=True)
        env["GRADLE_USER_HOME"] = str(gradle_home)
        maven_opts = env.get("MAVEN_OPTS", "").strip()
        local_repo_opt = "-Dmaven.repo.local=%s" % maven_repo
        if local_repo_opt not in maven_opts:
            maven_opts = (maven_opts + " " + local_repo_opt).strip()
        env["MAVEN_OPTS"] = maven_opts
    return env

def resolve_devkit(config: dict[str, Any]) -> list[str]:
    configured = str(config.get("devkit_command") or os.environ.get("KUNPENG_DEVKIT_COMMAND") or "").strip()
    if configured:
        parts = shlex.split(configured)
        if parts:
            executable = parts[0]
            if "/" in executable:
                executable_path = Path(executable).expanduser()
                if executable_path.is_file() and os.access(str(executable_path), os.X_OK):
                    return parts
            elif shutil.which(executable):
                return parts
        raise MigrationError("MISSING_DEVKIT", "Configured DevKit command is not available: %s" % configured, status="BLOCKED")
    found = shutil.which("devkit")
    if found:
        return [found]
    raise MigrationError(
        "MISSING_DEVKIT",
        "DevKit command is not available. Provide --devkit-command or KUNPENG_DEVKIT_COMMAND.",
        status="BLOCKED",
    )

def json_reports(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.json") if path.is_file())

def analyze_devkit_reports(paths: list[Path]) -> list[dict[str, Any]]:
    findings = []

    def add(report: str, path: str, value: Any, finding_type: str) -> None:
        findings.append({"report": report, "path": path, "value": value, "type": finding_type})

    def walk(value: Any, key_path: str, report: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                normalized = re.sub(r"[^a-z0-9]+", "_", str(key).lower()).strip("_")
                child_path = "%s.%s" % (key_path, key) if key_path else str(key)
                if normalized in {"source_need_migrated", "need_migrated", "migration_required"}:
                    if child is True or str(child).strip().lower() in {"yes", "true", "need migrated", "required"}:
                        add(report, child_path, child, "MIGRATION_REQUIRED")
                elif normalized in {"compatible", "is_compatible", "arm_compatible", "kunpeng_compatible"}:
                    if child is False or str(child).strip().lower() in {"false", "no", "incompatible", "not compatible"}:
                        add(report, child_path, child, "INCOMPATIBLE")
                elif any(token in normalized for token in ("incompatible_count", "to_be_verified", "need_migrate_count", "unresolved_count")):
                    try:
                        if float(child) > 0:
                            add(report, child_path, child, "NONZERO_FINDING_COUNT")
                    except (TypeError, ValueError):
                        pass
                walk(child, child_path, report)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, "%s[%d]" % (key_path, index), report)

    for report_path in paths:
        try:
            data = json.loads(report_path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        walk(data, "", str(report_path))
    return findings

def cleanup_untracked_build_outputs(work_source: Path) -> list[str]:
    """Remove generated build directories that are not part of the Git baseline."""
    removed = []
    candidates = []
    for root, dirs, _files in os.walk(str(work_source)):
        root_path = Path(root)
        if ".git" in root_path.parts:
            dirs[:] = []
            continue
        keep = []
        for name in dirs:
            if name in {"target", "build", "dist", "out"}:
                candidates.append(root_path / name)
            else:
                keep.append(name)
        dirs[:] = keep
    for path in sorted(candidates, key=lambda x: len(x.parts), reverse=True):
        try:
            relative = path.relative_to(work_source)
        except ValueError:
            continue
        tracked = subprocess.run(
            ["git", "ls-files", "--", str(relative)],
            cwd=str(work_source),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if (tracked.stdout or "").strip():
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(str(path))
            removed.append(str(relative))
    return removed

def database_route(work_dir: Path, config: dict[str, Any]) -> tuple[str, str, str]:
    if bool(config.get("skip_sql")):
        return "SKIP", "", ""
    source_db = str(config.get("source_db") or "").strip()
    target_db = str(config.get("target_db") or "").strip()
    route_file = work_dir / "database-route.json"
    if route_file.is_file():
        route = load_json(route_file)
        decision = str(route.get("decision") or "").upper()
        if decision == "SKIP":
            return "SKIP", "", ""
        source_db = str(route.get("source_db") or source_db).strip()
        target_db = str(route.get("target_db") or target_db).strip()
    if source_db and target_db:
        if source_db.lower() == target_db.lower():
            return "SKIP", source_db, target_db
        return "MIGRATE", source_db, target_db
    return "REQUIRED", source_db, target_db

def require_baseline_build_command(result: dict[str, Any], config: dict[str, Any]) -> str:
    current = str(config.get("build_command") or "").strip()
    baseline = result.get("baseline") if isinstance(result.get("baseline"), dict) else {}
    baseline_command = str(baseline.get("command") or "").strip()
    if baseline_command and current and baseline_command != current:
        raise MigrationError(
            "BUILD_COMMAND_CHANGED_AFTER_BASELINE",
            "Build command changed after the baseline was recorded. Use the baseline command or start a new workspace.",
            status="BLOCKED",
        )
    return baseline_command or current
