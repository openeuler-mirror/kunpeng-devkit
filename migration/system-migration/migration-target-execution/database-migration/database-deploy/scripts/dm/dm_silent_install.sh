#!/bin/bash
#==============================================================================
# 达梦 DM8 静默部署脚本 (鲲鹏 aarch64)
# 适用包: dm8_*_HWarm_kylin10_64_ent_*.zip  架构: aarch64
# 策略:   DMInstall.bin 仅安装软件，实例统一 dminit 初始化
# 模板:   支持外部 xml 模板 envsubst 渲染
# 详见:   references/dm-deploy-guide.md
#==============================================================================
set -euo pipefail

MIGRATION_WORK_DIR="${MIGRATION_WORK_DIR:-}"
if [ -n "$MIGRATION_WORK_DIR" ]; then
    DATABASE_WORK_DIR="$MIGRATION_WORK_DIR/database"
else
    DATABASE_WORK_DIR="${DATABASE_WORK_DIR:-}"
fi
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

#==================== 默认参数 ====================
INSTALL_PATH="/opt/dmdbms"; DATA_PATH=""
XML_TEMPLATE=""; ENV_CONF=""; PACKAGE=""
LOG_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/logs}"
INSTANCE_NAME="DAMENG"; PORT_NUM=5236; SYSDBA_PWD=""
PAGE_SIZE=16; EXTENT_SIZE=32; CASE_SENSITIVE="Y"; CHARSET=1; LENGTH_IN_CHAR=1
TIME_ZONE="+08:00"; CMD_TIMEOUT=600
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# 运行时变量
EXTRACT_DIR=""; EXTRACT_BASE_DIR=""; ISO_MNT=""; DM_INSTALL_BIN=""; SERVICE_NAME=""; RESPONSE_XML=""; _CLI_SYSDBA_PWD=""

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
        mkdir -p "$MIGRATION_WORK_DIR" "$DATABASE_WORK_DIR"
        root=$(cd "$DATABASE_WORK_DIR" && pwd -P)
        actual=$(cd "$path" && pwd -P)
        case "$actual/" in "$root/"*) ;; *) die "$label 必须位于 $root 下: $actual" ;; esac
    fi
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺失依赖命令: $1"; }
has_root() { [ "$(id -u)" -eq 0 ] && return 0; sudo -n true 2>/dev/null && return 0; return 1; }
run_as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }
run_timeout() { local t="$1"; shift; timeout "${t}" "$@" || die "命令执行超时[${t}s]: $*"; }
run_timeout_root() {
    local t="$1"; shift
    if [ "$(id -u)" -eq 0 ]; then timeout "${t}" "$@" || die "命令执行超时[${t}s]: $*"
    else timeout "${t}" sudo -n "$@" || die "命令执行超时[${t}s]: $* (sudo)"; fi
}

#==================== 参数解析 ====================
usage() { cat <<EOF
用法: $(basename "$0") [OPTIONS]
必选: --env-conf=FILE  --package=FILE  --xml-template=FILE
可选: --extract-dir=DIR --log-dir=DIR --sysdba-pwd=PWD
  --sysdba-pwd=PWD  SYSDBA 管理员密码（命令行优先于 env-conf 的 SYSDBA_PWD；不再提供默认值，必须显式指定）
其余安装参数（INSTALL_PATH/DATA_PATH/INSTANCE_NAME/PORT_NUM 等）统一由 env-conf 提供
EOF
exit 0; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --extract-dir=*)    EXTRACT_BASE_DIR="${1#*=}" ;;
            --xml-template=*)   XML_TEMPLATE="${1#*=}" ;;
            --env-conf=*)       ENV_CONF="${1#*=}" ;;
            --package=*)        PACKAGE="${1#*=}" ;;
            --log-dir=*)        LOG_DIR="${1#*=}" ;;
            --sysdba-pwd=*)     _CLI_SYSDBA_PWD="${1#*=}" ;;
            -h|--help)          usage ;;
            *) die "未知参数: $1" ;;
        esac; shift
    done
}

