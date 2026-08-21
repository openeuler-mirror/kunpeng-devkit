#!/bin/bash
# data-migration 主流程编排器
#
# 职责：把 gen_xml → prepare_schema → run_migration → verify_migration → 清理
#       5 步串成一个端到端流程，统一通过 --conf 指定的 600 临时 conf 接收全部字段，
#       内部再分发到各子脚本的子 conf（仍 600、用后即删）。
#       装 mariadb 客户端的前置依赖由 agent 在 md 前置步骤 inline 执行，不在本脚本范围。
#
# 命令行参数：
#   --conf=FILE      必填，临时配置文件路径（KEY='VALUE' 格式，权限 600，含密码，用后即删）
#                    支持 KEY：
#                      SRC_HOST  SRC_PORT  SRC_USER  SRC_PWD  SRC_SCHEMA
#                      DST_HOST  DST_PORT  DST_USER  DST_PWD  DST_SCHEMA
#                      TABLE_LIST       (空格分隔表名，纯表名 schema 缺省取 SRC_SCHEMA)
#                      TASK_NAME        (可选，默认 source2dm)
#                      THREAD_COUNT     (可选，默认 2)
#                      TO_UPPER         (可选，默认 true)
#                      DM_HOME          (可选，默认 /opt/dmdbms)
#
# 安全: conf 文件含明文密码，脚本 source 后立即删除，并在 EXIT 时兜底清理；
#       各子 conf 同样模式；任何子步骤非 0 退出均触发 cleanup 清理临时文件。
set -euo pipefail

CONF_FILE=""
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"

#==================== 工具函数 ====================
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() { cat <<EOF
用法: $(basename "$0") --conf=FILE

必选:
  --conf=FILE  临时配置文件路径（KEY='VALUE' 格式，权限 600）
               含源/目标连接信息与 TABLE_LIST，脚本读取后自动删除该文件。
               仅传入临时文件，不要传入需要保留的文件。
               编排内部依次调用：gen_xml.sh → prepare_schema.sh → run_migration.sh
                                 → verify_migration.sh → 清理 runtime xml
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

#==================== 清理所有临时文件（含密码，用后即焚） ====================
# 收集所有生成的子 conf 与 runtime xml，统一在 EXIT 时删除
TEMP_FILES=""
cleanup() {
    for f in $TEMP_FILES; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
    # 兜底：删除主 conf（防 load_conf 异常退出未及删除）
    if [ -n "${CONF_FILE:-}" ] && [ -f "${CONF_FILE:-}" ]; then
        rm -f "$CONF_FILE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 从 stdin 读取 KEY='VALUE' 行写入指定文件，chmod 600，并登记到 TEMP_FILES
# 用法：write_sub_conf <path> <<'EOF'
#          KEY1='val1'
#          KEY2='val2'
#        EOF
write_sub_conf() {
    local path="$1"
    cat > "$path"
    chmod 600 "$path"
    TEMP_FILES="${TEMP_FILES:+$TEMP_FILES }$path"
}

#==================== 加载配置（source 后立即删除） ====================
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
    : "${SRC_HOST:=}";  : "${SRC_PORT:=}";  : "${SRC_USER:=}";  : "${SRC_PWD:=}";  : "${SRC_SCHEMA:=}"
    : "${DST_HOST:=}";  : "${DST_PORT:=}";  : "${DST_USER:=}";  : "${DST_PWD:=}";  : "${DST_SCHEMA:=}"
    : "${TABLE_LIST:=}"
    [ -n "${MIGRATION_WORK_DIR:-}" ] || die "MIGRATION_WORK_DIR 未设置（由上层 Skill 统一 export）"
}

#==================== 主流程 ====================
parse_args "$@"
load_conf

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
SRC_PWD='$SRC_PWD'
SRC_SCHEMA='$SRC_SCHEMA'
DST_HOST='$DST_HOST'
DST_PORT='$DST_PORT'
DST_USER='$DST_USER'
DST_PWD='$DST_PWD'
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
DST_PWD='$DST_PWD'
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
SRC_PWD='$SRC_PWD'
SRC_SCHEMA='$SRC_SCHEMA'
DST_HOST='$DST_HOST'
DST_PORT='$DST_PORT'
DST_USER='$DST_USER'
DST_PWD='$DST_PWD'
DST_SCHEMA='$DST_SCHEMA'
TABLE_LIST='$TABLE_LIST'
DM_HOME='$DM_HOME'
EOF
bash "$SCRIPTS_DIR/verify_migration.sh" --conf="$VERIFY_SUB"

echo "DATA_MIGRATION_DONE runtime_xml=$RUNTIME_XML"
