#!/bin/bash
#==============================================================================
# 金仓数据库 KingbaseES V8R6 静默安装脚本 (ARM / 鲲鹏架构)
# 适用安装包 : kingbase_install.zip (内含 KingbaseES_V008R006C*_Kunpeng64_install.iso)
# 安装方式   : install.bin -i silent -f silent.cfg（ISO 复制到可写目录后执行）
# 模板       : assets/kingbase/kingbase_silent.cfg (envsubst 渲染，默认自动定位)
# 脚本职责   : 解压挂载/MD5校验/渲染响应文件/静默安装/直接启动/SQL验证（含密码操作）
# Agent 职责 : 资源限制、环境变量、systemd服务注册（见 references/kingbase-deploy-guide.md）
# 固化脚本   : 仅通过命令行参数控制安装行为
# 执行模型   : root 入口；root 负责解压/挂载/目录创建/chown，kingbase 用户负责 install.bin/数据库操作
#==============================================================================
set -euo pipefail

MIGRATION_WORK_DIR="${MIGRATION_WORK_DIR:-}"
if [ -n "$MIGRATION_WORK_DIR" ]; then
    DATABASE_WORK_DIR="$MIGRATION_WORK_DIR/database"
else
    DATABASE_WORK_DIR="${DATABASE_WORK_DIR:-}"
fi

#==================== 默认参数（与官方 silent.cfg 默认值一致） ====================
INSTALL_PATH="/opt/Kingbase/ES/V8"; DATA_PATH=""
CFG_TEMPLATE=""; ENV_CONF=""; PACKAGE=""; LICENSE_FILE=""
LOG_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/logs}"
DB_OS_USER="kingbase"                     # 数据库专属 OS 用户（install.bin 必须以此用户执行）
INSTANCE_NAME="kingbase"; DB_USER="system"; DB_PASS=""; _CLI_DB_PASS=""
PORT_NUM=54321
ENCODING_PARAM="UTF8"; LOCALE_PARAM="zh_CN.UTF-8"
DATABASE_MODE_PARAM="ORACLE"; CASE_SENSITIVE_PARAM="YES"; BLOCK_SIZE_PARAM="8k"
AUTHENTICATION_METHOD_PARAM="scram-sha-256"
CHOSEN_INSTALL_SET="Full"
CHOSEN_FEATURE_LIST="SERVER,KSTUDIO,KDTS,INTERFACE,DEPLOY,KINGBASEHA"
EXTRACT_BASE_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/tmp/kingbase}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# 运行时变量
EXTRACT_DIR=""; ISO_MOUNT_DIR=""; SETUP_DIR=""; SYS_CTL_BIN=""; RESPONSE_FILE=""

