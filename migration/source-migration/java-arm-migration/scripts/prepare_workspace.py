#!/usr/bin/env python3
"""Create an isolated Java migration workspace and Git baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


IGNORED_NAMES = {
    ".git",
    ".gradle",
    ".idea",
    ".vscode",
    "build",
    "dist",
    "node_modules",
    "out",
    "target",
}
IGNORED_SUFFIXES = {".class", ".log"}


def fail(message: str) -> None:
    print(json.dumps({"success": False, "error": message}, ensure_ascii=False, indent=2))
    raise SystemExit(2)


def validate_source(value: str) -> Path:
    source = Path(value).expanduser().resolve()
    if not source.is_dir():
        fail(f"Java project directory not found: {source}")
    return source


def safe_name(source: Path) -> str:
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", source.name).strip("-._")
    return name or "java-project"


def project_id(source: Path) -> str:
    digest = hashlib.sha256(str(source).encode("utf-8")).hexdigest()[:12]
    return f"{safe_name(source)}-{digest}"


def resolve_work_base() -> Path:
    base = (Path.home() / ".java-arm-migration" / "work").resolve()
    if base == Path("/").resolve():
        fail("Work base must not be the filesystem root")
    return base


def validate_symlinks(source: Path) -> None:
    root = source.resolve()
    for path in source.rglob("*"):
        if not path.is_symlink():
            continue
        target = path.resolve()
        try:
            target.relative_to(root)
        except ValueError:
            fail(f"Source symlink points outside the project: {path} -> {target}")


def ignore_generated(_directory: str, names: list[str]) -> set[str]:
    ignored = set()
    for name in names:
        path = Path(name)
        if name in IGNORED_NAMES or path.suffix.lower() in IGNORED_SUFFIXES:
            ignored.add(name)
    return ignored


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def initialize_baseline(work_source: Path) -> str:
    if shutil.which("git") is None:
        fail("git is required to create the migration baseline")

    steps = [
        ["git", "init"],
        ["git", "config", "user.name", "Java ARM Migration"],
        ["git", "config", "user.email", "java-arm-migration@example.invalid"],
        ["git", "add", "-A"],
        ["git", "commit", "-m", "Java ARM migration baseline"],
    ]
    for command in steps:
        result = run(command, work_source)
        if result.returncode != 0:
            fail(
                "Unable to create Git baseline; command failed: "
                + " ".join(command)
                + "\n"
                + (result.stdout or "")
            )

    baseline = run(["git", "rev-parse", "HEAD"], work_source)
    if baseline.returncode != 0:
        fail("Unable to read Git baseline commit")

    # Keep generated build output out of migration diffs without changing the
    # copied project's .gitignore. These directories were excluded from the
    # initial copy, so local excludes only affect files generated afterwards.
    info_exclude = work_source / ".git" / "info" / "exclude"
    with info_exclude.open("a", encoding="utf-8") as fh:
        fh.write("\n# java-arm-migration local build output\n")
        for pattern in ("target/", "build/", "dist/", "out/", ".gradle/"):
            fh.write(pattern + "\n")
    return baseline.stdout.strip()


def write_json(path: Path, data: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def prepare(source_value: str, emit: bool = True) -> dict[str, Any]:
    source = validate_source(source_value)
    work_base = resolve_work_base()
    work_dir = (work_base / project_id(source)).resolve()
    try:
        work_dir.relative_to(work_base)
    except ValueError:
        fail(f"Resolved work directory escapes work base: {work_dir}")
    try:
        work_dir.relative_to(source)
    except ValueError:
        pass
    else:
        fail("Work directory must not be created inside the source project")

    metadata_path = work_dir / "workspace.json"
    work_source = work_dir / "workspace" / "source"
    if metadata_path.is_file() and work_source.is_dir():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"Existing workspace metadata is unreadable: {exc}")
        if metadata.get("source") != str(source) or metadata.get("work_source") != str(work_source):
            fail("Existing workspace metadata does not match the requested source")
        if emit:
            print(json.dumps({**metadata, "reused": True}, ensure_ascii=False, indent=2))
        return metadata

    if work_dir.exists() and any(work_dir.iterdir()):
        fail(
            f"Work directory exists without a complete workspace: {work_dir}. "
            "Inspect or remove the conflicting workspace manually."
        )

    validate_symlinks(source)
    for relative in (
        "workspace",
        "logs",
        "reports/ai-migration-source",
        "reports/ai-migration-package",
        "output",
        "cache/maven/repository",
        "cache/gradle",
        "tmp",
    ):
        (work_dir / relative).mkdir(parents=True, exist_ok=True)

    shutil.copytree(
        source,
        work_source,
        symlinks=True,
        ignore=ignore_generated,
    )
    baseline_commit = initialize_baseline(work_source)
    metadata = {
        "source": str(source),
        "project_id": project_id(source),
        "work_dir": str(work_dir),
        "work_source": str(work_source),
        "baseline_commit": baseline_commit,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "reused": False,
    }
    write_json(metadata_path, metadata)
    if emit:
        print(json.dumps(metadata, ensure_ascii=False, indent=2))
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create an isolated source copy and Git baseline for Java ARM migration."
    )
    parser.add_argument("--source", required=True, help="Local Java project directory")
    args = parser.parse_args()
    prepare(args.source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
