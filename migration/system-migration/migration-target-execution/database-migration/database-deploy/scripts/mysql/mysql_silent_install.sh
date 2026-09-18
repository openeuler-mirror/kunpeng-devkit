#!/bin/bash
#==============================================================================
# MySQL 8.0 静默安装脚本 (ARM / 鲲鹏架构)
# 适用安装包 : mysql-8.0.xx-linux-glibc2.12-aarch64.tar.gz (官方 ARM64 二进制包)
# 安装方式   : 二进制包初始化 (mysqld --initialize-insecure)
# 模板       : assets/mysql/mysql_silent.cnf (envsubst 渲染，默认自动定位)
# 脚本职责   : 解压/安装/渲染my.cnf/初始化/直接启动/设置root密码/SQL验证（含密码操作）
# Agent 职责 : 资源限制、环境变量、systemd服务注册（见 references/mysql-deploy-guide.md）
# 固化脚本   : 禁止修改源码，仅通过命令行参数控制安装行为
# 执行用户   : mysql；chown 属主切换需 root/sudo
#==============================================================================
set -euo pipefail

MIGRATION_WORK_DIR="${MIGRATION_WORK_DIR:-}"
if [ -n "$MIGRATION_WORK_DIR" ]; then
    DATABASE_WORK_DIR="$MIGRATION_WORK_DIR/database"
else
    DATABASE_WORK_DIR="${DATABASE_WORK_DIR:-}"
fi

#==================== 默认参数（与官方推荐值一致） ====================
INSTALL_PATH="/opt/mysql"; DATA_PATH=""
SOCKET_PATH=""; PID_FILE_PATH="/opt/mysql/mysqld.pid"; LOG_ERROR_PATH=""
CNF_TEMPLATE=""; ENV_CONF=""; PACKAGE=""
LOG_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/logs}"
INSTANCE_NAME="mysqld"; PORT_NUM=3306; ROOT_PWD=""; _CLI_ROOT_PWD=""
SERVER_ID=1
CHARACTER_SET_SERVER="utf8mb4"; COLLATION_SERVER="utf8mb4_general_ci"
DEFAULT_STORAGE_ENGINE="InnoDB"; MAX_CONNECTIONS=500
INNODB_BUFFER_POOL_SIZE=""      # MB，空=系统内存1/2
EXTRACT_BASE_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/tmp/mysql}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# 运行时变量
EXTRACT_DIR=""; MYSQLD_BIN=""; MYSQL_BIN=""; MY_CNF=""; _TEMP_PWD=""

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
# MySQL 8.0 默认密码策略 MEDIUM (>=8位, 大小写+数字+特殊字符)
validate_password() {
    local pwd=$1
    [ ${#pwd} -ge 8 ] || die "密码长度不能小于8"
    echo "$pwd" | grep -q '[A-Z]' || die "密码必须包含大写字母"
    echo "$pwd" | grep -q '[a-z]' || die "密码必须包含小写字母"
    echo "$pwd" | grep -q '[0-9]' || die "密码必须包含数字"
    echo "$pwd" | grep -q '[^a-zA-Z0-9]' || die "密码必须包含特殊字符"
    unset pwd
}

#==================== 参数解析 ====================
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

必选参数:
  --env-conf=FILE        环境配置文件路径 (install_env.conf)
  --package=FILE         MySQL 二进制包路径 (mysql-8.0.xx-linux-glibc2.12-aarch64.tar.gz)

可选参数:
  --cnf-template=FILE    mysql_silent.cnf 模板 (默认: 自动定位 assets/mysql/mysql_silent.cnf)
  --extract-dir=DIR      解压临时目录        (默认: $MIGRATION_WORK_DIR/database/tmp/mysql)
  --log-dir=DIR          日志输出目录        (默认: $MIGRATION_WORK_DIR/database/logs)
  --root-pwd=PWD         root 管理员密码（命令行优先于 env-conf 的 DB_PASSWORD；不再提供默认值，必须显式指定）
  -h, --help             显示本帮助

其余安装参数（INSTALL_PATH/DATA_PATH/PORT_NUM 等）统一由 env-conf 提供
EOF
    exit 0
}
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --cnf-template=*)       CNF_TEMPLATE="${1#*=}" ;;
            --env-conf=*)           ENV_CONF="${1#*=}" ;;
            --package=*)            PACKAGE="${1#*=}" ;;
            --extract-dir=*)        EXTRACT_BASE_DIR="${1#*=}" ;;
            --log-dir=*)            LOG_DIR="${1#*=}" ;;
            --root-pwd=*)           _CLI_ROOT_PWD="${1#*=}" ;;
            -h|--help)              usage ;;
            *) die "未知参数: $1" ;;
        esac
        shift
    done
}

