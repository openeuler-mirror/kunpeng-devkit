#!/usr/bin/env bash
# download_devkit.sh
# DevKit 环境准备脚本（定位优先，下载兜底）
#
# 职责：定位或下载 DevKit，输出 devkit_path.txt 供后续阶段读取。
#
# 流程：
#   1. 定位已解压的 jar（找到即返回，不下载、不解压），搜索 DEVKIT_SEARCH_ROOTS（从小到大）：
#        a. 工作目录 work_dir（含 sql-analysis/ 子目录）
#        b. 系统目录 /opt, /home
#   2. 未定位到 jar 时，按以下来源取得压缩包并解压：
#        a. DEVKIT_PACKAGE_PATH（用户提供压缩包，仅解压）
#        b. DEVKIT_SEARCH_ROOTS 里已缓存的压缩包（含 work_dir/downloads/；命中且 size≥10MB 则复用，跳过下载）
#        c. 从华为云镜像站下载最新版（DEVKIT_URL/DEVKIT_VERSION 可指定）
#
# 压缩包格式（26.2.RC1+）：
#   DevKit-AI-Migration-Tool-<ver>-Linux-Kunpeng.tar.gz  单层结构
#   解压即得 DevKit-AI-Migration-Tool-<ver>-Linux-Kunpeng/ 目录，
#   jar 位于其下 sql_analysis/sql-analysis-<ver>.jar，config 位于 sql_analysis/config/，
#   内嵌 JRE 位于 sql_analysis/jre/。
#
# 用法：
#   WORK_DIR=<工作目录> bash download_devkit.sh
#   可选参数：
#     DEVKIT_VERSION=<版本号>      指定下载版本，留空则自动匹配最新版本
#     DEVKIT_URL=<下载URL>         直接指定下载URL（优先于版本号）
#     DEVKIT_PACKAGE_PATH=<压缩包> 跳过下载，仅解压用户提供的压缩包
#
# 输出：
#   成功时 stdout 打印 JSON 结果，含 devkit_tool_path / jar_file / config_dir / config_complete / java_home
#   同时将结果写入 $WORK_DIR/reports/devkit_path.txt
#
# 退出码：
#   0  成功
#   1  参数/环境校验失败
#   2  镜像站不可达或未匹配到包
#   3  下载失败或文件不完整
#   4  解压失败
#   5  未找到 sql-analysis-*.jar
#   6  配置文件校验失败
#   7  写入结果文件失败

set -euo pipefail

