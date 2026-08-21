#!/bin/bash
# run_migration.sh — 中间件批量迁移入口
# 读取 migration-plan.json，解析 route.middleware，按 JDK 优先排序后逐项迁移。
# 主要职责：解析 plan、部署目录推导、冲突预检（目录/服务）、依赖准备、调度产品迁移脚本、汇总输出。
# 输入：$1 = migration-plan.json 路径（或 MIGRATION_PLAN_PATH 环境变量）
# 输出：batch_migration_summary.json/.md + middleware-action-required.json（冲突时）
set -e

SKILL_DIR="${SKILL_DIR:-$(
    _s="${BASH_SOURCE[0]}"
    case "$_s" in /*) : ;; *) _s="$PWD/$_s" ;; esac
    _s="$(readlink -f "$_s" 2>/dev/null || printf '%s' "$_s")"
    cd "$(dirname "$_s")/.." && pwd
)}"
export SKILL_DIR

if [ $# -gt 0 ] && [ -n "$1" ]; then
    export MIGRATION_PLAN_PATH="$1"
fi

if [ -z "${WORK_DIR:-}" ] || [ ! -f "${WORK_DIR:-}/.env" ]; then
    source "$SKILL_DIR/scripts/init_context.sh"
fi
source "$SKILL_DIR/scripts/lib/common.sh"
load_env
require_env MIDDLEWARE_LIST REGISTRY_FILE || exit 1

MIDDLEWARE_COUNT=$(printf '%s' "$MIDDLEWARE_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
SUMMARY_FILE="$REPORTS_DIR/batch_migration_summary.md"
SUMMARY_JSON="$REPORTS_DIR/batch_migration_summary.json"
SUMMARY_ITEMS="$REPORTS_DIR/.batch_migration_items.ndjson"
ACTION_REQUIRED_JSON="$REPORTS_DIR/middleware-action-required.json"
SUCCESS_COUNT=0
WARNING_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
BLOCKED_COUNT=0

# 计划内所有 Java 中间件的 JDK 需求：全部一致时统一使用该版本，避免按各自版本解析导致顾左失右；
# 存在多版本（如 BES=8 与其余=11）时保持按各自需求解析安装，并在依赖解析处给出明确提示。
PLAN_JAVA_VERSIONS=$(plan_java_versions)
UNIFIED_JDK_VERSION=""
if [ -n "$PLAN_JAVA_VERSIONS" ]; then
    if [ "${PLAN_JAVA_VERSIONS%% *}" = "$PLAN_JAVA_VERSIONS" ]; then
        UNIFIED_JDK_VERSION="$PLAN_JAVA_VERSIONS"
        log_info "[JDK] 计划内 Java 中间件统一使用 JDK $UNIFIED_JDK_VERSION"
    else
        log_warn "[JDK] 计划内中间件需要多个 JDK 版本($PLAN_JAVA_VERSIONS)，将按各中间件需求分别解析安装"
    fi
fi
export UNIFIED_JDK_VERSION

load_item_context() {
    local idx="$1"
    unset MIDDLEWARE_ID MIDDLEWARE_TYPE CURRENT_VERSION TARGET_VERSION SOURCE_DIR SOURCE_PRODUCT TARGET_PRODUCT
    unset ARTIFACT_BASE_DIR DOWNLOAD_URL LOCAL_PACKAGE_PATH PACKAGE_FILE_NAME INSTALL_METHOD MIGRATION_PATH CONFIG_PATHS
    unset SOURCE_TYPE DEPLOY_DIR DERIVE_ERROR LICENSES MIGRATION_SCRIPT MIDDLEWARE_STATE_KEY

    eval "$(printf '%s' "$MIDDLEWARE_LIST" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)[$idx]
def g(k): return d.get(k) or ''
fields = {
    'MIDDLEWARE_ID': g('id'),
    'MIDDLEWARE_TYPE': g('type'),
    'CURRENT_VERSION': g('current_version'),
    'TARGET_VERSION': g('target_version'),
    'SOURCE_DIR': g('source_dir'),
    'SOURCE_PRODUCT': g('source_product'),
    'TARGET_PRODUCT': g('target_product'),
    'ARTIFACT_BASE_DIR': g('artifact_base_dir'),
    'DOWNLOAD_URL': g('download_url'),
    'LOCAL_PACKAGE_PATH': g('local_package_path'),
    'PACKAGE_FILE_NAME': g('package_file_name'),
    'SOURCE_TYPE': g('source_type'),
}
for k, v in fields.items():
    print('{}={}'.format(k, shlex.quote(v)))
print('CONFIG_PATHS=' + shlex.quote(json.dumps(d.get('config_paths') or [], ensure_ascii=False, separators=(',',':'))))
license_path = g('license_path')
licenses = [{'uploaded_files':[license_path]}] if license_path else []
print('LICENSES=' + shlex.quote(json.dumps(licenses, ensure_ascii=False, separators=(',',':'))))
" 2>/dev/null)" || return 1

    [ -n "$MIDDLEWARE_TYPE" ] || return 1
    MIDDLEWARE_TYPE=$(normalize_middleware_type "$MIDDLEWARE_TYPE")
    [ -z "$MIDDLEWARE_ID" ] && MIDDLEWARE_ID="$MIDDLEWARE_TYPE"
    MIDDLEWARE_STATE_KEY="$MIDDLEWARE_ID"

    if registry_has ".strategies.\"$MIDDLEWARE_TYPE\""; then
        INSTALL_METHOD=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".install_method")
        MIGRATION_SCRIPT=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".script")
        MIGRATION_PATH="REGISTERED"
    else
        INSTALL_METHOD="generic"
        MIGRATION_SCRIPT="scripts/migrate_generic.sh"
        MIGRATION_PATH="GENERIC"
    fi

    if [ -z "$TARGET_VERSION" ] && [ "$INSTALL_METHOD" != "yum" ] && [ "${SOURCE_TYPE:-}" != "SYSTEM_REPOSITORY" ]; then
        return 3
    fi
    [ -z "$TARGET_VERSION" ] && TARGET_VERSION="repository"
    [ -n "$MIGRATION_SCRIPT" ] || return 4
    case "$MIGRATION_SCRIPT" in
        /*) ;;
        *) MIGRATION_SCRIPT="$SKILL_DIR/$MIGRATION_SCRIPT" ;;
    esac
    [ -f "$MIGRATION_SCRIPT" ] || return 4
    return 0
}

resolve_item_deploy_dir() {
    DEPLOY_DIR=""
    local script_name safe_id
    script_name=$(basename "$MIGRATION_SCRIPT")
    if [ "$INSTALL_METHOD" = "jdk" ] || { [ "$SOURCE_TYPE" = "SYSTEM_REPOSITORY" ] && [ "$script_name" = "migrate_package.sh" ]; }; then
        return 0
    fi
    safe_id=$(printf '%s' "$MIDDLEWARE_ID" | tr -c 'A-Za-z0-9._-' '_')
    derive_deploy_dir "$MIDDLEWARE_TYPE" "$SOURCE_DIR" "$TARGET_VERSION" > "$WORK_DIR/.deploy_dir_${safe_id}" 2>/dev/null
    local rc=$?
    DEPLOY_DIR=$(cat "$WORK_DIR/.deploy_dir_${safe_id}" 2>/dev/null)
    rm -f "$WORK_DIR/.deploy_dir_${safe_id}"
    return "$rc"
}

# 非交互执行先一次性发现目录冲突，避免迁移一部分组件后才等待用户选择。
preflight_conflicts() {
    [ -t 0 ] && { rm -f "$ACTION_REQUIRED_JSON"; return 0; }
    [ "${PERMISSION_MODE:-strict}" = "auto" ] && { rm -f "$ACTION_REQUIRED_JSON"; return 0; }

    local pending="$REPORTS_DIR/.middleware_conflicts.ndjson" count=0 idx rc action
    : > "$pending"
    for ((idx=0; idx<MIDDLEWARE_COUNT; idx++)); do
        load_item_context "$idx" || continue
        resolve_item_deploy_dir
        rc=$?
        [ "$rc" -eq 0 ] || continue
        local has_conflict=false svc_name
        if [ -n "$DEPLOY_DIR" ] && [ -d "$DEPLOY_DIR" ]; then
            has_conflict=true
        fi
        svc_name=$(resolve_arm_service "$MIDDLEWARE_TYPE")
        if systemctl cat "$svc_name" >/dev/null 2>&1; then
            has_conflict=true
        fi
        [ "$has_conflict" = "true" ] || continue
        action=$(resolve_conflict_action "$MIDDLEWARE_TYPE" "$MIDDLEWARE_ID")
        case "$action" in overwrite|skip) continue ;; esac
        count=$((count + 1))
        python3 - "$pending" "$MIDDLEWARE_ID" "$MIDDLEWARE_TYPE" "$DEPLOY_DIR" "$svc_name" <<'PY'
import json, sys
with open(sys.argv[1], 'a', encoding='utf-8') as stream:
    stream.write(json.dumps({
        'id': sys.argv[2],
        'type': sys.argv[3],
        'deploy_dir': sys.argv[4],
        'service_name': sys.argv[5],
        'choices': ['overwrite', 'skip'],
    }, ensure_ascii=False) + '\n')
PY
    done

    if [ "$count" -eq 0 ]; then
        rm -f "$pending" "$ACTION_REQUIRED_JSON"
        return 0
    fi

    python3 - "$pending" "$ACTION_REQUIRED_JSON" <<'PY'
import json, sys
items = []
with open(sys.argv[1], encoding='utf-8') as stream:
    for line in stream:
        if line.strip():
            items.append(json.loads(line))
with open(sys.argv[2], 'w', encoding='utf-8') as stream:
    json.dump({
        'status': 'WAITING_FOR_USER',
        'reason_code': 'MIDDLEWARE_CONFLICT',
        'requires_user_confirmation': True,
        'items': items,
    }, stream, ensure_ascii=False, indent=2)
    stream.write('\n')
PY
    rm -f "$pending"
    echo "检测到 $count 个目标冲突（目录/服务），尚未执行中间件变更。" >&2
    echo "待确认信息: $ACTION_REQUIRED_JSON" >&2
    return 2
}

init_summary() {
    : > "$SUMMARY_ITEMS"
    cat > "$SUMMARY_FILE" <<EOF
# 中间件迁移汇总

- 迁移数量: $MIDDLEWARE_COUNT
- 执行时间: $(date '+%Y-%m-%d %H:%M:%S')
- 运行ID: ${RUN_ID:-}
- 目标主机: $(hostname)

## 迁移详情
EOF
}

append_summary() {
    local status="$1" mtype="$2" current="$3" target="$4" path="$5" reason="${6:-}" mid="${7:-$mtype}"
    echo "- [$status] **$mtype** ($current -> $target) [$path]${reason:+: $reason}" >> "$SUMMARY_FILE"
    python3 - "$SUMMARY_ITEMS" "$status" "$mid" "$mtype" "$current" "$target" "$path" "$reason" <<'PY'
import json, sys
out, status, mid, mtype, current, target, path, reason = sys.argv[1:]
with open(out, 'a', encoding='utf-8') as stream:
    stream.write(json.dumps({
        'status': status,
        'middleware_id': mid,
        'middleware_type': mtype,
        'source_version': current,
        'target_version': target,
        'migration_path': path,
        'reason': reason,
    }, ensure_ascii=False) + '\n')
PY
}

finalize_summary() {
    cat >> "$SUMMARY_FILE" <<EOF

## 结果统计
- 成功: $SUCCESS_COUNT
- 警告: $WARNING_COUNT
- 失败: $FAIL_COUNT
- 跳过: $SKIP_COUNT
- 阻塞: $BLOCKED_COUNT
- 总计: $MIDDLEWARE_COUNT
EOF

    python3 - "$SUMMARY_ITEMS" "$SUMMARY_JSON" "$SUMMARY_FILE" "$MIDDLEWARE_COUNT" "$SUCCESS_COUNT" "$WARNING_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$BLOCKED_COUNT" "${RUN_ID:-}" <<'PY'
import json, sys
from datetime import datetime, timezone
items_path, output_path, report_path, total, success, warnings, failed, skipped, blocked, run_id = sys.argv[1:]
items = []
try:
    with open(items_path, encoding='utf-8') as stream:
        items = [json.loads(line) for line in stream if line.strip()]
except FileNotFoundError:
    pass
counts = {
    'success': int(success),
    'warnings': int(warnings),
    'failed': int(failed),
    'skipped': int(skipped),
    'blocked': int(blocked),
    'total': int(total),
}
if counts['blocked']:
    status = 'BLOCKED'
elif counts['failed']:
    status = 'FAILED'
elif counts['warnings'] or counts['skipped']:
    status = 'SUCCEEDED_WITH_WARNINGS'
else:
    status = 'SUCCEEDED'
with open(output_path, 'w', encoding='utf-8') as stream:
    json.dump({
        'schema_version': '1.1',
        'module': 'middleware',
        'status': status,
        'run_id': run_id,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'counts': counts,
        'items': items,
        'report_refs': [report_path],
    }, stream, ensure_ascii=False, indent=2)
    stream.write('\n')
PY
    rm -f "$SUMMARY_ITEMS"
}

if preflight_conflicts; then
    :
else
    exit $?
fi

init_summary
set +e
for ((idx=0; idx<MIDDLEWARE_COUNT; idx++)); do
    load_item_context "$idx"
    load_rc=$?
    if [ "$load_rc" -ne 0 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        reason="中间件列表解析失败"
        [ "$load_rc" -eq 3 ] && reason="目标版本缺失"
        [ "$load_rc" -eq 4 ] && reason="迁移脚本未配置或不存在"
        append_summary FAIL "${MIDDLEWARE_TYPE:-unknown}" "${CURRENT_VERSION:--}" "${TARGET_VERSION:--}" "${MIGRATION_PATH:--}" "$reason" "${MIDDLEWARE_ID:-unknown}"
        continue
    fi

    log_info "[$((idx+1))/$MIDDLEWARE_COUNT] $MIDDLEWARE_TYPE ($CURRENT_VERSION -> $TARGET_VERSION) [$MIGRATION_PATH]"
    log_reference "$MIDDLEWARE_TYPE"

    resolve_item_deploy_dir
    derive_rc=$?
    case "$derive_rc" in
        0) ;;
        4)
            SKIP_COUNT=$((SKIP_COUNT + 1))
            append_summary SKIP "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "用户选择跳过" "$MIDDLEWARE_ID"
            continue ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "${DERIVE_ERROR:-部署目录推导失败}" "$MIDDLEWARE_ID"
            continue ;;
    esac

    if [ -n "$DEPLOY_DIR" ]; then
        prompt_deploy_dir_conflict "$DEPLOY_DIR" "$MIDDLEWARE_TYPE" "$MIDDLEWARE_ID"
        conflict_rc=$?
        case "$conflict_rc" in
            0) ;;
            1)
                SKIP_COUNT=$((SKIP_COUNT + 1))
                append_summary SKIP "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "用户选择跳过（目录冲突）" "$MIDDLEWARE_ID"
                continue ;;
            2)
                BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
                append_summary BLOCKED "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "部署目录冲突待确认: $DEPLOY_DIR" "$MIDDLEWARE_ID"
                continue ;;
            *)
                FAIL_COUNT=$((FAIL_COUNT + 1))
                append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "部署目录冲突处理失败" "$MIDDLEWARE_ID"
                continue ;;
        esac
    fi

    # 服务冲突检测（不删除原服务目录和配置，仅备份 service 文件后覆盖注册）
    arm_svc=$(resolve_arm_service "$MIDDLEWARE_TYPE")
    prompt_service_conflict "$arm_svc" "$MIDDLEWARE_TYPE" "$MIDDLEWARE_ID"
    svc_rc=$?
    case "$svc_rc" in
        0) ;;
        1)
            SKIP_COUNT=$((SKIP_COUNT + 1))
            append_summary SKIP "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "用户选择跳过（服务冲突）" "$MIDDLEWARE_ID"
            continue ;;
        2)
            BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
            append_summary BLOCKED "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "服务冲突待确认: $arm_svc" "$MIDDLEWARE_ID"
            continue ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "服务冲突处理失败" "$MIDDLEWARE_ID"
            continue ;;
    esac

    export MIDDLEWARE_ID MIDDLEWARE_STATE_KEY MIDDLEWARE_TYPE CURRENT_VERSION TARGET_VERSION SOURCE_DIR DEPLOY_DIR
    export INSTALL_METHOD MIGRATION_PATH SOURCE_PRODUCT TARGET_PRODUCT ARTIFACT_BASE_DIR
    export DOWNLOAD_URL LOCAL_PACKAGE_PATH PACKAGE_FILE_NAME SOURCE_TYPE CONFIG_PATHS LICENSES

    safe_id=$(printf '%s' "$MIDDLEWARE_ID" | tr -c 'A-Za-z0-9._-' '_')
    MIDDLEWARE_WORK_DIR="$WORK_DIR/$safe_id"
    export MIDDLEWARE_WORK_DIR
    mkdir -p "$MIDDLEWARE_WORK_DIR"

    ensure_dependencies "$MIDDLEWARE_TYPE"
    dep_rc=$?
    if [ "$dep_rc" -ne 0 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "依赖安装失败" "$MIDDLEWARE_ID"
        continue
    fi

    bash "$MIGRATION_SCRIPT"
    rc=$?
    case "$rc" in
        0)
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            set_migration_state "$MIDDLEWARE_TYPE" success
            append_summary OK "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "" "$MIDDLEWARE_ID" ;;
        10)
            WARNING_COUNT=$((WARNING_COUNT + 1))
            set_migration_state "$MIDDLEWARE_TYPE" success_with_warnings
            append_summary WARN "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "迁移完成但存在警告，查看组件报告" "$MIDDLEWARE_ID" ;;
        20)
            BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
            set_migration_state "$MIDDLEWARE_TYPE" blocked
            append_summary BLOCKED "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "License 或授权条件未就绪" "$MIDDLEWARE_ID" ;;
        30)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            set_migration_state "$MIDDLEWARE_TYPE" failed
            append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "安装来源全部失败" "$MIDDLEWARE_ID" ;;
        *)
            FAIL_COUNT=$((FAIL_COUNT + 1))
            set_migration_state "$MIDDLEWARE_TYPE" failed
            append_summary FAIL "$MIDDLEWARE_TYPE" "$CURRENT_VERSION" "$TARGET_VERSION" "$MIGRATION_PATH" "迁移脚本执行失败 (exit=$rc)" "$MIDDLEWARE_ID" ;;
    esac
done
set -e

finalize_summary
cat "$SUMMARY_FILE"

if [ "$BLOCKED_COUNT" -gt 0 ]; then exit 2; fi
if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
exit 0
