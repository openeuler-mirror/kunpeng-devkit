#!/usr/bin/env bash
# BoostKit KSL（Kunpeng Standard Library）自动下载安装脚本
#
# 用途：下载 BoostKit-ksl zip 包，解压并安装其中的 RPM 包，使鲲鹏平台获得
#       avx2ki.h 头文件和 libavx2ki.so 动态库（x86 AVX/SSE intrinsics 到
#       NEON 的映射兼容层）。
#
# 用法：
#   bash ksl_install.sh [--work-dir <工作目录>]
#
# 输出：
#   成功时 stdout 打印 `KSL_INCLUDE=<路径>` 与 `KSL_LIB=<路径>`，并将同一行
#   写入 $WORK_DIR/reports/ksl_path.txt，供后续阶段读取。
#
# 退出码：
#   0  成功
#   1  参数/环境校验失败（WORK_DIR 未设置、目录不存在、缺少依赖命令）
#   2  下载失败（重试后仍失败）或文件不完整
#   3  解压失败
#   4  解压后未找到 RPM 包
#   5  RPM 安装失败（dnf/yum/rpm 均失败）
#   6  安装后验证失败（未找到 avx2ki.h 或 libavx2ki.so）
#   7  持久化路径写入失败

set -euo pipefail

if [[ -v LD_LIBRARY_PATH_ORIG ]]; then
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH_ORIG"
fi

log()  { echo "[ksl_install] $*" >&2; }
warn() { echo "[ksl_install] WARN: $*" >&2; }
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

for cmd in wget unzip find; do
  command -v "$cmd" >/dev/null 2>&1 || fail 1 "缺少依赖命令：$cmd"
done

# RPM 安装工具：dnf / yum / rpm 至少需有一个
# 检测时不仅验证命令存在，还要验证能真正运行（避免 dnf 存在但模块损坏的情况）
RPM_TOOL=""
for cmd in dnf yum rpm; do
  if command -v "$cmd" >/dev/null 2>&1 && "$cmd" --version >/dev/null 2>&1; then
    RPM_TOOL="$cmd"
    break
  fi
done
[[ -n "$RPM_TOOL" ]] || fail 1 "缺少可用的 RPM 安装工具：dnf / yum / rpm 均未找到或不可用"

KSL_DIR="$WORK_DIR/ksl"
REPORT_DIR="$WORK_DIR/reports"
mkdir -p "$KSL_DIR" "$REPORT_DIR"

KSL_VERSION="2.5.3"
KSL_ZIP="BoostKit-ksl_${KSL_VERSION}.zip"
KSL_URL="https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20BoostKit/Kunpeng%20BoostKit%2025.3.0/${KSL_ZIP}"
KSL_EXTRACT_DIR="$KSL_DIR/BoostKit-ksl_${KSL_VERSION}"
MAX_RETRY=3
MIN_PKG_BYTES=1048576  # 1MB，低于此值视为下载不完整

# --- 1. 下载 BoostKit-ksl 包 ---
log "下载 $KSL_ZIP"
log "URL: $KSL_URL"
TARGET="$KSL_DIR/$KSL_ZIP"
DL_RC=0
for i in $(seq 1 "$MAX_RETRY"); do
  if wget -c --no-check-certificate --tries=3 --timeout=60 --read-timeout=60 "$KSL_URL" -O "$TARGET"; then
    DL_RC=0
    break
  else
    DL_RC=$?
    warn "下载失败（第 ${i}/${MAX_RETRY} 次，exit=${DL_RC}），重试中..."
    sleep 2
  fi
done
[[ $DL_RC -eq 0 ]] || fail 2 "下载失败：$KSL_URL"

# 完整性校验：文件须大于阈值
SIZE=$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET" 2>/dev/null || echo 0)
if [[ "$SIZE" -lt "$MIN_PKG_BYTES" ]]; then
  fail 2 "下载文件过小（${SIZE} 字节），疑似不完整：$TARGET"
