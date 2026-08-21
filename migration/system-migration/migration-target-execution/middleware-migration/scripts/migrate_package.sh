#!/bin/bash
# migrate_package.sh — 通用包迁移（Nginx/Redis/ES/RabbitMQ/Docker 等）：
# 按 install_method（yum/apt/源码编译/auto）安装 → 恢复配置 → 注册 systemd 服务 → 验证。
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

require_env MIDDLEWARE_TYPE INSTALL_METHOD || exit 1
# yum/SYSTEM_REPOSITORY 版本来自仓库，不要求 TARGET_VERSION；其余方式必填
if [ "$INSTALL_METHOD" != "yum" ] && [ "${SOURCE_TYPE:-}" != "SYSTEM_REPOSITORY" ]; then
    require_env CURRENT_VERSION TARGET_VERSION || exit 1
else
    require_env CURRENT_VERSION || exit 1
fi
# binary 无 source_type 时必须有 DEPLOY_DIR
if [ "$INSTALL_METHOD" = "binary" ] && [ -z "${SOURCE_TYPE:-}" ]; then
    require_env DEPLOY_DIR || exit 1
fi

SERVICE_NAME=$(resolve_service_name "$MIDDLEWARE_TYPE")
ARM_SERVICE=$(resolve_arm_service "$MIDDLEWARE_TYPE")
INSTALL_DIR=$(resolve_install_dir "$MIDDLEWARE_TYPE")
CONFIG_DIR=$(resolve_config_dir "$MIDDLEWARE_TYPE")
PACKAGE_NAME=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".package_name" "$MIDDLEWARE_TYPE")
BIN_PATH=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".bin_path" "")
NEW_HOME="${DEPLOY_DIR:-$INSTALL_DIR}"

log_info "$MIDDLEWARE_TYPE 迁移开始: $CURRENT_VERSION -> $TARGET_VERSION [install_method=$INSTALL_METHOD]"

stop_current_service "$MIDDLEWARE_TYPE" "$ARM_SERVICE"

# ===== 安装方式核心：给定安装包路径解压安装 =====
install_from_package() {
    local package_path="$1"
    log_info "部署安装包到 $NEW_HOME"
    mkdir -p "$NEW_HOME"
    if ! install_binary_package "$package_path" "$NEW_HOME"; then
        log_error "安装包部署失败: $package_path"
        return 1
    fi

    if [ -n "$BIN_PATH" ]; then
        ln -sf "$NEW_HOME/$BIN_PATH" "/usr/sbin/${MIDDLEWARE_TYPE}" 2>/dev/null || true
    fi

    _restore_config "$NEW_HOME"
}

# OFFICIAL：通过 url 下载安装
install_official() {
    local url fname package_path
    url=$(resolve_download_url)
    if [ -z "$url" ]; then
        log_warn "[OFFICIAL] plan 未提供 download_url，无法下载安装"
        return 1
    fi
    fname=$(resolve_package_file_name)
    if ! package_path=$(download_package "$url" "$fname"); then
        log_error "[OFFICIAL] 下载失败: $url"
        return 1
    fi
    install_from_package "$package_path"
}

# MANUAL：手动上传的本地安装包
install_manual() {
    if [ -z "${LOCAL_PACKAGE_PATH:-}" ] || [ ! -f "$LOCAL_PACKAGE_PATH" ]; then
        log_warn "[MANUAL] plan 未提供本地安装包（local_path）"
        return 1
    fi
    log_info "[MANUAL] 使用本地安装包: $LOCAL_PACKAGE_PATH"
    install_from_package "$LOCAL_PACKAGE_PATH"
}

# SYSTEM_REPOSITORY：yum / apt 系统包安装（自动判断包管理器）
install_system_repository() {
    if command -v yum >/dev/null 2>&1; then
        install_yum || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        install_apt || return 1
    else
        log_error "[SYSTEM_REPOSITORY] 未检测到 yum 或 apt 包管理器"
        return 1
    fi
}

# 按 source_type 决定来源优先级（0=成功 30=全失败 100=未知/空，交由 install_method）
install_with_source_type() {
    local st="${SOURCE_TYPE:-}" method
    case "$st" in
        SYSTEM_REPOSITORY) local order="system_repository official" ;;
        OFFICIAL|MANUAL)   local order="manual official" ;;
        *)                 return 100 ;;
    esac

    for method in $order; do
        log_info "[source_type=$st] 尝试安装方式: $method"
        if install_one_way "$method"; then
            log_info "[source_type=$st] 方式 $method 安装成功"
            return 0
        fi
        log_warn "[source_type=$st] 方式 $method 失败，尝试下一种"
    done

    log_error "[source_type=$st] 安装方式全部失败"
    return 30
}

install_one_way() {
    case "$1" in
        official)          install_official ;;
        manual)            install_manual ;;
        system_repository) install_system_repository ;;
        *)                 return 1 ;;
    esac
}

install_binary() {
    local url package_path
    if [ -n "${LOCAL_PACKAGE_PATH:-}" ] && [ -f "$LOCAL_PACKAGE_PATH" ]; then
        log_info "使用本地安装包: $LOCAL_PACKAGE_PATH"
        package_path="$LOCAL_PACKAGE_PATH"
    else
        url=$(resolve_download_url)
        if [ -z "$url" ]; then
            log_error "plan 未提供安装包源（download_url/local_path 均缺失），请在 migration-plan.json 的 route.middleware[].packages[0] 中补充"
            exit 1
        fi
        if ! package_path=$(download_package "$url" "$(basename "$url")"); then
            log_error "下载失败: $url"
            return 1
        fi
    fi

    install_from_package "$package_path"
}

install_yum() {
    local yum_spec="$PACKAGE_NAME"
    log_info "[yum] 安装 $yum_spec (plan 版本: ${TARGET_VERSION:-未指定}，不校验版本)"
    local yum_out
    if yum_out=$(yum install -y "$yum_spec" 2>&1); then
        local installed_ver
        installed_ver=$(rpm -q "$PACKAGE_NAME" 2>/dev/null || echo "未知")
        log_info "[yum] 安装成功，已安装: $installed_ver"
        SYSTEM_PKG_INSTALLED=1
    else
        log_error "[yum] 安装失败: $yum_spec"
        local repo_versions
        repo_versions=$(yum list available "$PACKAGE_NAME" 2>/dev/null | grep "^$PACKAGE_NAME" | awk '{print $2}' | head -3 | tr '\n' ' ')
        log_error "[yum] 仓库可用版本: ${repo_versions:-无}"
        log_error "[yum] yum 输出: $(echo "$yum_out" | tail -5 | tr '\n' ' ')"
        return 1
    fi
    _restore_config "${CONFIG_DIR}"
}

install_apt() {
    local apt_spec="$PACKAGE_NAME"
    log_info "[apt] 安装 $apt_spec (plan 版本: ${TARGET_VERSION:-未指定}，不校验版本)"
    local apt_out
    if apt_out=$(apt-get install -y "$apt_spec" 2>&1); then
        local installed_ver
        installed_ver=$(dpkg -l "$PACKAGE_NAME" 2>/dev/null | awk '/^ii/{print $3}' || echo "未知")
        log_info "[apt] 安装成功，已安装: $installed_ver"
        SYSTEM_PKG_INSTALLED=1
    else
        log_error "[apt] 安装失败: $apt_spec"
        log_error "[apt] apt 输出: $(echo "$apt_out" | tail -5 | tr '\n' ' ')"
        return 1
    fi
    _restore_config "${CONFIG_DIR}"
}

install_auto() {
    # 方式1: yum（registry 配了 package_name 才尝试）
    if [ -n "$PACKAGE_NAME" ]; then
        local yum_spec="$PACKAGE_NAME"
        log_info "[auto] 尝试 yum install $yum_spec (plan 版本: ${TARGET_VERSION:-未指定}，不校验版本)"
        local yum_out
        if yum_out=$(yum install -y "$yum_spec" 2>&1); then
            local installed_ver
            installed_ver=$(rpm -q "$PACKAGE_NAME" 2>/dev/null || echo "未知")
            log_info "[auto] yum 安装成功，已安装: $installed_ver"
            _restore_config "${CONFIG_DIR}"
            return 0
        fi
        local repo_versions
        repo_versions=$(yum list available "$PACKAGE_NAME" 2>/dev/null | grep "^$PACKAGE_NAME" | awk '{print $2}' | head -3 | tr '\n' ' ')
        log_warn "[auto] yum 未命中 $yum_spec，尝试包安装"
        log_warn "[auto] 仓库可用版本: ${repo_versions:-无}"
    fi

    # 方式2/3: 包文件解压检测（binary/source）
    if [ -z "${DEPLOY_DIR:-}" ]; then
        log_error "[auto] yum 未命中且 DEPLOY_DIR 为空，无法进行包安装"
        return 1
    fi
    local package_path=""
    if [ -n "${LOCAL_PACKAGE_PATH:-}" ] && [ -f "$LOCAL_PACKAGE_PATH" ]; then
        log_info "使用本地安装包: $LOCAL_PACKAGE_PATH"
        package_path="$LOCAL_PACKAGE_PATH"
    elif [ -n "${DOWNLOAD_URL:-}" ]; then
        local fname
        fname=$(resolve_package_file_name)
        if ! package_path=$(download_package "$DOWNLOAD_URL" "$fname"); then
            log_error "下载失败: $DOWNLOAD_URL"
            return 1
        fi
    else
        log_error "[auto] 无包源（local_path/download_url 均缺失）且 yum 未找到 $PACKAGE_NAME"
        return 1
    fi

    local tmp_dir tmp_root
    tmp_root="${MIDDLEWARE_WORK_DIR:-$TMP_DIR/$MIDDLEWARE_TYPE}"
    mkdir -p "$tmp_root/tmp"
    tmp_dir=$(mktemp -d "$tmp_root/tmp/package.XXXXXX")
    if ! install_binary_package "$package_path" "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    local pkg_type
    pkg_type=$(detect_package_type "$tmp_dir" "$MIDDLEWARE_TYPE")
    log_info "[auto] 检测到包类型: $pkg_type"

    case "$pkg_type" in
        binary)
            # 方式2：二进制包，直接配置路径
            rm -rf "$NEW_HOME"
            mv "$tmp_dir" "$NEW_HOME"
            if [ -n "$BIN_PATH" ]; then
                ln -sf "$NEW_HOME/$BIN_PATH" "/usr/sbin/${MIDDLEWARE_TYPE}" 2>/dev/null || true
            fi
            _restore_config "$NEW_HOME"
            ;;
        source)
            # 方式3: 源码编译
            rm -rf "$NEW_HOME"
            mkdir -p "$NEW_HOME"
            if ! install_from_source "$tmp_dir" "$NEW_HOME" "$MIDDLEWARE_TYPE"; then
                rm -rf "$tmp_dir"
                return 1
            fi
            rm -rf "$tmp_dir"
            if [ -n "$BIN_PATH" ] && [ -x "$NEW_HOME/$BIN_PATH" ]; then
                ln -sf "$NEW_HOME/$BIN_PATH" "/usr/sbin/${MIDDLEWARE_TYPE}" 2>/dev/null || true
            fi
            _restore_config "$NEW_HOME"
            ;;
        *)
            log_error "[auto] 无法识别包类型（既非二进制也非源码）"
            rm -rf "$tmp_dir"
            return 1
            ;;
    esac
    return 0
}

