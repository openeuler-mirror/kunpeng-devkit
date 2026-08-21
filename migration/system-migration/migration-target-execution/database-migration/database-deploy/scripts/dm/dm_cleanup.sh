#!/bin/bash
# DM8 卸载清理脚本
set -euo pipefail
log_info(){ echo "[$(date '+%F %T')] INFO $*"; }
log_warn(){ echo "[$(date '+%F %T')] WARN $*" >&2; }

DM_HOME="/opt/dmdbms"
INSTANCE_NAME="DAMENG"
DATA_PATH="/opt/dmdbms/data"

# 停止 DmServiceDAMENG 服务
if systemctl list-unit-files 2>/dev/null | grep "DmService${INSTANCE_NAME}" >/dev/null;then
    log_info "停止数据库服务 DmService${INSTANCE_NAME}"
    systemctl disable --now "DmService${INSTANCE_NAME}" 2>/dev/null || true
    rm -f "/usr/lib/systemd/system/DmService${INSTANCE_NAME}.service"
    rm -f "/etc/systemd/system/DmService${INSTANCE_NAME}.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/DmService${INSTANCE_NAME}.service"
    systemctl daemon-reload
    systemctl reset-failed "DmService${INSTANCE_NAME}" 2>/dev/null || true
fi

# 停止 DmAPService 服务（达梦辅助插件服务）
if systemctl list-unit-files 2>/dev/null | grep "DmAPService" >/dev/null;then
    log_info "停止辅助服务 DmAPService"
    systemctl disable --now DmAPService 2>/dev/null || true
    rm -f /usr/lib/systemd/system/DmAPService.service
    rm -f /etc/systemd/system/DmAPService.service
    rm -f /etc/systemd/system/multi-user.target.wants/DmAPService.service
    systemctl daemon-reload
    systemctl reset-failed DmAPService 2>/dev/null || true
fi

# 停止残留进程（dmserver + dmap）
# 注意：grep 无匹配返回非零，在 pipefail 下会触发 set -e 退出，需用 || true 兜底
PIDS=$(ps -ef | grep -E 'dmserver|dmap' | grep -v grep | awk '{print $2}' || true)
if [ -n "${PIDS}" ];then
    log_info "杀死残留进程: ${PIDS}"
    kill ${PIDS} 2>/dev/null || true
    sleep 2
    kill -9 ${PIDS} 2>/dev/null || true
fi

# 执行官方卸载（dmdba）
# 官方 uninstall.sh 是 Java 交互式程序，会询问两个问题：
#   1) 确认卸载数据库?  2) 是否删除 dm_svc.conf?
# 使用 yes y 提供无限 y 回答，避免 NoSuchElementException
if [ -f "${DM_HOME}/uninstall.sh" ] && id dmdba >/dev/null 2>&1;then
    log_info "执行官方卸载脚本"
    yes y | su - dmdba -c "${DM_HOME}/uninstall.sh -i" >/dev/null 2>&1 || \
        log_warn "官方 uninstall.sh 执行失败，继续强制清理"
    # 执行 root 服务卸载脚本（同样交互式，用 yes y 提供确认）
    if [ -f "${DM_HOME}/script/root/dm_service_uninstaller.sh" ];then
        yes y | bash "${DM_HOME}/script/root/dm_service_uninstaller.sh" -n "DmService${INSTANCE_NAME}" >/dev/null 2>&1 || \
            log_warn "root 服务卸载脚本执行失败"
    fi
fi

# 清理目录
rm -rf "${DM_HOME}"
rm -rf "${DATA_PATH}"

# 清理 dm_svc.conf 配置文件
rm -f /etc/dm_svc.conf 2>/dev/null || true

# 删除用户组
userdel -r dmdba 2>/dev/null || log_warn "dmdba 用户删除失败（可能仍有进程占用或已删除）"
groupdel dinstall 2>/dev/null || log_warn "dinstall 组删除失败（可能非空或已删除）"
log_info "达梦卸载清理完成"