#==================== 工具函数 ====================
log_info()  { echo "[$(date '+%F %T')] [INFO ] $*"; }
log_warn()  { echo "[$(date '+%F %T')] [WARN ] $*" >&2; }
log_error() { echo "[$(date '+%F %T')] [ERROR] $*" >&2; }
die() { log_error "$*"; exit 1; }
ensure_runtime_dir() {
    local path="$1" label="$2" root actual
    [ -n "$path" ] || die "$label 未设置；系统迁移必须使用 MIGRATION_WORK_DIR/database 下的运行目录"
    mkdir -p "$path" || die "无法创建 $label: $path"
    if [ -n "$MIGRATION_WORK_DIR" ]; then
        case "$MIGRATION_WORK_DIR" in /*) ;; *) die "MIGRATION_WORK_DIR 必须是绝对路径" ;; esac
        mkdir -p "$MIGRATION_WORK_DIR" "$DATABASE_WORK_DIR"
        root=$(cd "$DATABASE_WORK_DIR" && pwd -P)
        actual=$(cd "$path" && pwd -P)
        case "$actual/" in "$root/"*) ;; *) die "$label 必须位于 $root 下: $actual" ;; esac
    fi
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1"; }
run_as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }
has_root_priv() { [ "$(id -u)" -eq 0 ] && return 0; sudo -n true 2>/dev/null && return 0; return 1; }
# 以数据库专属 OS 用户执行 install.bin / sys_ctl / ksql（金仓安装器不允许 root 运行）
run_as_db_user() {
    local _user="$DB_OS_USER"
    [ -n "$_user" ] || die "DB_OS_USER 未设置"
    if [ "$(id -un)" = "$_user" ]; then "$@"; else su - "$_user" -s /bin/bash -c "$(printf '%q ' "$@")"; fi
}
# KingbaseES 密码策略：>=8位，含大小写字母+数字
validate_password() {
    local pwd=$1
    [ ${#pwd} -ge 8 ] || die "密码长度不能小于8"
    echo "$pwd" | grep -q '[A-Z]' || die "密码必须包含大写字母"
    echo "$pwd" | grep -q '[a-z]' || die "密码必须包含小写字母"
    echo "$pwd" | grep -q '[0-9]' || die "密码必须包含数字"
    unset pwd
}

#==================== 参数解析 ====================
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]
执行模型：以 root 身份运行；install.bin 与数据库进程自动 su 切换至 $DB_OS_USER 用户

必选参数:
  --env-conf=FILE        环境配置文件路径 (install_env.conf)
  --package=FILE         KingbaseES 安装包路径 (kingbase_install.zip)

可选参数:
  --license=FILE         license 文件路径 (.dat)，空则安装后生成试用 license
  --cfg-template=FILE    silent.cfg 模板 (默认: 自动定位 assets/kingbase/kingbase_silent.cfg)
  --extract-dir=DIR      解压基目录          (默认: $MIGRATION_WORK_DIR/database/tmp/kingbase)
  --log-dir=DIR          日志输出目录        (默认: $MIGRATION_WORK_DIR/database/logs)
  --db-pass=PWD          数据库管理员密码（命令行优先于 env-conf 的 DB_PASSWORD；不再提供默认值，必须显式指定）
  -h, --help             显示本帮助

其余安装参数（INSTALL_PATH/DATA_PATH/PORT_NUM/DB_USER 等）统一由 env-conf 提供
EOF
    exit 0
}
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --cfg-template=*)   CFG_TEMPLATE="${1#*=}" ;;
            --env-conf=*)       ENV_CONF="${1#*=}" ;;
            --package=*)        PACKAGE="${1#*=}" ;;
            --license=*)        LICENSE_FILE="${1#*=}" ;;
            --extract-dir=*)    EXTRACT_BASE_DIR="${1#*=}" ;;
            --log-dir=*)        LOG_DIR="${1#*=}" ;;
            --db-pass=*)        _CLI_DB_PASS="${1#*=}" ;;
            -h|--help)          usage ;;
            *) die "未知参数: $1" ;;
        esac
        shift
    done
}

#==================== 加载配置（命令行优先，env-conf 补全） ====================
load_env_conf() {
    [ -z "$ENV_CONF" ] && die "未指定 --env-conf 参数"
    [ -f "$ENV_CONF" ] || die "环境配置文件不存在: $ENV_CONF"
    log_info "加载环境配置: $ENV_CONF"
    # shellcheck disable=SC1090
    source "$ENV_CONF"
    [ -z "$DATA_PATH" ] && DATA_PATH="${DATA_PATH:-$INSTALL_PATH/data}"
    # 命令行 --db-pass 优先于 env-conf 的 DB_PASSWORD
    [ -n "${_CLI_DB_PASS:-}" ] && DB_PASSWORD="$_CLI_DB_PASS"
    unset _CLI_DB_PASS
    DB_PASS="${DB_PASSWORD:-}"
    # 兜底：从 references/kingbase-deploy-guide.md 表格读取约定默认密码（不再硬编码到脚本）
    if [ -z "$DB_PASS" ]; then
        local ref_file; ref_file="$(cd "$(dirname "$0")/../../references" && pwd)/kingbase-deploy-guide.md"
        DB_PASS=$(grep -E '^\| `DB_PASSWORD`' "$ref_file" 2>/dev/null \
            | awk -F'|' '{print $4}' | sed -E 's/.*`([^`]+)`.*/\1/' | head -1)
        [ -n "$DB_PASS" ] || die "DB_PASSWORD 未提供且无法从 $ref_file 读取默认值"
        DB_PASSWORD="$DB_PASS"
        log_warn "DB_PASSWORD 未提供，使用 reference 文档中的默认值（建议生产环境显式指定）"
    fi
    validate_password "$DB_PASS"
    case "$ENCODING_PARAM" in UTF8|GBK|GB18030|GB2312|default) ;; *) die "不支持的字符集: $ENCODING_PARAM" ;; esac
    case "$DATABASE_MODE_PARAM" in ORACLE|PG|MySQL) ;; *) die "不支持的兼容模式: $DATABASE_MODE_PARAM" ;; esac
    case "$CASE_SENSITIVE_PARAM" in YES|NO) ;; *) die "大小写敏感取值非法: $CASE_SENSITIVE_PARAM" ;; esac
    case "$BLOCK_SIZE_PARAM" in 8k|16k|32k) ;; *) die "块大小取值非法: $BLOCK_SIZE_PARAM" ;; esac
    case "$AUTHENTICATION_METHOD_PARAM" in scram-sha-256|scram-sm3|sm4|sm3) ;; *) die "认证方式取值非法: $AUTHENTICATION_METHOD_PARAM" ;; esac
    [ "$PORT_NUM" -gt 0 ] 2>/dev/null && [ "$PORT_NUM" -lt 65535 ] 2>/dev/null || die "端口取值非法: $PORT_NUM"
    [ ${#DB_USER} -lt 63 ] || die "数据库用户名长度须小于63字节"
}

#==================== 前置检查 ====================
preflight_check() {
    log_info "执行前置检查"
    [ "$(uname -m)" = "aarch64" ] || die "当前架构 $(uname -m) 非 aarch64，本脚本仅支持 ARM/鲲鹏"
    # root 入口模型：解压/挂载/目录创建需要 root，install.bin 通过 su 切换 kingbase 执行
    has_root_priv || die "本脚本必须以 root 身份执行（或具备 sudo 免密权限）；install.bin 会自动切换至 $DB_OS_USER 用户"
    id "$DB_OS_USER" >/dev/null 2>&1 || die "数据库 OS 用户 $DB_OS_USER 不存在，请先由前置流程创建"
    require_cmd unzip; require_cmd mount; require_cmd md5sum; require_cmd envsubst
    # 强制核对数据库必需运行库（glibc/libaio/ncurses/readline/zlib），任一缺失即环境检查不通过
    local _entry _soname _name _missing_libs=""
    for _entry in libc.so.6:glibc libaio.so.1:libaio libncurses.so:ncurses libreadline.so:readline libz.so.1:zlib; do
        _soname="${_entry%%:*}"; _name="${_entry##*:}"
        ldconfig -p 2>/dev/null | grep -q "$_soname" || _missing_libs="$_missing_libs $_name"
    done
    [ -z "$_missing_libs" ] || die "缺少必需运行库:$_missing_libs"
    [ -n "$PACKAGE" ] && [ -f "$PACKAGE" ] || die "安装包不存在: ${PACKAGE:-未指定}"
    [ -n "$LICENSE_FILE" ] && [ ! -f "$LICENSE_FILE" ] && die "license 文件不存在: $LICENSE_FILE"
    [ -n "$EXTRACT_BASE_DIR" ] || EXTRACT_BASE_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/tmp/kingbase}"
    ensure_runtime_dir "$LOG_DIR" "日志目录"
    ensure_runtime_dir "$EXTRACT_BASE_DIR" "解压临时目录"
    [ -n "$MIGRATION_WORK_DIR" ] && {
        mkdir -p "$DATABASE_WORK_DIR/tmp"
        export TMPDIR="$DATABASE_WORK_DIR/tmp" TMP="$DATABASE_WORK_DIR/tmp" TEMP="$DATABASE_WORK_DIR/tmp"; }
    [ -n "$CFG_TEMPLATE" ] || CFG_TEMPLATE="$(cd "$(dirname "$0")/../../assets/kingbase" && pwd)/kingbase_silent.cfg"
    log_info "前置检查通过"
}

