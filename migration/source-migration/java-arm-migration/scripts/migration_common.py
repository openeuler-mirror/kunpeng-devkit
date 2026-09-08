#!/usr/bin/env python3
"""Shared runtime helpers for Java source ARM64 migration."""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
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





def git_worktree_tree(work_source: Path) -> str:
    """Create a Git tree object for the current worktree without touching its real index."""
    tmp_dir = work_source / ".git" / "java-arm-migration-tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    fd, index_name = tempfile.mkstemp(prefix="index-", dir=str(tmp_dir))
    os.close(fd)
    index_path = Path(index_name)
    try:
        try:
            index_path.unlink()
        except OSError:
            pass
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index_path)
        for args, code in [
            (["git", "read-tree", "HEAD"], "SOURCE_CHECKPOINT_BASELINE_MISSING"),
            (["git", "add", "-A", "--", "."], "SOURCE_CHECKPOINT_STAGE_FAILED"),
        ]:
            proc = subprocess.run(args, cwd=str(work_source), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            if proc.returncode != 0:
                raise MigrationError(code, "Unable to create a source migration checkpoint", status="BLOCKED")
        tree = subprocess.run(
            ["git", "write-tree"], cwd=str(work_source), env=env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if tree.returncode != 0 or not (tree.stdout or "").strip():
            raise MigrationError("SOURCE_CHECKPOINT_WRITE_FAILED", "Unable to persist source migration checkpoint", status="BLOCKED")
        return (tree.stdout or "").strip()
    finally:
        try:
            index_path.unlink()
        except OSError:
            pass
        try:
            tmp_dir.rmdir()
        except OSError:
            pass


def write_git_patch_from_tree(work_source: Path, base_tree: str, output_path: Path) -> dict[str, Any]:
    """Write a patch from a saved Git tree checkpoint to the current worktree."""
    current_tree = git_worktree_tree(work_source)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    diff = subprocess.run(
        ["git", "diff", "--binary", base_tree, current_tree, "--"],
        cwd=str(work_source), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if diff.returncode != 0:
        raise MigrationError("SOURCE_PATCH_GENERATION_FAILED", "Unable to generate source patch: %s" % output_path, status="BLOCKED")
    names = subprocess.run(
        ["git", "diff", "--name-only", base_tree, current_tree, "--"],
        cwd=str(work_source), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    output_path.write_bytes(diff.stdout or b"")
    return {
        "path": str(output_path),
        "sha256": sha256_file(output_path),
        "size": output_path.stat().st_size,
        "changed_files": [line.strip() for line in (names.stdout or "").splitlines() if line.strip()],
        "base_tree": base_tree,
        "current_tree": current_tree,
    }

def write_git_worktree_patch(work_source: Path, output_path: Path) -> dict[str, Any]:
    """Write a binary-safe patch from Git HEAD to the current worktree.

    A temporary Git index is used so untracked source files are included without
    mutating the repository's real index.  Ignored/generated files remain
    excluded according to the repository's normal Git rules.
    """
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_root = output_path.parent / ".tmp"
    tmp_root.mkdir(parents=True, exist_ok=True)
    fd, index_name = tempfile.mkstemp(prefix="git-index-", dir=str(tmp_root))
    os.close(fd)
    index_path = Path(index_name)
    try:
        # Git expects a missing index file when constructing it from HEAD.
        try:
            index_path.unlink()
        except OSError:
            pass
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str(index_path)
        read_tree = subprocess.run(
            ["git", "read-tree", "HEAD"],
            cwd=str(work_source),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if read_tree.returncode != 0:
            raise MigrationError(
                "SOURCE_PATCH_BASELINE_MISSING",
                "Unable to read the migration Git baseline while generating %s" % output_path,
                status="BLOCKED",
            )
        add = subprocess.run(
            ["git", "add", "-A", "--", "."],
            cwd=str(work_source),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if add.returncode != 0:
            raise MigrationError(
                "SOURCE_PATCH_STAGE_FAILED",
                "Unable to stage the migration worktree in a temporary index while generating %s" % output_path,
                status="BLOCKED",
            )
        diff = subprocess.run(
            ["git", "diff", "--cached", "--binary", "HEAD", "--"],
            cwd=str(work_source),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if diff.returncode != 0:
            raise MigrationError(
                "SOURCE_PATCH_GENERATION_FAILED",
                "Unable to generate source patch: %s" % output_path,
                status="BLOCKED",
            )
        names = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "HEAD", "--"],
            cwd=str(work_source),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        output_path.write_bytes(diff.stdout or b"")
        changed_files = [line.strip() for line in (names.stdout or "").splitlines() if line.strip()]
        return {
            "path": str(output_path),
            "sha256": sha256_file(output_path),
            "size": output_path.stat().st_size,
            "changed_files": changed_files,
        }
    finally:
        try:
            index_path.unlink()
        except OSError:
            pass
        try:
            tmp_root.rmdir()
        except OSError:
            pass

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

SKILL_ROOT = Path(__file__).resolve().parent.parent
MIGRATION_TOOLS_CONFIG = SKILL_ROOT / "assets" / "migration-tools.json"
AI_MIGRATION_TOOL_NAME = "devKit-ai-migration-tool"
AI_MIGRATION_EXECUTABLE = "ai-migration"
ARCHIVE_SUFFIXES = (".tar.gz", ".zip", ".tar")

def _validate_command(command: str) -> list[str]:
    parts = shlex.split(command)
    if not parts:
        raise MigrationError(
            "MISSING_AI_MIGRATION",
            "Configured ai-migration command is empty.",
            status="BLOCKED",
        )
    executable = parts[0]
    if "/" in executable:
        executable_path = Path(executable).expanduser()
        if executable_path.is_file() and os.access(str(executable_path), os.X_OK):
            parts[0] = str(executable_path.resolve())
            return parts
    else:
        found = shutil.which(executable)
        if found:
            parts[0] = found
            return parts
    raise MigrationError(
        "MISSING_AI_MIGRATION",
        "Configured ai-migration command is not available: %s" % command,
        status="BLOCKED",
    )

def _load_migration_tool_entry() -> dict[str, str]:
    if not MIGRATION_TOOLS_CONFIG.is_file():
        raise MigrationError(
            "MIGRATION_TOOLS_CONFIG_MISSING",
            "Migration tools config is missing: %s" % MIGRATION_TOOLS_CONFIG,
            status="BLOCKED",
        )
    data = load_json(MIGRATION_TOOLS_CONFIG)
    tools = data.get("migration_tools")
    if not isinstance(tools, list):
        raise MigrationError(
            "INVALID_MIGRATION_TOOLS_CONFIG",
            "migration_tools must be an array: %s" % MIGRATION_TOOLS_CONFIG,
            status="BLOCKED",
        )
    for item in tools:
        if not isinstance(item, dict):
            continue
        if str(item.get("name") or "").strip() != AI_MIGRATION_TOOL_NAME:
            continue
        download_url = str(item.get("download_url") or "").strip()
        local_path = str(item.get("local_path") or "").strip()
        if local_path and not Path(local_path).is_absolute():
            raise MigrationError(
                "AI_MIGRATION_LOCAL_PATH_NOT_ABSOLUTE",
                "local_path must be a complete absolute path in %s: %s" % (MIGRATION_TOOLS_CONFIG, local_path),
                status="BLOCKED",
            )
        return {
            "name": AI_MIGRATION_TOOL_NAME,
            "download_url": download_url,
            "local_path": local_path,
        }
    raise MigrationError(
        "AI_MIGRATION_TOOL_CONFIG_MISSING",
        "No migration tool entry named %s exists in %s" % (AI_MIGRATION_TOOL_NAME, MIGRATION_TOOLS_CONFIG),
        status="BLOCKED",
    )

def _safe_archive_target(root: Path, member_name: str) -> Path:
    member = member_name.replace("\\", "/")
    target = (root / member).resolve()
    root_resolved = root.resolve()
    try:
        target.relative_to(root_resolved)
    except ValueError:
        raise MigrationError(
            "UNSAFE_AI_MIGRATION_ARCHIVE",
            "Tool archive contains a path outside the extraction directory: %s" % member_name,
            status="BLOCKED",
        )
    return target

def _archive_suffix(name: str) -> str | None:
    lower = name.lower()
    for suffix in ARCHIVE_SUFFIXES:
        if lower.endswith(suffix):
            return suffix
    return None

def _require_supported_archive_name(name: str, source_label: str) -> str:
    suffix = _archive_suffix(name)
    if suffix:
        return suffix
    raise MigrationError(
        "UNSUPPORTED_AI_MIGRATION_PACKAGE",
        "%s must point to a .zip, .tar, or .tar.gz package: %s" % (source_label, name),
        status="BLOCKED",
    )

def _safe_archive_link_target(root: Path, member: tarfile.TarInfo) -> None:
    """Allow relative links only when their resolved target remains inside root."""
    link_name = member.linkname.replace("\\", "/")
    if Path(link_name).is_absolute():
        raise MigrationError(
            "UNSAFE_AI_MIGRATION_ARCHIVE",
            "Tool archive contains an absolute link: %s -> %s" % (member.name, member.linkname),
            status="BLOCKED",
        )
    member_target = _safe_archive_target(root, member.name)
    if member.issym():
        # A symbolic-link target is resolved relative to the directory containing
        # the link.  DevKit packages legitimately use ../ between sibling
        # directories, so reject only links that actually escape the root.
        target = (member_target.parent / link_name).resolve()
    else:
        # tar hard-link names are archive-root relative.
        target = (root / link_name).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError:
        raise MigrationError(
            "UNSAFE_AI_MIGRATION_ARCHIVE",
            "Tool archive contains a link outside the extraction directory: %s -> %s" % (member.name, member.linkname),
            status="BLOCKED",
        )

def _extract_tool_archive(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    suffix = _require_supported_archive_name(archive.name, "ai-migration tool package")
    try:
        if suffix == ".zip":
            with zipfile.ZipFile(archive) as zf:
                for member in zf.infolist():
                    _safe_archive_target(destination, member.filename)
                zf.extractall(destination)
            return
        mode = "r:gz" if suffix == ".tar.gz" else "r:"
        with tarfile.open(archive, mode=mode) as tf:
            for member in tf.getmembers():
                _safe_archive_target(destination, member.name)
                if member.issym() or member.islnk():
                    _safe_archive_link_target(destination, member)
            tf.extractall(destination)
    except MigrationError:
        raise
    except (OSError, tarfile.TarError, zipfile.BadZipFile) as exc:
        raise MigrationError(
            "AI_MIGRATION_ARCHIVE_EXTRACT_FAILED",
            "Failed to extract ai-migration tool package %s: %s" % (archive, exc),
            status="BLOCKED",
        )

def _find_ai_migration(root: Path) -> Path | None:
    if root.is_file():
        return root if root.name == AI_MIGRATION_EXECUTABLE else None
    candidates = [path for path in root.rglob(AI_MIGRATION_EXECUTABLE) if path.is_file()]
    if not candidates:
        return None
    candidates.sort(key=lambda path: (0 if path.parent.name == "bin" else 1, len(path.parts), str(path)))
    return candidates[0]

def _ensure_executable(path: Path) -> Path:
    try:
        mode = path.stat().st_mode
        path.chmod(mode | 0o111)
    except OSError as exc:
        raise MigrationError(
            "AI_MIGRATION_NOT_EXECUTABLE",
            "Cannot make ai-migration executable: %s: %s" % (path, exc),
            status="BLOCKED",
        )
    if not os.access(str(path), os.X_OK):
        raise MigrationError(
            "AI_MIGRATION_NOT_EXECUTABLE",
            "ai-migration is not executable: %s" % path,
            status="BLOCKED",
        )
    return path.resolve()

def _tool_cache_signature(source_type: str, source_value: str, source_path: Path | None = None) -> dict[str, Any]:
    signature: dict[str, Any] = {"source_type": source_type, "source": source_value}
    if source_path is not None and source_path.is_file():
        try:
            stat = source_path.stat()
            signature["size"] = stat.st_size
            signature["mtime_ns"] = stat.st_mtime_ns
        except OSError:
            pass
    return signature

def _cached_tool(cache_root: Path, signature: dict[str, Any]) -> Path | None:
    metadata_path = cache_root / "acquisition.json"
    if not metadata_path.is_file():
        return None
    try:
        metadata = load_json(metadata_path)
    except MigrationError:
        return None
    recorded = metadata.get("source")
    if recorded != signature:
        return None
    tool = _find_ai_migration(cache_root / "payload")
    if tool and tool.is_file():
        return _ensure_executable(tool)
    return None

def _write_tool_metadata(cache_root: Path, signature: dict[str, Any], executable: Path) -> None:
    write_json(cache_root / "acquisition.json", {
        "name": AI_MIGRATION_TOOL_NAME,
        "source": signature,
        "executable": str(executable),
        "acquired_at": now_iso(),
    })

def _materialize_local_tool(local_path: str, work_dir: Path) -> Path:
    source = Path(local_path)
    if not source.is_absolute():
        raise MigrationError(
            "AI_MIGRATION_LOCAL_PATH_NOT_ABSOLUTE",
            "local_path must be a complete absolute path: %s" % local_path,
            status="BLOCKED",
        )
    source = source.resolve()
    if not source.exists():
        raise MigrationError(
            "AI_MIGRATION_LOCAL_PATH_NOT_FOUND",
            "Configured local_path does not exist: %s" % source,
            status="BLOCKED",
        )

    cache_root = work_dir / "tools" / AI_MIGRATION_TOOL_NAME

    if source.is_dir():
        if not _find_ai_migration(source):
            raise MigrationError(
                "AI_MIGRATION_EXECUTABLE_NOT_FOUND",
                "Local ai-migration tool directory does not contain ai-migration: %s" % source,
                status="BLOCKED",
            )

        # Local directories deliberately do not use fingerprint/cache-change
        # detection. Every resolution starts from a clean copy so stale cached
        # files cannot survive between runs.
        if cache_root.exists():
            shutil.rmtree(cache_root)
        payload = cache_root / "payload"
        try:
            shutil.copytree(source, payload, symlinks=True)
        except OSError as exc:
            raise MigrationError(
                "AI_MIGRATION_LOCAL_COPY_FAILED",
                "Failed to copy local ai-migration tool directory %s: %s" % (source, exc),
                status="BLOCKED",
            )
        tool = _find_ai_migration(payload)
        if not tool:
            raise MigrationError(
                "AI_MIGRATION_EXECUTABLE_NOT_FOUND",
                "Copied local ai-migration tool directory does not contain ai-migration: %s" % source,
                status="BLOCKED",
            )
        tool = _ensure_executable(tool)
        _write_tool_metadata(
            cache_root,
            {
                "source_type": "local_path_directory",
                "source": str(source),
                "refresh_policy": "always_recopy",
            },
            tool,
        )
        return tool

    if not source.is_file():
        raise MigrationError(
            "UNSUPPORTED_AI_MIGRATION_PACKAGE",
            "local_path must point to a directory or a .zip, .tar, or .tar.gz package: %s" % source,
            status="BLOCKED",
        )

    _require_supported_archive_name(source.name, "local_path")
    signature = _tool_cache_signature("local_path_archive", str(source), source)
    cached = _cached_tool(cache_root, signature)
    if cached:
        return cached
    if cache_root.exists():
        shutil.rmtree(cache_root)
    payload = cache_root / "payload"
    payload.mkdir(parents=True, exist_ok=True)
    try:
        archive_copy = cache_root / source.name
        shutil.copy2(source, archive_copy)
        _extract_tool_archive(archive_copy, payload)
    except MigrationError:
        raise
    except OSError as exc:
        raise MigrationError(
            "AI_MIGRATION_LOCAL_COPY_FAILED",
            "Failed to materialize ai-migration tool from %s: %s" % (source, exc),
            status="BLOCKED",
        )
    tool = _find_ai_migration(payload)
    if not tool:
        raise MigrationError(
            "AI_MIGRATION_EXECUTABLE_NOT_FOUND",
            "Local ai-migration tool package does not contain ai-migration: %s" % source,
            status="BLOCKED",
        )
    tool = _ensure_executable(tool)
    _write_tool_metadata(cache_root, signature, tool)
    return tool

def _download_ai_migration(download_url: str, work_dir: Path) -> Path:
    parsed = urllib.parse.urlparse(download_url)
    filename = Path(urllib.parse.unquote(parsed.path)).name
    if not filename:
        raise MigrationError(
            "UNSUPPORTED_AI_MIGRATION_PACKAGE",
            "download_url must point to a .zip, .tar, or .tar.gz package: %s" % download_url,
            status="BLOCKED",
        )
    _require_supported_archive_name(filename, "download_url")
    signature = _tool_cache_signature("download_url", download_url)
    cache_root = work_dir / "tools" / AI_MIGRATION_TOOL_NAME
    cached = _cached_tool(cache_root, signature)
    if cached:
        return cached
    if cache_root.exists():
        shutil.rmtree(cache_root)
    payload = cache_root / "payload"
    payload.mkdir(parents=True, exist_ok=True)
    download_dir = cache_root / "download"
    download_dir.mkdir(parents=True, exist_ok=True)
    downloaded = download_dir / filename
    partial = downloaded.with_suffix(downloaded.suffix + ".part")
    try:
        request = urllib.request.Request(download_url)
        with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
        partial.replace(downloaded)
    except Exception as exc:
        try:
            partial.unlink(missing_ok=True)
        except OSError:
            pass
        raise MigrationError(
            "AI_MIGRATION_DOWNLOAD_FAILED",
            "Failed to download ai-migration tool from %s: %s" % (download_url, exc),
            status="BLOCKED",
        )
    if downloaded.stat().st_size <= 0:
        raise MigrationError(
            "AI_MIGRATION_DOWNLOAD_EMPTY",
            "Downloaded ai-migration tool package is empty: %s" % download_url,
            status="BLOCKED",
        )
    _extract_tool_archive(downloaded, payload)
    tool = _find_ai_migration(payload)
    if not tool:
        raise MigrationError(
            "AI_MIGRATION_EXECUTABLE_NOT_FOUND",
            "Downloaded tool package does not contain ai-migration: %s" % download_url,
            status="BLOCKED",
        )
    tool = _ensure_executable(tool)
    _write_tool_metadata(cache_root, signature, tool)
    return tool

def resolve_ai_migration(work_dir: Path) -> list[str]:
    """Resolve ai-migration only from assets/migration-tools.json."""
    tool = _load_migration_tool_entry()
    download_url = tool["download_url"]
    local_path = tool["local_path"]
    if download_url:
        return [str(_download_ai_migration(download_url, work_dir))]
    if local_path:
        return [str(_materialize_local_tool(local_path, work_dir))]
    raise MigrationError(
        "AI_MIGRATION_TOOL_SOURCE_EMPTY",
        "Both download_url and local_path are empty for %s in %s" % (AI_MIGRATION_TOOL_NAME, MIGRATION_TOOLS_CONFIG),
        status="BLOCKED",
    )


def zh_csv_reports(root: Path) -> list[Path]:
    """Return only Chinese DevKit CSV reports generated with ``-r csv``.

    The workflow keeps the established rule that non-zero scans use only
    the Chinese report as the repair source.  ``*_en.csv`` (if emitted by a
    future DevKit version) is deliberately ignored.
    """
    return sorted(
        path for path in root.rglob("*.csv")
        if path.is_file() and re.search(r"_zh\.csv$", path.name, flags=re.I)
    )


def _read_ai_migration_csv(report_path: Path) -> list[list[str]]:
    data = None
    last_exc: Exception | None = None
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            data = report_path.read_text(encoding=encoding)
            break
        except (OSError, UnicodeError) as exc:
            last_exc = exc
    if data is None:
        raise MigrationError(
            "AI_MIGRATION_CSV_REPORT_INVALID",
            "Invalid ai-migration Chinese CSV report %s: %s" % (report_path, last_exc),
        )
    try:
        rows = list(csv.reader(io.StringIO(data)))
    except csv.Error as exc:
        raise MigrationError(
            "AI_MIGRATION_CSV_REPORT_INVALID",
            "Invalid ai-migration Chinese CSV report %s: %s" % (report_path, exc),
        )
    if not any(any(str(cell).strip() for cell in row) for row in rows):
        raise MigrationError(
            "AI_MIGRATION_CSV_REPORT_INVALID",
            "ai-migration Chinese CSV report is empty: %s" % report_path,
        )
    return rows


def inspect_ai_migration_csv_reports(paths: list[Path]) -> dict[str, Any]:
    """Validate Chinese DevKit CSV reports without interpreting scan semantics."""
    if not paths:
        raise MigrationError(
            "AI_MIGRATION_ZH_CSV_REPORT_MISSING",
            "No *_zh.csv ai-migration report was generated for the non-zero scan result.",
        )
    analyzed: list[str] = []
    for report_path in paths:
        if not re.search(r"_zh\.csv$", report_path.name, flags=re.I):
            continue
        _read_ai_migration_csv(report_path)
        analyzed.append(str(report_path))
    if not analyzed:
        raise MigrationError(
            "AI_MIGRATION_ZH_CSV_REPORT_MISSING",
            "No *_zh.csv ai-migration report was generated for the non-zero scan result.",
        )
    return {
        "findings": [],
        "report_count": len(analyzed),
        "analyzed_reports": analyzed,
    }


def _normalize_csv_header(value: str) -> str:
    return re.sub(r"[\s（）()：:]", "", str(value or "").strip().lower())


def _source_detail_header(row: list[str]) -> dict[str, int] | None:
    aliases = {
        "file": {"文件名", "filename", "filepath", "文件路径"},
        "file_type": {"文件类型", "filetype"},
        "line_range": {"行号起始行结束行", "行号", "linesstartlineendline", "linerange"},
        "lines": {"行数", "lines"},
        "category": {"类别", "category"},
        "keyword": {"关键字", "keyword"},
        "suggestion": {"建议", "suggestion"},
        "description": {"描述", "description"},
        "modification_level": {"修改级别", "modificationlevel"},
        "reason": {"修改原因", "原因", "reason"},
    }
    normalized = [_normalize_csv_header(cell) for cell in row]
    indexes: dict[str, int] = {}
    for field, names in aliases.items():
        for idx, value in enumerate(normalized):
            if value in names:
                indexes[field] = idx
                break
    # DevKit documents "修改级别" as the authoritative rule/suggestion field.
    # Require it plus at least one scan-detail identity column so summary rows
    # cannot be mistaken for detail headers.
    if "modification_level" not in indexes:
        return None
    if not any(name in indexes for name in ("file", "category", "keyword", "suggestion", "reason")):
        return None
    return indexes


def _row_value(row: list[str], indexes: dict[str, int], key: str) -> str:
    idx = indexes.get(key)
    if idx is None or idx >= len(row):
        return ""
    return str(row[idx] or "").strip()


def _classify_modification_level(level: str) -> str:
    value = re.sub(r"\s+", "", str(level or "")).lower()
    if value == "规则项" or value.startswith("规则项_") or value in {"rule", "ruleitem"}:
        return "RULE"
    if value.startswith("建议项") or value.startswith("suggestion") or value in {"advisory", "advice"}:
        return "SUGGESTION"
    return "UNKNOWN"


def _source_scan_item(report_path: Path, row: list[str], indexes: dict[str, int]) -> dict[str, Any]:
    item = {
        "report": str(report_path),
        "file": _row_value(row, indexes, "file"),
        "file_type": _row_value(row, indexes, "file_type"),
        "line_range": _row_value(row, indexes, "line_range"),
        "lines": _row_value(row, indexes, "lines"),
        "category": _row_value(row, indexes, "category"),
        "keyword": _row_value(row, indexes, "keyword"),
        "suggestion": _row_value(row, indexes, "suggestion"),
        "description": _row_value(row, indexes, "description"),
        "modification_level": _row_value(row, indexes, "modification_level"),
        "reason": _row_value(row, indexes, "reason"),
    }
    # Keep only meaningful values while preserving modification_level.
    return {key: value for key, value in item.items() if value not in ("", None)}


def _extract_source_summary_counts(rows: list[list[str]]) -> dict[str, int | None]:
    """Best-effort extraction of the CSV summary counts for audit output.

    The source detail rows remain authoritative for deciding which concrete
    items require repair. Summary counts are retained only as cross-check data.
    """
    counts: dict[str, int | None] = {"rule_count": None, "suggestion_count": None}
    patterns = {
        "rule_count": re.compile(r"规则项(?:总数)?[^0-9]*(\d+)", re.I),
        "suggestion_count": re.compile(r"建议项(?:总数)?[^0-9]*(\d+)", re.I),
    }
    for row in rows:
        # Summary counts appear before the documented source scan detail table.
        # Stop here so detail values such as ``建议项_规范类`` cannot be
        # mistaken for summary labels followed by unrelated line numbers.
        if _source_detail_header(row) is not None:
            break
        text = " ".join(str(cell or "").strip() for cell in row if str(cell or "").strip())
        for key, pattern in patterns.items():
            if counts[key] is None:
                match = pattern.search(text)
                if match:
                    counts[key] = int(match.group(1))
        # Some CSV releases place a label and numeric value in adjacent cells.
        for idx, cell in enumerate(row[:-1]):
            label = _normalize_csv_header(cell)
            next_value = str(row[idx + 1] or "").strip()
            if not next_value.isdigit():
                continue
            if counts["rule_count"] is None and label in {"规则项", "规则项总数"}:
                counts["rule_count"] = int(next_value)
            if counts["suggestion_count"] is None and label in {"建议项", "建议项总数"}:
                counts["suggestion_count"] = int(next_value)
    return counts


def inspect_ai_migration_source_csv_reports(paths: list[Path]) -> dict[str, Any]:
    """Parse DevKit source CSV using the documented ``修改级别`` field.

    DevKit defines ``规则项`` as mandatory changes and ``建议项_*`` as
    non-mandatory advisories. Only RULE items are returned in ``findings``;
    suggestions are retained separately for the final migration summary.
    """
    if not paths:
        raise MigrationError(
            "AI_MIGRATION_ZH_CSV_REPORT_MISSING",
            "No *_zh.csv ai-migration source report was generated.",
        )
    analyzed: list[str] = []
    rules: list[dict[str, Any]] = []
    suggestions: list[dict[str, Any]] = []
    unknown: list[dict[str, Any]] = []
    summary_rule_count: int | None = None
    summary_suggestion_count: int | None = None
    detail_headers_found = 0

    for report_path in paths:
        if not re.search(r"_zh\.csv$", report_path.name, flags=re.I):
            continue
        rows = _read_ai_migration_csv(report_path)
        analyzed.append(str(report_path))
        summary = _extract_source_summary_counts(rows)
        if summary_rule_count is None and summary.get("rule_count") is not None:
            summary_rule_count = int(summary["rule_count"] or 0)
        if summary_suggestion_count is None and summary.get("suggestion_count") is not None:
            summary_suggestion_count = int(summary["suggestion_count"] or 0)

        indexes: dict[str, int] | None = None
        for row in rows:
            possible_header = _source_detail_header(row)
            if possible_header is not None:
                indexes = possible_header
                detail_headers_found += 1
                continue
            if indexes is None:
                continue
            level = _row_value(row, indexes, "modification_level")
            if not level:
                # Blank rows/section boundaries stop the current detail block.
                if not any(str(cell or "").strip() for cell in row):
                    indexes = None
                continue
            item = _source_scan_item(report_path, row, indexes)
            kind = _classify_modification_level(level)
            item["classification"] = kind
            if kind == "RULE":
                item["type"] = "SOURCE_COMPATIBILITY_RULE"
                rules.append(item)
            elif kind == "SUGGESTION":
                item["type"] = "SOURCE_COMPATIBILITY_SUGGESTION"
                suggestions.append(item)
            else:
                item["type"] = "SOURCE_COMPATIBILITY_UNCLASSIFIED"
                unknown.append(item)

    if not analyzed:
        raise MigrationError(
            "AI_MIGRATION_ZH_CSV_REPORT_MISSING",
            "No *_zh.csv ai-migration source report was generated.",
        )

    # If the summary says rules exist but no concrete rule row was parsed,
    # never silently treat the scan as advisory-only.
    classification_complete = True
    classification_reason = ""
    if unknown:
        classification_complete = False
        classification_reason = "CSV contains source detail rows with an unknown modification level."
    elif summary_rule_count is not None and summary_rule_count > len(rules):
        classification_complete = False
        classification_reason = (
            "CSV source statistics report %d rule items, but only %d rule detail rows were parsed."
            % (summary_rule_count, len(rules))
        )
    elif detail_headers_found == 0 and ((summary_rule_count or 0) > 0 or (summary_suggestion_count or 0) > 0):
        classification_complete = False
        classification_reason = "CSV has source rule/suggestion statistics but no recognizable source detail header."

    return {
        "findings": rules,
        "rule_items": rules,
        "suggestion_items": suggestions,
        "unclassified_items": unknown,
        "rule_count": len(rules),
        "suggestion_count": len(suggestions),
        "unclassified_count": len(unknown),
        "summary_rule_count": summary_rule_count,
        "summary_suggestion_count": summary_suggestion_count,
        "classification_complete": classification_complete,
        "classification_reason": classification_reason,
        "report_count": len(analyzed),
        "analyzed_reports": analyzed,
    }

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
    # database-route.json is the only persisted authority for the SQL decision.
    # Legacy migration-config.json database fields must never silently decide a
    # later invocation.  Explicit CLI inputs are persisted into this file by
    # run_migration.py before the stage is evaluated.
    route_file = work_dir / "database-route.json"
    if not route_file.is_file():
        return "REQUIRED", "", ""
    route = load_json(route_file)
    decision = str(route.get("decision") or "").upper()
    source_db = str(route.get("source_db") or "").strip()
    target_db = str(route.get("target_db") or "").strip()
    if decision == "SKIP":
        return "SKIP", source_db, target_db
    if decision == "MIGRATE" and source_db and target_db:
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