_restore_config() {
    local dest="$1"
    if [ -z "$CONFIG_DIR" ]; then
        return 0
    fi

    # CONFIG_DIR 为绝对路径（registry 中如 /etc/nginx、/opt/tomcat/conf）时直接使用；
    # 相对路径时拼接 SOURCE_DIR 作为基目录
    local src
    case "$CONFIG_DIR" in
        /*) src="$CONFIG_DIR" ;;
        *)  [ -n "$SOURCE_DIR" ] || return 0
            src="${SOURCE_DIR%/}/$CONFIG_DIR" ;;
    esac
    if [ ! -d "$src" ]; then
        return 0
    fi
    # 防止 src 与 dest 相同导致目录自我复制（如 yum 安装时 dest=CONFIG_DIR）
    if [ "$src" = "$dest" ]; then
        log_info "配置源与目标目录相同，跳过: $src"
        return 0
    fi

    log_info "从 $src 恢复配置"
    if [ -d "$dest/conf" ]; then
        cp -r "$src"/* "$dest/conf/" 2>/dev/null || log_warn "配置恢复到 conf 失败"
    elif [ -d "$dest/config" ]; then
        cp -r "$src"/* "$dest/config/" 2>/dev/null || log_warn "配置恢复到 config 失败"
    else
        mkdir -p "$dest"
        cp -r "$src"/* "$dest/" 2>/dev/null || log_warn "配置恢复失败"
    fi
}

# source_type 优先；无/未知时回退到 install_method 分发（set -e 下须用 if 上下文）
if install_with_source_type; then
    :
else
    src_rc=$?
    if [ "$src_rc" -eq 30 ]; then
        # 安装来源全部失败：由 run_migration.sh 记为 FAILED
        exit 30
    fi
    case "$INSTALL_METHOD" in
        binary)
            install_binary
            ;;
        yum)
            install_yum
            ;;
        auto)
            install_auto
            ;;
        *)
            log_error "未知安装方式: $INSTALL_METHOD"
            exit 1
            ;;
    esac
fi

# 生成/更新 systemd 服务
if [ -n "$SYSTEM_PKG_INSTALLED" ]; then
    # 系统包安装：复制系统自带服务单元
    if [ -f "/usr/lib/systemd/system/${SERVICE_NAME}.service" ]; then
        cp "/usr/lib/systemd/system/${SERVICE_NAME}.service" "/etc/systemd/system/${ARM_SERVICE}.service"
        systemctl daemon-reload
        systemctl enable "$ARM_SERVICE" 2>/dev/null || true
    fi
elif [ -n "$BIN_PATH" ] && [ -x "$NEW_HOME/$BIN_PATH" ]; then
    # service_prefix: 二进制用相对路径 conf/ 时需 -p；daemon_off: nginx 需注入 daemon off; 防 systemd 退出
    SERVICE_PREFIX=""
    DAEMON_OFF_FLAG=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".daemon_off" "false")
    if [ "$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".service_prefix" "false")" = "true" ]; then
        SERVICE_PREFIX="-p $NEW_HOME/"
    fi
    # 注入到 conf 首行（仅当尚未存在）
    if [ "$DAEMON_OFF_FLAG" = "true" ]; then
        conf_file="$NEW_HOME/conf/nginx.conf"
        [ -f "$conf_file" ] && ! grep -q "^daemon off;" "$conf_file" 2>/dev/null && sed -i '1i daemon off;' "$conf_file" 2>/dev/null || true
    fi
    install_systemd_service \
        "$MIDDLEWARE_TYPE" \
        "$ARM_SERVICE" \
        "$NEW_HOME/$BIN_PATH $SERVICE_PREFIX" \
        "" \
        "" \
        "simple"
elif [ "$INSTALL_METHOD" = "yum" ] || [ "$INSTALL_METHOD" = "auto" ]; then
    # yum 安装已自带服务，复制到目标服务单元（如需要）
    if [ -f "/usr/lib/systemd/system/${SERVICE_NAME}.service" ]; then
        cp "/usr/lib/systemd/system/${SERVICE_NAME}.service" "/etc/systemd/system/${ARM_SERVICE}.service"
        systemctl daemon-reload
        systemctl enable "$ARM_SERVICE" 2>/dev/null || true
    fi
fi

if ! start_service "$ARM_SERVICE"; then
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

if ! run_validation "$MIDDLEWARE_TYPE"; then
    log_error "$MIDDLEWARE_TYPE 验证失败"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

set_migration_state "$MIDDLEWARE_TYPE" "success"

write_report "$MIDDLEWARE_TYPE" "
## 安装内容
1. 软件版本: $TARGET_VERSION
2. 安装方式: ${SOURCE_TYPE:+source_type=$SOURCE_TYPE }($INSTALL_METHOD)
3. 安装目录: $NEW_HOME
4. 配置恢复源: ${SOURCE_DIR}${CONFIG_DIR:-}
"

log_info "$MIDDLEWARE_TYPE 迁移完成: $CURRENT_VERSION -> $TARGET_VERSION (服务: $ARM_SERVICE)"
