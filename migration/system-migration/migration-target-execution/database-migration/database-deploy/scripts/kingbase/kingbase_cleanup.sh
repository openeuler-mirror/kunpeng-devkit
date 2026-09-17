#!/bin/bash
# KingbaseES 卸载清理脚本（对应安装脚本 scripts/kingbase/kingbase_silent_install.sh）
# 详见 references/kingbase-deploy-guide.md
set -euo pipefail
log_info(){ echo "[$(date '+%F %T')] INFO $*"; }
log_warn(){ echo "[$(date '+%F %T')] WARN $*" >&2; }

INSTALL_PATH="${INSTALL_PATH:-/opt/Kingbase/ES/V8}"
DATA_PATH="${DATA_PATH:-$INSTALL_PATH/data}"
WORK_DIR="${MIGRATION_WORK_DIR:-/tmp}/database"

# 停止 kingbased systemd 服务（服务由 Agent 按 guide 注册）
if systemctl list-unit-files 2>/dev/null | grep -q "^kingbased\.service"; then
    log_info "停止并卸载系统服务 kingbased"
    systemctl disable --now kingbased 2>/dev/null || true
    rm -f /usr/lib/systemd/system/kingbased.service /etc/systemd/system/kingbased.service \
          /etc/systemd/system/multi-user.target.wants/kingbased.service
    systemctl daemon-reload
    systemctl reset-failed kingbased 2>/dev/null || true
fi

# 停止残留进程
# 注意：grep 无匹配返回非零，pipefail 下需 || true 兜底
PIDS=$(ps -ef | grep -E 'kingbase|sys_ctl' | grep -v grep | awk '{print $2}' || true)
if [ -n "${PIDS}" ]; then
    log_info "杀死残留进程: ${PIDS}"
    kill ${PIDS} 2>/dev/null || true
    sleep 2
    kill -9 ${PIDS} 2>/dev/null || true
fi

# 卸载 ISO 挂载残留（安装脚本异常中断时）
for mnt in $(find "$WORK_DIR/tmp/kingbase" -type d -name iso_mount 2>/dev/null || true); do
    mountpoint -q "$mnt" && { log_info "卸载 ISO 挂载点: $mnt"; umount "$mnt" 2>/dev/null || true; }
done

# 清理目录
log_info "删除安装目录: ${INSTALL_PATH}"
rm -rf "${INSTALL_PATH}"
log_info "删除数据目录: ${DATA_PATH}"
rm -rf "${DATA_PATH}"

# 还原 limits.conf 标记块（由 Agent 按 guide 追加）
LIMITS_FILE="/etc/security/limits.conf"
if grep -q "# kingbase-limits-begin" "$LIMITS_FILE" 2>/dev/null; then
    log_info "移除 limits.conf 中 kingbase 标记块"
    sed -i "/# kingbase-limits-begin/,/# kingbase-limits-end/d" "$LIMITS_FILE"
fi

# 删除用户组
userdel -r kingbase 2>/dev/null || log_warn "kingbase 用户删除失败（可能仍有进程占用或已删除）"
groupdel kingbase 2>/dev/null || log_warn "kingbase 组删除失败（可能非空或已删除）"
log_info "KingbaseES 卸载清理完成"
