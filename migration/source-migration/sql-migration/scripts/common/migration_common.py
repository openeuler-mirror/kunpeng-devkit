#!/usr/bin/env python3
"""Shared deterministic runtime helpers for sql-migration."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

STATE_NAME = "sql-migration-state.json"


class MigrationError(RuntimeError):
    def __init__(self, reason: str, message: str, exit_code: int = 20):
        super().__init__(message)
        self.reason = reason
        self.exit_code = exit_code


def load_json(path: Path, default: Any = None) -> Any:
    if not path.is_file():
        return default
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(value, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(str(tmp), str(path))


def now_local() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def timeline_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000)


def state_path(work_dir: Path) -> Path:
    return work_dir / STATE_NAME


def save_state(work_dir: Path, state: dict[str, Any]) -> None:
    state["updated_at"] = now_local()
    write_json(state_path(work_dir), state)


def command_log_path(work_dir: Path) -> Path:
    path = work_dir / "logs" / "sql-migration-entry.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def run_command(
    cmd: list[str],
    work_dir: Path,
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    reason: str = "COMMAND_FAILED",
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    started = now_local()
    started_ms = monotonic_ms()
    merged_env = os.environ.copy()
    if env:
        merged_env.update({k: str(v) for k, v in env.items()})
    result = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=merged_env,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    elapsed = monotonic_ms() - started_ms
    with command_log_path(work_dir).open("a", encoding="utf-8") as fh:
        fh.write(f"\n[{started}] elapsed_ms={elapsed} rc={result.returncode}\n")
        fh.write("$ " + " ".join(cmd) + "\n")
        fh.write(result.stdout or "")
        if result.stdout and not result.stdout.endswith("\n"):
            fh.write("\n")
    if result.returncode != 0:
        tail = "\n".join((result.stdout or "").splitlines()[-20:])
        raise MigrationError(reason, f"command failed rc={result.returncode}: {' '.join(cmd)}\n{tail}")
    return result


def stage_begin(state: dict[str, Any], name: str, work_dir: Path) -> int:
    state["stage"] = name
    state.setdefault("timings", {}).setdefault(name, {})["started_at"] = now_local()
    reports = work_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    with (reports / "timeline.log").open("a", encoding="utf-8") as fh:
        fh.write(f"{name}_START|{timeline_stamp()}\n")
    return monotonic_ms()


def stage_end(state: dict[str, Any], name: str, started_ms: int, work_dir: Path) -> None:
    timing = state.setdefault("timings", {}).setdefault(name, {})
    timing["finished_at"] = now_local()
    timing["elapsed_ms"] = monotonic_ms() - started_ms
    with (work_dir / "reports" / "timeline.log").open("a", encoding="utf-8") as fh:
        fh.write(f"{name}_END|{timeline_stamp()}|elapsed_ms={timing['elapsed_ms']}\n")


# reset 时需跨次保留的环境准备产物（由入口脚本 download_devkit.sh/download_jdk.sh 写入）。
# 与 downloads/、sql-analysis/、devkit-sql-migration-cache/ 同属环境缓存，跨 reset 复用，
# 避免二次迁移重跑时入口已预置的 DevKit/JDK 路径被清理导致 read_devkit_environment 失败。
RESET_PRESERVED_REPORTS = ("devkit_path.txt", "jdk_path.txt")


def reset_workdir(work_dir: Path) -> None:
    reports_dir = work_dir / "reports"
    preserved: dict[str, bytes] = {}
    for fname in RESET_PRESERVED_REPORTS:
        fpath = reports_dir / fname
        if fpath.is_file():
            preserved[fname] = fpath.read_bytes()

    for name in ("source-code", "reports", "logs", STATE_NAME):
        path = work_dir / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()
    work_dir.mkdir(parents=True, exist_ok=True)
    for name in ("source-code", "reports", "logs", "downloads", "sql-analysis", "devkit-sql-migration-cache"):
        (work_dir / name).mkdir(parents=True, exist_ok=True)

    for fname, data in preserved.items():
        (reports_dir / fname).write_bytes(data)


def result_payload(state: dict[str, Any], **extra: Any) -> dict[str, Any]:
    value = {
        "status": state.get("status"),
        "stage": state.get("stage"),
        "reason_code": state.get("reason_code", ""),
        "project_path": state.get("project_path"),
        "work_dir": state.get("work_dir"),
        "source_db": state.get("source_db"),
        "target_db": state.get("target_db"),
        "route": state.get("route"),
    }
    value.update(extra)
    return value


def json_list(path: Path) -> list[dict[str, Any]]:
    value = load_json(path, [])
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []
