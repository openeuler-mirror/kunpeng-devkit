#!/usr/bin/env bash
# DevKit CLI 自动下载安装脚本
#
# 用法：
#   bash devkit_download.sh [--work-dir <工作目录>]
#
# 输出：
#   成功时 stdout 打印 `DEVKIT=<绝对路径>`，并将同一行写入
#   $WORK_DIR/reports/devkit_path.txt，供后续阶段读取。
#
# 退出码：
#   0  成功
#   1  参数/环境校验失败（WORK_DIR 未设置、目录不存在、缺少依赖命令）
#   2  镜像站不可达或未匹配到 CLI 包
#   3  下载失败（重试后仍失败）或文件不完整
#   4  解压失败
#   5  解压后未找到 devkit 可执行文件
#   6  devkit --version 验证失败
#   7  持久化路径写入失败

set -euo pipefail

log()  { echo "[devkit_download] $*" >&2; }
warn() { echo "[devkit_download] WARN: $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

# --- 0. 参数解析与前置校验 ---
WORK_DIR="${WORK_DIR:-./output}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir=*) WORK_DIR="${1#--work-dir=}"; shift ;;
    --work-dir|-w) WORK_DIR="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$WORK_DIR" || fail 1 "无法创建 WORK_DIR：$WORK_DIR"

for cmd in curl wget tar find stat; do
  command -v "$cmd" >/dev/null 2>&1 || fail 1 "缺少依赖命令：$cmd"
done

DOWNLOAD_DIR="$WORK_DIR/downloads"
DEVKIT_DIR="$WORK_DIR/devkit"
REPORT_DIR="$WORK_DIR/reports"
mkdir -p "$REPORT_DIR" "$DOWNLOAD_DIR" "$DEVKIT_DIR"

MIRROR_BASE="https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit"
PKG_PATTERN='DevKit-CLI-[0-9][^"]*Linux-Kunpeng\.tar\.gz'
MAX_RETRY=3
MIN_PKG_BYTES=1048576  # 1MB，低于此值视为下载不完整

# --- 1. 匹配最新 CLI 包 ---
log "查询镜像站：$MIRROR_BASE/"
LISTING=$(curl -fsSL --max-time 30 "$MIRROR_BASE/" 2>/dev/null || true)
[[ -n "$LISTING" ]] || fail 2 "镜像站不可达或返回空（请检查网络/代理）"

CLI_PKG=$(printf '%s\n' "$LISTING" \
  | grep -oE "$PKG_PATTERN" \
  | sort -V \
  | tail -1 || true)
[[ -n "$CLI_PKG" ]] || fail 2 "镜像站未匹配到 DevKit-CLI-*-Linux-Kunpeng.tar.gz（确认目录结构未变更）"

log "匹配到最新 CLI 包：$CLI_PKG"

# --- 2. 下载（断点续传 + 重试）---
TARGET="$DOWNLOAD_DIR/$CLI_PKG"
DL_RC=0
for i in $(seq 1 "$MAX_RETRY"); do
  if wget -c --no-check-certificate --tries=3 --timeout=60 --read-timeout=60 \
          "$MIRROR_BASE/$CLI_PKG" -O "$TARGET"; then
    DL_RC=0
    break
  else
    DL_RC=$?
    warn "下载失败（第 ${i}/${MAX_RETRY} 次，exit=${DL_RC}），重试中..."
    sleep 2
  fi
done
[[ $DL_RC -eq 0 ]] || fail 3 "下载失败：$MIRROR_BASE/$CLI_PKG"

# 完整性校验：文件须大于阈值
SIZE=$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET" 2>/dev/null || echo 0)
if [[ "$SIZE" -lt "$MIN_PKG_BYTES" ]]; then
  fail 3 "下载文件过小（${SIZE} 字节），疑似不完整：$TARGET"
fi

# --- 3. 解压（清理后重解，确保无残留）---
log "解压到 $DEVKIT_DIR"
rm -rf "$DEVKIT_DIR" && mkdir -p "$DEVKIT_DIR"
if ! tar -xzf "$TARGET" -C "$DEVKIT_DIR"; then
  fail 4 "解压失败：$TARGET（文件可能损坏，请删除后重试）"
fi

# --- 4. 定位 devkit 可执行文件 ---
DEVKIT_BIN=$(find "$DEVKIT_DIR" -type f -name "devkit" 2>/dev/null | head -1 || true)
[[ -n "$DEVKIT_BIN" ]] || fail 5 "解压后未找到 devkit 可执行文件（确认包结构未变更）"

# 确保可执行权限（失败仅告警，不中止）
if ! chmod +x "$DEVKIT_BIN" 2>/dev/null; then
  warn "chmod +x 失败：$DEVKIT_BIN（继续尝试 --version）"
fi

# --- 5. 验证 --version ---
BIN_DIR="$(dirname "$DEVKIT_BIN")"
export LD_LIBRARY_PATH="${BIN_DIR}/lib:${BIN_DIR}/../lib:${LD_LIBRARY_PATH:-}"
log "验证：$DEVKIT_BIN --version"
if ! "$DEVKIT_BIN" --version >/dev/null 2>&1; then
  # 再次执行以输出诊断信息
  "$DEVKIT_BIN" --version >&2 || true
  fail 6 "devkit --version 验证失败（检查 LD_LIBRARY_PATH / 缺失动态库 / 架构匹配）"
fi

# --- 6. 持久化路径 ---
PATH_FILE="$REPORT_DIR/devkit_path.txt"
if ! printf 'DEVKIT_BIN=%s\n' "$DEVKIT_BIN" > "$PATH_FILE"; then
  fail 7 "写入 $PATH_FILE 失败（检查目录权限/磁盘空间）"
fi

# 结果输出（供 agent 解析）
echo "DEVKIT=$DEVKIT_BIN"
log "成功：DEVKIT=$DEVKIT_BIN"
log "路径已写入：$PATH_FILE"