#==================== 解压 zip 并挂载 ISO ====================
extract_package() {
    EXTRACT_DIR="$EXTRACT_BASE_DIR/kingbase_${TIMESTAMP}_$$"
    log_info "解压安装包到目录: $EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    unzip -q -o "$PACKAGE" -d "$EXTRACT_DIR" >> "$LOG_DIR/extract_$TIMESTAMP.log" 2>&1 \
        || die "解压失败 (日志: $LOG_DIR/extract_$TIMESTAMP.log)"
    # 解压产物 chown 给数据库 OS 用户，确保后续 install.bin 可访问
    chown -R "$DB_OS_USER:$DB_OS_USER" "$EXTRACT_DIR"

    local iso_path
    iso_path=$(find "$EXTRACT_DIR" -name "KingbaseES_*.iso" -type f 2>/dev/null | head -n 1)
    [ -n "$iso_path" ] && [ -f "$iso_path" ] || die "解压后未找到 KingbaseES ISO 文件 (解压目录: $EXTRACT_DIR)"
    log_info "找到 ISO: $iso_path"

    ISO_MOUNT_DIR="$EXTRACT_DIR/iso_mount"
    mkdir -p "$ISO_MOUNT_DIR"
    umount "$ISO_MOUNT_DIR" 2>/dev/null || true
    mount -o loop,ro "$iso_path" "$ISO_MOUNT_DIR" >> "$LOG_DIR/mount_$TIMESTAMP.log" 2>&1 \
        || die "ISO 挂载失败 (日志: $LOG_DIR/mount_$TIMESTAMP.log)"

    SETUP_DIR="$ISO_MOUNT_DIR/setup"
    [ -f "$ISO_MOUNT_DIR/setup.sh" ] || die "ISO 中未找到 setup.sh: $ISO_MOUNT_DIR/setup.sh"

    # 内置 MD5 完整性校验
    log_info "执行 install.bin MD5 完整性校验"
    (cd "$SETUP_DIR" && md5sum -c MD5) >> "$LOG_DIR/md5_$TIMESTAMP.log" 2>&1 \
        || die "install.bin MD5 校验失败，安装包可能损坏 (日志: $LOG_DIR/md5_$TIMESTAMP.log)"
}

