#!/bin/bash
# migrate_besappserver.sh — BES AppServer 迁移：依赖 JDK → 安装 BES → 恢复配置 →
# 注册 systemd 服务 → 健康检查（HTTP 8080）。
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

BES_HOME="${BES_HOME:-$DEPLOY_DIR}"
BES_HEALTH_URL="${BES_HEALTH_URL:-}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
BES_USER="${BES_USER:-bes}"
BES_GROUP="${BES_GROUP:-bes}"
BES_ADMIN_USER="${BES_ADMIN_USER:-admin}"
# 管理员密码不设默认值：未显式传入时随机生成，仅用于 configserver 初始化与 .passwordfile/envfile 引用，
# 不落任何明文（unit 文件、脚本仓库均不含密码）
BES_ADMIN_PASSWORD="${BES_ADMIN_PASSWORD:-}"
if [ -z "$BES_ADMIN_PASSWORD" ]; then
    BES_ADMIN_PASSWORD=$(head -c 24 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '/+=' | head -c 20)
    [ -z "$BES_ADMIN_PASSWORD" ] && BES_ADMIN_PASSWORD=$(date +%s%N$$ | md5sum | head -c 20)
fi
BES_ADMIN_HOST="${BES_ADMIN_HOST:-localhost}"
BES_ADMIN_PORT="${BES_ADMIN_PORT:-1900}"
BES_USER_PORT="${BES_USER_PORT:-8080}"

log_info "BES AppServer 迁移开始: $CURRENT_VERSION -> $TARGET_VERSION (部署目录: $BES_HOME)"

if [ -z "$BES_HEALTH_URL" ]; then
    BES_HEALTH_URL=$(registry_get '.strategies.besappserver.health_url')
fi

