#!/usr/bin/env python3
"""Tuner 训练/续调监控脚本。

在后台启动 Tuner 训练或续调，监控训练进度，记录轮次、性能、失败次数等信息，
并持续写入工作空间的 tuning-data.json 供 TUI 仪表盘展示。

用法:
  新训练:  python3 tuner_monitor.py train_dir task.yaml param.yaml
  续调:    python3 tuner_monitor.py continue <train_result_dir> <rounds>

"""

import asyncio
import os
import shutil
import subprocess
import re
import glob
import sys
import datetime
import time
import json
import tempfile

# ── 输出文件路径 ──────────────────────────────────────────────────
# 输出到 Agent 工作空间（当前工作目录），而非脚本所在目录
OUTPUT_PATH = os.path.join(os.getcwd(), "tuning-data.json")


# ── devkit 路径解析 ─────────────────────────────────────────────────

# 常见安装目录（可执行文件名为 devkit）
DEVKIT_CANDIDATE_DIRS = [
    "/opt/*/devkit",
    "/root/workspace/*/devkit",
    "/usr/local/*/devkit",
    "/home/*/devkit",
]

def _which_devkit():
    """通过 PATH 查找 devkit 命令。"""
    try:
        p = subprocess.run(["which", "devkit"], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except FileNotFoundError:
        pass
    return None


def _glob_devkit():
    """在常见安装目录下用 glob 探测可执行的 devkit。"""
    for pattern in DEVKIT_CANDIDATE_DIRS:
        for path in sorted(glob.glob(pattern)):
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
    return None


def resolve_devkit(user):
    """解析 devkit 可执行文件路径。

    优先级：
      1. 用户显式传入的路径（非默认值 'devkit'）——直接信任
      2. which devkit（PATH 中可用）
      3. 常见安装目录 glob 探测
      4. 全部失败 → 返回 None，由调用方报错
    """
    if user and user != "devkit":
        return user
    found = _which_devkit() or _glob_devkit()
    return found

class LogType:
    """日志类型枚举。"""
    BASELINE = "baseline"
    PERF = "perf"
    FAIL = "fail"
    DONE = "done"


# ── 日志解析 ────────────────────────────────────────────────────────

BASELINE_RE = re.compile(r"kunpeng automatic tuning - baseline test")
ROUND_RE = re.compile(r"automatic tuning - round (\d+)")
PERF_RE = re.compile(r"Performance\s+:\s+([0-9.]+)")
TOTAL_RE = re.compile(r"Total round\s+:\s+(\d+)")
FAIL_RE = re.compile(r"Run test failed|Round \[\d+\] failed|run test.*failed", re.I)
DONE_RE = re.compile(r"Auto Tuning Report|Total Report|Finish using")
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")


def _log_ts(line):
    """从日志行提取时间戳（秒），失败返回 None。"""
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        return dt.timestamp()
    except ValueError:
        return None

def parse_log_since(lines_iter, state):
    """解析日志行，更新监控状态。lines_iter 为新增行迭代器。"""
    log_type = None
    for line in lines_iter:
        m = BASELINE_RE.search(line)
        if m:
            log_type = LogType.BASELINE
            continue
        m = TOTAL_RE.search(line)
        if m:
            state["total"] = int(m.group(1))
            continue
        m = ROUND_RE.search(line)
        if m:
            r = int(m.group(1))
            state["current_round"] = r
            # 记录轮次开始时间（优先用日志时间戳）用于计算轮耗时
            ts = _log_ts(line)
            if ts is None:
                ts = time.time()
            state.setdefault("_round_starts", []).append((r, ts))
            log_type = LogType.PERF
            continue
        m = PERF_RE.search(line)
        if m:
            val = float(m.group(1))
            if log_type == LogType.BASELINE:
                state["baseline"] = val
            else:
                state["results"].append(val)
                ts = _log_ts(line)
                if ts is None:
                    ts = time.time()
                state.setdefault("_round_ends", []).append(ts)
                if state["best"] is None or val > state["best"]:
                    state["best"] = val
                    state["best_round"] = r
                state["fails"] = 0  # 成功一轮，重置连续失败
            continue
        if FAIL_RE.search(line):
            state["fails"] = state["fails"] + 1
            if r :
                state["results"].append(0)
            continue
        if DONE_RE.search(line):
            state["done_seen"] = True
            log_type = LogType.DONE
            continue
    return log_type


def build_output(state, prior_iterations=None):
    """根据监控状态构建输出数据。prior_iterations 为续调时已存在的历史轮次。"""
    baseline = state["baseline"] or 0.0

    # 合并历史轮次 + 本轮新增轮次（按轮次号去重，保持单调递增）
    merged: dict[int, dict] = {}
    if prior_iterations:
        for it in prior_iterations:
            r = it.get("round")
            if r is not None:
                merged[int(r)] = dict(it)
    next_free = max(merged.keys(), default=0) + 1
    for i, score in enumerate(state["results"], start=1):
        improvement = round((score - baseline) / baseline * 100, 2) if baseline else 0.0
        r = 0
        for n in range(next_free, next_free + len(state["results"]) + 1):
            if n not in merged:
                r = n
                break
        merged[r] = {
            "round": r,
            "score": score,
            "improvement": improvement,
            "status": "completed",
            "timestamp": datetime.datetime.fromtimestamp(state["_round_ends"][i - 1], tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if i - 1 < len(state["_round_ends"]) else None,
        }

    iterations = [merged[k] for k in sorted(merged)]

    # 重新计算最优轮/最新轮（基于合并后全量数据）
    best_round = None
    best_score = None
    for it in iterations:
        s = it.get("score")
        if s is not None and (best_score is None or s > best_score):
            best_score = s
            best_round = it.get("round")

    output = {}
    output["task"] = "Kunpeng DevKit Parameter Tuning"
    output["status"] = "done" if state.get("done_seen") else "running"
    output["totalRounds"] = state["total"]
    output["currentRound"] = iterations[-1]["round"] if iterations else state["current_round"]
    output["bestRound"] = best_round if best_round is not None else state["best_round"]
    output["bestScore"] = best_score if best_score is not None else state["best"]
    output["baseScore"] = state["baseline"]
    output["iterations"] = iterations
    return output


def atomic_write_json(path, data):
    """原子写入 JSON 文件：先写临时文件，再 rename，避免多线程读取错误。"""
    dir_name = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def build_cmd(output_dir, task, param):
    train_dir = os.path.abspath(output_dir or os.getcwd())

    if os.path.exists(train_dir):
        print(f"Warning: Training directory {train_dir} already exists. Removing it.")
        shutil.rmtree(train_dir)

    # 解析 devkit 路径（自动探测，找不到则报错）
    devkit = resolve_devkit(None)
    if devkit is None:
        print("Error: Failed to locate devkit automatically. Please specify the full path with --devkit.", file=sys.stderr)
        print("  Example: python3 tuner_monitor.py launch ... --devkit /root/workspace/DevKit-CLI-*/devkit",
              file=sys.stderr)
        sys.exit(1)

    return [
        devkit, "kat", "train",
        "-t", task,
        "-p", param,    
        "-o", train_dir,
    ]


def build_continue_cmd(train_result_dir, rounds):
    """构造 continue 命令：基于历史结果追加训练。

    注意：continue 内部会自动 audit+bak+clear，训练结束自动 set(0) 恢复基线。
    """
    train_result_dir = os.path.abspath(train_result_dir)
    if not os.path.isdir(train_result_dir):
        print(f"Error: Training result directory does not exist: {train_result_dir}", file=sys.stderr)
        sys.exit(1)

    devkit = resolve_devkit(None)
    if devkit is None:
        print("Error: Failed to locate devkit automatically. Please specify the full path with --devkit.", file=sys.stderr)
        sys.exit(1)

    if int(rounds) <= 0:
        print("Error: rounds must be > 0 for continue training.", file=sys.stderr)
        sys.exit(1)

    return [devkit, "kat", "continue", "-i", train_result_dir, "-r", str(int(rounds))]


def load_prior_iterations(json_path):
    """读取已有 tuning-data.json，返回 (iterations, base_score, total_rounds, best)。"""
    if not json_path or not os.path.isfile(json_path):
        return [], None, None, None
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        iterations = data.get("iterations", [])
        base_score = data.get("baseScore")
        total = data.get("totalRounds")
        best_round = data.get("bestRound")
        best_score = data.get("bestScore")
        return iterations, base_score, total, {"round": best_round, "score": best_score}
    except Exception as e:
        print(f"Warning: Failed to read prior tuning data {json_path}: {e}", file=sys.stderr)
        return [], None, None, None

async def _drain_stderr(stream):
    """并发读取并打印 stderr 输出。"""
    while True:
        line = await stream.readline()
        if not line:
            break
        print(f"[stderr] {line.decode('utf-8').strip()}", file=sys.stderr)


async def monitor_loop(train_dir, task, param, mode="train", rounds=None):
    """监控循环，后台运行。mode = train | continue。"""
    # continue 模式：读取已有 tuning-data.json 作为历史轮次，合并输出
    prior_iterations = []
    state = {
        "total": None,
        "current_round": 0,
        "results": [],
        "best": None,
        "baseline": None,
        "fails": 0,
        "best_round": None,
        "done_seen": False,
        "_round_starts": [],
        "_round_ends": [],
    }
    if mode == "continue":
        prior_iterations, base_score, total_prior, prior_best = load_prior_iterations(OUTPUT_PATH)
        state["baseline"] = base_score
        state["total"] = total_prior
        state["best"] = prior_best.get("score") if prior_best else None
        state["best_round"] = prior_best.get("round") if prior_best else None

    cmd = build_continue_cmd(train_dir, rounds) if mode == "continue" else build_cmd(train_dir, task, param)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    stderr_task = asyncio.create_task(_drain_stderr(proc.stderr))
    lines = []
    try:
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            line_str = line.decode("utf-8").strip()
            if "==============================" in line_str:
                if lines:
                    log_type = parse_log_since(lines, state)
                    if log_type is not None:
                        atomic_write_json(OUTPUT_PATH, build_output(state, prior_iterations))
                    if log_type is LogType.BASELINE:
                        print(f"Baseline test completed. Baseline performance: {state['baseline']}")
                    elif log_type is LogType.PERF:
                        print(f"Round {state['current_round']} completed. Performance: {state['results'][-1]}, Improvement: {(state['results'][-1] - state['baseline']) / state['baseline'] * 100:.2f}%")
                    elif log_type is LogType.FAIL:
                        print(f"Round {state['current_round']} failed. Fails: {state['fails'][-1]}")
                    elif log_type is LogType.DONE:
                        print("Auto Tuning Report completed.")
                        print(f"Total round: {state['total']}")
                        print(f"Best performance: {state['best']}, Best round: {state['best_round']}")
                        print(f"Fails: {state['fails']}")
                        print(f"Done: {state['done_seen']}")
                    lines.clear()
            lines.append(line_str)
    except KeyboardInterrupt:
        print("\nMonitor interrupted by user, terminating training process...")
    except Exception as e:
        print(f"\nMonitor exited due to exception: {e}", file=sys.stderr)
    finally:
        stderr_task.cancel()
        try:
            await stderr_task
        except asyncio.CancelledError:
            pass
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
        else:
            await proc.wait()

if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "continue":
        # 续调：python3 tuner_monitor.py continue <train_result_dir> <rounds>
        try:
            rounds = int(sys.argv[3])
        except ValueError:
            print("Usage: python3 tuner_monitor.py continue <train_result_dir> <rounds>", file=sys.stderr)
            sys.exit(1)
        asyncio.run(monitor_loop(sys.argv[2], None, None, mode="continue", rounds=rounds))
    elif len(sys.argv) < 4:
        print("Usage: python3 tuner_monitor.py <train_dir> <task> <param>", file=sys.stderr)
        print("       python3 tuner_monitor.py continue <train_result_dir> <rounds>", file=sys.stderr)
        sys.exit(1)
    else:
        asyncio.run(monitor_loop(sys.argv[1], sys.argv[2], sys.argv[3]))   
