#!/usr/bin/env bash
# download_jdk.sh
# 毕昇 JDK 21 定位/下载脚本（定位优先，下载兜底）
#
# 职责：定位或下载 JDK，输出 jdk_path.txt 供后续阶段读取。
# 定位顺序（找到且版本 >=21 即返回，不下载）：
#   1. $WORK_DIR/reports/jdk_path.txt 已记录的 JAVA_HOME
#   2. /opt, /home, /usr/lib, $WORK_DIR 下的 bin/javac
#   3. 未定位到则从华为云镜像站下载毕昇 JDK 21（备选标准 OpenJDK）
# 注：通过 JDK_URL/JDK_VERSION 显式指定下载源时跳过定位，直接下载。
#
# 用法：
#   WORK_DIR=<工作目录> bash download_jdk.sh
#
# 可选参数：
#   JDK_VERSION=<版本号>  指定下载版本，默认 21.0.6（跳过定位直接下载）
#   JDK_URL=<下载URL>     直接指定下载URL（优先于版本号，跳过定位直接下载）
#
# 输出：
#   成功时 stdout 打印 `JAVA_HOME=<绝对路径>`，供后续阶段读取。
#   同时将结果写入 $WORK_DIR/reports/jdk_path.txt。
#
# 退出码：
#   0  成功
#   1  参数/环境校验失败
#   2  镜像站不可达或未匹配到包
#   3  下载失败或文件不完整
#   4  解压失败
#   5  解压后未找到 JDK
#   6  Java 版本验证失败
#   7  写入结果文件失败

set -euo pipefail