fi
log "下载完成（$(echo "$SIZE" | numfmt --to=iec 2>/dev/null || echo "${SIZE} 字节")）"

# --- 2. 解压 zip 包 ---
log "解压到 $KSL_EXTRACT_DIR"
rm -rf "$KSL_EXTRACT_DIR" && mkdir -p "$KSL_EXTRACT_DIR"
if ! unzip -q "$TARGET" -d "$KSL_EXTRACT_DIR"; then
  fail 3 "解压失败：$TARGET（文件可能损坏，请删除后重试）"
fi

# 列出解压出的 rpm 包
log "解压内容中的 RPM 包："
find "$KSL_EXTRACT_DIR" -name "*.rpm" -print | sort >&2 || true

# --- 3. 安装 RPM 包 ---
RPM_LIST=$(find "$KSL_EXTRACT_DIR" -name "*.rpm" | sort)
[[ -n "$RPM_LIST" ]] || fail 4 "解压后未找到 RPM 包（确认包结构未变更）"

log "使用 $RPM_TOOL 安装 RPM 包"
INSTALL_OK=0
# 按优先级尝试安装：优先用检测到的工具，失败则依次降级
for tool in "$RPM_TOOL" yum rpm; do
  command -v "$tool" >/dev/null 2>&1 || continue
  case "$tool" in
    dnf)
      if find "$KSL_EXTRACT_DIR" -name "*.rpm" -print0 | xargs -0 dnf install -y; then
        INSTALL_OK=1
      fi
      ;;
    yum)
      if find "$KSL_EXTRACT_DIR" -name "*.rpm" -print0 | xargs -0 yum install -y; then
        INSTALL_OK=1
      fi
      ;;
    rpm)
      # rpm 无依赖解析，加 --nodeps 避免依赖链阻断
      if find "$KSL_EXTRACT_DIR" -name "*.rpm" -exec rpm -ivh --nodeps {} \;; then
        INSTALL_OK=1
      fi
      ;;
  esac
  [[ $INSTALL_OK -eq 1 ]] && break
  [[ "$tool" != "rpm" ]] && warn "$tool 安装失败，尝试下一个工具"
done
[[ $INSTALL_OK -eq 1 ]] || fail 5 "RPM 安装失败（dnf/yum/rpm 均失败）"

# --- 4. 验证安装 ---
log "验证 avx2ki.h 和 libavx2ki.so"

KSL_HEADER=$(find /usr -name "avx2ki.h" 2>/dev/null | head -1 || true)
[[ -n "$KSL_HEADER" ]] || fail 6 "未找到 avx2ki.h（安装可能未成功）"

KSL_LIBFILE=$(find /usr -name "libavx2ki.so" 2>/dev/null | head -1 || true)
[[ -n "$KSL_LIBFILE" ]] || fail 6 "未找到 libavx2ki.so（安装可能未成功）"

KSL_INCLUDE=$(dirname "$KSL_HEADER")
KSL_LIB=$(dirname "$KSL_LIBFILE")
log "KSL_INCLUDE=$KSL_INCLUDE"
log "KSL_LIB=$KSL_LIB"

# --- 5. 持久化路径 ---
PATH_FILE="$REPORT_DIR/ksl_path.txt"
if ! printf 'KSL_INCLUDE=%s\nKSL_LIB=%s\n' "$KSL_INCLUDE" "$KSL_LIB" > "$PATH_FILE"; then
  fail 7 "写入 $PATH_FILE 失败（检查目录权限/磁盘空间）"
fi

# 结果输出（供 agent 解析）
echo "KSL_INCLUDE=$KSL_INCLUDE"
echo "KSL_LIB=$KSL_LIB"
log "成功：KSL 已安装（头文件=$KSL_INCLUDE，库=$KSL_LIB）"
log "路径已写入：$PATH_FILE"