#==================== 加载配置 ====================
load_env_conf() {
    [ -z "$ENV_CONF" ] && die "必须指定 --env-conf"
    [ -f "$ENV_CONF" ] || die "配置文件不存在: $ENV_CONF"
    log_info "加载配置文件: $ENV_CONF"
    source "$ENV_CONF"
    # 命令行 --sysdba-pwd 优先于 env-conf
    [ -n "${_CLI_SYSDBA_PWD:-}" ] && SYSDBA_PWD="$_CLI_SYSDBA_PWD"
    unset _CLI_SYSDBA_PWD
    # 兜底：从 references/dm-deploy-guide.md 表格读取约定默认密码（不再硬编码到脚本）
    if [ -z "${SYSDBA_PWD:-}" ]; then
        local ref_file; ref_file="$(cd "$(dirname "$0")/../../references" && pwd)/dm-deploy-guide.md"
        SYSDBA_PWD=$(grep -E '^\| `SYSDBA_PWD`' "$ref_file" 2>/dev/null \
            | awk -F'|' '{print $4}' | sed -E 's/.*`([^`]+)`.*/\1/' | head -1)
        [ -n "$SYSDBA_PWD" ] || die "SYSDBA_PWD 未提供且无法从 $ref_file 读取默认值"
        log_warn "SYSDBA_PWD 未提供，使用 reference 文档中的默认值（建议生产环境显式指定）"
    fi
    DATA_PATH=${DATA_PATH:-${INSTALL_PATH}/data}
}

#==================== 前置检查 ====================
preflight_check() {
    log_info "执行前置环境校验"
    [ "$(uname -m)" = "aarch64" ] || die "仅支持aarch64鲲鹏架构"
    require_cmd unzip; require_cmd timeout; require_cmd envsubst
    # 强制核对数据库必需运行库（glibc/libaio/zlib），任一缺失即环境检查不通过
    local _entry _soname _name _missing_libs=""
    for _entry in libc.so.6:glibc libaio.so.1:libaio libz.so.1:zlib; do
        _soname="${_entry%%:*}"; _name="${_entry##*:}"
        ldconfig -p 2>/dev/null | grep -q "$_soname" || _missing_libs="$_missing_libs $_name"
    done
    [ -z "$_missing_libs" ] || die "缺少必需运行库:$_missing_libs"
    [ -n "$PACKAGE" ] && [ -f "$PACKAGE" ] || die "安装包不存在: ${PACKAGE:-未指定}"

    # 创建 dmdba:dinstall
    getent group dinstall >/dev/null || { run_as_root groupadd dinstall; log_info "创建用户组 dinstall"; }
    getent passwd dmdba >/dev/null    || { run_as_root useradd -m -g dinstall dmdba; log_info "创建用户 dmdba"; }

    [ -n "$EXTRACT_BASE_DIR" ] || EXTRACT_BASE_DIR="${DATABASE_WORK_DIR:+$DATABASE_WORK_DIR/tmp/dm}"
    ensure_runtime_dir "$LOG_DIR" "日志目录"
    ensure_runtime_dir "$EXTRACT_BASE_DIR" "解压临时目录"
    if [ -n "$MIGRATION_WORK_DIR" ]; then
        mkdir -p "$DATABASE_WORK_DIR/tmp"
        export TMPDIR="$DATABASE_WORK_DIR/tmp" TMP="$DATABASE_WORK_DIR/tmp" TEMP="$DATABASE_WORK_DIR/tmp"
    fi
    # DMInstall.bin 要求安装目录为空
    [ -d "${INSTALL_PATH}" ] && [ -n "$(ls -A "${INSTALL_PATH}" 2>/dev/null)" ] && {
        log_warn "安装目录非空，清理: ${INSTALL_PATH}"; run_as_root rm -rf "${INSTALL_PATH}"; }
    mkdir -p "${INSTALL_PATH}"
    run_as_root chown -R dmdba:dinstall "${INSTALL_PATH}" "${LOG_DIR}"
    log_info "前置校验完成"
}

#==================== XML 模板渲染 ====================
render_xml_template() {
    [ -n "${XML_TEMPLATE}" ] || die "必须指定 --xml-template"
    [ -f "${XML_TEMPLATE}" ] || die "XML模板不存在: ${XML_TEMPLATE}"
    RESPONSE_XML="${LOG_DIR}/dm_silent_install.xml"
    log_info "渲染响应文件: ${XML_TEMPLATE} -> ${RESPONSE_XML}"
    export INSTALL_PATH TIME_ZONE
    envsubst < "${XML_TEMPLATE}" > "${RESPONSE_XML}"
    chmod 600 "${RESPONSE_XML}"
    run_as_root chown dmdba:dinstall "${RESPONSE_XML}"
}

