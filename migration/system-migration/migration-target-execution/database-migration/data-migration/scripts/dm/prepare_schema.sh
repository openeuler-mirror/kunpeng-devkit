#!/bin/bash
# 在目标 DM 中预创建目标 schema（如不存在）
#
# DTS 不会自动创建 schema，目标 schema 必须预先存在，否则 CREATE_TABLE 任务会因
# "无效的模式名[X]" 失败。本脚本在 run_migration.sh 之前执行，确保 schema 就绪。
# 非密码字段经 --conf（600 临时文件，source 后即删）传入；DST_PWD 禁止落盘，由调用方 export
# （见 data-migration.md「密码处理」）。
#
# 参数：
#   --conf=FILE    600 临时 conf，仅含 DST_HOST DST_PORT DST_USER DST_SCHEMA
#   --dm-home=PATH 可选，达梦安装根目录，默认 /opt/dmdbms
# 环境变量：DST_PWD (由调用方 export)
set -euo pipefail

CONF_FILE=""
DM_HOME="/opt/dmdbms"

#==================== 工具函数 ====================
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() { cat <<EOF
用法: $(basename "$0") --conf=FILE [--dm-home=PATH]  （须先 export DST_PWD）
  --conf=FILE    600 临时 conf，仅含 DST_HOST/DST_PORT/DST_USER/DST_SCHEMA，读取后删除
  --dm-home=PATH 可选，默认 /opt/dmdbms
EOF
exit 0; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --conf=*)     CONF_FILE="${1#*=}" ;;
            --dm-home=*)  DM_HOME="${1#*=}" ;;
            -h|--help)    usage ;;
            *)             die "未知参数: $1" ;;
        esac; shift
    done
}

#==================== 清理临时 conf ====================
cleanup_conf() {
    [ -n "${CONF_FILE:-}" ] && [ -f "${CONF_FILE:-}" ] && rm -f "${CONF_FILE}" 2>/dev/null || true
}
trap cleanup_conf EXIT

#==================== 加载配置（conf source 后删除；DST_PWD 从环境变量） ====================
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

    : "${DST_HOST:?DST_HOST required}"
    : "${DST_PORT:?DST_PORT required}"
    : "${DST_USER:?DST_USER required}"
    : "${DST_PWD:?DST_PWD required (export)}"
    : "${DST_SCHEMA:?DST_SCHEMA required}"
}

#==================== 主流程 ====================
parse_args "$@"
load_conf

DISQL="${DM_HOME}/bin/disql"

[ -x "$DISQL" ] || die "disql not found: $DISQL"
export LD_LIBRARY_PATH="${DM_HOME}/bin:${LD_LIBRARY_PATH:-}"
export DISPLAY=

CONN="${DST_USER}/${DST_PWD}@${DST_HOST}:${DST_PORT}"

# 查询 schema 是否已存在（DM 的 sysobjects 中 type$='SCH' 记录 schema，name 区分大小写）
# 注意：disql -e 模式不支持 SET HEADING OFF 等会话命令，直接用 SQL 输出 + grep 提取数字
query_schema_count() {
  "$DISQL" "$CONN" -e "SELECT COUNT(*) FROM sysobjects WHERE type\$='SCH' AND name='${DST_SCHEMA}';" 2>&1 \
    | grep -E '^[0-9]+$' | head -1
}

EXIST_CNT=$(query_schema_count || echo "")
if [ "${EXIST_CNT:-0}" -gt 0 ]; then
  echo "[INFO] schema '${DST_SCHEMA}' already exists, skip creation"
  exit 0
fi

echo "[INFO] schema '${DST_SCHEMA}' not found, creating..."
# DM 不支持 CREATE SCHEMA IF NOT EXISTS，且 schema 名大小写敏感，
# 用双引号包裹以保留 DST_SCHEMA 的原始大小写形式，与 DTS destSchema 值保持一致
"$DISQL" "$CONN" -e "CREATE SCHEMA \"${DST_SCHEMA}\";" >/dev/null 2>&1 || {
  echo "FAIL: CREATE SCHEMA \"${DST_SCHEMA}\" 执行失败" >&2; exit 1; }

# 二次确认创建成功
EXIST_CNT=$(query_schema_count || echo "")
if [ "${EXIST_CNT:-0}" -gt 0 ]; then
  echo "[OK] schema '${DST_SCHEMA}' created successfully"
  exit 0
else
  echo "FAIL: schema '${DST_SCHEMA}' creation failed" >&2
  exit 1
fi
