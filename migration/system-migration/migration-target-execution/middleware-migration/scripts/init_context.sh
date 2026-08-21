#!/bin/bash
# init_context.sh — 运行环境初始化：解析 SKILL_DIR/RUN_ID/WORK_DIR 等路径，加载 .env。
set -e

# SKILL_DIR：优先用父进程传入值，fallback 用 BASH_SOURCE[0] 解析
SKILL_DIR="${SKILL_DIR:-$(
    _s="${BASH_SOURCE[0]}"
    case "$_s" in /*) : ;; *) _s="$PWD/$_s" ;; esac
    _s="$(readlink -f "$_s" 2>/dev/null || printf '%s' "$_s")"
    cd "$(dirname "$_s")/.." && pwd
)}"
export SKILL_DIR

# RUN_ID 仅用于报告标识
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
export RUN_ID
export REFERENCE_DIR="$SKILL_DIR/reference"
export REGISTRY_FILE="$SKILL_DIR/config/middleware_registry.json"

# 参数文件优先级：MIGRATION_PLAN_PATH > migration-plan.json > 自动搜索
if [ -n "${MIGRATION_PLAN_PATH:-}" ] && [ -f "$MIGRATION_PLAN_PATH" ]; then
    echo "[INIT] 使用系统迁移传入的参数文件: $MIGRATION_PLAN_PATH"
elif [ -f "migration-plan.json" ]; then
    MIGRATION_PLAN_PATH="migration-plan.json"
    echo "[INIT] 使用默认参数文件: $MIGRATION_PLAN_PATH"
else
    echo "[INIT] 未找到默认 migration-plan.json，开始自动搜索..."

    CANDIDATES=()
    # 搜索当前目录及 skill 上级目录（项目根，plan 常放置于此）
    while IFS= read -r -d '' json_file; do
        if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('route',{}).get('middleware') is not None else 1)" "$json_file" 2>/dev/null; then
            CANDIDATES+=("$json_file")
        fi
    done < <(find . -maxdepth 3 -name "*.json" -print0 2>/dev/null)

    CANDIDATE_COUNT=${#CANDIDATES[@]}

    if [ "$CANDIDATE_COUNT" -eq 0 ]; then
        echo "[INIT] ERROR: 未找到有效的 migration-plan.json 文件"
        echo "  请通过 MIGRATION_PLAN_PATH 环境变量指定路径，或在当前目录放置 migration-plan.json"
        exit 1
    elif [ "$CANDIDATE_COUNT" -eq 1 ]; then
        MIGRATION_PLAN_PATH="${CANDIDATES[0]}"
        echo "[INIT] 自动发现参数文件: $MIGRATION_PLAN_PATH"
    else
        echo "[INIT] 发现多个参数文件候选："
        for ((i=0; i<CANDIDATE_COUNT; i++)); do
            echo "  [$((i+1))] ${CANDIDATES[$i]}"
        done
        echo "[INIT] ERROR: 存在多个候选 plan，请通过 MIGRATION_PLAN_PATH 环境变量或命令行参数指定其一"
        echo "  示例: MIGRATION_PLAN_PATH='${CANDIDATES[0]}' bash middleware-migration/scripts/run_migration.sh"
        echo "  示例: bash middleware-migration/scripts/run_migration.sh '${CANDIDATES[0]}'"
        exit 1
    fi
fi

if [ ! -f "$MIGRATION_PLAN_PATH" ]; then
    echo "[INIT] ERROR: $MIGRATION_PLAN_PATH 不存在"
    exit 1
fi

if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MIGRATION_PLAN_PATH" 2>/dev/null; then
    echo "[INIT] ERROR: $MIGRATION_PLAN_PATH 不是有效的 JSON 文件"
    exit 1
fi

if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('route',{}).get('middleware') is not None else 1)" "$MIGRATION_PLAN_PATH" 2>/dev/null; then
    echo "[INIT] ERROR: $MIGRATION_PLAN_PATH 必须包含 .route.middleware 数组"
    exit 1
fi

MIGRATION_WORK_DIR=$(python3 - "$MIGRATION_PLAN_PATH" <<'PY_WORK_DIR'
import json
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8-sig") as stream:
    plan = json.load(stream)
base = str((plan.get("target_environment") or {}).get("migration_work_dir") or "").strip()
migration_id = str(plan.get("migration_id") or "").strip()
if not base or not migration_id:
    raise SystemExit(2)
path = Path(base).expanduser()
if not path.is_absolute():
    raise SystemExit(2)
print((path / migration_id).resolve())
PY_WORK_DIR
) || {
    echo "[INIT] ERROR: 无法从 target_environment.migration_work_dir 和 migration_id 解析工作目录" >&2
    exit 1
}
WORK_DIR="$MIGRATION_WORK_DIR/middleware"
STATE_DIR="$WORK_DIR/state"
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$WORK_DIR"/{reports,downloads} "$STATE_DIR" "$TMP_DIR"

export MIGRATION_WORK_DIR WORK_DIR TMP_DIR
export TMPDIR="$TMP_DIR" TMP="$TMP_DIR" TEMP="$TMP_DIR"
export REPORTS_DIR="$WORK_DIR/reports"
export DOWNLOADS_DIR="$WORK_DIR/downloads"
export STATE_DIR="$STATE_DIR"

# plan → 统一内部格式（标准化 type 字段）
PLAN_BASE_DIR=$(cd "$(dirname "$MIGRATION_PLAN_PATH")" && pwd)
export MIDDLEWARE_LIST=$(python3 "$SKILL_DIR/scripts/lib/transform_plan.py" "$MIGRATION_PLAN_PATH" "$PLAN_BASE_DIR")

# 提取 JDK 项包源信息供 ensure_dependencies 安装依赖时使用
eval "$(printf '%s' "$MIDDLEWARE_LIST" | python3 -c "
import json, sys, shlex
for item in json.load(sys.stdin):
    if item.get('type') == 'openjdk':
        print('JAVA_RUNTIME_URL=' + shlex.quote(item.get('download_url', '')))
        print('JAVA_RUNTIME_LOCAL_PATH=' + shlex.quote(item.get('local_package_path', '')))
        print('JAVA_RUNTIME_FILE_NAME=' + shlex.quote(item.get('package_file_name', '')))
        print('JAVA_RUNTIME_VERSION=' + shlex.quote(item.get('target_version', '')))
        break
" 2>/dev/null)"
export JAVA_RUNTIME_URL JAVA_RUNTIME_LOCAL_PATH JAVA_RUNTIME_FILE_NAME JAVA_RUNTIME_VERSION
if [ -n "$JAVA_RUNTIME_URL" ]; then
    echo "[INIT] JDK 依赖优先使用: $JAVA_RUNTIME_URL"
elif [ -n "$JAVA_RUNTIME_LOCAL_PATH" ]; then
    echo "[INIT] JDK 依赖优先使用本地包: $JAVA_RUNTIME_LOCAL_PATH"
fi

MIDDLEWARE_COUNT=$(printf '%s' "$MIDDLEWARE_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$MIDDLEWARE_COUNT" -eq 0 ]; then
    echo "[INIT] ERROR: route.middleware 列表为空"
    exit 1
fi

echo "[INIT] 初始化完成（含 JDK 项）："
echo "  middleware_count=$MIDDLEWARE_COUNT"
echo "  列表:"
printf '%s' "$MIDDLEWARE_LIST" | python3 -c "
import json, sys
for x in json.load(sys.stdin):
    t = x.get('type', '?')
    sp = x.get('source_product') or '?'
    cv = x.get('current_version') or '?'
    tp = x.get('target_product') or '?'
    tv = x.get('target_version') or 'auto'
    print('    - [{}] {} {} -> {} {}'.format(t, sp, cv, tp, tv))
"

# 保存快照用于恢复/调试；使用 shell 转义避免 JSON/路径中的特殊字符破坏 .env。
: > "$WORK_DIR/.env"
for _name in MIDDLEWARE_LIST MIGRATION_PLAN_PATH RUN_ID MIGRATION_WORK_DIR WORK_DIR TMP_DIR TMPDIR TMP TEMP REPORTS_DIR DOWNLOADS_DIR STATE_DIR SKILL_DIR REFERENCE_DIR REGISTRY_FILE JAVA_RUNTIME_URL JAVA_RUNTIME_LOCAL_PATH JAVA_RUNTIME_FILE_NAME JAVA_RUNTIME_VERSION; do
    _value="${!_name-}"
    printf 'export %s=%q\n' "$_name" "$_value" >> "$WORK_DIR/.env"
done
unset _name _value

echo "[INIT] 环境变量已保存到 $WORK_DIR/.env"
