#!/usr/bin/env python3
"""DevKit SQL 迁移 jar 调用 + 密码自动化（替代 devkit-sql-migration.sh）。

等价于原 shell 脚本的逻辑：
  1. 构造 jar 命令（JAVA_PATH -jar JAR_PATH -p PROJECT_ROOT -o WORK_DIR/reports
     --db-source-type SOURCE_DB --db-target-type TARGET_DB）
  2. 处理两种 DB 连接信息模式：
     - 方式1（环境变量）：SOURCE_DB_*/TARGET_DB_* 系列字段（统一入口默认）
     - 方式2（JSON 文件）：DB_PARAMS_MODE=1 + DB_PARAMS_FILE_PATH（仅供调试）
  3. 检测到 DB 连接信息时自动加 --enable-analysis-enhance
  4. 密码自动化：
     - 优先用 pty（Python 标准库，等价 expect 的伪终端，兼容 Console.readPassword()）
     - 回退 stdin 管道（适用于 Scanner/BufferedReader 读取方式）
  5. 密码只发送 1 次，jar 再次提示即视为密码错误，立即报错退出
  6. 用完立即清理 env 中的密码字段
"""
from __future__ import annotations

import os
import re
import select
import subprocess
import sys
import time
from pathlib import Path

from common.migration_common import (
    MigrationError,
    command_log_path,
    monotonic_ms,
    now_local,
    run_command,
)

try:
    import pty as _pty_mod  # noqa: F401  仅用于探测可用性
    _HAS_PTY_MODULE = True
except ImportError:
    _HAS_PTY_MODULE = False

# 与原 expect 超时一致（30 分钟）
_CMD_TIMEOUT = 1800
_SOURCE_PWD_PROMPT = re.compile(r"Source.*[Pp]assword", re.DOTALL)
_TARGET_PWD_PROMPT = re.compile(r"Target.*[Pp]assword", re.DOTALL)


def _build_cmd(
    env: dict[str, str], work_dir: Path,
) -> tuple[list[str], bool, bool, bool]:
    """构造 jar 命令列表，返回 (cmd, has_db_params, has_source, has_target)。

    方式2（DB_PARAMS_MODE=1 + DB_PARAMS_FILE_PATH）仅供调试，统一入口不走此路径；
    方式1（环境变量 SOURCE_DB_*/TARGET_DB_*）为统一入口默认。
    """
    java_path = env.get("JAVA_PATH", "")
    jar_path = env.get("JAR_PATH", "")
    project_root = env.get("PROJECT_ROOT", "")
    source_db = env.get("SOURCE_DB", "")
    target_db = env.get("TARGET_DB", "")
    if not all([java_path, jar_path, project_root, source_db, target_db]):
        raise MigrationError(
            "DEVKIT_ENV_INCOMPLETE",
            f"env missing required fields: JAVA_PATH={java_path!r}, JAR_PATH={jar_path!r}, "
            f"PROJECT_ROOT={project_root!r}, SOURCE_DB={source_db!r}, TARGET_DB={target_db!r}",
            1,
        )

    cmd: list[str] = [
        java_path, "-jar", jar_path,
        "-p", project_root,
        "-o", str(work_dir / "reports"),
        "--db-source-type", source_db,
        "--db-target-type", target_db,
    ]

    has_db_params = False
    has_source = False
    has_target = False

    if env.get("DB_PARAMS_MODE") == "1":
        # 方式2：JSON 文件路径（调试用）
        params_file = env.get("DB_PARAMS_FILE_PATH", "")
        if not params_file:
            raise MigrationError(
                "DEVKIT_DB_PARAMS_MISSING",
                "DB_PARAMS_MODE=1 缺少 DB_PARAMS_FILE_PATH",
                1,
            )
        if not Path(params_file).is_file():
            raise MigrationError(
                "DEVKIT_DB_PARAMS_MISSING",
                f"DB_PARAMS_FILE_PATH 文件不存在：{params_file}",
                1,
            )
        cmd.extend(["--db-params-file-path", params_file])
        has_db_params = True
        has_source = True
        has_target = True
    else:
        # 方式1：环境变量（统一入口默认）
        if env.get("SOURCE_DB_JDBC_URL"):
            cmd.extend(["--source-db-jdbc-url", env["SOURCE_DB_JDBC_URL"]])
            has_db_params = True
            has_source = True
        if env.get("SOURCE_DB_USER"):
            cmd.extend(["--source-db-user", env["SOURCE_DB_USER"]])
        if env.get("SOURCE_DB_DRIVER_JAR_PATH"):
            cmd.extend(["--source-db-driver-jar-path", env["SOURCE_DB_DRIVER_JAR_PATH"]])
        if env.get("SOURCE_DB_DRIVER_CLASS_NAME"):
            cmd.extend(["--source-db-driver-class-name", env["SOURCE_DB_DRIVER_CLASS_NAME"]])
        if env.get("TARGET_DB_JDBC_URL"):
            cmd.extend(["--target-db-jdbc-url", env["TARGET_DB_JDBC_URL"]])
            has_db_params = True
            has_target = True
        if env.get("TARGET_DB_USER"):
            cmd.extend(["--target-db-user", env["TARGET_DB_USER"]])
        if env.get("TARGET_DB_DRIVER_JAR_PATH"):
            cmd.extend(["--target-db-driver-jar-path", env["TARGET_DB_DRIVER_JAR_PATH"]])
        if env.get("TARGET_DB_DRIVER_CLASS_NAME"):
            cmd.extend(["--target-db-driver-class-name", env["TARGET_DB_DRIVER_CLASS_NAME"]])

    if has_db_params:
        cmd.append("--enable-analysis-enhance")
        sys.stderr.write("[devkit_call] 检测到数据库连接信息，自动启用动态兼容性评估\n")

    return cmd, has_db_params, has_source, has_target