#==================== 解压安装包，定位 DMInstall.bin ====================
extract_package() {
    mkdir -p "${EXTRACT_BASE_DIR}"
    EXTRACT_DIR=$(run_timeout 120 mktemp -d "${EXTRACT_BASE_DIR}/dm_extract_XXXXXX")
    log_info "解压到: ${EXTRACT_DIR}"
    run_timeout 120 unzip -q -o "${PACKAGE}" -d "${EXTRACT_DIR}" >> "${LOG_DIR}/extract_${TIMESTAMP}.log" 2>&1

    # 优先直接查找 DMInstall.bin（HWarm zip 包），找不到再尝试 ISO 挂载
    DM_INSTALL_BIN=$(find "${EXTRACT_DIR}" -maxdepth 3 -name "DMInstall.bin" -type f | head -n1)
    ISO_MNT=""
    if [ -z "${DM_INSTALL_BIN}" ]; then
        local iso_file; iso_file=$(find "${EXTRACT_DIR}" -maxdepth 3 -name "*.iso" -type f | head -n1)
        if [ -n "${iso_file}" ] && has_root; then
            ISO_MNT=$(run_timeout 60 mktemp -d "${EXTRACT_BASE_DIR}/dm_iso_mnt_XXXXXX")
            run_timeout_root 120 mount -o loop,ro "${iso_file}" "${ISO_MNT}" >> "${LOG_DIR}/extract_${TIMESTAMP}.log" 2>&1
            DM_INSTALL_BIN=$(find "${ISO_MNT}" -name "DMInstall.bin" -type f | head -n1)
        fi
    fi
    [ -n "${DM_INSTALL_BIN}" ] && [ -f "${DM_INSTALL_BIN}" ] || die "未找到 DMInstall.bin"

    # 只读介质（ISO）内文件已有可执行权限，仅可写目录才 chmod
    [ -w "$(dirname "${DM_INSTALL_BIN}")" ] && {
        run_as_root chmod +x "${DM_INSTALL_BIN}" 2>/dev/null || true
        run_as_root chown dmdba:dinstall "${DM_INSTALL_BIN}" 2>/dev/null || true; }
    [ -x "${DM_INSTALL_BIN}" ] || die "DMInstall.bin 不可执行: ${DM_INSTALL_BIN}"
    log_info "定位安装程序: ${DM_INSTALL_BIN}"
}

#==================== 静默安装软件 ====================
run_software_install() {
    log_info "开始静默安装达梦软件（仅安装程序，不初始化实例）"
    local tmpdir="${DM_INSTALL_TMPDIR:-${DATABASE_WORK_DIR}/tmp/dm-install}"
    mkdir -p "${tmpdir}"; run_as_root chown -R dmdba:dinstall "${tmpdir}"
    run_timeout "${CMD_TIMEOUT}" su - dmdba <<SHELL
export DM_INSTALL_TMPDIR='${tmpdir}'
cd $(dirname "${DM_INSTALL_BIN}")
./DMInstall.bin -q "${RESPONSE_XML}" >> "${LOG_DIR}/install_${TIMESTAMP}.log" 2>&1
SHELL
    [ -f "${INSTALL_PATH}/bin/dmserver" ] || die "软件安装失败，未找到 dmserver"
    log_info "达梦软件安装完成"

    mkdir -p "${DATA_PATH}"
    run_as_root chown -R dmdba:dinstall "${INSTALL_PATH}" "${DATA_PATH}"

    # 执行官方 root 初始化脚本
    local root_sh="${INSTALL_PATH}/script/root/root_installer.sh"
    [ -f "${root_sh}" ] && has_root && {
        log_info "执行 root 初始化脚本: ${root_sh}"
        run_timeout_root 120 bash "${root_sh}" >> "${LOG_DIR}/root_install_${TIMESTAMP}.log" 2>&1; }
}