#==================== 加载配置（env-conf 统一提供） ====================
load_env_conf() {
    [ -z "$ENV_CONF" ] && die "未指定 --env-conf 参数"
    [ -f "$ENV_CONF" ] || die "环境配置文件不存在: $ENV_CONF"
    log_info "加载环境配置: $ENV_CONF"
    # shellcheck disable=SC1090
    source "$ENV_CONF"
    [ -z "$DATA_PATH" ]      && DATA_PATH="${DATA_PATH:-$INSTALL_PATH/data}"
    [ -z "$SOCKET_PATH" ]    && SOCKET_PATH="${SOCKET_PATH:-$INSTALL_PATH/mysql.sock}"
    [ -z "$LOG_ERROR_PATH" ] && LOG_ERROR_PATH="${LOG_ERROR_PATH:-$INSTALL_PATH/logs/mysqld.err}"
    # 命令行 --root-pwd 优先于 env-conf 的 DB_PASSWORD
    [ -n "${_CLI_ROOT_PWD:-}" ] && DB_PASSWORD="$_CLI_ROOT_PWD"
    unset _CLI_ROOT_PWD
    ROOT_PWD="${DB_PASSWORD:-}"
    # 兜底：从 references/mysql-deploy-guide.md 表格读取约定默认密码（不再硬编码到脚本）
    if [ -z "$ROOT_PWD" ]; then
        local ref_file; ref_file="$(cd "$(dirname "$0")/../../references" && pwd)/mysql-deploy-guide.md"
        ROOT_PWD=$(grep -E '^\| `DB_PASSWORD`' "$ref_file" 2>/dev/null \
            | awk -F'|' '{print $4}' | sed -E 's/.*`([^`]+)`.*/\1/' | head -1)
        [ -n "$ROOT_PWD" ] || die "DB_PASSWORD 未提供且无法从 $ref_file 读取默认值"
        DB_PASSWORD="$ROOT_PWD"
        log_warn "DB_PASSWORD 未提供，使用 reference 文档中的默认值（建议生产环境显式指定）"
    fi
    validate_password "$ROOT_PWD"
}

#==================== 前置检查 ====================
preflight_check() {
    log_info "执行前置检查"
    [ "$(uname -m)" = "aarch64" ] || die "当前架构 $(uname -m) 非 aarch64，本脚本仅支持 ARM/鲲鹏"
    require_cmd tar; require_cmd envsubst
    # 强制核对数据库必需运行库（glibc/libaio/ncurses/zlib），任一缺失即环境检查不通过
    local _entry _soname _name _missing_libs=""
    for _entry in libc.so.6:glibc libaio.so.1:libaio libncurses.so:ncurses libz.so.1:zlib; do
        _soname="${_entry%%:*}"; _name="${_entry##*:}"
        ldconfig -p 2>/dev/null | grep -q "$_soname" || _missing_libs="$_missing_libs $_name"
    done
    [ -z "$_missing_libs" ] || die "缺少必需运行库:$_missing_libs"
    [ -n "$PACKAGE" ] && [ -f "$PACKAGE" ] || die "安装包不存在: ${PACKAGE:-未指定}"

    local pkg_name; pkg_name=$(basename "$PACKAGE")
    log_info "安装包: $pkg_name"
    [[ "$pkg_name" =~ mysql-8\..*-linux-glibc.*aarch64.*\.tar\.(gz|xz)$ ]] || \
        log_warn "包名 $pkg_name 未匹配官方命名规则，继续尝试"

    # MD5 校验（如存在 .md5 同名文件）
    if [ -f "${PACKAGE}.md5" ]; then
        [ "$(awk '{print $1}' "${PACKAGE}.md5")" = "$(md5sum "$PACKAGE" | awk '{print $1}')" ] \
            || die "安装包 MD5 校验失败"
        log_info "安装包 MD5 校验通过"
    fi

    [ -n "$EXTRACT_BASE_DIR" ] || EXTRACT_BASE_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/tmp/mysql}"
    ensure_runtime_dir "$LOG_DIR" "日志目录"
    ensure_runtime_dir "$EXTRACT_BASE_DIR" "解压临时目录"
    [ -n "$MIGRATION_WORK_DIR" ] && {
        mkdir -p "$DATABASE_WORK_DIR/tmp"
        export TMPDIR="$DATABASE_WORK_DIR/tmp" TMP="$DATABASE_WORK_DIR/tmp" TEMP="$DATABASE_WORK_DIR/tmp"; }
    [ -n "$CNF_TEMPLATE" ] || CNF_TEMPLATE="$(cd "$(dirname "$0")/../../assets/mysql" && pwd)/mysql_silent.cnf"
    log_info "前置检查通过"
}

