#!/bin/bash
# 检测并安装 DevKit 工具（devkit、kspect、ksys）及 async-profiler
# 用法: bash check_install.sh [--install]

set -e

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==================== 配置 ====================
ARCH=$(uname -m)
# async-profiler 使用不同的架构命名: arm64 / x64
case "$ARCH" in
    aarch64) AP_ARCH="arm64" ;;
    x86_64)  AP_ARCH="x64" ;;
    *)       AP_ARCH="$ARCH" ;;
esac
BASE_URL="https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit/Kunpeng%20DevKit%2026.1.RC1"
INSTALL_DIR="${HOME}/.local/kunpeng/devkit"
BIN_DIR="${HOME}/.local/bin"
CACHE_DIR="${HOME}/.local/kunpeng/cache"

# 三个工具的下载地址与包名
declare -A TOOL_URL
declare -A TOOL_PKG
declare -A TOOL_CMD

TOOL_URL["devkit"]="${BASE_URL}/DevKit-Tuner-CLI-26.1.RC1-Linux-${ARCH}.tar.gz"
TOOL_PKG["devkit"]="devkit-tuner-${ARCH}.tar.gz"
TOOL_CMD["devkit"]="devkit"

TOOL_URL["kspect"]="${BASE_URL}/devkit-kspect-26.1.RC1-Linux-${ARCH}.tar.gz"
TOOL_PKG["kspect"]="devkit-kspect-${ARCH}.tar.gz"
TOOL_CMD["kspect"]="kspect"

TOOL_URL["ksys"]="${BASE_URL}/ksys-26.1.RC1-Linux-${ARCH}.tar.gz"
TOOL_PKG["ksys"]="devkit-ksys-${ARCH}.tar.gz"
TOOL_CMD["ksys"]="ksys"

TOOL_URL["asprof"]="https://github.com/async-profiler/async-profiler/releases/download/v4.5/async-profiler-4.5-linux-${AP_ARCH}.tar.gz"
TOOL_PKG["asprof"]="async-profiler-4.5-${AP_ARCH}.tar.gz"
TOOL_CMD["asprof"]="asprof"

ALL_TOOLS=(devkit kspect ksys asprof)

INSTALL_MODE=false
UNINSTALL_MODE=false
if [[ "$1" == "--install" ]]; then
    INSTALL_MODE=true
elif [[ "$1" == "--remove" ]]; then
    UNINSTALL_MODE=true
fi

# ==================== 函数 ====================
is_installed() {
    command -v "$1" &> /dev/null
}

check_tool() {
    local tool="$1"
    if is_installed "${TOOL_CMD[$tool]}"; then
        echo -e "  ${GREEN}✓${NC} ${tool} 已安装 ($(which ${TOOL_CMD[$tool]}))"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${tool} 未安装"
        return 1
    fi
}

install_tool() {
    local tool="$1"
    local pkg="${TOOL_PKG[$tool]}"
    local url="${TOOL_URL[$tool]}"
    local cmd="${TOOL_CMD[$tool]}"
    local tool_dir="${INSTALL_DIR}/${tool}"

    # 1. 在缓存目录查找已有安装包
    local pkg_file="${CACHE_DIR}/${pkg}"
    if [[ -f "$pkg_file" ]]; then
        echo "  使用已有安装包: ${pkg_file}"
    else
        # 2. 没找到包则下载
        mkdir -p "$CACHE_DIR"
        echo -ne "  下载 ${tool} ... "
        if curl -sL -o "$pkg_file" "$url" 2>/dev/null; then
            echo "完成"
        else
            echo -e "${RED}失败${NC}"
            echo "  请手动下载: ${url}"
            return 1
        fi
    fi

    # 3. 解压到安装目录
    rm -rf "$tool_dir"
    mkdir -p "$tool_dir"
    tar -xzf "$pkg_file" -C "$tool_dir"
    echo "  解压到: ${tool_dir}"

    # 4. 查找可执行文件并创建软链接
    mkdir -p "$BIN_DIR"
    local found=$(find "$tool_dir" -maxdepth 3 -type f -executable -name "$cmd" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        ln -sf "$found" "${BIN_DIR}/${cmd}"
        echo -e "  ${GREEN}已安装: ${BIN_DIR}/${cmd} -> ${found}${NC}"
    else
        echo -e "  ${YELLOW}未在解压内容中找到 ${cmd}，请手动检查: ${tool_dir}${NC}"
    fi
    return 0
}

# ==================== 主流程 ====================
echo "=== 工具检测 ==="
echo ""

if [[ "$UNINSTALL_MODE" == true ]]; then
    echo "卸载目录: ${INSTALL_DIR}/"
    echo "卸载链接: ${BIN_DIR}/"
    echo ""

    for tool in "${ALL_TOOLS[@]}"; do
        dir="${INSTALL_DIR}/${tool}"
        link="${BIN_DIR}/${TOOL_CMD[$tool]}"

        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            echo -e "  ${GREEN}✓${NC} 已删除 ${dir}"
        else
            echo -e "  ${GREEN}○${NC} ${dir} 不存在，跳过"
        fi

        if [[ -L "$link" ]]; then
            rm -f "$link"
            echo -e "  ${GREEN}✓${NC} 已删除 ${link}"
        elif [[ -f "$link" ]]; then
            rm -f "$link"
            echo -e "  ${GREEN}✓${NC} 已删除 ${link}"
        else
            echo -e "  ${GREEN}○${NC} ${link} 不存在，跳过"
        fi
    done

    # 删除下载的压缩包
    for tool in "${ALL_TOOLS[@]}"; do
        pkg="${TOOL_PKG[$tool]}"
        if [[ -f "${CACHE_DIR}/${pkg}" ]]; then
            rm -f "${CACHE_DIR}/${pkg}"
            echo -e "  ${GREEN}✓${NC} 已删除 ${CACHE_DIR}/${pkg}"
        fi
    done

    echo ""
    echo "卸载完成。"
    exit 0
fi

MISSING=()
for tool in "${ALL_TOOLS[@]}"; do
    check_tool "$tool" || MISSING+=("$tool")
done

echo ""

if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo -e "${GREEN}所有 DevKit 工具已就绪${NC}"
    exit 0
fi

echo -e "${YELLOW}以下工具未安装: ${MISSING[*]}${NC}"

if [[ "$INSTALL_MODE" == true ]]; then
    echo ""
    echo "安装目录: ${INSTALL_DIR}/"
    echo "软链接:   ${BIN_DIR}/"
    echo ""

    echo "开始自动下载安装..."
    for tool in "${MISSING[@]}"; do
        echo ""
        install_tool "$tool"
    done

    echo ""
    echo "安装完成。"
    if ! echo "$PATH" | tr ':' '\n' | grep -qxF "${BIN_DIR}"; then
        echo -e "${YELLOW}注意: ${BIN_DIR} 不在 PATH 中，请执行以下命令后生效:${NC}"
        echo "  export PATH=${BIN_DIR}:\$PATH"
        echo "（建议将上述命令追加到 ~/.bashrc 中持久化）"
    fi
else
    echo ""
    echo "用法:"
    echo "  bash check_install.sh --install   安装缺失的 DevKit 工具"
    echo "  bash check_install.sh --remove  卸载已安装的 DevKit 工具"
fi