#!/bin/bash
# 执行 DTS 迁移（命令行参数模式，无交互）
# 用法: run_migration.sh <RUNTIME_XML>
set -euo pipefail

RUNTIME_XML="${1:?RUNTIME_XML required}"
DM_HOME="${DM_HOME:-/opt/dmdbms}"
WORK_BASE="${MIGRATION_WORK_DIR:+$MIGRATION_WORK_DIR/database/dts_work}"
TIMEOUT_SEC=3600

DTS_SCRIPT="${DM_HOME}/tool/dts_cmd_run.sh"
RUN_LOG="${WORK_BASE}/dts_run.log"

[ -n "$WORK_BASE" ] || { echo "FAIL: resolve MIGRATION_WORK_DIR from migration-plan.json before running DTS" >&2; exit 2; }
mkdir -p "$WORK_BASE"
if [ -n "${MIGRATION_WORK_DIR:-}" ]; then
  case "$WORK_BASE/" in "$MIGRATION_WORK_DIR/"*) ;; *) echo "FAIL: WORK_BASE must be under MIGRATION_WORK_DIR" >&2; exit 2 ;; esac
  mkdir -p "$MIGRATION_WORK_DIR/database/tmp"
  export TMPDIR="$MIGRATION_WORK_DIR/database/tmp" TMP="$MIGRATION_WORK_DIR/database/tmp" TEMP="$MIGRATION_WORK_DIR/database/tmp"
fi
cd "${DM_HOME}/tool"
export LD_LIBRARY_PATH="${DM_HOME}/bin:${LD_LIBRARY_PATH:-}"
export DISPLAY=

[ -x "$DTS_SCRIPT" ] || { echo "FAIL: $DTS_SCRIPT not found" >&2; exit 1; }

echo "[INFO] dts_cmd_run.sh CONFIG FILE=$RUNTIME_XML DESCRYPT_PASSWORD=0"
set +e
timeout "$TIMEOUT_SEC" "$DTS_SCRIPT" CONFIG FILE="$RUNTIME_XML" DESCRYPT_PASSWORD=0 2>&1 | tee "$RUN_LOG"
RC=${PIPESTATUS[0]}
set -e

echo "${RC}" > "${WORK_BASE}/.dts_exit_code"
echo "DTS_EXIT=${RC}"
echo "RUN_LOG=${RUN_LOG}"
exit ${RC}