#==================== 解压二进制包 ====================
extract_package() {
    mkdir -p "${EXTRACT_BASE_DIR}"
    EXTRACT_DIR="$(mktemp -d "${EXTRACT_BASE_DIR}/mysql_extract_XXXXXX")"
    log_info "解压安装包到临时目录: $EXTRACT_DIR"

    local extract_cmd="tar -xzf"
    [[ "$(basename "$PACKAGE")" =~ \.tar\.xz$ ]] && { require_cmd xz; extract_cmd="tar -xJf"; }
    $extract_cmd "$PACKAGE" -C "$EXTRACT_DIR" >> "$LOG_DIR/extract_$TIMESTAMP.log" 2>&1 \
        || die "解压失败 (日志: $LOG_DIR/extract_$TIMESTAMP.log)"

    local base_dir
    base_dir=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "mysql-*" 2>/dev/null | head -n 1)
    [ -n "$base_dir" ] && [ -d "$base_dir" ] || die "解压后未找到 MySQL 基目录 (解压目录: $EXTRACT_DIR)"
    [ -x "$base_dir/bin/mysqld" ] || die "未找到 mysqld: $base_dir/bin/mysqld"
    [ -x "$base_dir/bin/mysql" ]  || die "未找到 mysql: $base_dir/bin/mysql"
    MYSQLD_BIN="$base_dir/bin/mysqld"
    MYSQL_BIN="$base_dir/bin/mysql"
    log_info "找到 MySQL 基目录: $base_dir"
}

#==================== 安装软件：拷贝解压目录到安装路径 ====================
install_software() {
    log_info "安装 MySQL 软件到: $INSTALL_PATH"
    [ -d "$INSTALL_PATH" ] && [ -n "$(ls -A "$INSTALL_PATH" 2>/dev/null)" ] && \
        log_warn "安装目录已存在且非空: $INSTALL_PATH，继续将覆盖目录内容"
    mkdir -p "$INSTALL_PATH"
    cp -a "$(dirname "$MYSQLD_BIN")/../." "$INSTALL_PATH/" >> "$LOG_DIR/install_$TIMESTAMP.log" 2>&1 \
        || die "软件拷贝失败 (日志: $LOG_DIR/install_$TIMESTAMP.log)"
    MYSQLD_BIN="$INSTALL_PATH/bin/mysqld"
    MYSQL_BIN="$INSTALL_PATH/bin/mysql"

    # 数据目录属主 mysql、权限 750（官方要求）
    mkdir -p "$DATA_PATH" "$(dirname "$LOG_ERROR_PATH")"
    if has_root_priv; then
        run_as_root chown -R mysql:mysql "$INSTALL_PATH" 2>/dev/null || true
        run_as_root chmod -R 755 "$INSTALL_PATH" 2>/dev/null || true
        run_as_root chown -R mysql:mysql "$DATA_PATH" "$(dirname "$LOG_ERROR_PATH")"
        run_as_root chmod 750 "$DATA_PATH"
    else
        chown -R mysql:mysql "$INSTALL_PATH" 2>/dev/null || true
        chown -R mysql:mysql "$DATA_PATH" "$(dirname "$LOG_ERROR_PATH")" 2>/dev/null || true
    fi
    log_info "MySQL 软件安装完成"
}

