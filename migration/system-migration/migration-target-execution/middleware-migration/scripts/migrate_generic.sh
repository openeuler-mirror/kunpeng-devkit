#!/bin/bash
# migrate_generic.sh — 兜底通用迁移脚本
# 适用：未在 registry 登记的中间件产品。
# 职责：尽力安装（解压/编译）→ 恢复配置 → 无法确定启动方式时保留产物并返回 SUCCEEDED_WITH_WARNINGS。
set -e

SKILL_DIR="${SKILL_DIR:-$(
    _s="${BASH_SOURCE[0]}"
    case "$_s" in /*) : ;; *) _s="$PWD/$_s" ;; esac
    _s="$(readlink -f "$_s" 2>/dev/null || printf '%s' "$_s")"
    cd "$(dirname "$_s")/.." && pwd
)}"
export SKILL_DIR
source "$SKILL_DIR/scripts/lib/common.sh"
load_env

require_env MIDDLEWARE_TYPE CURRENT_VERSION TARGET_VERSION DEPLOY_DIR || exit 1

ARM_SERVICE=$(resolve_arm_service "$MIDDLEWARE_TYPE")
CURRENT_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
VERIFY_STATUS="NOT_AVAILABLE"

log_info "$MIDDLEWARE_TYPE 通用迁移开始: $CURRENT_VERSION -> $TARGET_VERSION"
stop_current_service "$MIDDLEWARE_TYPE" "$ARM_SERVICE"

generic_install_artifact "$MIDDLEWARE_TYPE" || {
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
}

generic_restore_config "$MIDDLEWARE_TYPE" || log_warn "配置恢复存在未完成项"

# 未注册产品没有可推导的启动命令。仅在目标机已经存在同名 systemd 服务时执行启动验证。
if systemctl cat "$ARM_SERVICE" >/dev/null 2>&1 \
   || [ -f "/etc/systemd/system/${ARM_SERVICE}.service" ] \
   || [ -f "/usr/lib/systemd/system/${ARM_SERVICE}.service" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ! start_service "$ARM_SERVICE"; then
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
    if systemctl is-active --quiet "$ARM_SERVICE" 2>/dev/null; then
        VERIFY_STATUS="SERVICE_ACTIVE"
    else
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
else
    VERIFY_STATUS="SERVICE_VALIDATION_UNAVAILABLE"
    log_warn "$MIDDLEWARE_TYPE 未注册启动策略且目标机无可识别 systemd 服务，仅完成安装与配置恢复"
fi

cat > "$REPORTS_DIR/${MIDDLEWARE_TYPE}_migration_report.md" << EOF
# $MIDDLEWARE_TYPE 迁移报告

- 原版本: $CURRENT_VERSION
- 目标版本: $TARGET_VERSION
- 安装目录: $DEPLOY_DIR
- 配置来源: ${SOURCE_DIR:-未提供}
- 策略: GENERIC
- 验证: $VERIFY_STATUS
- 迁移时间: $CURRENT_DATETIME
EOF

if [ "$VERIFY_STATUS" = "SERVICE_VALIDATION_UNAVAILABLE" ]; then
    set_migration_state "$MIDDLEWARE_TYPE" "success_with_warnings"
    exit 10
fi

set_migration_state "$MIDDLEWARE_TYPE" "success"
log_info "$MIDDLEWARE_TYPE 通用迁移完成"
