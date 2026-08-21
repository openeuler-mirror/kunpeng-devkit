#!/bin/bash
# migrate_tongweb.sh — TongWeb 应用服务器迁移脚本
# 职责：依赖 JDK → 安装 TongWeb → 恢复配置 → 注册 systemd 服务 → 健康检查（HTTP 9088）。
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

require_env MIDDLEWARE_TYPE TARGET_VERSION DEPLOY_DIR || exit 1

CURRENT_VERSION="${CURRENT_VERSION:-unknown}"

TONGWEB_HOME="${TONGWEB_HOME:-$DEPLOY_DIR}"
TONGWEB_HEALTH_URL="${TONGWEB_HEALTH_URL:-}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

log_info "TongWeb 迁移开始: $CURRENT_VERSION -> $TARGET_VERSION (部署目录: $TONGWEB_HOME)"

if [ -z "$TONGWEB_HEALTH_URL" ]; then
    TONGWEB_HEALTH_URL=$(registry_get '.strategies.tongweb.health_url')
fi

case "$TONGWEB_HOME" in
    /*) ;;
    *) log_error "TongWeb 安装目录必须是绝对路径: $TONGWEB_HOME"; exit 1 ;;
esac
case "$TONGWEB_HOME" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        log_error "拒绝使用系统目录作为 TongWeb 安装目录: $TONGWEB_HOME"; exit 1 ;;
esac
# 拒绝符号链接安装目录，防止 rm -rf 跟随链接删除目标内容
if [ -L "$TONGWEB_HOME" ]; then
    log_error "拒绝使用符号链接作为 TongWeb 安装目录: $TONGWEB_HOME"
    exit 1
fi

if ! JAVA_HOME=$(resolve_java_home); then
    log_error "未找到可用 JAVA_HOME，请先完成 JDK 迁移"
    exit 1
fi
log_info "使用 JAVA_HOME=$JAVA_HOME"

TARGET_ARCH=$(uname -m)
case "$TARGET_ARCH" in
    aarch64|arm64) ;;
    *) log_error "TongWeb 目标架构必须是 aarch64/arm64，当前为 $TARGET_ARCH"; exit 1 ;;
esac

# 安装包源仅取自 plan（local_path/download_url）；缺失时直接失败
PACKAGE_PATH="${LOCAL_PACKAGE_PATH:-}"
PACKAGE_FILE=""
if [ -n "$PACKAGE_PATH" ] && [ -s "$PACKAGE_PATH" ]; then
    PACKAGE_FILE="$PACKAGE_PATH"
    log_info "使用本地 TongWeb 安装包: $PACKAGE_FILE"
else
    DOWNLOAD_URL=$(resolve_download_url)
    if [ -z "$DOWNLOAD_URL" ] || ! echo "$DOWNLOAD_URL" | grep -q '^https://'; then
        log_error "plan 未提供 TongWeb 安装包源（download_url/local_path 均缺失或非 HTTPS），请在 migration-plan.json 的 route.middleware[].packages[0] 中补充"
        exit 1
    fi
    log_info "下载 TongWeb 安装包: $DOWNLOAD_URL"
    PACKAGE_FILE=$(download_package "$DOWNLOAD_URL" "$(basename "${DOWNLOAD_URL%%\?*}")") || {
        log_error "TongWeb 安装包下载失败"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    }
fi

STAGE_DIR="$WORK_DIR/tongweb/staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
case "$PACKAGE_FILE" in
    *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tar.xz) tar -xf "$PACKAGE_FILE" -C "$STAGE_DIR" ;;
    *.zip) unzip -q "$PACKAGE_FILE" -d "$STAGE_DIR" ;;
    *) log_error "不支持的 TongWeb 安装包格式: $PACKAGE_FILE"; exit 1 ;;
esac

# 安装包可能是外层打包（内含 tar.gz/zip 二次打包），自动解包内层归档
find_pkg_start_script() {
    local d="$1"
    find "$d" -type f -name startservernohup.sh 2>/dev/null | head -1
}
START_SCRIPT=$(find_pkg_start_script "$STAGE_DIR")
if [ -z "$START_SCRIPT" ]; then
    for inner in "$STAGE_DIR"/*.tar.gz "$STAGE_DIR"/*.tgz "$STAGE_DIR"/*.tar.bz2 "$STAGE_DIR"/*.tar.xz "$STAGE_DIR"/*.tar "$STAGE_DIR"/*.zip; do
        [ -e "$inner" ] || continue
        log_info "解包内层安装包: $(basename "$inner")"
        case "$inner" in
            *.zip) unzip -q "$inner" -d "$STAGE_DIR" ;;
            *) tar -xf "$inner" -C "$STAGE_DIR" ;;
        esac
        START_SCRIPT=$(find_pkg_start_script "$STAGE_DIR")
        [ -n "$START_SCRIPT" ] && break
    done
fi

SERVICE_TYPE="forking"
if [ -z "$START_SCRIPT" ]; then
    START_SCRIPT=$(find "$STAGE_DIR" -type f -name startserver.sh | head -1)
    SERVICE_TYPE="simple"
fi
if [ -z "$START_SCRIPT" ]; then
    log_error "安装包内未找到 bin/startservernohup.sh 或 bin/startserver.sh"
    exit 1
fi
EXTRACTED_HOME=$(dirname "$(dirname "$START_SCRIPT")")

ARM_SVC=$(resolve_arm_service "$MIDDLEWARE_TYPE")
# 检查磁盘空间（至少 500MB）——须在删除旧环境之前
TONGWEB_PARENT_DIR=$(dirname "$TONGWEB_HOME")
mkdir -p "$TONGWEB_PARENT_DIR"
AVAILABLE_SPACE=$(df -m "$TONGWEB_PARENT_DIR" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_SPACE:-0}" -lt 500 ]; then
    log_error "磁盘空间不足: ${AVAILABLE_SPACE}MB（需要至少 500MB）"
    exit 1
fi
log_info "停止当前服务: $ARM_SVC"
"$SYSTEMCTL_BIN" stop "$ARM_SVC" 2>/dev/null || true
"$SYSTEMCTL_BIN" disable "$ARM_SVC" 2>/dev/null || true
rm -rf "$TONGWEB_HOME"

log_info "安装 TongWeb 到 $TONGWEB_HOME"
mkdir -p "$TONGWEB_HOME"
cp -a "$EXTRACTED_HOME/." "$TONGWEB_HOME/"

# 配置恢复
mkdir -p "$TONGWEB_HOME/conf/migration-source"
resolve_artifact_paths | while IFS= read -r config_path; do
    resolved_path=$(resolve_artifact_file "$config_path") || continue
    [ -f "$resolved_path" ] || continue
    cp "$resolved_path" "$TONGWEB_HOME/conf/migration-source/"
done

# License 处理
LICENSES="${LICENSES:-[]}"
LICENSE_FILE=$(printf '%s' "$LICENSES" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    files = []
    for item in data:
        uf = item.get('uploaded_files') or []
        files.extend(uf)
    print(files[0] if files else '')
except: print('')
" 2>/dev/null)
if [ -n "$LICENSE_FILE" ] && [ -s "$LICENSE_FILE" ]; then
    cp "$LICENSE_FILE" "$TONGWEB_HOME/license.dat"
    LICENSE_STATUS="UPLOADED"
else
    LICENSE_STATUS="PENDING_UPLOAD"
    log_warn "未提供 TongWeb License；将继续启动，失败时请先补充 license.dat"
fi

defer_if_license_error() {
    [ "$LICENSE_STATUS" = "PENDING_UPLOAD" ] || return 1
    if [ -d "$TONGWEB_HOME/logs" ] && grep -RqiE 'license.*(missing|invalid|expired|not found)|授权.*(缺失|无效|过期|不存在)' "$TONGWEB_HOME/logs"; then
        log_warn "TongWeb 日志确认 License 不可用，组件延期到 License 补充后继续"
        cat > "$REPORTS_DIR/tongweb_migration_report.md" << EOF
# TongWeb 迁移报告

- 路线: Tomcat ${CURRENT_VERSION:-未知} → TongWeb $TARGET_VERSION
- 安装目录: $TONGWEB_HOME
- License: PENDING_UPLOAD
- 服务: DEFERRED_LICENSE
- 说明: 日志确认 License 不可用，补充 license.dat 后恢复启动与验证
EOF
        set_migration_state "$MIDDLEWARE_TYPE" "blocked"
        return 20
    fi
    return 1
}

START_SCRIPT="$TONGWEB_HOME/bin/$(basename "$START_SCRIPT")"
STOP_SCRIPT=$(find "$TONGWEB_HOME/bin" -maxdepth 1 -type f \( -name stopserver.sh -o -name shutdown.sh \) | head -1)
[ -n "$STOP_SCRIPT" ] || { log_error "安装后未找到 TongWeb 停止脚本"; exit 1; }
chmod +x "$START_SCRIPT" "$STOP_SCRIPT"

# 创建 systemd 服务
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/$ARM_SVC.service" << EOF
[Unit]
Description=TongWeb ARM Service
After=network.target

[Service]
Type=$SERVICE_TYPE
Environment="JAVA_HOME=$JAVA_HOME"
WorkingDirectory="$TONGWEB_HOME"
ExecStart="$START_SCRIPT"
ExecStop="$STOP_SCRIPT"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

"$SYSTEMCTL_BIN" daemon-reload
"$SYSTEMCTL_BIN" enable "$ARM_SVC" >/dev/null
if ! start_service "$ARM_SVC"; then
    defer_if_license_error
    RC=$?
    [ $RC -eq 20 ] && exit 20
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

# HTTP 健康检查
HEALTH_STATUS="NOT_CHECKED"
if [ -n "$TONGWEB_HEALTH_URL" ]; then
    command -v curl >/dev/null 2>&1 || { log_error "缺少 curl，无法执行 TongWeb HTTP 验证"; exit 1; }
    _attempt=0
    while [ "$_attempt" -lt 10 ]; do
        _attempt=$((_attempt + 1))
        HTTP_CODE=$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 -w '%{http_code}' "$TONGWEB_HEALTH_URL" 2>/dev/null || true)
        case "$HTTP_CODE" in
            2??|3??) HEALTH_STATUS="HTTP_$HTTP_CODE"; break ;;
        esac
        sleep 3
    done
    if [ "$HEALTH_STATUS" = "NOT_CHECKED" ]; then
        defer_if_license_error
        RC=$?
        [ $RC -eq 20 ] && exit 20
        log_error "TongWeb HTTP 健康检查失败"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
fi

set_migration_state "$MIDDLEWARE_TYPE" "success"

# 报告
cat > "$REPORTS_DIR/tongweb_migration_report.md" << EOF
# TongWeb 迁移报告

- 路线: Tomcat ${CURRENT_VERSION:-未知} → TongWeb $TARGET_VERSION
- 安装包: $PACKAGE_FILE
- 安装目录: $TONGWEB_HOME
- License: $LICENSE_STATUS
- 源配置: 已保存到 $TONGWEB_HOME/conf/migration-source
- 服务: $ARM_SVC（active）
- HTTP 验证: $HEALTH_STATUS
- 架构: $TARGET_ARCH
EOF

log_info "TongWeb 迁移完成: $CURRENT_VERSION -> $TARGET_VERSION (服务: $ARM_SVC)"