def _needs_password_automation(
    env: dict[str, str], has_db_params: bool, has_source: bool, has_target: bool,
) -> tuple[bool, str, str]:
    """判断是否需要密码自动化，返回 (need_automation, source_pwd, target_pwd)。

    规则（与原 shell 一致）：
      - 有 DB 连接信息 且 至少一个密码已设置 → 需要自动化
      - 有 source 连接信息但 SOURCE_DB_PWD 缺失 → 报错（jar 会挂起）
      - 有 target 连接信息但 TARGET_DB_PWD 缺失 → 报错（jar 会挂起）
    """
    source_pwd = env.get("SOURCE_DB_PWD", "")
    target_pwd = env.get("TARGET_DB_PWD", "")

    if has_source and not source_pwd:
        raise MigrationError(
            "DEVKIT_SOURCE_PWD_MISSING",
            "检测到源库连接信息但未设置 SOURCE_DB_PWD，jar 会挂起等待输入",
            1,
        )
    if has_target and not target_pwd:
        raise MigrationError(
            "DEVKIT_TARGET_PWD_MISSING",
            "检测到目标库连接信息但未设置 TARGET_DB_PWD，jar 会挂起等待输入",
            1,
        )

    need_source = has_source and bool(source_pwd)
    need_target = has_target and bool(target_pwd)
    need_automation = has_db_params and (need_source or need_target)
    return need_automation, source_pwd, target_pwd


def _has_pty_support() -> bool:
    """检查 pty 模块是否可用（Linux/macOS 可用，Windows 不可用）。"""
    if not _HAS_PTY_MODULE:
        return False
    try:
        import pty as _pty
        master, slave = _pty.openpty()
        os.close(master)
        os.close(slave)
        return True
    except (OSError, AttributeError):
        return False


def _write_log(
    work_dir: Path, started: str, started_ms: int,
    cmd: list[str], rc: int, note: str = "",
) -> None:
    """写入 sql-migration-entry.log，格式与 run_command 一致。"""
    elapsed = monotonic_ms() - started_ms
    try:
        with command_log_path(work_dir).open("a", encoding="utf-8") as fh:
            fh.write(f"\n[{started}] elapsed_ms={elapsed} rc={rc}\n")
            fh.write("$ " + " ".join(cmd) + "\n")
            if note:
                fh.write(note + "\n")
    except OSError:
        pass