log()  { echo "[download_devkit] $*" >&2; }
warn() { echo "[download_devkit] WARN: $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

# --- 0. 前置校验 ---
[[ -n "${WORK_DIR:-}" ]] || fail 1 "环境变量 WORK_DIR 未设置"
[[ -d  "$WORK_DIR"    ]] || fail 1 "WORK_DIR 不是目录：$WORK_DIR"

for cmd in tar find; do
  command -v "$cmd" >/dev/null 2>&1 || fail 1 "缺少依赖命令：$cmd"
done

DOWNLOAD_DIR="$WORK_DIR/downloads"
REPORT_DIR="$WORK_DIR/reports"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$REPORT_DIR" "$DOWNLOAD_DIR" "$LOG_DIR"

# 压缩包完整性下限（10MB）：缓存复用与下载校验共用
MIN_PKG_BYTES=10485760

# 脚本所在目录（用于推断 DevKit 内置场景）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# DevKit 搜索根目录：locate_existing_devkit（找 jar）与 locate_cached_devkit_package
# （找压缩包）共用，单一数据源便于维护。按数组顺序先命中先返回（从小到大）。
DEVKIT_SEARCH_ROOTS=(
    "${WORK_DIR}"    # 工作目录（含 sql-analysis/ 的 jar 与 downloads/ 的压缩包）
    "/opt"
    "/home"
)

# --- 0.5 定位优先：在 DEVKIT_SEARCH_ROOTS 搜索已存在的 DevKit ---
#
# 定位时必须同时校验 jar 和 toolscript 入口，避免命中只有 jar 而无 toolscript
# 的旧版 Porting-Advisor 包（会导致后续入口定位失败）。
locate_existing_devkit() {
    for root in "${DEVKIT_SEARCH_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        # 找到所有 jar 候选，逐个校验是否同时含 toolscript 入口
        while IFS= read -r found_jar; do
            [[ -n "$found_jar" ]] || continue
            # DevKit 工具根目录 = jar 所在 sql_analysis 目录的上级
            local jar_dir devkit_root toolscript_entry
            jar_dir=$(dirname "$found_jar")
            devkit_root=$(dirname "$jar_dir")
            toolscript_entry="$devkit_root/toolscript/sql-migration/scripts/sql_migration.pyc"
            if [[ -f "$toolscript_entry" ]]; then
                echo "$found_jar"
                return 0
            fi
            log "跳过（无 toolscript 入口）：$found_jar"
        done < <(find "$root" -maxdepth 5 -type f -name "sql-analysis-*.jar" 2>/dev/null)
    done
    return 1
}

# 校验找到的 jar 并写 devkit_path.txt
write_devkit_path() {
    local jar_file="$1"
    local jar_dir
    jar_dir=$(dirname "$jar_file")

    # 定位 config 目录
    local config_dir="${jar_dir}/config"
    if [[ ! -d "$config_dir" ]]; then
        local parent_dir
        parent_dir=$(dirname "$jar_dir")
        if [[ -d "${parent_dir}/config" ]]; then
            config_dir="${parent_dir}/config"
            jar_dir="$parent_dir"
        else
            fail 6 "config 目录不存在（jar=${jar_file}）"
        fi
    fi

    # 校验配置文件
    local required_configs=(
        "DefaultValuePattern.json"
        "sqlAnalysisSettingsConfig.json"
        "sqlKeywordsConfig.json"
        "sqlSeparatorConfig.json"
        "SqlValueReplaceRuleConfig.json"
        "typeConverterDefaultValue.json"
    )
    local missing_configs=()
    for cfg in "${required_configs[@]}"; do
        [[ -f "${config_dir}/${cfg}" ]] || missing_configs+=("$cfg")
    done
    if [[ ${#missing_configs[@]} -gt 0 ]]; then
        warn "以下配置文件缺失: ${missing_configs[*]}"
    fi

    # 定位 Java（jar 同目录或上级目录；其次系统 PATH）
    # DevKit 内嵌 JDK 时，java 通常位于 jar 同级的 bin/java 或 jar 上级的 bin/java
    local java_home_result=""
    local java_bin
    java_bin=$(find "$jar_dir" "$jar_dir/.." -maxdepth 3 -type f -name "java" 2>/dev/null | head -1 || true)
    if [[ -n "$java_bin" ]]; then
        java_home_result=$(dirname "$(dirname "$java_bin")")
        log "找到内嵌 Java：$java_home_result（来自 $java_bin）"
    else
        local path_java
        path_java=$(command -v java 2>/dev/null || true)
        if [[ -n "$path_java" ]]; then
            java_home_result=$(dirname "$(dirname "$(readlink -f "$path_java")")")
            log "使用系统 Java：$java_home_result"
        fi
    fi

    local config_complete="true"
    [[ ${#missing_configs[@]} -eq 0 ]] || config_complete="false"

    # 写 devkit_path.txt
    local path_file="$REPORT_DIR/devkit_path.txt"
    printf 'DEVKIT_TOOL_PATH=%s\nJAR_FILE=%s\nCONFIG_DIR=%s\nCONFIG_COMPLETE=%s\nMISSING_CONFIGS=%s\nJAVA_HOME=%s\n' \
        "$jar_dir" "$jar_file" "$config_dir" "$config_complete" "${missing_configs[*]:-none}" "${java_home_result:-none}" \
        > "$path_file" || fail 7 "写入 $path_file 失败"

    # 输出 JSON
    local java_home_json
    if [[ -n "$java_home_result" ]]; then
        java_home_json="\"$java_home_result\""
    else
        java_home_json="null"
    fi
    cat <<EOF
{
  "devkit_tool_path": "${jar_dir}",
  "jar_file": "${jar_file}",
  "config_dir": "${config_dir}",
  "config_complete": ${config_complete},
  "missing_configs": [$(IFS=,; echo "${missing_configs[*]:-}" | sed 's/,/","/g; s/^/"/; s/$/"/' | sed 's/""//g')],
  "java_home": ${java_home_json}
}
EOF
    log "已定位 DevKit（未下载）：jar=${jar_file}"
    log "路径已写入：$path_file"
    exit 0
}

# 在 DEVKIT_SEARCH_ROOTS 里查找已缓存的 DevKit 压缩包，命中且完整性合格则输出路径。
# 仅在未定位到 jar、未指定 DEVKIT_PACKAGE_PATH/DEVKIT_URL 时由调用方触发。
# DEVKIT_VERSION 指定时精确匹配该版本，未指定时取版本最新；按搜索根顺序先命中先返回。
locate_cached_devkit_package() {
    local pattern
    if [ -n "${DEVKIT_VERSION:-}" ]; then
        pattern="DevKit-AI-Migration-Tool-${DEVKIT_VERSION}-Linux-Kunpeng.tar.gz"
    else
        pattern="DevKit-AI-Migration-Tool-*-Linux-Kunpeng.tar.gz"
    fi
    local root found size
    for root in "${DEVKIT_SEARCH_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        found=$(find "$root" -maxdepth 5 -type f -name "$pattern" 2>/dev/null | sort -V | tail -1 || true)
        [[ -n "$found" ]] || continue
        size=$(stat -c%s "$found" 2>/dev/null || stat -f%z "$found" 2>/dev/null || echo 0)
        if [[ "$size" -lt "$MIN_PKG_BYTES" ]]; then
            warn "缓存压缩包过小（${size} 字节），跳过：$found"
            continue
        fi
        echo "$found"
        return 0
    done
    return 1
}

# 尝试定位已存在的 DevKit
EXISTING_JAR=""
if [[ -z "${DEVKIT_PACKAGE_PATH:-}" && -z "${DEVKIT_URL:-}" && -z "${DEVKIT_VERSION:-}" ]]; then
    EXISTING_JAR=$(locate_existing_devkit || true)
fi
if [[ -n "$EXISTING_JAR" ]]; then
    write_devkit_path "$EXISTING_JAR"
fi

# --- 1. 未定位到，进入下载或解压流程 ---
log "未定位到已有 DevKit，进入下载/解压流程"
SKIP_EXTRACT=false

if [ -n "${DEVKIT_PACKAGE_PATH:-}" ]; then
    # ===== 模式2：仅解压 =====
    [[ -f "$DEVKIT_PACKAGE_PATH" ]] || fail 1 "DEVKIT_PACKAGE_PATH 文件不存在：$DEVKIT_PACKAGE_PATH"
    TARGET="$DEVKIT_PACKAGE_PATH"
    DEVKIT_DIR=$(dirname "$TARGET")
    log "模式：仅解压（用户提供压缩包：$DEVKIT_PACKAGE_PATH）"
    # 先在压缩包所在目录查找已解压的 jar，避免重复解压
    EXISTING_JAR=$(find "$DEVKIT_DIR" -type f -name "sql-analysis-*.jar" 2>/dev/null | head -1 || true)
    if [ -n "$EXISTING_JAR" ]; then
        SKIP_EXTRACT=true
        log "检测到已解压的 DevKit，跳过解压：$EXISTING_JAR"
    fi
elif [ -z "${DEVKIT_URL:-}" ] && CACHED_PKG=$(locate_cached_devkit_package); then
    # ===== 模式3：复用 downloads/ 缓存压缩包（跳过下载）=====
    TARGET="$CACHED_PKG"
    DEVKIT_DIR="$WORK_DIR/sql-analysis"
    mkdir -p "$DEVKIT_DIR"
    log "模式：复用缓存压缩包（跳过下载）：$TARGET"
else
    # ===== 模式1：下载并解压 =====
    DEVKIT_DIR="$WORK_DIR/sql-analysis"
    mkdir -p "$DEVKIT_DIR"
    for cmd in curl wget stat; do
      command -v "$cmd" >/dev/null 2>&1 || fail 1 "缺少依赖命令：$cmd（下载模式需要）"
    done

    # 华为云镜像站：DevKit-AI-Migration-Tool 包下载源
    MIRROR_BASE="https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/AI-Migration"
    MAX_RETRY=3

    if [ -n "${DEVKIT_URL:-}" ]; then
        DOWNLOAD_URL="${DEVKIT_URL}"
        CLI_PKG=$(basename "${DOWNLOAD_URL}")
        log "使用指定URL: ${DOWNLOAD_URL}"
    elif [ -n "${DEVKIT_VERSION:-}" ]; then
        ARCHIVE_NAME="DevKit-AI-Migration-Tool-${DEVKIT_VERSION}-Linux-Kunpeng.tar.gz"
        DOWNLOAD_URL="${MIRROR_BASE}/${ARCHIVE_NAME}"
        CLI_PKG="${ARCHIVE_NAME}"
        log "下载指定版本 ${DEVKIT_VERSION}: ${DOWNLOAD_URL}"
    else
        # 自动匹配最新版本
        PKG_PATTERN='DevKit-AI-Migration-Tool-[0-9][^"]*Linux-Kunpeng\.tar\.gz'
        log "查询镜像站：$MIRROR_BASE/"
        LISTING=$(curl -fsSL --max-time 30 "$MIRROR_BASE/" 2>/dev/null || true)
        [[ -n "$LISTING" ]] || fail 2 "镜像站不可达或返回空（请检查网络/代理）"

        CLI_PKG=$(printf '%s\n' "$LISTING" \
          | grep -oE "$PKG_PATTERN" \
          | sort -V \
          | tail -1 || true)
        [[ -n "$CLI_PKG" ]] || fail 2 "镜像站未匹配到 DevKit-AI-Migration-Tool-*-Linux-Kunpeng.tar.gz"

        DOWNLOAD_URL="${MIRROR_BASE}/${CLI_PKG}"
        log "匹配到最新版本包：$CLI_PKG"
    fi

    # 下载（断点续传 + 重试）
    TARGET="$DOWNLOAD_DIR/$CLI_PKG"
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

    SIZE=$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET" 2>/dev/null || echo 0)
    if [[ "$SIZE" -lt "$MIN_PKG_BYTES" ]]; then
      fail 3 "下载文件过小（${SIZE} 字节），疑似不完整：$TARGET"
    fi
    log "下载完成，文件大小: $SIZE 字节"
fi

# --- 2. 解压（DevKit 安装包为单层 tar.gz）---
#
# 压缩包结构（26.2.RC1+）：
#   DevKit-AI-Migration-Tool-<ver>-Linux-Kunpeng.tar.gz
#     -> DevKit-AI-Migration-Tool-<ver>-Linux-Kunpeng/
#       -> sql_analysis/sql-analysis-<ver>.jar + config/ + jre/
#
# 解压后目录即为 DevKit 工具根目录，jar 位于 sql_analysis/ 子目录下。
if [ "$SKIP_EXTRACT" = "true" ]; then
    log "跳过解压（已检测到已解压的 DevKit）"
else
    log "解压到 $DEVKIT_DIR"
    if [ -n "${DEVKIT_PACKAGE_PATH:-}" ]; then
        mkdir -p "$DEVKIT_DIR"
    else
        rm -rf "$DEVKIT_DIR" && mkdir -p "$DEVKIT_DIR"
    fi

    case "$TARGET" in
      *.tar.gz)
        if ! tar -xzf "$TARGET" -C "$DEVKIT_DIR"; then
          fail 4 "解压失败：$TARGET（文件可能损坏）"
        fi
        ;;
      *.zip)
        if ! unzip -o "$TARGET" -d "$DEVKIT_DIR" >/dev/null; then
          fail 4 "解压失败：$TARGET（文件可能损坏）"
        fi
        ;;
      *)
        fail 1 "不支持的压缩格式：$TARGET（仅支持 .tar.gz / .zip）"
        ;;
    esac
    log "解压完成"
fi

# --- 3. 定位 sql-analysis-*.jar ---
JAR_FILE=$(find "$DEVKIT_DIR" -type f -name "sql-analysis-*.jar" 2>/dev/null | head -1 || true)
[[ -n "$JAR_FILE" ]] || fail 5 "解压后未找到 sql-analysis-*.jar 文件"

JAR_DIR=$(dirname "$JAR_FILE")
log "找到 jar 文件: $JAR_FILE"

# --- 4. 定位 Java（若包内含 JDK）---
JAVA_HOME_RESULT=""
JAVA_BIN=$(find "$DEVKIT_DIR" -type f -name "java" 2>/dev/null | head -1 || true)
if [ -n "$JAVA_BIN" ]; then
    # java 的典型路径：.../bin/java，JAVA_HOME 取 bin 的上级目录
    JAVA_HOME_RESULT=$(dirname "$(dirname "$JAVA_BIN")")
    log "找到内嵌 JDK：$JAVA_HOME_RESULT"
fi

# --- 5. 校验 config 目录和配置文件 ---
CONFIG_DIR="${JAR_DIR}/config"
if [ ! -d "${CONFIG_DIR}" ]; then
    PARENT_DIR=$(dirname "${JAR_DIR}")
    if [ -d "${PARENT_DIR}/config" ]; then
        CONFIG_DIR="${PARENT_DIR}/config"
        JAR_DIR="${PARENT_DIR}"
        log "在上级目录找到 config 目录"
    else
        fail 6 "config 目录不存在"
    fi
fi

REQUIRED_CONFIGS=(
    "DefaultValuePattern.json"
    "sqlAnalysisSettingsConfig.json"
    "sqlKeywordsConfig.json"
    "sqlSeparatorConfig.json"
    "SqlValueReplaceRuleConfig.json"
    "typeConverterDefaultValue.json"
)

MISSING_CONFIGS=()
for config in "${REQUIRED_CONFIGS[@]}"; do
    if [ ! -f "${CONFIG_DIR}/${config}" ]; then
        MISSING_CONFIGS+=("${config}")
    fi
done

if [ ${#MISSING_CONFIGS[@]} -gt 0 ]; then
    warn "以下配置文件缺失: ${MISSING_CONFIGS[*]}"
fi

# --- 6. 持久化路径 ---
PATH_FILE="$REPORT_DIR/devkit_path.txt"
CONFIG_COMPLETE=$(if [ ${#MISSING_CONFIGS[@]} -eq 0 ]; then echo "true"; else echo "false"; fi)

if ! printf 'DEVKIT_TOOL_PATH=%s\nJAR_FILE=%s\nCONFIG_DIR=%s\nCONFIG_COMPLETE=%s\nMISSING_CONFIGS=%s\nJAVA_HOME=%s\n' \
    "$JAR_DIR" "$JAR_FILE" "$CONFIG_DIR" "$CONFIG_COMPLETE" "${MISSING_CONFIGS[*]:-none}" "${JAVA_HOME_RESULT:-none}" \
    > "$PATH_FILE"; then
  fail 7 "写入 $PATH_FILE 失败（检查目录权限/磁盘空间）"
fi

# 结果输出（JSON）
echo "DEVKIT_TOOL_PATH=$JAR_DIR"
[ -n "$JAVA_HOME_RESULT" ] && echo "JAVA_HOME=$JAVA_HOME_RESULT"
log "成功：DEVKIT_TOOL_PATH=$JAR_DIR"
log "路径已写入：$PATH_FILE"

# 同时输出 JSON 格式结果
JAVA_HOME_JSON=$(if [ -n "$JAVA_HOME_RESULT" ]; then echo "\"$JAVA_HOME_RESULT\""; else echo "null"; fi)
cat <<EOF
{
  "devkit_tool_path": "${JAR_DIR}",
  "jar_file": "${JAR_FILE}",
  "config_dir": "${CONFIG_DIR}",
  "config_complete": ${CONFIG_COMPLETE},
  "missing_configs": [$(IFS=,; echo "${MISSING_CONFIGS[*]:-}" | sed 's/,/","/g; s/^/"/; s/$/"/' | sed 's/""//g')],
  "java_home": ${JAVA_HOME_JSON}
}
EOF
