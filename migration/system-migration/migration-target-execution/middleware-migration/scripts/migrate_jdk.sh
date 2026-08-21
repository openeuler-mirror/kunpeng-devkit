#!/bin/bash
# migrate_jdk.sh — JDK/JRE 迁移脚本
# 职责：安装目标 Java 运行时（BiSheng JDK/Oracle/IBM 等），设置 JAVA_HOME，
#       配置环境变量，执行 java -version 验证。
# 依赖：无（JDK 是最底层依赖，优先迁移）
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

require_env MIDDLEWARE_TYPE TARGET_VERSION || exit 1
CURRENT_VERSION="${CURRENT_VERSION:-unknown}"
OLD_JAVA_HOME="${JAVA_HOME:-}"

log_info "$MIDDLEWARE_TYPE 迁移开始: $CURRENT_VERSION -> $TARGET_VERSION"

# JDK 固定安装到 /opt（版本化目录不冲突）
if [ -n "${LOCAL_PACKAGE_PATH:-}" ] && [ -f "$LOCAL_PACKAGE_PATH" ]; then
    log_info "使用本地 JDK 包: $LOCAL_PACKAGE_PATH"
    package_path="$LOCAL_PACKAGE_PATH"
elif [ -n "${DOWNLOAD_URL:-}" ]; then
    DOWNLOAD_URL=$(resolve_download_url)
    FILENAME="${PACKAGE_FILE_NAME:-$(basename "$DOWNLOAD_URL")}"
else
    log_error "plan 未提供 JDK 安装包源（download_url/local_path 均缺失），请在 migration-plan.json 的 route.middleware[].packages[0] 中补充"
    exit 1
fi

# 下载（若未使用本地包）并解压
if [ -z "$package_path" ]; then
    if ! package_path=$(download_package "$DOWNLOAD_URL" "$FILENAME"); then
        log_error "JDK 下载失败: $DOWNLOAD_URL"
        set_migration_state "$MIDDLEWARE_TYPE" "failed"
        exit 1
    fi
fi

tar -xzf "$package_path" -C /opt/ 2>/dev/null || {
    log_error "JDK 解压失败"
    exit 1
}

# 定位新 JDK 目录
# 解压后 JDK 目录命名多样：jdk-11.0.26、ibm-semeru-open-jdk-11.0.26、bisheng-jdk-11.0.26、zulu11-* 等
# 优先按版本号匹配（版本号是解压后新加入的目录最显著特征），找不到则退回最新修改的 jdk 相关目录
NEW_JAVA_HOME=""
# 1. 精确匹配：包含目标版本号的 JDK 目录
for candidate in /opt/jdk-* /opt/ibm-semeru-open-jdk* /opt/zulu*jdk* /opt/bisheng-jdk* /opt/*jdk*; do
    [ -d "$candidate" ] || continue
    if echo "$candidate" | grep -q "$TARGET_VERSION"; then
        NEW_JAVA_HOME="$candidate"
        break
    fi
done

# 2. 兜底：取 /opt 下最近修改的、名称含 jdk 的目录
if [ -z "$NEW_JAVA_HOME" ]; then
    NEW_JAVA_HOME=$(ls -dt /opt/*jdk* /opt/jdk-* 2>/dev/null | head -1)
fi

if [ -z "$NEW_JAVA_HOME" ] || [ ! -d "$NEW_JAVA_HOME" ]; then
    log_error "解压后未找到 JDK $TARGET_VERSION 目录"
    exit 1
fi

# 使用新安装 JDK 的绝对路径进行专用验证，不依赖目标环境现有 PATH/JAVA_HOME
if [ ! -x "$NEW_JAVA_HOME/bin/java" ]; then
    log_error "新安装 JDK 缺少可执行 java: $NEW_JAVA_HOME/bin/java"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

if ! "$NEW_JAVA_HOME/bin/java" -version >/dev/null 2>&1; then
    log_error "新安装 JDK 无法正常运行: $NEW_JAVA_HOME/bin/java"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

# 创建/更新系统 JDK 运行时入口。目录创建或链接失败时必须显式失败，不能吞掉错误。
if ! mkdir -p /usr/lib/jvm; then
    log_error "无法创建 JDK 运行时目录: /usr/lib/jvm"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

JDK_RUNTIME_LINK="/usr/lib/jvm/java-arm"
if [ -e "$JDK_RUNTIME_LINK" ] && [ ! -L "$JDK_RUNTIME_LINK" ]; then
    log_error "JDK 运行时入口已存在且不是符号链接: $JDK_RUNTIME_LINK"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

if ! ln -sfn "$NEW_JAVA_HOME" "$JDK_RUNTIME_LINK"; then
    log_error "创建 JDK 运行时链接失败: $JDK_RUNTIME_LINK -> $NEW_JAVA_HOME"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi

# 配置当前进程及后续登录环境。验证使用绝对路径，不依赖这里的 PATH 生效时机。
if ! cat > /etc/profile.d/jdk-arm.sh << EOF
export JAVA_HOME=$NEW_JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
then
    log_error "写入 JDK 环境配置失败: /etc/profile.d/jdk-arm.sh"
    set_migration_state "$MIDDLEWARE_TYPE" "failed"
    exit 1
fi
export JAVA_HOME="$NEW_JAVA_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

# 配置恢复与 JAVA_HOME 路径替换
# JDK 迁移时若 plan 提供了 artifact_paths（CONFIG_PATHS），对配置文件中的 JAVA_HOME 路径进行替换
# 产物输出到 WORK_DIR/jdk_configs/ 下，避免污染当前工作目录
if [ -n "$SOURCE_DIR" ] && [ -n "${CONFIG_PATHS:-}" ] && [ "${CONFIG_PATHS:-}" != "null" ]; then
    JDK_CONFIG_OUT="${WORK_DIR}/jdk_configs"
    mkdir -p "$JDK_CONFIG_OUT"
    while IFS= read -r artifact; do
        [ -z "$artifact" ] && continue
        src="${SOURCE_DIR}/${artifact}"
        if [ -f "$src" ]; then
            filename=$(basename "$artifact")
            dest="$JDK_CONFIG_OUT/${filename}.arm"
            cp "$src" "$dest"
            # 使用迁移前的 JAVA_HOME 进行路径替换；当前 JAVA_HOME 已切换到新 JDK。
            if [ -n "$OLD_JAVA_HOME" ]; then
                sed -i "s|$OLD_JAVA_HOME|$NEW_JAVA_HOME|g" "$dest" 2>/dev/null || true
            fi
            log_info "迁移配置: $artifact -> $dest"
        fi
    done < <(resolve_artifact_paths)
fi

write_report "$MIDDLEWARE_TYPE" "
## 安装内容
1. JDK 版本: $TARGET_VERSION
2. JDK 目录: $NEW_JAVA_HOME
3. 配置恢复源: ${SOURCE_DIR:-未提供}

## 验证结果
- java -version: $($NEW_JAVA_HOME/bin/java -version 2>&1 | head -1)
- 运行时入口: $JDK_RUNTIME_LINK
"

set_migration_state "$MIDDLEWARE_TYPE" "success"

log_info "$MIDDLEWARE_TYPE 迁移完成: $CURRENT_VERSION -> $TARGET_VERSION (JDK: $NEW_JAVA_HOME)"