#==================== dminit 初始化实例 ====================
init_dm_instance() {
    local dm_ini="${DATA_PATH}/${INSTANCE_NAME}/dm.ini"
    [ -f "${dm_ini}" ] && { log_info "实例 ${INSTANCE_NAME} 已存在，跳过"; return; }
    log_info "初始化数据库实例 ${INSTANCE_NAME}"
    local dminit="${INSTALL_PATH}/bin/dminit"
    run_timeout "${CMD_TIMEOUT}" su - dmdba <<SHELL
"${dminit}" \
PATH="${DATA_PATH}" DB_NAME="${INSTANCE_NAME}" INSTANCE_NAME="${INSTANCE_NAME}" \
PORT_NUM="${PORT_NUM}" SYSDBA_PWD="${SYSDBA_PWD}" PAGE_SIZE="${PAGE_SIZE}" \
EXTENT_SIZE="${EXTENT_SIZE}" CASE_SENSITIVE="${CASE_SENSITIVE}" \
CHARSET="${CHARSET}" LENGTH_IN_CHAR="${LENGTH_IN_CHAR}" \
TIME_ZONE="${TIME_ZONE}" >> "${LOG_DIR}/dminit_${TIMESTAMP}.log" 2>&1
SHELL
    [ -f "${dm_ini}" ] || die "实例初始化失败，缺失 dm.ini"
    log_info "实例初始化成功: ${dm_ini}"
}

#==================== 注册 systemd 服务 ====================
register_systemd_service() {
    local dm_ini="${DATA_PATH}/${INSTANCE_NAME}/dm.ini"
    local svc_installer="${INSTALL_PATH}/script/root/dm_service_installer.sh"
    [ -f "${svc_installer}" ] || die "服务脚本不存在: ${svc_installer}"
    SERVICE_NAME="DmService${INSTANCE_NAME}"
    log_info "注册 systemd 服务: ${SERVICE_NAME}"
    if ! has_root; then
        log_warn "无 root 权限，跳过服务注册。手动执行: bash ${svc_installer} -t dmserver -p ${INSTANCE_NAME} -dm_ini ${dm_ini}"
        return
    fi
    run_timeout_root 120 bash "${svc_installer}" -t dmserver -p "${INSTANCE_NAME}" -dm_ini "${dm_ini}" >> "${LOG_DIR}/service_reg_${TIMESTAMP}.log" 2>&1
    run_as_root systemctl daemon-reload
    log_info "服务注册完成: ${SERVICE_NAME}"
}

#==================== 启动 + 验证 ====================
start_and_verify() {
    [ -n "${SERVICE_NAME}" ] && has_root && {
        log_info "启动服务: ${SERVICE_NAME}"
        run_as_root systemctl start "${SERVICE_NAME}"
        run_as_root systemctl enable "${SERVICE_NAME}"; }
    sleep 4
    pgrep -f "dmserver.*${INSTANCE_NAME}" >/dev/null || die "数据库进程启动失败"
    local disql="${INSTALL_PATH}/bin/disql"
    log_info "执行连通性验证"
    run_timeout 60 su - dmdba <<SHELL
"${disql}" "SYSDBA/${SYSDBA_PWD}@127.0.0.1:${PORT_NUM}" -e "SELECT 1;" >> "${LOG_DIR}/verify_${TIMESTAMP}.log" 2>&1
SHELL
    log_info "===== 达梦数据库部署全部完成 ====="
    log_info "软件路径: ${INSTALL_PATH}"
    log_info "数据路径: ${DATA_PATH}/${INSTANCE_NAME}"
    log_info "实例名称: ${INSTANCE_NAME}"
    log_info "监听端口: ${PORT_NUM}"
    log_info "服务名称: ${SERVICE_NAME:-未注册}"
    unset SYSDBA_PWD
}

#==================== 临时资源清理 ====================
cleanup() {
    unset SYSDBA_PWD 2>/dev/null || true
    [ -n "${ISO_MNT}" ] && [ -d "${ISO_MNT}" ] && { run_as_root umount "${ISO_MNT}" 2>/dev/null || true; rmdir "${ISO_MNT}" 2>/dev/null || true; }
    [ -n "${EXTRACT_DIR}" ] && [ -d "${EXTRACT_DIR}" ] && rm -rf "${EXTRACT_DIR}"
}

#==================== 主流程 ====================
main() {
    parse_args "$@"
    load_env_conf
    preflight_check
    render_xml_template
    extract_package
    run_software_install
    init_dm_instance
    register_systemd_service
    start_and_verify
}

trap cleanup EXIT
main "$@"