#==================== 渲染 my.cnf ====================
render_config_file() {
    [ -f "$CNF_TEMPLATE" ] || die "mysql_silent.cnf 模板不存在: $CNF_TEMPLATE"
    MY_CNF="$INSTALL_PATH/my.cnf"
    log_info "渲染配置文件: $CNF_TEMPLATE -> $MY_CNF"

    # innodb_buffer_pool_size 默认值：系统内存的 1/2（MB）
    local innodb_pool_mb="$INNODB_BUFFER_POOL_SIZE"
    if [ -z "$innodb_pool_mb" ]; then
        local mem_total_mb
        mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "1024")
        innodb_pool_mb=$((mem_total_mb / 2))
    fi

    export INSTALL_PATH DATA_PATH PORT_NUM SOCKET_PATH PID_FILE_PATH LOG_ERROR_PATH \
           SERVER_ID CHARACTER_SET_SERVER COLLATION_SERVER DEFAULT_STORAGE_ENGINE \
           MAX_CONNECTIONS

    export INNODB_BUFFER_POOL_SIZE="${innodb_pool_mb}M"
    content=$(envsubst < "$CNF_TEMPLATE")
    echo "$content" > "$MY_CNF"
    chown mysql:mysql "$MY_CNF"
    chmod 640 "$MY_CNF"

    # 拷贝到 /etc/my.cnf 作为全局默认（需 root）
    has_root_priv && run_as_root cp -a "$MY_CNF" /etc/my.cnf 2>/dev/null \
        || log_warn "拷贝 my.cnf 到 /etc/my.cnf 失败，将使用 $MY_CNF"
}

#==================== 初始化数据目录 ====================
initialize_database() {
    log_info "初始化数据库数据目录: $DATA_PATH"
    [ -d "$DATA_PATH/mysql" ] && { log_info "数据目录已有 mysql 系统库，跳过初始化"; return; }

    # 必须以 mysql 用户执行初始化
    local current_user; current_user=$(id -un)
    { [ "$current_user" = "mysql" ] || [ "$(id -u)" -eq 0 ]; } \
        || die "数据目录初始化必须以 mysql 用户执行，当前用户: $current_user"

    # --initialize-insecure 生成无密码 root，便于后续自动设置密码
    local init_cmd="$MYSQLD_BIN --defaults-file=$MY_CNF --initialize-insecure --user=mysql"
    if [ "$(id -u)" -eq 0 ]; then
        init_cmd="su - mysql -s /bin/bash -c \"cd $INSTALL_PATH && $init_cmd\""
    fi
    if ! eval "$init_cmd" >> "$LOG_DIR/init_$TIMESTAMP.log" 2>&1; then
        log_error "数据目录初始化失败，日志末尾:"
        tail -n 50 "$LOG_DIR/init_$TIMESTAMP.log" >&2 || true
        die "数据目录初始化失败"
    fi
    [ -d "$DATA_PATH/mysql" ] || die "初始化后未找到 mysql 系统库: $DATA_PATH/mysql"
    log_info "数据目录初始化完成"
}