def _run_with_pty(
    cmd: list[str], env: dict[str, str], work_dir: Path,
    source_pwd: str, target_pwd: str,
) -> int:
    """通过伪终端运行 jar，处理交互式密码输入。

    兼容 Console.readPassword()，因为伪终端下 System.console() 不返回 null。
    密码只发送 1 次，jar 再次提示（密码错误）即报错退出。
    输出实时转发到 stderr，日志只记 command/rc/elapsed（不记 output，避免泄露密码提示）。
    """
    import pty as _pty

    sys.stderr.write("[devkit_call] 使用 pty 自动处理密码输入\n")

    master, slave = _pty.openpty()
    merged_env = os.environ.copy()
    merged_env.update({k: str(v) for k, v in env.items()})

    try:
        proc = subprocess.Popen(
            cmd, env=merged_env, cwd=str(work_dir),
            stdin=slave, stdout=slave, stderr=slave,
            close_fds=True,
        )
    finally:
        os.close(slave)

    src_sent = 0
    tgt_sent = 0
    buffer = b""
    output_chunks: list[bytes] = []
    start_mono = time.monotonic()
    started = now_local()
    started_ms = monotonic_ms()
    error_rc: int | None = None

    try:
        while True:
            if time.monotonic() - start_mono > _CMD_TIMEOUT:
                sys.stderr.write("[devkit_call] ERROR: Timeout waiting for jar to complete\n")
                error_rc = 1
                break

            ready, _, _ = select.select([master], [], [], 1.0)
            if ready:
                try:
                    data = os.read(master, 4096)
                except OSError:
                    # EIO on Linux when slave side closed
                    break
                if not data:
                    break
                buffer += data
                output_chunks.append(data)
                try:
                    sys.stderr.buffer.write(data)
                    sys.stderr.buffer.flush()
                except (OSError, ValueError):
                    pass

                try:
                    text = buffer.decode("utf-8", errors="replace")
                except UnicodeDecodeError:
                    continue

                if _SOURCE_PWD_PROMPT.search(text):
                    if src_sent > 0:
                        sys.stderr.write("[devkit_call] ERROR: Source DB Password rejected\n")
                        error_rc = 1
                        break
                    try:
                        os.write(master, (source_pwd + "\r").encode())
                    except OSError:
                        pass
                    src_sent = 1
                    buffer = b""
                elif _TARGET_PWD_PROMPT.search(text):
                    if tgt_sent > 0:
                        sys.stderr.write("[devkit_call] ERROR: Target DB Password rejected\n")
                        error_rc = 1
                        break
                    try:
                        os.write(master, (target_pwd + "\r").encode())
                    except OSError:
                        pass
                    tgt_sent = 1
                    buffer = b""
                elif len(buffer) > 16384:
                    # 保留尾部用于跨 read 的模式匹配
                    buffer = buffer[-1024:]

            if proc.poll() is not None:
                # drain 剩余输出
                deadline = time.monotonic() + 2.0
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], 0.1)
                    if not ready:
                        break
                    try:
                        data = os.read(master, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    output_chunks.append(data)
                    try:
                        sys.stderr.buffer.write(data)
                        sys.stderr.buffer.flush()
                    except (OSError, ValueError):
                        pass
                break
    finally:
        try:
            os.close(master)
        except OSError:
            pass
        if proc.poll() is None:
            proc.kill()
        proc_rc = proc.wait()
        _write_log(work_dir, started, started_ms, cmd,
                   error_rc if error_rc is not None else proc_rc,
                   "(pty mode: output forwarded to stderr)")

    return error_rc if error_rc is not None else proc_rc


def _run_with_stdin_pipe(
    cmd: list[str], env: dict[str, str], work_dir: Path,
    source_pwd: str, target_pwd: str,
    has_source: bool, has_target: bool, reason: str,
) -> None:
    """回退方案：通过 stdin 管道传递密码（兼容 Scanner/BufferedReader）。

    限制：
      - 若 jar 使用 Console.readPassword()，stdin 重定向时 System.console() 返回 null，
        jar 可能崩溃。此场景需 pty 路径。
      - 密码只发送 1 次，错误则 jar 收到 EOF 报错退出。
      - 输出不捕获（避免密码回显泄露），仅记 command/rc/elapsed 到日志。
    """
    sys.stderr.write("[devkit_call] 警告：pty 不可用，使用 stdin 管道传递密码（可靠性较低，建议安装 pty 支持）\n")

    stdin_lines: list[str] = []
    if has_source and source_pwd:
        stdin_lines.append(source_pwd)
    if has_target and target_pwd:
        stdin_lines.append(target_pwd)
    stdin_data = "\n".join(stdin_lines).encode()

    merged_env = os.environ.copy()
    merged_env.update({k: str(v) for k, v in env.items()})

    started = now_local()
    started_ms = monotonic_ms()
    proc = subprocess.run(
        cmd, env=merged_env, cwd=str(work_dir),
        input=stdin_data,
        stdout=None, stderr=None,
    )
    _write_log(work_dir, started, started_ms, cmd, proc.returncode,
               "(stdin pipe mode: output not captured)")

    if proc.returncode != 0:
        raise MigrationError(reason, f"DevKit jar exited with code {proc.returncode}", proc.returncode)


def _run_plain(
    cmd: list[str], env: dict[str, str], work_dir: Path, reason: str,
) -> None:
    """无 DB 连接信息或无密码自动化的场景：直接执行 jar（通过 run_command 统一日志）。"""
    run_command(cmd, work_dir, env=env, reason=reason)


def run(
    env: dict[str, str], work_dir: Path,
    reason: str = "DEVKIT_SQL_MIGRATION_FAILED",
) -> None:
    """运行 DevKit jar，自动处理密码输入。失败时抛 MigrationError。

    env 应由调用方（如 analyze.run_devkit）通过 db_env() + 必填字段构造。
    密码（SOURCE_DB_PWD / TARGET_DB_PWD）从 env 取，用完即从 env 字典删除。
    """
    cmd, has_db_params, has_source, has_target = _build_cmd(env, work_dir)

    sys.stderr.write("[devkit_call] 执行 DevKit SQL 迁移...\n")
    sys.stderr.write(f"[devkit_call] cmd: {' '.join(cmd)}\n")

    need_automation, source_pwd, target_pwd = _needs_password_automation(
        env, has_db_params, has_source, has_target,
    )

    try:
        if need_automation and _has_pty_support():
            rc = _run_with_pty(cmd, env, work_dir, source_pwd, target_pwd)
            if rc != 0:
                if has_db_params:
                    sys.stderr.write(
                        "[devkit_call] 提示：数据库连接信息可能导致失败（密码错误/连接不通），"
                        "可降级为无数据库连接模式重跑（不传 DB 参数和密码）\n"
                    )
                raise MigrationError(reason, f"DevKit jar exited with code {rc}", rc)
        elif need_automation:
            _run_with_stdin_pipe(
                cmd, env, work_dir,
                source_pwd, target_pwd,
                has_source, has_target, reason,
            )
            if has_db_params:
                sys.stderr.write(
                    "[devkit_call] 提示：若因密码错误/连接不通失败，"
                    "可降级为无数据库连接模式重跑\n"
                )
        else:
            _run_plain(cmd, env, work_dir, reason)
            if has_db_params:
                sys.stderr.write(
                    "[devkit_call] 提示：若因数据库连接失败，"
                    "可降级为无数据库连接模式重跑\n"
                )
    finally:
        # 敏感信息使用完毕后立即清理（与原 shell 一致）
        env.pop("SOURCE_DB_PWD", None)
        env.pop("TARGET_DB_PWD", None)
