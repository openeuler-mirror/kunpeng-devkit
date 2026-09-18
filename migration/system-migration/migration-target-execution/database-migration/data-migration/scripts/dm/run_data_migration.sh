#!/bin/bash
# data-migration 主流程编排器
#
# 串行执行 gen_xml → prepare_schema → run_migration → verify_migration → 清理。
# 非密码字段经 --conf（600 临时文件，source 后即删）传入；密码字段（SRC_PWD、DST_PWD）
# 禁止落盘，由调用方 export 为环境变量，本脚本透传给子脚本（见 data-migration.md「密码处理」）。
#
# 参数：
#   --conf=FILE  600 临时 conf，KEY='VALUE' 格式，仅含非密码字段：
#                 SRC_HOST SRC_PORT SRC_USER SRC_SCHEMA
#                 DST_HOST DST_PORT DST_USER DST_SCHEMA
#                 TABLE_LIST  (空格分隔表名；纯表名 schema 取 SRC_SCHEMA)
#                 TASK_NAME/THREAD_COUNT/TO_UPPER/DM_HOME (可选，有默认值)
# 环境变量：SRC_PWD DST_PWD (由调用方 export)
set -euo pipefail

CONF_FILE=""
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"

#==================== 工具函数 ====================
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() { cat <<EOF
用法: $(basename "$0") --conf=FILE  （须先 export SRC_PWD DST_PWD）
  --conf=FILE  600 临时 conf，仅含非密码字段，读取后删除。
               依次调用：gen_xml → prepare_schema → run_migration → verify_migration → 清理
EOF
exit 0; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --conf=*)  CONF_FILE="${1#*=}" ;;
            -h|--help) usage ;;
            *) die "未知参数: $1" ;;
        esac; shift
    done
}

#==================== 清理临时文件（子 conf + runtime xml） ====================
TEMP_FILES=""
cleanup() {
    for f in $TEMP_FILES; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
    [ -n "${CONF_FILE:-}" ] && [ -f "${CONF_FILE:-}" ] && rm -f "$CONF_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# 从 stdin 写 KEY='VALUE' 到指定文件，chmod 600，登记到 TEMP_FILES
write_sub_conf() {
    local path="$1"
    cat > "$path"
    chmod 600 "$path"
    TEMP_FILES="${TEMP_FILES:+$TEMP_FILES }$path"
}

#==================== 加载配置（conf source 后删除；密码从环境变量） ====================
load_conf() {
    [ -n "$CONF_FILE" ] || die "必须指定 --conf=FILE"
    [ -f "$CONF_FILE" ] || die "配置文件不存在: $CONF_FILE"
    local mode
    mode=$(stat -c '%a' "$CONF_FILE" 2>/dev/null || stat -f '%Lp' "$CONF_FILE" 2>/dev/null || echo "")
    [ "$mode" = "600" ] || die "配置文件权限必须为 600，当前: ${mode:-未知}（请 chmod 600 后重试）"
    echo "[INFO] $(date '+%F %T') 加载配置文件: $CONF_FILE"
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    rm -f "$CONF_FILE"
    CONF_FILE=""

    : "${TASK_NAME:=source2dm}"
    : "${THREAD_COUNT:=2}"
    : "${TO_UPPER:=true}"
    : "${DM_HOME:=/opt/dmdbms}"
    : "${SRC_HOST:=}";  : "${SRC_PORT:=}";  : "${SRC_USER:=}";  : "${SRC_SCHEMA:=}"
    : "${DST_HOST:=}";  : "${DST_PORT:=}";  : "${DST_USER:=}";  : "${DST_SCHEMA:=}"
    : "${TABLE_LIST:=}"
    : "${SRC_PWD:?SRC_PWD required (export)}"
    : "${DST_PWD:?DST_PWD required (export)}"
    [ -n "${MIGRATION_WORK_DIR:-}" ] || die "MIGRATION_WORK_DIR 未设置（由上层 Skill 统一 export）"
}

#==================== 主流程 ====================
parse_args "$@"
load_conf

# 透传密码给子脚本
export SRC_PWD DST_PWD

WORK_BASE="$MIGRATION_WORK_DIR/database/dts_work"
mkdir -p "$WORK_BASE"
RUNTIME_XML="$WORK_BASE/task_runtime.xml"
GEN_SUB="$WORK_BASE/.gen_sub_conf.$$"
PREP_SUB="$WORK_BASE/.prep_sub_conf.$$"
VERIFY_SUB="$WORK_BASE/.verify_sub_conf.$$"
TEMP_FILES="$RUNTIME_XML $GEN_SUB $PREP_SUB $VERIFY_SUB"

# 1. 渲染 runtime XML
echo "[INFO] 步骤1/4 渲染 runtime XML"
write_sub_conf "$GEN_SUB" <<EOF
SRC_HOST='$SRC_HOST'
SRC_PORT='$SRC_PORT'
SRC_USER='$SRC_USER'
SRC_SCHEMA='$SRC_SCHEMA'
DST_HOST='$DST_HOST'
DST_PORT='$DST_PORT'
DST_USER='$DST_USER'
DST_SCHEMA='$DST_SCHEMA'
TABLE_LIST='$TABLE_LIST'
TASK_NAME='$TASK_NAME'
THREAD_COUNT='$THREAD_COUNT'
TO_UPPER='$TO_UPPER'
EOF
bash "$SCRIPTS_DIR/gen_xml.sh" --conf="$GEN_SUB" --output="$RUNTIME_XML"

# 2. 预创建目标 schema（DTS 不会自动建 schema，必须先执行）
echo "[INFO] 步骤2/4 预创建目标 schema"
write_sub_conf "$PREP_SUB" <<EOF
DST_HOST='$DST_HOST'
DST_PORT='$DST_PORT'
DST_USER='$DST_USER'
DST_SCHEMA='$DST_SCHEMA'
EOF
bash "$SCRIPTS_DIR/prepare_schema.sh" --conf="$PREP_SUB" --dm-home="$DM_HOME"

# 3. 执行迁移
echo "[INFO] 步骤3/4 执行 DTS 迁移"
bash "$SCRIPTS_DIR/run_migration.sh" "$RUNTIME_XML"

# 4. 校验（硬校验+软校验）
echo "[INFO] 步骤4/4 校验迁移结果"
write_sub_conf "$VERIFY_SUB" <<EOF
SRC_HOST='$SRC_HOST'
SRC_PORT='$SRC_PORT'
SRC_USER='$SRC_USER'
SRC_SCHEMA='$SRC_SCHEMA'
DST_HOST='$DST_HOST'
DST_PORT='$DST_PORT'
DST_USER='$DST_USER'
DST_SCHEMA='$DST_SCHEMA'
TABLE_LIST='$TABLE_LIST'
DM_HOME='$DM_HOME'
EOF
bash "$SCRIPTS_DIR/verify_migration.sh" --conf="$VERIFY_SUB"

echo "DATA_MIGRATION_DONE runtime_xml=$RUNTIME_XML"
