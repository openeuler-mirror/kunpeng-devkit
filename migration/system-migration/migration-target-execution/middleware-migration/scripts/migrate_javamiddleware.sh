#!/bin/bash
# migrate_javamiddleware.sh — 通用 Java 中间件迁移脚本
# 适用：Tomcat/Resin/Nacos/RocketMQ 等基于 JDK 运行的中间件。
# 职责：依赖 JDK → 安装中间件 → 恢复配置 → 注册 systemd 服务 → 健康验证。
set -e

_deploy_application() {
    local package_path=""
    local package_url=""
    local package_name=""

    # 1. 优先使用本地已上传的包（plan 提供 local_path）
    package_path=$(resolve_local_package_path)
    if [ -n "$package_path" ] && [ -f "$package_path" ]; then
        log_info "使用本地安装包: $package_path"
        _extract_package "$package_path" || return 1
        return 0
    fi

    # 2. 从 plan 下载目标包（download_url 由 plan 提供，不再回退 registry）
    package_url=$(resolve_download_url)
    package_name=$(resolve_package_file_name)
    if [ -n "$package_url" ]; then
        log_info "下载目标安装包: $package_url"
        if package_path=$(download_package "$package_url" "$package_name"); then
            _extract_package "$package_path" || return 1
            return 0
        fi
        log_warn "下载失败，尝试其他方式"
    fi

    # 3. 同源架构迁移：从 source_dir 复制原应用
    if [ "$LOCALIZATION" = "false" ] && [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
        log_info "从 $SOURCE_DIR 复制应用到 $NEW_APP_DIR"
        cp -r "$SOURCE_DIR" "$NEW_APP_DIR"
        return 0
    fi

    # 4. plan 未提供安装包源且无法从源端复制：直接失败
    log_error "plan 未提供安装包源（download_url/local_path 均缺失）且无源端目录可复制，请在 migration-plan.json 的 route.middleware[].packages[0] 中补充"
    exit 1
}

_extract_package() {
    local package_path="$1"
    mkdir -p "$NEW_APP_DIR"
    case "$package_path" in
        *.tar.gz|*.tgz)
            tar -xzf "$package_path" -C "$NEW_APP_DIR" --strip-components=1 2>/dev/null || { log_error "解压失败: $package_path"; return 1; }
            ;;
        *.tar)
            tar -xf "$package_path" -C "$NEW_APP_DIR" --strip-components=1 2>/dev/null || { log_error "解压失败: $package_path"; return 1; }
            ;;
        *.zip)
            unzip -q "$package_path" -d "$NEW_APP_DIR" 2>/dev/null || { log_error "解压失败: $package_path"; return 1; }
            ;;
        *)
            log_error "未知压缩格式: $package_path"; return 1
            ;;
    esac
    return 0
}

