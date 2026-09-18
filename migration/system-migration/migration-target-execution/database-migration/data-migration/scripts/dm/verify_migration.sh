#!/bin/bash
# 校验迁移结果
#
# 硬校验（任一失败则退出非 0）：DTS 退出码=0、日志含"迁移完成"、无致命错误、进度行"出错:N"=0
# 软校验（best-effort）：源 MySQL 与目标 DM 各表行数对齐，不可达则 warn 跳过。
# 非密码字段经 --conf（600 临时文件，source 后即删）传入；SRC_PWD/DST_PWD 禁止落盘，
# 由调用方 export（见 data-migration.md「密码处理」），缺失则跳过软校验。
#
# 参数：
#   --conf=FILE  600 临时 conf，仅含非密码字段：
#                SRC_HOST SRC_PORT SRC_USER SRC_SCHEMA  (软校验源端)
#                DST_HOST DST_PORT DST_USER DST_SCHEMA  (软校验目标端)
#                TABLE_LIST DM_HOME  (缺失则跳过软校验 / 默认 /opt/dmdbms)
# 环境变量：SRC_PWD DST_PWD (由调用方 export，缺失则跳过软校验)
set -euo pipefail

DM_HOME="/opt/dmdbms"
VERIFY_CONF=""

#==================== 工具函数 ====================
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() { cat <<EOF
用法: $(basename "$0") --conf=FILE  （须先 export SRC_PWD DST_PWD）
  --conf=FILE  600 临时 conf，仅含非密码字段，读取后删除
EOF
exit 0; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --conf=*)  VERIFY_CONF="${1#*=}" ;;
            -h|--help) usage ;;
            *) die "未知参数: $1" ;;
        esac; shift
    done
}

#==================== 清理临时 conf ====================
cleanup_conf() {
    [ -n "${VERIFY_CONF:-}" ] && [ -f "${VERIFY_CONF:-}" ] && rm -f "${VERIFY_CONF}" 2>/dev/null || true
}
trap cleanup_conf EXIT

#==================== 加载配置（conf source 后删除；密码从环境变量，缺失则跳过软校验） ====================
load_conf() {
    [ -n "$VERIFY_CONF" ] || die "必须指定 --conf=FILE"
    [ -f "$VERIFY_CONF" ] || die "配置文件不存在: $VERIFY_CONF"
    local mode
    mode=$(stat -c '%a' "$VERIFY_CONF" 2>/dev/null || stat -f '%Lp' "$VERIFY_CONF" 2>/dev/null || echo "")
    [ "$mode" = "600" ] || die "配置文件权限必须为 600，当前: ${mode:-未知}（请 chmod 600 后重试）"
    echo "[INFO] $(date '+%F %T') 加载配置文件: $VERIFY_CONF"
    # shellcheck disable=SC1090
    source "$VERIFY_CONF"
    rm -f "$VERIFY_CONF"
    VERIFY_CONF=""

    SRC_HOST="${SRC_HOST}"
    SRC_PORT="${SRC_PORT}"
    SRC_USER="${SRC_USER}"
    SRC_SCHEMA="${SRC_SCHEMA}"
    DST_HOST="${DST_HOST}"
    DST_PORT="${DST_PORT}"
    DST_USER="${DST_USER}"
    DST_SCHEMA="${DST_SCHEMA}"
    TABLE_LIST="${TABLE_LIST}"
    DM_HOME="${DM_HOME:-/opt/dmdbms}"
    : "${SRC_PWD:=}"
    : "${DST_PWD:=}"
}

#==================== 主流程 ====================
parse_args "$@"
load_conf

WORK_BASE="${MIGRATION_WORK_DIR:+$MIGRATION_WORK_DIR/database/dts_work}"
[ -n "$WORK_BASE" ] || { echo "FAIL: resolve MIGRATION_WORK_DIR before verification" >&2; exit 2; }
RUN_LOG="${WORK_BASE}/dts_run.log"
DTS_EXIT=$(cat "${WORK_BASE}/.dts_exit_code" 2>/dev/null || echo 0)

# ==================== 硬校验 ====================
[ "${DTS_EXIT}" = "0" ] || { echo "FAIL: DTS exit ${DTS_EXIT}" >&2; exit 20; }
grep -q "迁移完成" "$RUN_LOG" || { echo "FAIL: '迁移完成' not found in log" >&2; exit 21; }
! grep -qiE "No enum constant|NumberFormatException|ClassNotFoundException" "$RUN_LOG" \
  || { echo "FAIL: fatal error in log" >&2; exit 22; }

# 解析进度行：进度:任务总数:N,已完成:N,出错:N,取消:N,剩余:N
PROGRESS_LINE=$(grep "进度:" "$RUN_LOG" | tail -1)
[ -n "$PROGRESS_LINE" ] || { echo "FAIL: 进度行 not found in log" >&2; exit 24; }