case "$BES_HOME" in
    /*) ;;
    *) log_error "BES AppServer 安装目录必须是绝对路径: $BES_HOME"; exit 1 ;;
esac
case "$BES_HOME" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        log_error "拒绝使用系统目录作为 BES AppServer 安装目录: $BES_HOME"; exit 1 ;;
esac
# 拒绝符号链接安装目录，防止 rm -rf 跟随链接删除目标内容
if [ -L "$BES_HOME" ]; then
    log_error "拒绝使用符号链接作为 BES AppServer 安装目录: $BES_HOME"
    exit 1
fi

# BES AppServer 9.5.x 依赖 JDK（JDK 主版本取自 registry 的 dependencies[].target_version，不在脚本内写死；
# UNIFIED_JDK_VERSION 统一时使用该版本）。也可用 BES_JAVA8_HOME 显式指定。
BES_JAVA_REQUIRED=$(registry_get '.strategies.besappserver.dependencies[0].target_version' "8")
[ -n "${UNIFIED_JDK_VERSION:-}" ] && BES_JAVA_REQUIRED="$UNIFIED_JDK_VERSION"
JAVA8_HOME="${BES_JAVA8_HOME:-}"
if [ -n "$JAVA8_HOME" ] && ! java_version_ok "$JAVA8_HOME" "$BES_JAVA_REQUIRED"; then
    log_warn "BES_JAVA8_HOME 版本不匹配(需 JDK $BES_JAVA_REQUIRED)，重新解析"
    JAVA8_HOME=""
fi
if [ -z "$JAVA8_HOME" ]; then
    JAVA8_HOME=$(resolve_java_home_for_version "$BES_JAVA_REQUIRED")
fi
if [ -z "$JAVA8_HOME" ]; then
    log_error "未找到满足版本要求(需 JDK ${BES_JAVA_REQUIRED})的 Java 运行时（BES AppServer 9.5.x 必需），请先完成对应 JDK 迁移或设置 BES_JAVA8_HOME"
    exit 1
fi
export JAVA_HOME="$JAVA8_HOME"
log_info "使用 JAVA_HOME=$JAVA_HOME (BES AppServer 需要 JDK ${BES_JAVA_REQUIRED})"

TARGET_ARCH=$(uname -m)
case "$TARGET_ARCH" in
    aarch64|arm64) ;;
    *) log_error "BES AppServer 目标架构必须是 aarch64/arm64，当前为 $TARGET_ARCH"; exit 1 ;;
esac

# 安装包源仅取自 plan（local_path/download_url）；缺失时直接失败
PACKAGE_PATH="${LOCAL_PACKAGE_PATH:-}"
PACKAGE_FILE=""
if [ -n "$PACKAGE_PATH" ] && [ -s "$PACKAGE_PATH" ]; then
    PACKAGE_FILE="$PACKAGE_PATH"
    log_info "使用本地 BES AppServer 安装包: $PACKAGE_FILE"
else
    DOWNLOAD_URL=$(resolve_download_url)
    if [ -z "$DOWNLOAD_URL" ] || ! echo "$DOWNLOAD_URL" | grep -q '^https://'; then
        log_error "plan 未提供 BES AppServer 安装包源（download_url/local_path 均缺失或非 HTTPS），请在 migration-plan.json 的 route.middleware[].packages[0] 中补充"
        exit 1
    fi
    log_info "下载 BES AppServer 安装包: $DOWNLOAD_URL"
    PACKAGE_FILE=$(download_package "$DOWNLOAD_URL" "$(basename "${DOWNLOAD_URL%%\?*}")") || {
        log_error "BES AppServer 安装包下载失败"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    }
fi

STAGE_DIR="$WORK_DIR/besappserver/staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
case "$PACKAGE_FILE" in
    *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tar.xz) tar -xf "$PACKAGE_FILE" -C "$STAGE_DIR" ;;
    *.zip) unzip -q "$PACKAGE_FILE" -d "$STAGE_DIR" ;;
    *) log_error "不支持的 BES AppServer 安装包格式: $PACKAGE_FILE"; exit 1 ;;
esac

# 查找 BES AppServer 根目录（含 bin/iastool 的 bin 的父目录）
find_bes_home() {
    local d="$1"
    local b
    b=$(find "$d" -type d -name bin -exec test -f '{}/iastool' \; -print 2>/dev/null | head -1)
    [ -n "$b" ] && dirname "$b"
    return 0
}
BES_PKG_HOME="$(find_bes_home "$STAGE_DIR")"
# 安装包可能是外层打包（内含 tar.gz/zip 二次打包），自动解包内层归档
if [ -z "$BES_PKG_HOME" ]; then
    for inner in "$STAGE_DIR"/*.tar.gz "$STAGE_DIR"/*.tgz "$STAGE_DIR"/*.tar.bz2 "$STAGE_DIR"/*.tar.xz "$STAGE_DIR"/*.tar "$STAGE_DIR"/*.zip; do
        [ -e "$inner" ] || continue
        log_info "解包内层安装包: $(basename "$inner")"
        case "$inner" in
            *.zip) unzip -q "$inner" -d "$STAGE_DIR" ;;
            *) tar -xf "$inner" -C "$STAGE_DIR" ;;
        esac
        BES_PKG_HOME="$(find_bes_home "$STAGE_DIR")"
        [ -n "$BES_PKG_HOME" ] && break
    done
fi
if [ -z "$BES_PKG_HOME" ]; then
    log_error "安装包内未找到 BES AppServer（bin/iastool）"
    exit 1
fi
EXTRACTED_HOME="$BES_PKG_HOME"

ARM_SVC=$(resolve_arm_service "$MIDDLEWARE_TYPE")

# 检查磁盘空间（至少 500MB）——须在删除旧环境之前，避免磁盘不足时旧环境被毁且无法回滚
BES_PARENT_DIR=$(dirname "$BES_HOME")
mkdir -p "$BES_PARENT_DIR"
AVAILABLE_SPACE=$(df -m "$BES_PARENT_DIR" | awk 'NR==2 {print $4}')
if [ "${AVAILABLE_SPACE:-0}" -lt 500 ]; then
    log_error "磁盘空间不足: ${AVAILABLE_SPACE}MB（需要至少 500MB）"
    exit 1
fi

log_info "停止当前服务: $ARM_SVC"
"$SYSTEMCTL_BIN" stop "$ARM_SVC" 2>/dev/null || true
"$SYSTEMCTL_BIN" disable "$ARM_SVC" 2>/dev/null || true
# 清理已有部署目录（上层冲突处理已删除用户选择 overwrite 的目录，此处为兜底）
if [ -d "$BES_HOME" ]; then
    log_info "清理已有部署目录: $BES_HOME"
fi
rm -rf "$BES_HOME"

# 创建 BES 用户（如果不存在）
if ! id "$BES_USER" &>/dev/null; then
    log_info "创建用户: $BES_USER"
    groupadd "$BES_GROUP" 2>/dev/null || true
    useradd -m -g "$BES_GROUP" "$BES_USER"
fi

log_info "安装 BES AppServer 到 $BES_HOME"
mkdir -p "$BES_HOME"
cp -a "$EXTRACTED_HOME/." "$BES_HOME/"

# 设置目录权限：BES_HOME 归服务用户；父目录保证可遍历（711），否则 systemd 服务用户无法 chdir 进入
chown -hR "$BES_USER:$BES_GROUP" "$BES_HOME"

chmod 700 "$BES_HOME" 2>/dev/null || true
chmod 711 "$BES_PARENT_DIR" 2>/dev/null || true

# 配置恢复：保存源 Tomcat 配置到迁移源目录
mkdir -p "$BES_HOME/conf/migration-source"
resolve_artifact_paths | while IFS= read -r config_path; do
    resolved_path=$(resolve_artifact_file "$config_path") || continue
    [ -f "$resolved_path" ] || continue
    cp "$resolved_path" "$BES_HOME/conf/migration-source/"
done

# License 处理：BES 首次启动时自动从 license/bes.lic.txt 导入到 license/bes.lic，
# 预置 bes.lic 会导致 "License file has been tampered"。因此：
#  - 有上传 License 时覆盖 license/bes.lic.txt（作为授权依据）
#  - 清理历史 bes.lic/.installtime，交由 BES 首次启动导入
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
    mkdir -p "$BES_HOME/license"
    cp "$LICENSE_FILE" "$BES_HOME/license/bes.lic.txt"
    chown -hR "$BES_USER:$BES_GROUP" "$BES_HOME/license"
    chmod 700 "$BES_HOME/license"
    LICENSE_STATUS="UPLOADED"
    log_info "License 已写入: $BES_HOME/license/bes.lic.txt（首次启动自动导入）"
else
    LICENSE_STATUS="PENDING_UPLOAD"
    log_warn "未提供 BES License；将使用安装包自带试用授权，正式使用请补充 license 文件"
fi
rm -f "$BES_HOME/license/bes.lic" "$BES_HOME/license/.installtime"

# 为 BES 用户配置 JAVA_HOME（JDK 8）
BES_BASHRC="/home/$BES_USER/.bashrc"
if ! grep -q "JAVA_HOME" "$BES_BASHRC" 2>/dev/null; then
    log_info "为 $BES_USER 用户配置 JAVA_HOME"
    cat >> "$BES_BASHRC" << EOF
export JAVA_HOME=$JAVA8_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    chown "$BES_USER:$BES_GROUP" "$BES_BASHRC"
fi

# BES AppServer 9.5.x 初始化：configserver 创建实例配置、密钥库与 .passwordfile
# （未初始化直接启动会报 "Options --user is required"）
BES_BIN="$BES_HOME/bin"
CONFIG_INIT_MARKER="$BES_HOME/conf/.configserver_inited"
if [ ! -f "$CONFIG_INIT_MARKER" ]; then
    log_info "执行 configserver 初始化 BES 实例..."
    if ! runuser -u "$BES_USER" -- env JAVA_HOME="$JAVA8_HOME" "$BES_BIN/configserver" \
            --user="$BES_ADMIN_USER" --password="$BES_ADMIN_PASSWORD" \
            --adminhost=0.0.0.0 --adminport="$BES_ADMIN_PORT" \
            --userhost=0.0.0.0 --userport="$BES_USER_PORT" >> "$WORK_DIR/besappserver/configserver.log" 2>&1; then
        log_error "BES configserver 初始化失败，详见 $WORK_DIR/besappserver/configserver.log"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
    touch "$CONFIG_INIT_MARKER"
fi

# iastool 启停命令（前缀一致，仅末尾 start/stop 不同）
IASTOOL_BASE="$BES_BIN/iastool --user $BES_ADMIN_USER --host $BES_ADMIN_HOST --port $BES_ADMIN_PORT"
PASSWORD_FILE="$BES_HOME/conf/.passwordfile"
UNIT_ENVFILE_LINE=""
if [ -f "$PASSWORD_FILE" ]; then
    START_CMD="$IASTOOL_BASE --passwordfile $PASSWORD_FILE start --server"
    STOP_CMD="$IASTOOL_BASE --passwordfile $PASSWORD_FILE stop --server"
else
    # 无 .passwordfile 时：密码写入仅属主可读的 EnvironmentFile，unit 内以环境变量引用（不落 unit 明文）
    ADMIN_ENV_FILE="$BES_HOME/conf/.admin.env"
    printf 'BES_ADMIN_PASSWORD=%s\n' "$BES_ADMIN_PASSWORD" > "$ADMIN_ENV_FILE"
    chown "$BES_USER:$BES_GROUP" "$ADMIN_ENV_FILE" 2>/dev/null || true
    chmod 600 "$ADMIN_ENV_FILE"
    UNIT_ENVFILE_LINE="EnvironmentFile=$ADMIN_ENV_FILE"
    # \$BES_ADMIN_PASSWORD 保持字面量写入 unit，由 sh 从 systemd 注入的环境展开
    START_CMD="$IASTOOL_BASE --password \$BES_ADMIN_PASSWORD start --server"
    STOP_CMD="$IASTOOL_BASE --password \$BES_ADMIN_PASSWORD stop --server"
fi

# 创建 systemd 服务（iastool start 内部 fork 守护进程，Type=forking）
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/$ARM_SVC.service" << EOF
[Unit]
Description=BES AppServer ARM Service
After=network.target

[Service]
Type=forking
User=$BES_USER
Group=$BES_GROUP
Environment=JAVA_HOME=$JAVA8_HOME
$UNIT_ENVFILE_LINE
WorkingDirectory=$BES_HOME
ExecStart=/bin/sh -c 'cd $BES_HOME/bin && $START_CMD'
ExecStop=/bin/sh -c 'cd $BES_HOME/bin && $STOP_CMD'
TimeoutStartSec=600
TimeoutStopSec=60
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

"$SYSTEMCTL_BIN" daemon-reload
"$SYSTEMCTL_BIN" enable "$ARM_SVC" >/dev/null
if ! start_service "$ARM_SVC"; then
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

# HTTP 健康检查
HEALTH_STATUS="NOT_CHECKED"
if [ -n "$BES_HEALTH_URL" ]; then
    command -v curl >/dev/null 2>&1 || { log_error "缺少 curl，无法执行 BES AppServer HTTP 验证"; exit 1; }
    _attempt=0
    while [ "$_attempt" -lt 10 ]; do
        _attempt=$((_attempt + 1))
        HTTP_CODE=$(curl -sS -o /dev/null --connect-timeout 3 --max-time 5 -w '%{http_code}' "$BES_HEALTH_URL" 2>/dev/null || true)
        case "$HTTP_CODE" in
            2??|3??) HEALTH_STATUS="HTTP_$HTTP_CODE"; break ;;
        esac
        sleep 3
    done
    if [ "$HEALTH_STATUS" = "NOT_CHECKED" ]; then
        log_error "BES AppServer HTTP 健康检查失败"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
fi

set_migration_state "$MIDDLEWARE_TYPE" "success"

# 报告
cat > "$REPORTS_DIR/besappserver_migration_report.md" << EOF
# BES AppServer 迁移报告

- 路线: Tomcat ${CURRENT_VERSION:-未知} → BES AppServer $TARGET_VERSION
- 安装包: $PACKAGE_FILE
- 安装目录: $BES_HOME
- 运行用户: $BES_USER
- License: $LICENSE_STATUS
- 源配置: 已保存到 $BES_HOME/conf/migration-source
- 服务: $ARM_SVC（active）
- HTTP 验证: $HEALTH_STATUS
- 架构: $TARGET_ARCH
EOF

log_info "BES AppServer 迁移完成: $CURRENT_VERSION -> $TARGET_VERSION (服务: $ARM_SVC)"