log()  { echo "[download_jdk] $*" >&2; }
warn() { echo "[download_jdk] WARN: $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

# --- 0. 前置校验 ---
[[ -n "${WORK_DIR:-}" ]] || fail 1 "环境变量 WORK_DIR 未设置"
[[ -d  "$WORK_DIR"    ]] || fail 1 "WORK_DIR 不是目录：$WORK_DIR"

for cmd in curl wget tar find stat; do
  command -v "$cmd" >/dev/null 2>&1 || fail 1 "缺少依赖命令：$cmd"
done

DOWNLOAD_DIR="$WORK_DIR/downloads"
JDK_DIR="$WORK_DIR/bisheng-jdk"
REPORT_DIR="$WORK_DIR/reports"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$REPORT_DIR" "$DOWNLOAD_DIR" "$JDK_DIR" "$LOG_DIR"

# --- 0.5 定位优先：在已知位置搜索已存在的 JDK ---
#
# 搜索顺序（找到且满足版本要求即返回，不下载）：
#   1. $WORK_DIR/reports/jdk_path.txt（之前已下载/定位的 JDK 路径记录）
#   2. /opt, /home, /usr/lib, $WORK_DIR 下的 bin/javac
# 仅当未通过 JDK_URL/JDK_VERSION 显式指定下载源时才尝试定位。
locate_existing_jdk() {
    # 1. 已有路径记录
    local report_file="$REPORT_DIR/jdk_path.txt"
    if [[ -f "$report_file" ]]; then
        local recorded_home
        recorded_home=$(grep -E '^JAVA_HOME=' "$report_file" 2>/dev/null | head -1 | cut -d= -f2- || true)
        if [[ -n "$recorded_home" && -x "${recorded_home}/bin/javac" ]]; then
            echo "${recorded_home}/bin/javac"
            return 0
        fi
    fi

    # 2. 搜索系统常见目录与工作目录
    local search_roots=("/opt" "/home" "/usr/lib" "$WORK_DIR")
    for root in "${search_roots[@]}"; do
        [[ -d "$root" ]] || continue
        local found_javac
        found_javac=$(find "$root" -maxdepth 6 -type f -name "javac" 2>/dev/null | head -1 || true)
        if [[ -n "$found_javac" && -x "$found_javac" ]]; then
            echo "$found_javac"
            return 0
        fi
    done
    return 1
}

# 校验定位到的 javac 并写 jdk_path.txt；版本不满足时返回 1 让外层继续下载。
write_jdk_path() {
    local javac_path="$1"
    local java_home
    java_home=$(dirname "$(dirname "$javac_path")")

    local java_cmd="${java_home}/bin/java"
    if [[ ! -x "$java_cmd" ]]; then
        warn "定位到的 JDK 缺少 bin/java：$java_home，继续下载"
        return 1
    fi

    local version_output version major
    version_output=$("${java_cmd}" -version 2>&1 | head -1 || true)
    version=$(echo "$version_output" | awk -F '"' '{print $2}')
    major=$(echo "${version}" | cut -d'.' -f1)
    if [[ -z "$major" || "$major" -lt 21 ]]; then
        warn "定位到的 JDK 版本不满足 >=21（${version:-未知}），继续下载"
        return 1
    fi
    log "定位到可用 JDK：$java_home（版本 $version）"

    local path_file="$REPORT_DIR/jdk_path.txt"
    printf 'JAVA_HOME=%s\nJAVA_BIN=%s\nJAVA_VERSION=%s\n' \
        "$java_home" "${java_home}/bin/java" "${version}" > "$path_file" \
        || fail 7 "写入 $path_file 失败（检查目录权限/磁盘空间）"

    echo "JAVA_HOME=$java_home"
    cat <<EOF
{
  "java_home": "${java_home}",
  "java_bin": "${java_home}/bin/java",
  "java_version": "${version}",
  "located": true,
  "success": true
}
EOF
    log "已定位 JDK（未下载）：javac=${javac_path}"
    log "路径已写入：$path_file"
    exit 0
}

EXISTING_JAVAC=""
if [[ -z "${JDK_URL:-}" && -z "${JDK_VERSION:-}" ]]; then
    EXISTING_JAVAC=$(locate_existing_jdk || true)
fi
if [[ -n "$EXISTING_JAVAC" ]]; then
    write_jdk_path "$EXISTING_JAVAC" || EXISTING_JAVAC=""
fi

log "未定位到可用 JDK，进入下载流程"

# 毕昇 JDK 下载源
# 毕昇 JDK 位于 kunpeng/archive/compiler/bisheng_jdk/ 目录下
# 包名格式为 bisheng-jdk-{version}-linux-aarch64.tar.gz（部分版本含构建号后缀，如 -b12）
# 仅支持 Kunpeng/aarch64 架构
MIRROR_BASE="https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk"
# 标准 OpenJDK 备选下载源
OPENJDK_MIRROR_BASE="https://mirrors.huaweicloud.com/openjdk"
MAX_RETRY=3
MIN_PKG_BYTES=104857600  # 100MB，低于此值视为下载不完整

# 默认版本
if [ -n "${JDK_VERSION:-}" ]; then
    VERSION="${JDK_VERSION}"
else
    VERSION="21.0.6"
fi

ARCH_SUFFIX="linux-aarch64"
OPENJDK_ARCH="linux-aarch64_bin"
log "包名后缀: $ARCH_SUFFIX"

# --- 1. 确定下载 URL ---
if [ -n "${JDK_URL:-}" ]; then
    DOWNLOAD_URL="${JDK_URL}"
    ARCHIVE_NAME=$(basename "${DOWNLOAD_URL}")
    log "使用指定URL: ${DOWNLOAD_URL}"
else
    # 根据版本构建下载URL
    # 毕昇 JDK 包名格式有两种：
    #   1. bisheng-jdk-{version}-{arch}.tar.gz（如 21.0.3, 21.0.4, 21.0.5）
    #   2. bisheng-jdk-{version}-b{build}-{arch}.tar.gz（如 21.0.6-b12, 21.0.7-b12）
    # 先尝试不带构建号的包名，404时再尝试带构建号的包名
    JDK_MAJOR=$(echo "${VERSION}" | cut -d'.' -f1)
    
    # 尝试方式1：不带构建号
    ARCHIVE_NAME="bisheng-jdk-${VERSION}-${ARCH_SUFFIX}.tar.gz"
    DOWNLOAD_URL="${MIRROR_BASE}/${ARCHIVE_NAME}"
    
    # 检查URL是否有效
    HTTP_CODE=$(curl -sI --max-time 15 -o /dev/null -w "%{http_code}" "$DOWNLOAD_URL" 2>/dev/null || echo "000")
    
    if [[ "$HTTP_CODE" != "200" ]]; then
        # 尝试方式2：带构建号，从镜像站目录页爬取匹配的包名
        log "不带构建号的包不存在(HTTP $HTTP_CODE)，查询镜像站匹配带构建号的包..."
        LISTING=$(curl -fsSL --max-time 30 "$MIRROR_BASE/" 2>/dev/null || true)
        if [[ -n "$LISTING" ]]; then
            # 匹配 bisheng-jdk-{version}-b*-{arch}.tar.gz
            MATCHED_PKG=$(printf '%s\n' "$LISTING" \
              | grep -oE "bisheng-jdk-${VERSION}-b[0-9]+-${ARCH_SUFFIX}\.tar\.gz" \
              | sort -V \
              | tail -1 || true)
            if [[ -n "$MATCHED_PKG" ]]; then
                ARCHIVE_NAME="$MATCHED_PKG"
                DOWNLOAD_URL="${MIRROR_BASE}/${ARCHIVE_NAME}"
                log "匹配到带构建号的包: $ARCHIVE_NAME"
            else
                # 尝试方式3：标准 OpenJDK 作为备选
                log "毕昇 JDK ${VERSION} 未找到，尝试标准 OpenJDK..."
                ARCHIVE_NAME="openjdk-${JDK_MAJOR}_linux-x64_bin.tar.gz"
                DOWNLOAD_URL="${OPENJDK_MIRROR_BASE}/${JDK_MAJOR}/${ARCHIVE_NAME}"
                HTTP_CODE=$(curl -sI --max-time 15 -o /dev/null -w "%{http_code}" "$DOWNLOAD_URL" 2>/dev/null || echo "000")
                if [[ "$HTTP_CODE" != "200" ]]; then
                    fail 2 "镜像站未找到毕昇 JDK ${VERSION} 或标准 OpenJDK ${JDK_MAJOR}（HTTP $HTTP_CODE）"
                fi
                log "使用标准 OpenJDK: $ARCHIVE_NAME"
            fi
        else
            fail 2 "镜像站不可达：$MIRROR_BASE/"
        fi
    fi
    log "下载版本 ${VERSION}: ${DOWNLOAD_URL}"
fi

# --- 2. 下载（断点续传 + 重试）---
TARGET="$DOWNLOAD_DIR/$ARCHIVE_NAME"
DL_RC=0
for i in $(seq 1 "$MAX_RETRY"); do
  if wget -c --tries=3 --timeout=60 --read-timeout=60 \
          "$DOWNLOAD_URL" -O "$TARGET"; then
    DL_RC=0
    break
  fi
  DL_RC=$?
  warn "下载失败（第 ${i}/${MAX_RETRY} 次，exit=${DL_RC}），重试中..."
  sleep 2
done
[[ $DL_RC -eq 0 ]] || fail 3 "下载失败：$DOWNLOAD_URL"

# 完整性校验：文件须大于阈值
SIZE=$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET" 2>/dev/null || echo 0)
if [[ "$SIZE" -lt "$MIN_PKG_BYTES" ]]; then
  fail 3 "下载文件过小（${SIZE} 字节），疑似不完整：$TARGET"
fi
log "下载完成，文件大小: $SIZE 字节"

# --- 3. 解压（清理后重解，确保无残留）---
log "解压到 $JDK_DIR"
rm -rf "$JDK_DIR" && mkdir -p "$JDK_DIR"
if ! tar -xzf "$TARGET" -C "$JDK_DIR"; then
  fail 4 "解压失败：$TARGET（文件可能损坏，请删除后重试）"
fi

# --- 4. 定位 JDK ---
JDK_HOME=$(find "$JDK_DIR" -maxdepth 2 -name "bin" -type d 2>/dev/null | head -1 || true)
if [ -z "${JDK_HOME}" ]; then
    fail 5 "解压后未找到 JDK bin 目录"
fi

JDK_HOME=$(dirname "${JDK_HOME}")
log "找到 JDK: ${JDK_HOME}"

# --- 5. 验证 Java 版本 ---
JAVA_CMD="${JDK_HOME}/bin/java"
if [ ! -f "${JAVA_CMD}" ]; then
    fail 5 "未找到 java 命令: ${JAVA_CMD}"
fi

JAVA_VERSION_OUTPUT=$("${JAVA_CMD}" -version 2>&1 | head -1 || true)
JAVA_VERSION=$(echo "${JAVA_VERSION_OUTPUT}" | awk -F '"' '{print $2}')
log "Java 版本: ${JAVA_VERSION_OUTPUT}"

# 校验版本 >= 21
JDK_MAJOR_VERSION=$(echo "${JAVA_VERSION}" | cut -d'.' -f1)
if [[ "$JDK_MAJOR_VERSION" -lt 21 ]]; then
    fail 6 "Java 版本 ${JAVA_VERSION} 低于 21，不满足要求"
fi

# --- 6. 持久化路径 ---
PATH_FILE="$REPORT_DIR/jdk_path.txt"

if ! printf 'JAVA_HOME=%s\nJAVA_BIN=%s\nJAVA_VERSION=%s\n' \
    "$JDK_HOME" "$JDK_HOME/bin/java" "$JAVA_VERSION" \
    > "$PATH_FILE"; then
  fail 7 "写入 $PATH_FILE 失败（检查目录权限/磁盘空间）"
fi

# 结果输出（JSON）
echo "JAVA_HOME=$JDK_HOME"
log "成功：JAVA_HOME=$JDK_HOME"
log "路径已写入：$PATH_FILE"

# 同时输出 JSON 格式结果
cat <<EOF
{
  "java_home": "${JDK_HOME}",
  "java_bin": "${JDK_HOME}/bin/java",
  "java_version": "${JAVA_VERSION}",
  "success": true
}
EOF
