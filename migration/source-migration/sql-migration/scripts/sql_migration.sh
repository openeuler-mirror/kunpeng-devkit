#!/usr/bin/env bash
# sql_migration.sh
# SQL 迁移统一入口脚本（外层编排，不随 DevKit 内部分发）
#
# 职责：
#   1. 校验必填参数（PROJECT_PATH / SOURCE_DB / TARGET_DB）
#   2. 确定并初始化 WORK_DIR（未传入则默认 $PROJECT_PATH/.devkit-sql-migration）
#   3. 定位或下载 DevKit（调用 download_devkit.sh，写 reports/devkit_path.txt）
#   4. 若 assets/db-connection.json 的 target_db_conn.flag=true，定位或下载 JDK
#      （调用 download_jdk.sh，写 reports/jdk_path.txt）
#   5. 调用 DevKit 内部 sql_migration.py 执行迁移主流程，透传全部参数与退出码
#
# DevKit 内部代码（sql_migration.py / sql_context.py / stages/* 等）假设环境已就绪，
# 不再包含 DevKit/JDK 的定位或下载逻辑。
#
# 用法：
#   bash scripts/sql_migration.sh \
#     --project-path <PATH> \
#     --source-db <SOURCE_DB> \
#     --target-db <TARGET_DB> \
#     [--work-dir <WORK_DIR>] \
#     [--reset]

#
# 退出码：透传 sql_migration.py 的退出码；环境准备阶段失败按 download_devkit.sh /
# download_jdk.sh 的退出码返回。

set -euo pipefail

log()  { echo "[sql-migration] $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH="$SKILL_DIR/assets/db-connection.json"

# --- 1. 解析参数 ---
PROJECT_PATH=""
SOURCE_DB=""
TARGET_DB=""
WORK_DIR_ARG=""
RESET_FLAG=""

PY_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-path)
            [[ $# -ge 2 ]] || fail 1 "--project-path 需要参数值"
            PROJECT_PATH="$2"; shift 2
            PY_ARGS+=(--project-path "$PROJECT_PATH")
            ;;
        --source-db)
            [[ $# -ge 2 ]] || fail 1 "--source-db 需要参数值"
            SOURCE_DB="$2"; shift 2
            PY_ARGS+=(--source-db "$SOURCE_DB")
            ;;
        --target-db)
            [[ $# -ge 2 ]] || fail 1 "--target-db 需要参数值"
            TARGET_DB="$2"; shift 2
            PY_ARGS+=(--target-db "$TARGET_DB")
            ;;
        --work-dir)
            [[ $# -ge 2 ]] || fail 1 "--work-dir 需要参数值"
            WORK_DIR_ARG="$2"; shift 2
            ;;
        --reset)
            RESET_FLAG="1"; shift
            PY_ARGS+=(--reset)
            ;;
        --)
            shift; PY_ARGS+=("$@"); break
            ;;
        *)
            fail 1 "未知参数：$1"
            ;;
    esac
done

# --- 2. 校验必填 ---
[[ -n "$PROJECT_PATH" ]] || fail 1 "--project-path 必填"
[[ -n "$SOURCE_DB" ]]     || fail 1 "--source-db 必填"
[[ -n "$TARGET_DB" ]]     || fail 1 "--target-db 必填"

PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)" || fail 1 "--project-path 不是有效目录：$PROJECT_PATH"

# --- 3. 确定 WORK_DIR（与 sql_migration.py:resolve_work_dir 规则一致）---
if [[ -n "$WORK_DIR_ARG" ]]; then
    WORK_DIR="$WORK_DIR_ARG"
else
    WORK_DIR="$PROJECT_PATH/.devkit-sql-migration"
fi
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# 把确定的 WORK_DIR 显式传给 sql_migration.py，避免默认值计算不一致
PY_ARGS+=(--work-dir "$WORK_DIR")

log "PROJECT_PATH=$PROJECT_PATH"
log "WORK_DIR=$WORK_DIR"
log "SOURCE_DB=$SOURCE_DB  TARGET_DB=$TARGET_DB"
[[ -n "$RESET_FLAG" ]] && log "RESET=enabled"

# --- 4. 初始化 WORK_DIR 子目录（已存在跳过，与 migration_common.reset_workdir 重建列表一致）---
for name in source-code reports logs downloads sql-analysis devkit-sql-migration-cache; do
    mkdir -p "$WORK_DIR/$name"
done

# --- 5. 定位或下载 DevKit ---
log "准备 DevKit 环境（download_devkit.sh）"
WORK_DIR="$WORK_DIR" bash "$SCRIPT_DIR/download_devkit.sh"
[[ -f "$WORK_DIR/reports/devkit_path.txt" ]] || fail 5 "download_devkit.sh 未生成 reports/devkit_path.txt"

# 从 devkit_path.txt 读取 ai-migration 二进制路径
AI_MIGRATION_BIN=""
if [[ -f "$WORK_DIR/reports/devkit_path.txt" ]]; then
    AI_MIGRATION_BIN=$(awk -F'=' '/^AI_MIGRATION=/{sub(/^AI_MIGRATION=/, ""); print; exit}' "$WORK_DIR/reports/devkit_path.txt")
fi
if [[ -z "$AI_MIGRATION_BIN" || ! -x "$AI_MIGRATION_BIN" ]]; then
    if [[ -n "$AI_MIGRATION_BIN" && -f "$AI_MIGRATION_BIN" ]]; then
        chmod +x "$AI_MIGRATION_BIN" 2>/dev/null || true
    fi
    [[ -n "$AI_MIGRATION_BIN" && -x "$AI_MIGRATION_BIN" ]] || fail 5 "devkit_path.txt 中未找到可执行的 ai-migration 二进制"
fi
log "ai-migration 二进制：$AI_MIGRATION_BIN"

# --- 6. 按需定位或下载 JDK（仅 target_db_conn.flag=true）---
TARGET_FLAG="false"
if [[ -f "$CONFIG_PATH" ]]; then
    TARGET_FLAG=$(CONFIG_PATH="$CONFIG_PATH" python3 -c '
import json, os
try:
    c = json.load(open(os.environ["CONFIG_PATH"]))
    v = (c.get("target_db_conn") or {}).get("flag")
    print("true" if v in (True, "true", "True", "1", "yes", "y", 1) else "false")
except Exception:
    print("false")
' 2>/dev/null || echo "false")
fi

if [[ "$TARGET_FLAG" == "true" ]]; then
    log "目标库动态验证已启用（target_db_conn.flag=true），准备 JDK 环境（download_jdk.sh）"
    WORK_DIR="$WORK_DIR" bash "$SCRIPT_DIR/download_jdk.sh"
    [[ -f "$WORK_DIR/reports/jdk_path.txt" ]] || fail 5 "download_jdk.sh 未生成 reports/jdk_path.txt"
else
    log "目标库动态验证未启用，跳过 JDK 准备"
fi

# --- 7. 调用 ai-migration 二进制 sql-migration 子命令 ---
log "启动迁移主流程：ai-migration sql-migration migrate ${PY_ARGS[*]} --db-config $CONFIG_PATH"
exec "$AI_MIGRATION_BIN" sql-migration migrate\
    "${PY_ARGS[@]}" \
    --db-config "$CONFIG_PATH"