_restore_config_files() {
    # 使用 plan 中的 artifact_paths（CONFIG_PATHS）恢复具体配置文件
    if [ -n "$CONFIG_PATHS" ]; then
        local artifact
        while IFS= read -r artifact; do
            [ -z "$artifact" ] && continue
            local src
            src=$(resolve_artifact_file "$artifact") || { log_warn "无法解析配置产物: $artifact"; continue; }
            local filename
            filename=$(basename "$artifact")
            # 目标目录优先匹配应用包自带目录（conf > config），否则落到 conf
            local dest_dir="$NEW_APP_DIR/conf"
            [ -d "$NEW_APP_DIR/config" ] && dest_dir="$NEW_APP_DIR/config"
            # 处理 registry 中 config_dir 为绝对路径的情况：取末尾目录名拼到 NEW_APP_DIR 下
            if [ -n "$CONFIG_DIR" ]; then
                local rel_config="${CONFIG_DIR#/}"
                # 去掉前缀路径，仅保留末尾目录（如 /opt/tomcat/conf -> conf）
                rel_config="${rel_config##*/}"
                if [ -n "$rel_config" ] && [ -d "$NEW_APP_DIR/$rel_config" ]; then
                    dest_dir="$NEW_APP_DIR/$rel_config"
                fi
            fi

            if [ -f "$src" ]; then
                mkdir -p "$dest_dir"
                log_info "恢复配置: $src -> $dest_dir/$filename"
                cp "$src" "$dest_dir/$filename"
            else
                log_warn "配置源文件不存在: $src"
            fi
        done <<< "$(resolve_artifact_paths)"
        return 0
    fi

    # 兜底：使用 CONFIG_DIR 整体复制（CONFIG_DIR 为绝对路径时直接使用，否则拼 SOURCE_DIR）
    local src_dir=""
    case "$CONFIG_DIR" in
        /*) src_dir="$CONFIG_DIR" ;;
        *)  [ -n "$SOURCE_DIR" ] && src_dir="${SOURCE_DIR%/}/$CONFIG_DIR" ;;
    esac
    if [ -n "$src_dir" ] && [ -d "$src_dir" ]; then
        log_info "从 $src_dir 恢复配置到 $NEW_APP_DIR/conf"
        mkdir -p "$NEW_APP_DIR/conf"
        cp -r "$src_dir"/* "$NEW_APP_DIR/conf/" 2>/dev/null || {
            log_warn "配置恢复失败"
        }
    fi
}

# ==================== 主流程 ====================

# SKILL_DIR：优先用父进程传入值，fallback 用 BASH_SOURCE[0] 解析
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

# 解析 registry 元数据
ARM_SERVICE=$(resolve_arm_service "$MIDDLEWARE_TYPE")
CONFIG_DIR=$(resolve_config_dir "$MIDDLEWARE_TYPE")
EXEC_START=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".exec_start")
EXEC_STOP=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".exec_stop" "")
SERVICE_TYPE=$(registry_get ".strategies.\"$MIDDLEWARE_TYPE\".service_type" "simple")

NEW_APP_DIR="$DEPLOY_DIR"

# 展开 exec_start/exec_stop 中的 ${INSTALL_DIR} 占位符
EXEC_START="${EXEC_START//\$\{INSTALL_DIR\}/$NEW_APP_DIR}"
EXEC_STOP="${EXEC_STOP//\$\{INSTALL_DIR\}/$NEW_APP_DIR}"
SOURCE_PRODUCT="${SOURCE_PRODUCT:-$MIDDLEWARE_TYPE}"
TARGET_PRODUCT="${TARGET_PRODUCT:-$MIDDLEWARE_TYPE}"

LOCALIZATION=false
if [ "$SOURCE_PRODUCT" != "$TARGET_PRODUCT" ]; then
    LOCALIZATION=true
    log_info "识别为本地化迁移: $SOURCE_PRODUCT $CURRENT_VERSION -> $TARGET_PRODUCT $TARGET_VERSION"
fi

log_info "$MIDDLEWARE_TYPE 迁移开始: $CURRENT_VERSION -> $TARGET_VERSION"

stop_current_service "$MIDDLEWARE_TYPE" "$ARM_SERVICE"

if ! JAVA_HOME=$(resolve_java_home); then
    log_error "未找到 JAVA_HOME，请先执行 JDK 迁移"
    exit 1
fi
log_info "使用 JAVA_HOME=$JAVA_HOME"

# --- 应用部署 ---
_deploy_application

if [ ! -d "$NEW_APP_DIR" ]; then
    log_error "应用目录不存在: $NEW_APP_DIR"
    exit 1
fi

# --- JVM 参数适配 ---
log_info "适配 JAVA_HOME 和 JVM 参数..."
if [ -d "$NEW_APP_DIR/bin" ]; then
    for script in "$NEW_APP_DIR"/bin/*.sh; do
        [ -f "$script" ] || continue
        sed -i "s|export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|g" "$script" 2>/dev/null || true
        sed -i "s|JAVA_HOME=.*|JAVA_HOME=$JAVA_HOME|g" "$script" 2>/dev/null || true
    done
fi

JVM_CONFIGS=$(find "$NEW_APP_DIR" \( -name "*.conf" -o -name "*.sh" -o -name "*.properties" \) 2>/dev/null | xargs grep -l "JAVA_OPTS\|JVM_OPTS\|Xmx\|Xms" 2>/dev/null || true)
for jvm_conf in $JVM_CONFIGS; do
    [ -f "$jvm_conf" ] || continue
    sed -i 's/-XX:+UseParallelGC/-XX:+UseG1GC/g' "$jvm_conf" 2>/dev/null || true
    sed -i 's/-XX:+UseConcMarkSweepGC/-XX:+UseG1GC/g' "$jvm_conf" 2>/dev/null || true
    sed -i 's/-XX:+UseSerialGC/-XX:+UseG1GC/g' "$jvm_conf" 2>/dev/null || true
done

# --- 配置恢复 ---
_restore_config_files

# --- 确定启动命令 ---
if [ -z "$EXEC_START" ] || [ "$EXEC_START" = "null" ]; then
    if [ -f "$NEW_APP_DIR/bin/startup.sh" ]; then
        EXEC_START="$NEW_APP_DIR/bin/startup.sh"
    elif [ -f "$NEW_APP_DIR/bin/startserver.sh" ]; then
        EXEC_START="$NEW_APP_DIR/bin/startserver.sh"
    elif [ -f "$NEW_APP_DIR/bin/startServer.sh" ]; then
        EXEC_START="$NEW_APP_DIR/bin/startServer.sh"
    else
        EXEC_START=$(ls "$NEW_APP_DIR/bin/"*.sh 2>/dev/null | head -1)
    fi
fi

if [ -z "$EXEC_START" ]; then
    EXEC_START="$NEW_APP_DIR/bin/start.sh"
fi

if [ -z "$EXEC_STOP" ] || [ "$EXEC_STOP" = "null" ]; then
    if [ -f "$NEW_APP_DIR/bin/shutdown.sh" ]; then
        EXEC_STOP="$NEW_APP_DIR/bin/shutdown.sh"
    elif [ -f "$NEW_APP_DIR/bin/stopserver.sh" ]; then
        EXEC_STOP="$NEW_APP_DIR/bin/stopserver.sh"
    elif [ -f "$NEW_APP_DIR/bin/stopServer.sh" ]; then
        EXEC_STOP="$NEW_APP_DIR/bin/stopServer.sh"
    fi
fi

log_info "启动命令: $EXEC_START"

# --- 服务安装 ---
install_systemd_service \
    "$MIDDLEWARE_TYPE" \
    "$ARM_SERVICE" \
    "$EXEC_START" \
    "$EXEC_STOP" \
    "JAVA_HOME=$JAVA_HOME" \
    "$SERVICE_TYPE"

# --- 启动服务 ---
if ! start_service "$ARM_SERVICE"; then
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

# --- 验证 ---
if ! run_validation "$MIDDLEWARE_TYPE"; then
    log_error "$MIDDLEWARE_TYPE 验证失败"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

set_migration_state "$MIDDLEWARE_TYPE" "success"

# --- 报告 ---
write_report "$MIDDLEWARE_TYPE" "
## 安装内容
1. 应用目录: $NEW_APP_DIR
2. JAVA_HOME: $JAVA_HOME
3. JVM 参数: 已适配 aarch64 架构（G1GC）
4. 服务名: $ARM_SERVICE
5. 源产品: $SOURCE_PRODUCT $CURRENT_VERSION
6. 目标产品: $TARGET_PRODUCT $TARGET_VERSION
"

log_info "$MIDDLEWARE_TYPE 迁移完成: $CURRENT_VERSION -> $TARGET_VERSION (服务: $ARM_SERVICE)"