#==================== 渲染 silent.cfg ====================
render_response_file() {
    [ -f "$CFG_TEMPLATE" ] || die "silent.cfg 模板不存在: $CFG_TEMPLATE"
    RESPONSE_FILE="$LOG_DIR/silent.cfg"
    log_info "渲染响应文件: $CFG_TEMPLATE -> $RESPONSE_FILE"
    export KB_LICENSE_PATH="$LICENSE_FILE" CHOSEN_INSTALL_SET CHOSEN_FEATURE_LIST \
           INSTALL_PATH DATA_PATH PORT_NUM DB_USER DB_PASS \
           ENCODING_PARAM LOCALE_PARAM DATABASE_MODE_PARAM CASE_SENSITIVE_PARAM \
           BLOCK_SIZE_PARAM AUTHENTICATION_METHOD_PARAM
    envsubst < "$CFG_TEMPLATE" > "$RESPONSE_FILE"
    chmod 600 "$RESPONSE_FILE"
}

#==================== 静默安装 ====================
run_silent_install() {
    log_info "执行 KingbaseES 静默安装"

    # ISO 只读，复制 setup 目录到可写目录后执行
    local work_src="$EXTRACT_BASE_DIR/kingbase_install_src"
    mkdir -p "$work_src"
    cp -f "$SETUP_DIR/install.bin" "$work_src/" || die "复制 install.bin 失败"
    cp -f "$SETUP_DIR/MD5" "$work_src/" 2>/dev/null || true
    cp -f "$SETUP_DIR/WenQuanDengKuanZhengHei-1.ttf" "$work_src/" 2>/dev/null || true
    cp -f "$RESPONSE_FILE" "$work_src/silent.cfg" || die "无法放置 silent.cfg"
    chmod 600 "$work_src/silent.cfg"
    # 可写目录及其内容 chown 给数据库 OS 用户
    chown -R "$DB_OS_USER:$DB_OS_USER" "$work_src"

    # InstallAnywhere 静默模式：-i silent -f 显式指定响应文件
    # 金仓 install.bin 不允许 root 执行，通过 su 切换至 $DB_OS_USER
    if ! su - "$DB_OS_USER" -s /bin/bash -c "cd '$work_src' && ./install.bin -i silent -f '$work_src/silent.cfg'" \
            >> "$LOG_DIR/install_$TIMESTAMP.log" 2>&1; then
        log_error "静默安装失败，日志末尾:"
        tail -n 50 "$LOG_DIR/install_$TIMESTAMP.log" >&2 || true
        die "静默安装失败"
    fi

    # 安装产物属主统一为数据库 OS 用户
    chown -R "$DB_OS_USER:$DB_OS_USER" "$INSTALL_PATH" 2>/dev/null || true

    # 关键文件校验：实际安装目录为 <INSTALL_PATH>/KESRealPro/V*/Server/bin/sys_ctl
    local actual_home
    actual_home=$(dirname "$(find "$INSTALL_PATH/KESRealPro" -name sys_ctl -type f 2>/dev/null | head -n 1)")
    [ -z "$actual_home" ] && actual_home=$(dirname "$(find "$INSTALL_PATH" -name sys_ctl -type f 2>/dev/null | head -n 1)")
    [ -n "$actual_home" ] || die "安装后未找到 sys_ctl，安装可能未成功"
    ln -sfn "$(dirname "$actual_home")" "$INSTALL_PATH/current" 2>/dev/null || true
    SYS_CTL_BIN="$actual_home/sys_ctl"
    log_info "找到 sys_ctl: $SYS_CTL_BIN"
}