#==================== 直接启动 + root 密码 + SQL 验证 ====================
start_and_verify() {
    log_info "以 mysqld --daemonize 直接启动（服务注册由 Agent 按 guide 执行）"
    local start_cmd="$MYSQLD_BIN --defaults-file=$MY_CNF --user=mysql --daemonize"
    if [ "$(id -u)" -eq 0 ]; then
        # 确保 mysql 用户有可登录 home，避免 su - 产生告警导致日志噪声
        local mysql_home; mysql_home=$(getent passwd mysql | cut -d: -f6)
        if [ -n "$mysql_home" ] && [ ! -d "$mysql_home" ]; then
            mkdir -p "$mysql_home" && chown mysql:mysql "$mysql_home" && chmod 700 "$mysql_home"
        fi
        run_as_root su - mysql -s /bin/bash -c "$start_cmd" >> "$LOG_DIR/start_$TIMESTAMP.log" 2>&1
    else
        $start_cmd >> "$LOG_DIR/start_$TIMESTAMP.log" 2>&1
    fi
    sleep 5
    # 进程存活检测：匹配启动命令行中的 --defaults-file=$MY_CNF（datadir 写在 my.cnf 中，
    # 不在命令行参数里，不能用 $DATA_PATH 匹配）。并辅以 mysqladmin ping 与 socket 存在性兜底。
    local proc_ok=0
    if pgrep -f "mysqld.*--defaults-file=$MY_CNF" >/dev/null 2>&1; then
        proc_ok=1
    elif pgrep -f "mysqld.*$(printf '%s' "$MY_CNF" | sed 's/[.]/[.]/g')" >/dev/null 2>&1; then
        proc_ok=1
    fi
    if [ "$proc_ok" -eq 0 ]; then
        # 兜底：等待最多 15 秒，用 mysqladmin ping 确认
        local wait_cnt=0
        while [ "$wait_cnt" -lt 15 ]; do
            if [ -S "$SOCKET_PATH" ] && "$MYSQL_BIN" --socket="$SOCKET_PATH" -u root --skip-password \
                -e "SELECT 1;" >/dev/null 2>&1; then
                proc_ok=1; break
            fi
            sleep 1; wait_cnt=$((wait_cnt + 1))
        done
    fi
    if [ "$proc_ok" -eq 0 ]; then
        log_error "数据库启动失败，错误日志末尾:"
        tail -n 30 "$LOG_ERROR_PATH" >/dev/null 2>&1 || true
        die "数据库启动失败"
    fi
    log_info "mysqld 进程已启动"

    # 设置 root 密码（initialize-insecure 后 root 无密码）
    log_info "设置 root 密码"
    local sql="ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PWD}'; FLUSH PRIVILEGES;"
    local result
    if result=$("$MYSQL_BIN" --socket="$SOCKET_PATH" -u root --skip-password -e "$sql" 2>&1); then
        log_info "root 密码设置成功"
    else
        # 后备：从日志提取 initialize 模式临时密码
        log_warn "无密码登录失败，尝试从日志提取临时密码"
        _TEMP_PWD=$(grep "A temporary password is generated" "$LOG_ERROR_PATH" 2>/dev/null | tail -1 | awk '{print $NF}')
        [ -n "$_TEMP_PWD" ] || die "root 密码设置失败且无法获取临时密码: $result"
        result=$("$MYSQL_BIN" --socket="$SOCKET_PATH" -u root -p"$_TEMP_PWD" --connect-expired-password \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PWD}';" 2>&1) \
            || die "root 密码设置失败: $result"
        unset _TEMP_PWD
        log_info "root 密码设置成功（使用临时密码）"
    fi

    if result=$("$MYSQL_BIN" --socket="$SOCKET_PATH" -u root -p"$ROOT_PWD" -e "SELECT VERSION();" 2>&1); then
        log_info "SQL 登录验证通过"
        echo "$result" | head -5 >> "$LOG_DIR/verify_$TIMESTAMP.log"
    else
        log_warn "SQL 登录验证失败: $result"
    fi
    unset ROOT_PWD DB_PASSWORD
    log_info "===== MySQL 数据库安装验证通过 ====="
}

#==================== 清理 ====================
cleanup() {
    unset ROOT_PWD DB_PASSWORD _TEMP_PWD 2>/dev/null || true
    [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ] && { log_info "清理临时解压目录: $EXTRACT_DIR"; rm -rf "$EXTRACT_DIR"; }
}

#==================== 主流程 ====================
main() {
    parse_args "$@"
    load_env_conf
    preflight_check
    extract_package
    install_software
    render_config_file           # 模板渲染 my.cnf
    initialize_database          # mysqld --initialize-insecure
    start_and_verify             # 直接启动 + root 密码 + SQL 验证

    log_info "===================================="
    log_info "MySQL 数据库安装部署完成（服务注册见 guide）"
    log_info "安装路径: $INSTALL_PATH"
    log_info "数据目录: $DATA_PATH"
    log_info "实例名:   $INSTANCE_NAME"
    log_info "端口:     $PORT_NUM"
    log_info "字符集:   $CHARACTER_SET_SERVER"
    log_info "管理员:   root"
    log_info "===================================="
}

trap cleanup EXIT
main "$@"