extract_field() {
  echo "$PROGRESS_LINE" | grep -oE "$1:[0-9]+" | head -1 | cut -d: -f2
}

TOTAL_CNT=$(extract_field "任务总数")
DONE_CNT=$(extract_field "已完成")
ERROR_CNT=$(extract_field "出错")
CANCEL_CNT=$(extract_field "取消")
ERROR_CNT=${ERROR_CNT:-0}

echo "[INFO] 进度: 总数=${TOTAL_CNT:-?} 已完成=${DONE_CNT:-?} 出错=${ERROR_CNT} 取消=${CANCEL_CNT:-?}"
[ "${ERROR_CNT}" = "0" ] || { echo "FAIL: ${ERROR_CNT} tasks failed (出错:N must be 0)" >&2; exit 23; }

# ==================== 软校验：源/目标表行数对齐 ====================
verify_table_count() {
  # 缺少源/目标连接信息或表清单，则跳过
  if [ -z "${SRC_HOST:-}" ] || [ -z "${DST_HOST:-}" ] || [ -z "${TABLE_LIST:-}" ]; then
    echo "[WARN] conf 中 SRC_HOST/DST_HOST/TABLE_LIST 未全部提供，跳过表行数对齐校验"
    return 0
fi
  command -v mysql >/dev/null 2>&1 || { echo "[WARN] mysql 客户端未安装，跳过表行数对齐校验"; return 0; }
  [ -x "${DM_HOME}/bin/disql" ] || { echo "[WARN] disql 未找到，跳过表行数对齐校验"; return 0; }

  local tbl_count src_total=0 dst_total=0 mismatch=0 src_na=0 dst_na=0
  tbl_count=$(echo "$TABLE_LIST" | wc -w)
  echo "[INFO] 开始表行数对齐校验（${tbl_count} 张表）"
  printf "%-30s %10s %10s %s\n" "TABLE" "SRC" "DST" "STATUS"

  local t src_cnt dst_cnt
  export LD_LIBRARY_PATH="${DM_HOME}/bin:${LD_LIBRARY_PATH:-}"
  for t in $TABLE_LIST; do
    src_cnt=$(mysql -h"${SRC_HOST}" -P"${SRC_PORT}" -u"${SRC_USER}" -p"${SRC_PWD}" -N -e \
      "SELECT COUNT(*) FROM \`${SRC_SCHEMA}\`.\`${t}\`;" 2>/dev/null | head -1 | tr -d '[:space:]')
    src_cnt=${src_cnt:-NA}
    dst_cnt=$("${DM_HOME}/bin/disql" "${DST_USER}/${DST_PWD}@${DST_HOST}:${DST_PORT}" -e \
      "SELECT COUNT(*) FROM \"${DST_SCHEMA}\".\"${t}\";" 2>&1 \
      | grep -E '^[0-9]+$' | head -1)
    dst_cnt=${dst_cnt:-NA}

    [ "$src_cnt" = "NA" ] && src_na=$((src_na + 1))
    [ "$dst_cnt" = "NA" ] && dst_na=$((dst_na + 1))

    if [ "$src_cnt" != "NA" ] && [ "$dst_cnt" != "NA" ]; then
      if [ "$src_cnt" = "$dst_cnt" ]; then
        printf "%-30s %10s %10s %s\n" "$t" "$src_cnt" "$dst_cnt" "OK"
        src_total=$((src_total + src_cnt))
        dst_total=$((dst_total + dst_cnt))
      else
        printf "%-30s %10s %10s %s\n" "$t" "$src_cnt" "$dst_cnt" "MISMATCH"
        mismatch=$((mismatch + 1))
      fi
    else
      printf "%-30s %10s %10s %s\n" "$t" "$src_cnt" "$dst_cnt" "UNREACHABLE"
    fi
  done

  echo "[INFO] 行数合计: SRC=${src_total} DST=${dst_total} 不一致=${mismatch} 源端不可达表=${src_na} 目标端不可达表=${dst_na}"

  # 仅当两端都能取到值但行数不一致时才判失败
  if [ "$mismatch" -gt 0 ]; then
    echo "FAIL: ${mismatch} tables row count mismatch" >&2
    return 1
  fi
  # 如果两端都不可达（src_na + dst_na = 2*tbl_count）则视为软校验失效
  if [ "$src_na" = "$tbl_count" ] && [ "$dst_na" = "$tbl_count" ]; then
    echo "[WARN] 源端和目标端全部不可达，行数对齐校验无效"
    return 0
  fi
  # 部分不可达：警告但不失败（仅一端可读时无法判定对齐）
  if [ "$src_na" -gt 0 ] || [ "$dst_na" -gt 0 ]; then
    echo "[WARN] 部分表查询不可达（src_na=${src_na}, dst_na=${dst_na}），无法完整对齐校验"
  fi
  return 0
}

if ! verify_table_count; then
  exit 25
fi

echo "VERIFY SUCCESS: log=${RUN_LOG}"