#==================== 直接启动 + SQL 验证 ====================
start_and_verify() {
    log_info "以 sys_ctl 直接启动数据库（服务注册由 Agent 按 guide 执行）"
    mkdir -p "$DATA_PATH/sys_log" 2>/dev/null || true
    chown -R "$DB_OS_USER:$DB_OS_USER" "$DATA_PATH" 2>/dev/null || true
    # 数据库进程必须以数据库 OS 用户运行
    su - "$DB_OS_USER" -s /bin/bash -c "'$SYS_CTL_BIN' start -D '$DATA_PATH' -l '$DATA_PATH/sys_log/startup.log'" \
        >> "$LOG_DIR/start_$TIMESTAMP.log" 2>&1 || true
    sleep 5
    pgrep -f "kingbase.*$DATA_PATH" >/dev/null 2>&1 || die "数据库启动失败"

    local ksql_bin
    ksql_bin="$(dirname "$SYS_CTL_BIN")/ksql"
    if [ -x "$ksql_bin" ]; then
        local result
        if result=$(echo "$DB_PASS" | su - "$DB_OS_USER" -s /bin/bash -c "'$ksql_bin' -p '$PORT_NUM' -U '$DB_USER' -d test -c 'SELECT version();'" 2>&1); then
            log_info "SQL 登录验证通过"
            echo "$result" | head -5 >> "$LOG_DIR/verify_$TIMESTAMP.log"
        else
            log_warn "SQL 登录验证失败: $result"
        fi
    else
        log_warn "未找到 ksql 客户端，跳过 SQL 验证"
    fi
    unset DB_PASS DB_PASSWORD
}

#==================== 清理 ====================
cleanup() {
    unset DB_PASS DB_PASSWORD 2>/dev/null || true
    [ -n "$ISO_MOUNT_DIR" ] && [ -d "$ISO_MOUNT_DIR" ] && \
        umount "$ISO_MOUNT_DIR" 2>/dev/null || true
}

#==================== 主流程 ====================
main() {
    parse_args "$@"
    load_env_conf
    preflight_check
    extract_package             # 解压 zip + 挂载 ISO + MD5 校验
    render_response_file        # 模板渲染 silent.cfg
    run_silent_install          # install.bin -i silent -f
    start_and_verify            # sys_ctl 直接启动 + SQL 验证

    log_info "===================================="
    log_info "KingbaseES 数据库安装部署完成（服务注册见 guide）"
    log_info "安装路径: $INSTALL_PATH"
    log_info "数据目录: $DATA_PATH"
    log_info "节点名:   $INSTANCE_NAME"
    log_info "端口:     $PORT_NUM"
    log_info "兼容模式: $DATABASE_MODE_PARAM"
    log_info "字符集:   $ENCODING_PARAM"
    log_info "管理员:   $DB_USER"
    log_info "===================================="
}

trap cleanup EXIT
main "$@"
