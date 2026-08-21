from __future__ import annotations
import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any

EXIT_OK = 0
EXIT_FAILED = 2
EXIT_WAITING_FOR_SKILL = 20
EXIT_NEEDS_AGENT_FIX = 21
EXIT_WAITING_FOR_AGENT = 22
EXIT_WAITING_FOR_USER = 23
ARCHIVE_SUFFIXES = (".jar", ".war", ".zip")
TOP_LEVEL_SUFFIXES = (".jar", ".war")

class MigrationError(RuntimeError):
    def __init__(self, code: str, message: str, status: str = "FAILED") -> None:
        super().__init__(message)
        self.code = code
        self.status = status

def load_json_value(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)

def load_json(path: Path) -> dict[str, Any]:
    data = load_json_value(path)
    if not isinstance(data, dict):
        raise MigrationError("INVALID_INPUT", "Input JSON root must be an object")
    return data

def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    tmp.replace(path)


def run(
    command: list[str],
    log_path: Path,
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    with log_path.open("a", encoding="utf-8") as fh:
        fh.write("$ " + " ".join(shlex.quote(x) for x in command) + "\n")
        fh.write(proc.stdout or "")
        if not (proc.stdout or "").endswith("\n"):
            fh.write("\n")
        fh.write(f"[exit={proc.returncode}]\n")
    if check and proc.returncode != 0:
        raise MigrationError("COMMAND_FAILED", f"Command failed ({proc.returncode}): {command[0]}")
    return proc

def run_shell(
    command: str,
    log_path: Path,
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return run(["bash", "-lc", command], log_path, cwd=cwd, env=env, timeout=timeout, check=check)



def java_tool(jdk_home: str | None, tool: str) -> str:
    if not jdk_home:
        raise MigrationError("MISSING_MIGRATION_JDK", "Migration JDK under tools/runtime/jdk is required")
    path = Path(jdk_home).expanduser() / "bin" / tool
    if path.is_file() and os.access(path, os.X_OK):
        return str(path)
    raise MigrationError("MISSING_MIGRATION_JDK_TOOL", f"Migration JDK tool not found: {path}")

