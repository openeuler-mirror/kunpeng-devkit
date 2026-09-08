#!/bin/bash
# ============================================================
# 服务器数据采集脚本 —— 独立版本
# 由 package.sh 自动生成，合并了 lib/common.sh + devkit/*.sh + os/*.sh
# 用法: ./server_data_collect_release.sh -d <持续时间> [-p <进程ID>] [-o <输出目录>] [-c <采集项目>] [-t <超时缓冲>] [-C] [-h]
# ============================================================

# ========== lib/common.sh ==========
# ============================================================
# 共享函数库 —— 颜色、日志、命令检测、辅助功能
# 被 devkit/ 和 os/ 下的子脚本 source
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info()    { echo -e "${BLUE}$1${NC}"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_warning() { echo -e "${YELLOW}$1${NC}"; }
log_error()   { echo -e "${RED}$1${NC}"; }

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "命令 $1 未找到"
        return 1
    fi
    return 0
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warning "建议使用 root 权限运行此脚本以获取完整信息"
        log_warning "某些命令可能需要 sudo 权限"
    fi
}

# 软件列表扫描（附加功能）
get_software() {
    local output_file="$1"
    [[ -f "$output_file" ]] && return
    if command -v rpm &>/dev/null; then
        rpm -qa --queryformat "%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n" > "$output_file" 2>/dev/null
    elif command -v dpkg &>/dev/null; then
        dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' > "$output_file" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk list --installed 2>/dev/null | tail -n +2 | awk '{print $1, $2, $3}' > "$output_file"
    else
        log_error "无法识别包管理器"
        return
    fi
    log_success "软件列表已保存到 ${output_file}，共 $(wc -l < "$output_file") 个软件"
}

# 交互式补充数据（附加功能）
supple_data() {
    local output_file="$1"
    while true; do
        read -p "是否需要补充内容？(Y/N): " choice
        case $choice in
            [Yy])
                read -p "请输入要执行的命令: " cmd
                echo "正在执行: $cmd"
                echo "----------------------------------------"
                local temp_output
                temp_output=$(mktemp)
                eval "$cmd" > "$temp_output" 2>&1
                local exit_code=$?
                cat "$temp_output"
                echo "----------------------------------------"
                if [ $exit_code -eq 0 ]; then
                    cat "$temp_output" >> "$output_file"
                    echo "✓ 命令执行成功，输出已记录到 ${output_file}"
                else
                    echo "✗ 命令执行失败（退出码: $exit_code），输出未记录"
                fi
                rm -f "$temp_output"
                echo ""
                ;;
            *)
                echo "退出补充流程。"
                break
                ;;
        esac
    done
}

# ============================================================
# 容器（跨挂载命名空间）采集支持 —— 通用路径映射
# ------------------------------------------------------------
# 当目标进程位于容器中（与采集进程不在同一挂载命名空间），
# 其 exe / cwd / maps 映射文件 / 日志等路径均为容器内路径，宿主机无法直接访问。
# 通过对比 /proc/self/ns/mnt 与 /proc/<pid>/ns/mnt 的 st_ino 判断是否
# 同命名空间；若不同，则依据 /proc/<pid>/mountinfo 构建
# "容器路径 -> 宿主机路径" 映射，并在采集前完成路径替换。
#
# 全局数组（由 setup_container_env / ctr_build_path_map 填充）：
#   CONTAINER_PATH_MAP_CTR[i] 容器路径（按深度降序，最深的在前）
#   CONTAINER_PATH_MAP_HOST[i] 对应的宿主机路径
# 环境变量（可选，便于测试注入）：
#   CONTAINER_PID_MNTINFO   覆盖 /proc/<pid>/mountinfo 路径
#   CONTAINER_SELF_MNTINFO  覆盖 /proc/self/mountinfo 路径
#   CONTAINER_PID_STATUS    覆盖 /proc/<pid>/status 路径
# ============================================================

# 获取 /proc/<pid>/ns/mnt 的 inode 号（即 st_ino）
# readlink 形如 "mnt:[4026531840]"，方括号内数字即命名空间 inode
ctr_get_mnt_ns_ino() {
    local pid="$1"
    local ns_file="/proc/${pid}/ns/mnt"
    local link
    link=$(readlink "$ns_file" 2>/dev/null) || { echo ""; return 1; }
    echo "$link" | grep -oE '[0-9]+'
}

# 判断目标进程是否与采集进程处于同一挂载命名空间
# 返回 0=同命名空间（可正常采集）；1=不同命名空间（容器环境）
ctr_is_same_mnt_ns() {
    local pid="$1"
    local self_ino pid_ino
    self_ino=$(ctr_get_mnt_ns_ino "self")
    pid_ino=$(ctr_get_mnt_ns_ino "$pid")
    if [[ -z "$self_ino" || -z "$pid_ino" ]]; then
        return 0
    fi
    [[ "$self_ino" == "$pid_ino" ]]
}

# 解析一行 mountinfo，输出 "dev<TAB>root<TAB>mountpoint<TAB>fs_type"
# mountinfo 字段：mount_id parent_id major:minor root mount_point options [可选字段...] - fs_type source super_options
ctr_parse_mountinfo_line() {
    local line="$1"
    [[ -z "$line" ]] && return 1
    local -a _f=()
    read -ra _f <<< "$line"
    [[ ${#_f[@]} -lt 7 ]] && return 1
    local dev="${_f[2]}"
    local root="${_f[3]}"
    local mp="${_f[4]}"
    local sep=-1 i
    for i in "${!_f[@]}"; do
        if [[ "${_f[i]}" == "-" ]]; then sep=$i; break; fi
    done
    [[ $sep -lt 0 || $((sep+1)) -ge ${#_f[@]} ]] && return 1
    local fs_type="${_f[$((sep+1))]}"
    printf '%s\t%s\t%s\t%s\n' "$dev" "$root" "$mp" "$fs_type"
}

# 计算路径深度（按 / 分段数，根 / 深度为 0）
ctr_path_depth() {
    local p="$1"
    p="${p%/}"
    [[ -z "$p" || "$p" == "/" ]] && { echo 0; return; }
    echo "$p" | tr -cd '/' | wc -c
}

# 构建 容器路径 -> 宿主机路径 映射（结果存入全局数组）
# 规则：
#   - ext4/ext3/ext2/xfs/zfs/nfs/nfs4：宿主机路径 = pid.root，容器路径 = pid.mountPoint
#   - overlay：以设备号(major:minor)在 /proc/self/mountinfo 中查找，
#               宿主机路径 = self.mountPoint，容器路径 = pid.mountPoint
ctr_build_path_map() {
    local pid="$1"
    CONTAINER_PATH_MAP_CTR=()
    CONTAINER_PATH_MAP_HOST=()

    local pid_mntinfo="${CONTAINER_PID_MNTINFO:-/proc/${pid}/mountinfo}"
    local self_mntinfo="${CONTAINER_SELF_MNTINFO:-/proc/self/mountinfo}"
    [[ -f "$pid_mntinfo" ]] || return 1

    declare -A self_dev_mp=()
    if [[ -f "$self_mntinfo" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local parsed dev root mp fs_type
            parsed=$(ctr_parse_mountinfo_line "$line") || continue
            IFS=$'\t' read -r dev root mp fs_type <<< "$parsed"
            [[ -z "$dev" || -z "$mp" ]] && continue
            if [[ "$fs_type" == "overlay" || -z "${self_dev_mp[$dev]+x}" ]]; then
                self_dev_mp["$dev"]="$mp"
            fi
        done < "$self_mntinfo"
    fi

    local tmp_ctr=()
    local tmp_host=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local parsed dev root mp fs_type
        parsed=$(ctr_parse_mountinfo_line "$line") || continue
        IFS=$'\t' read -r dev root mp fs_type <<< "$parsed"
        [[ -z "$dev" || -z "$mp" || -z "$fs_type" ]] && continue

        local host_path=""
        case "$fs_type" in
            ext4|ext3|ext2|xfs|zfs|nfs|nfs4)
                host_path="$root"
                ;;
            overlay)
                host_path="${self_dev_mp[$dev]:-}"
                ;;
            *)
                continue
                ;;
        esac
        [[ -z "$host_path" ]] && continue
        tmp_ctr+=("$mp")
        tmp_host+=("$host_path")
    done < "$pid_mntinfo"

    local depths=()
    local k
    for ((k=0; k<${#tmp_ctr[@]}; k++)); do
        depths+=("$(ctr_path_depth "${tmp_ctr[k]}")")
    done

    local n=${#tmp_ctr[@]}
    local i j
    for ((i=0; i<n; i++)); do
        for ((j=i+1; j<n; j++)); do
            if (( ${depths[j]} > ${depths[i]} )); then
                local tc th td
                tc="${tmp_ctr[i]}"; th="${tmp_host[i]}"; td="${depths[i]}"
                tmp_ctr[i]="${tmp_ctr[j]}"; tmp_host[i]="${tmp_host[j]}"; depths[i]="${depths[j]}"
                tmp_ctr[j]="$tc"; tmp_host[j]="$th"; depths[j]="$td"
            fi
        done
    done

    CONTAINER_PATH_MAP_CTR=("${tmp_ctr[@]}")
    CONTAINER_PATH_MAP_HOST=("${tmp_host[@]}")
    return 0
}

# 将容器路径转换为宿主机路径（最长前缀优先匹配）
# 映射已按容器路径深度降序排列，故首个命中即为最深匹配
ctr_to_host() {
    local ctr_path="$1"
    [[ ${#CONTAINER_PATH_MAP_CTR[@]} -eq 0 ]] && { echo "$ctr_path"; return; }
    local i
    for ((i=0; i<${#CONTAINER_PATH_MAP_CTR[@]}; i++)); do
        local ctr="${CONTAINER_PATH_MAP_CTR[i]}"
        local host="${CONTAINER_PATH_MAP_HOST[i]}"
        if [[ "$ctr" == "/" ]]; then
            host="${host%/}"
            if [[ "$ctr_path" == "/" ]]; then
                echo "$host"
            else
                echo "${host}${ctr_path}"
            fi
            return
        fi
        if [[ "$ctr_path" == "$ctr" ]]; then
            echo "$host"
            return
        elif [[ "$ctr_path" == "$ctr"/* ]]; then
            local rel="${ctr_path#"$ctr"}"
            host="${host%/}"
            echo "${host}${rel}"
            return
        fi
    done
    echo "$ctr_path"
}

# 容器环境初始化：检测命名空间并在跨命名空间时构建路径映射
setup_container_env() {
    local pid="$1"
    CONTAINER_PATH_MAP_CTR=()
    CONTAINER_PATH_MAP_HOST=()
    if ctr_is_same_mnt_ns "$pid"; then
        return 0
    fi
    if ctr_build_path_map "$pid"; then
        local cnt=${#CONTAINER_PATH_MAP_CTR[@]}
        if [[ $cnt -gt 0 ]]; then
            log_info "检测到 PID=$pid 位于不同挂载命名空间（容器环境），已建立 $cnt 条 容器->宿主机 路径映射"
        else
            log_warning "PID=$pid 位于不同挂载命名空间，但未构建到有效路径映射，按原路径采集"
        fi
    else
        log_warning "无法读取 PID=$pid 的 mountinfo，路径映射未建立，按同命名空间采集"
    fi
}

# 获取目标进程在其最内层 PID 命名空间中的 PID（容器内 PID）
# 通过 /proc/<pid>/status 的 NSpid 字段取最后一个值（从外层到内层）；
# 同命名空间时 NSpid 只有一个值，即返回 pid 本身；解析失败回退为 pid。
ctr_get_innermost_pid() {
    local pid="$1"
    local status_file="${CONTAINER_PID_STATUS:-/proc/${pid}/status}"
    local nspid_line
    nspid_line=$(grep '^NSpid:' "$status_file" 2>/dev/null)
    if [[ -z "$nspid_line" ]]; then
        echo "$pid"
        return
    fi
    local inner
    inner=$(echo "$nspid_line" | awk '{print $NF}')
    if [[ "$inner" =~ ^[0-9]+$ ]]; then
        echo "$inner"
    else
        echo "$pid"
    fi
}

# ========== os/check-64k-opt.sh ==========

check_64k_opt() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：ARM 64K 页大小内核检测"
    local output_file="$output_dir/check_64k_opt.txt"

    {
        echo "========================================"
        echo "ARM 64K 内核检测"
        echo "检测时间: $(date)"
        echo "========================================"
        echo ""

        ARCH=$(uname -m)
        echo "CPU 架构: $ARCH"

        echo ""
        echo "=== 方法一：getconf 命令 ==="
        PAGE_SIZE=$(getconf PAGE_SIZE 2>/dev/null || echo "unknown")
        echo "页大小 (getconf): $PAGE_SIZE 字节"

        if [ "$ARCH" = "aarch64" ] && [ "$PAGE_SIZE" = "65536" ]; then
            echo "结果: 当前环境是 ARM 64K 内核"
        else
            echo "结果: 当前环境不是 ARM 64K 内核 (arch=$ARCH, pagesize=$PAGE_SIZE)"
        fi

        echo ""
        echo "=== 方法二：/proc/self/smaps KernelPageSize ==="
        if [ "$ARCH" != "aarch64" ]; then
            echo "非 ARM 架构，跳过此方法"
        else
            KERNEL_PAGESIZE=$(grep -m1 "KernelPageSize" /proc/self/smaps 2>/dev/null | awk '{print $2}')
            if [ -n "$KERNEL_PAGESIZE" ]; then
                echo "KernelPageSize: $KERNEL_PAGESIZE kB"
                if [ "$KERNEL_PAGESIZE" = "64" ]; then
                    echo "结果: 当前环境是 ARM 64K 内核"
                else
                    echo "结果: 当前环境不是 ARM 64K 内核 (KernelPageSize=$KERNEL_PAGESIZE kB)"
                fi
            else
                echo "无法读取 KernelPageSize"
            fi
        fi

        echo ""
        echo "=== 常见页大小参考 ==="
        echo "4K  (4096 字节)  - x86_64, ARM（标准）"
        echo "16K (16384 字节) - ARM（可选）"
        echo "64K (65536 字节) - ARM（可选）, ppc64le"

    } > "$output_file"

    log_success "ARM 64K 内核检测完成，结果已保存至 $output_file"
}


# ========== os/check-arm-crc32.sh ==========

check_arm_crc32() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [ "$(uname -m)" != "aarch64" ]; then
        log_info "当前系统不是 ARM aarch64 架构，跳过 CRC32 检测"
        return 0
    fi

    if [ -z "$pids" ]; then
        log_warning "未指定 PID，跳过 CRC32 检测"
        return 0
    fi

    log_info "执行：ARM CRC32 指令加速检测"
    local output_file="$output_dir/check_arm_crc32.txt"

    IFS=',' read -ra pid_array <<< "$pids"
    for pid in "${pid_array[@]}"; do
        pid=$(echo "$pid" | xargs)
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || [ ! -d "/proc/$pid" ]; then
            log_warning "无效 PID: $pid，跳过"
            continue
        fi

        setup_container_env "$pid"

        BINARY_PATH=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        if [[ -n "$BINARY_PATH" && ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 ]]; then
            local bp_host
            bp_host=$(ctr_to_host "$BINARY_PATH")
            [[ "$bp_host" != "$BINARY_PATH" ]] && BINARY_PATH="$bp_host"
        fi
        if [[ -n "$BINARY_PATH" ]]; then
            local bp_canon
            bp_canon=$(readlink -f "$BINARY_PATH" 2>/dev/null || true)
            [[ -n "$bp_canon" ]] && BINARY_PATH="$bp_canon"
        fi
        if [ -z "$BINARY_PATH" ]; then
            echo "PID: $pid - 无法获取二进制路径" >> "$output_file"
            continue
        fi

        {
            echo "========================================"
            echo "PID: $pid"
            echo "Binary: $BINARY_PATH"
            echo "========================================"

            echo ""
            echo "=== 方法一：objdump 反汇编搜索 CRC32 指令 ==="
            CRC32_INSTRUCTIONS=$(objdump -d "$BINARY_PATH" 2>/dev/null | grep -E '\b(crc32b|crc32h|crc32w|crc32x|crc32cb|crc32ch|crc32cw|crc32cx)\b' || true)
            if [ -n "$CRC32_INSTRUCTIONS" ]; then
                echo "二进制文件使用了 ARM CRC32 指令加速"
                echo "$CRC32_INSTRUCTIONS" | head -20
            else
                echo "二进制文件未使用 ARM CRC32 指令加速"
            fi

            echo ""
            echo "=== 方法二：ELF 构建属性（Build Attributes）==="
            FILE_ARCH=$(file "$BINARY_PATH" | grep -o "ARM aarch64" || true)
            if [ -z "$FILE_ARCH" ]; then
                echo "二进制文件不是 ARM aarch64 架构，跳过此方法"
            else
                CRC_ATTR=$(readelf -n "$BINARY_PATH" 2>/dev/null | grep -i crc || true)
                if [ -n "$CRC_ATTR" ]; then
                    echo "二进制文件的构建属性中包含 CRC 扩展标记"
                    echo "$CRC_ATTR"
                else
                    echo "二进制文件的构建属性中未找到 CRC 扩展标记"
                fi
            fi

            echo ""
            echo "=== 方法三：.ARM.attributes 段 ==="
            ATTRS=$(readelf -A "$BINARY_PATH" 2>/dev/null || true)
            if echo "$ATTRS" | grep -qi "crc"; then
                echo "二进制文件的 .ARM.attributes 段中包含 CRC 扩展标记"
                echo "$ATTRS" | grep -i crc
            else
                echo "二进制文件的 .ARM.attributes 段中未找到 CRC 扩展标记"
            fi

            echo ""
            echo "=== 方法四：共享库 CRC32 指令检查 ==="
            CRC32_MAIN=$(objdump -d "$BINARY_PATH" 2>/dev/null | grep -E '\b(crc32b|crc32h|crc32w|crc32x|crc32cb|crc32ch|crc32cw|crc32cx)\b' || true)
            if [ -n "$CRC32_MAIN" ]; then
                echo "主二进制中包含 CRC32 指令"
            else
                echo "主二进制中未找到 CRC32 指令"
            fi
            echo "--- 检查共享库 ---"
            MAPS_FILE="/proc/$pid/maps"
            LIBS=$(awk '{print $6}' "$MAPS_FILE" 2>/dev/null | grep '\.so' | sort -u || true)
            found_lib_crc=false
            for lib in $LIBS; do
                local lib_host="$lib"
                if [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 ]]; then
                    lib_host=$(ctr_to_host "$lib")
                fi
                if [ -f "$lib_host" ]; then
                    CRC32_LIB=$(objdump -d "$lib_host" 2>/dev/null | grep -E '\b(crc32b|crc32h|crc32w|crc32x|crc32cb|crc32ch|crc32cw|crc32cx)\b' || true)
                    if [ -n "$CRC32_LIB" ]; then
                        echo "共享库 $lib_host 中包含 CRC32 指令"
                        found_lib_crc=true
                    fi
                fi
            done
            if [ "$found_lib_crc" = false ]; then
                echo "未在共享库中找到 CRC32 指令"
            fi

            echo ""
            echo "=== 方法五：CPU 运行时 CRC32 支持 ==="
            if [ -f /proc/cpuinfo ]; then
                CRC_FEATURE=$(grep -i "crc32" /proc/cpuinfo || true)
                if [ -n "$CRC_FEATURE" ]; then
                    echo "CPU 支持 CRC32 扩展"
                    echo "$CRC_FEATURE" | head -5
                else
                    echo "CPU 不支持 CRC32 扩展（或 /proc/cpuinfo 未暴露该信息）"
                fi
            else
                echo "无法读取 /proc/cpuinfo"
            fi
        } >> "$output_file"
    done

    log_success "ARM CRC32 检测完成，结果已保存至 $output_file"
}


# ========== os/check_kraio.sh ==========

check_kraio() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [ "$(uname -m)" != "aarch64" ]; then
        log_info "当前系统不是 ARM aarch64 架构，跳过 KRAIO 检测"
        return 0
    fi

    if [ -z "$pids" ]; then
        log_warning "未指定 PID，跳过 KRAIO 检测"
        return 0
    fi

    log_info "执行：KRAIO 网络异步优化使能状态检查"
    local output_file="$output_dir/check_kraio.txt"
    local found_redis=false

    IFS=',' read -ra pid_array <<< "$pids"
    for pid in "${pid_array[@]}"; do
        pid=$(echo "$pid" | xargs)
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || [ ! -d "/proc/$pid" ]; then
            log_warning "无效 PID: $pid，跳过"
            continue
        fi

        setup_container_env "$pid"

        local proc_name=$(ps -p "$pid" -o comm= 2>/dev/null)
        if [ "$proc_name" != "redis-server" ]; then
            log_info "进程 $pid ($proc_name) 不是 redis-server，跳过 KRAIO 检测"
            continue
        fi
        found_redis=true

        {
            echo "========================================="
            echo "PID: $pid  |  进程: $proc_name"
            echo "KRAIO 网络异步优化使能状态检查"
            echo "检测时间: $(date)"
            echo "========================================="
            echo ""

            echo "[1] 检查系统架构 ..."
            ARCH=$(uname -m)
            echo "    ✓ 鲲鹏 (aarch64) 平台"

            echo ""
            echo "[2] 检查 Redis 进程是否加载异步 IO 库 ..."
            KRAIO_LOADED=0
            if cat /proc/$pid/maps 2>/dev/null | grep -qE 'libkraio\.so|libkbaio\.so'; then
                KRAIO_LOADED=1
                KRAIO_TYPE=$(cat /proc/$pid/maps 2>/dev/null | grep -oE 'libk(r|b)aio\.so[^ ]*' | head -1)
                echo "    ✓ Redis 进程 ($pid) 已加载 $KRAIO_TYPE"
            else
                echo "    ✗ Redis 进程未加载 libkraio.so / libkbaio.so"
            fi

            echo ""
            echo "[3] 检查 LD_PRELOAD 配置 ..."
            LD_VAL=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^LD_PRELOAD=')
            if echo "$LD_VAL" | grep -qE 'libkraio\.so|libkbaio\.so'; then
                echo "    ✓ Redis 进程 ($pid) LD_PRELOAD 已配置异步 IO 库"
                echo "    $LD_VAL"
            else
                echo "    ✗ LD_PRELOAD 未配置异步 IO 库"
            fi

            echo ""
            echo "[4] 检查异步 IO 库文件 ..."
            KRAIO_LIB=$(find /usr/lib64 /lib64 /usr/lib /lib /usr/local/lib64 /usr/local/lib -name "libkraio.so*" -o -name "libkbaio.so*" 2>/dev/null)
            if [ -n "$KRAIO_LIB" ]; then
                echo "    ✓ 异步 IO 库文件存在:"
                echo "$KRAIO_LIB" | sed 's/^/      /'
            else
                echo "    ✗ 异步 IO 库文件不存在"
            fi

            echo ""
            echo "[5] 检查 BoostKit Redis 软件包 ..."
            PKG_INSTALLED=$(rpm -qa 2>/dev/null | grep -cE 'boostkit.*redis|kraio|kbaio')
            if [ "$PKG_INSTALLED" -eq 0 ]; then
                PKG_INSTALLED=$(dpkg -l 2>/dev/null | grep -cE 'boostkit.*redis|kraio|kbaio')
            fi
            if [ "$PKG_INSTALLED" -gt 0 ]; then
                echo "    ✓ BoostKit Redis 相关软件包已安装"
                rpm -qa 2>/dev/null | grep -iE 'boostkit.*redis|kraio|kbaio' | sed 's/^/      /'
                dpkg -l 2>/dev/null | grep -iE 'boostkit.*redis|kraio|kbaio' | sed 's/^/      /'
            else
                echo "    ✗ BoostKit Redis 相关软件包未安装"
            fi

            echo ""
            echo "[6] 检查 Redis 版本兼容性 ..."
            REDIS_BIN=$(readlink /proc/$pid/exe 2>/dev/null)
            if [[ -n "$REDIS_BIN" && ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 ]]; then
                local rb_host
                rb_host=$(ctr_to_host "$REDIS_BIN")
                [[ "$rb_host" != "$REDIS_BIN" ]] && REDIS_BIN="$rb_host"
            fi
            if [[ -n "$REDIS_BIN" ]]; then
                local rb_canon
                rb_canon=$(readlink -f "$REDIS_BIN" 2>/dev/null || true)
                [[ -n "$rb_canon" ]] && REDIS_BIN="$rb_canon"
            fi
            if [ -n "$REDIS_BIN" ] && [ -x "$REDIS_BIN" ]; then
                REDIS_VERSION=$($REDIS_BIN --version 2>/dev/null | head -1)
                echo "    Redis 进程 ($pid) 版本: $REDIS_VERSION"
                if echo "$REDIS_VERSION" | grep -qE 'v=6\.0\.|v=7\.0\.'; then
                    echo "    ✓ Redis 版本可能支持 KRAIO"
                else
                    echo "    ⚠ KRAIO 支持 Redis 6.0.20 和 Redis 7.0.15 版本"
                fi
            else
                echo "    ✗ 无法获取 Redis 版本信息"
            fi

            echo ""
            echo "========================================="
            echo "检查结果:"

            if [ "$KRAIO_LOADED" -eq 1 ]; then
                echo "结论: Redis 网络异步优化 (KRAIO) 已使能"
                if [ -n "$KRAIO_TYPE" ]; then
                    echo "  使用版本: $KRAIO_TYPE"
                fi
            elif [ -n "$KRAIO_LIB" ] && [ "$PKG_INSTALLED" -gt 0 ]; then
                echo "结论: KRAIO 库文件和软件包已就绪，但 Redis 进程未加载异步 IO 库"
                echo "建议: 按以下步骤使能 KRAIO 网络异步优化："
                echo "  1. 停止 Redis 服务"
                echo "  2. 配置 LD_PRELOAD 加载 libkraio.so"
                echo "     export LD_PRELOAD=/usr/lib64/libkraio.so"
                echo "  3. 重新启动 Redis"
                echo "     LD_PRELOAD=/usr/lib64/libkraio.so redis-server /path/to/redis.conf"
                echo "  或在 systemd 服务文件中配置 Environment=LD_PRELOAD=/usr/lib64/libkraio.so"
            elif [ "$PKG_INSTALLED" -gt 0 ]; then
                echo "结论: BoostKit 软件包已安装，但 KRAIO 库文件未找到"
                echo "建议: 检查 BoostKit 软件包是否完整安装，确认 libkraio.so 路径"
            else
                echo "结论: Redis 网络异步优化 (KRAIO) 未使能"
                echo "建议: 按以下步骤使能 KRAIO："
                echo "  1. 确认系统架构为 aarch64（鲲鹏平台）"
                echo "  2. 安装鲲鹏 BoostKit 数据库使能套件"
                echo "  3. 安装 KRAIO 库 (libkraio.so)"
                echo "  4. 配置 Redis 启动时加载 libkraio.so"
                echo "  5. 重启 Redis 服务"
            fi
            echo "========================================="
        } > "$output_file"
    done

    if [ "$found_redis" = true ]; then
        log_success "KRAIO 检查完成，结果已保存至 $output_file"
    else
        log_info "未发现 redis-server 进程，跳过 KRAIO 检测"
        [ -f "$output_file" ] && rm -f "$output_file"
    fi
}


# ========== os/collect_assembly_analysis.sh ==========


collect_assembly_analysis() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [[ -z "$pids" ]]; then
        log_warning "未指定进程ID，跳过汇编分析"
        return
    fi

    log_info "执行：汇编代码采集"

    if ! check_command objdump; then
        log_error "objdump 未找到，跳过汇编分析"
        return
    fi
    if ! check_command nm; then
        log_error "nm 未找到，跳过汇编分析"
        return
    fi

    local assembly_file="$output_dir/assembly_analysis.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_file="${assembly_file}.tmp"
    : > "$temp_file"

    {
        echo "============================================================"
        echo "汇编代码采集 (基于热点数据)"
        echo "采集时间: $(date)"
        echo "============================================================"
        echo ""
    } >> "$temp_file"

    local single_pid
    single_pid=$(echo "${pids%%,*}" | xargs)
    if ! ps -p "$single_pid" > /dev/null 2>&1; then
        log_warning "进程 $single_pid 不存在或已终止，跳过汇编分析"
        echo "错误: 进程 $single_pid 不存在或已终止" >> "$temp_file"
        cat "$temp_file" >> "$error_log" 2>/dev/null
        rm -f "$temp_file"
        return
    fi

    if [[ ! -r "/proc/$single_pid/maps" ]]; then
        log_warning "无法读取 /proc/$single_pid/maps，跳过汇编分析"
        echo "错误: 无法读取 /proc/$single_pid/maps" >> "$temp_file"
        cat "$temp_file" >> "$error_log" 2>/dev/null
        rm -f "$temp_file"
        return
    fi

    setup_container_env "$single_pid"

    local hotspot_src="" src_type=""
    if [[ -f "$output_dir/devkit_hotspot.txt" ]]; then
        hotspot_src="$output_dir/devkit_hotspot.txt"
        src_type="devkit"
    elif [[ -f "$output_dir/hotspot_analysis.txt" ]]; then
        hotspot_src="$output_dir/hotspot_analysis.txt"
        src_type="perf"
    else
        log_warning "未找到热点数据 (devkit_hotspot.txt / hotspot_analysis.txt)，跳过汇编分析"
        echo "错误: 未找到热点数据文件" >> "$temp_file"
        cat "$temp_file" >> "$error_log" 2>/dev/null
        rm -f "$temp_file"
        return
    fi
    log_info "热点数据源: $hotspot_src ($src_type)"
    echo "热点数据源: $hotspot_src ($src_type)" >> "$temp_file"
    echo "目标进程: $single_pid" >> "$temp_file"
    echo "" >> "$temp_file"

    declare -A seen
    local pairs=() mod func key
    if [[ "$src_type" == "devkit" ]]; then
        while read -r mod func; do
            [[ -z "$mod" || -z "$func" ]] && continue
            [[ "$mod" == "[unknown]" ]] && continue
            if [[ "$func" =~ ^(.+)[+]0x[0-9a-fA-F]+$ ]]; then
                func="${BASH_REMATCH[1]}"
            fi
            [[ "$func" =~ ^0x[0-9a-fA-F]+$ ]] && continue
            [[ -z "$func" ]] && continue
            key="$mod|$func"
            [[ -n "${seen[$key]:-}" ]] && continue
            seen[$key]=1
            pairs+=("$key")
            (( ${#pairs[@]} >= 30 )) && break
        done < <(awk '
            NF>=4 && $1!~/^-/ && $1!="function" && $2 ~ /^[0-9][0-9,]*$/ {
                print $3, $1
            }
        ' "$hotspot_src" 2>/dev/null)
    else
        while read -r mod func; do
            [[ -z "$mod" || -z "$func" ]] && continue
            [[ "$mod" == "[unknown]" ]] && continue
            if [[ "$func" =~ ^(.+)[+]0x[0-9a-fA-F]+$ ]]; then
                func="${BASH_REMATCH[1]}"
            fi
            [[ "$func" =~ ^0x[0-9a-fA-F]+$ ]] && continue
            [[ -z "$func" ]] && continue
            key="$mod|$func"
            [[ -n "${seen[$key]:-}" ]] && continue
            seen[$key]=1
            pairs+=("$key")
            (( ${#pairs[@]} >= 30 )) && break
        done < <(awk '
            $1 ~ /^[0-9.]+%$/ && $2 ~ /^[0-9.]+%$/ {
                self=$2; sub(/%/,"",self); if (self+0 == 0) next
                mod=$4
                if (mod=="" || mod=="[unknown]") next
                sym=""; found=0
                for (i=5; i<=NF; i++) {
                    if ($i=="[.]") { found=1; continue }
                    if (found) sym=(sym=="" ? $i : sym " " $i)
                }
                if (!found) next
                sub(/\r$/,"",sym)
                if (sym=="") next
                print mod, sym
            }
        ' "$hotspot_src" 2>/dev/null)
    fi

    if [[ ${#pairs[@]} -eq 0 ]]; then
        if [[ "$src_type" == "devkit" ]]; then
            log_warning "热点数据($hotspot_src)中未解析出可反汇编的函数 (devkit格式: 需含 function/count/module 非空)"
        else
            log_warning "热点数据($hotspot_src)中未解析出可反汇编的函数 (perf格式: 需5列齐全且self!=0: Children/Self/Command/SharedObject/Symbol)"
        fi
        echo "错误: 未解析出可反汇编的函数" >> "$temp_file"
        cat "$temp_file" >> "$error_log" 2>/dev/null
        rm -f "$temp_file"
        return
    fi

    log_info "解析到 ${#pairs[@]} 个热点函数，开始反汇编"

    declare -A mod_cache
    local ok_count=0
    for key in "${pairs[@]}"; do
        mod="${key%%|*}"
        func="${key#*|}"

        echo "============================================================" >> "$temp_file"
        echo "Module: $mod    Function: $func" >> "$temp_file"

        local map_info="${mod_cache[$mod]:-}"
        if [[ -z "$map_info" ]]; then
            map_info=$(awk -v mod="$mod" '
                $2 ~ /x/ && $6 ~ /\// {
                    path=$6; n=split(path, parts, "/"); base=parts[n];
                    if (base == mod) { split($1,a,"-"); print a[1], $3, path; exit }
                }
            ' /proc/$single_pid/maps 2>/dev/null)
            mod_cache[$mod]="$map_info"
        fi

        if [[ -z "$map_info" ]]; then
            echo "  映射: 未在 /proc/$single_pid/maps 中找到可执行映射 ($mod)，跳过" >> "$temp_file"
            echo "" >> "$temp_file"
            continue
        fi

        local map_start map_off module_path
        read -r map_start map_off module_path <<< "$map_info"
        if [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 && -n "$module_path" ]]; then
            local mp_host
            mp_host=$(ctr_to_host "$module_path")
            if [[ "$mp_host" != "$module_path" ]]; then
                echo "  映射路径(容器->宿主机): $module_path -> $mp_host" >> "$temp_file"
                module_path="$mp_host"
            fi
        fi
        echo "  映射路径: $module_path" >> "$temp_file"
        echo "  映射基址: 0x$map_start  文件偏移: 0x$map_off" >> "$temp_file"

        if [[ ! -r "$module_path" ]]; then
            echo "  映射文件不可读: $module_path，跳过" >> "$temp_file"
            echo "" >> "$temp_file"
            continue
        fi

        # 仅反汇编该函数符号：用 nm 定位地址(+大小)，objdump --start/--stop 限定范围，避免整库反汇编
        local sym_info=""
        sym_info=$(nm -C -S "$module_path" 2>/dev/null | awk -v f="$func" '
            $1 ~ /^[0-9a-f]+$/ {
                if ($2 ~ /^[0-9a-f]+$/) { sz=$2; nm=""; for(i=4;i<=NF;i++) nm=nm (i>4?" ":"") $i }
                else { sz=""; nm=""; for(i=3;i<=NF;i++) nm=nm (i>3?" ":"") $i }
                if (nm==f) { print $1, sz; exit }
            }
        ')
        if [[ -z "$sym_info" ]]; then
            sym_info=$(nm -C -D -S "$module_path" 2>/dev/null | awk -v f="$func" '
                $1 ~ /^[0-9a-f]+$/ {
                    if ($2 ~ /^[0-9a-f]+$/) { sz=$2; nm=""; for(i=4;i<=NF;i++) nm=nm (i>4?" ":"") $i }
                    else { sz=""; nm=""; for(i=3;i<=NF;i++) nm=nm (i>3?" ":"") $i }
                    if (nm==f) { print $1, sz; exit }
                }
            ')
        fi

        echo "  函数符号: $func" >> "$temp_file"
        if [[ -z "$sym_info" ]]; then
            echo "  (未在符号表中找到该符号，跳过反汇编)" >> "$temp_file"
            echo "" >> "$temp_file"
            continue
        fi

        local sym_addr sym_size
        read -r sym_addr sym_size <<< "$sym_info"
        echo "  符号地址: 0x$sym_addr" >> "$temp_file"

        local stop_addr
        if [[ -n "$sym_size" ]] && (( 0x$sym_size > 0 )); then
            stop_addr=$(printf '0x%x' $(( 0x$sym_addr + 0x$sym_size )))
            echo "  符号大小: 0x$sym_size  反汇编范围: 0x$sym_addr .. $stop_addr" >> "$temp_file"
        else
            stop_addr=$(printf '0x%x' $(( 0x$sym_addr + 0x1000 )))
            echo "  符号大小: 未知(默认0x1000)  反汇编范围: 0x$sym_addr .. $stop_addr" >> "$temp_file"
        fi

        local disasm_out
        disasm_out=$(objdump -d -C --start-address="0x$sym_addr" --stop-address="$stop_addr" "$module_path" 2>/dev/null | awk -v f="$func" '
            /<.*>:/ {
                if (index($0, "<"f">:") > 0) { want=1; cnt=0; print; next }
                else if (want==1) { exit }
            }
            want==1 { print; cnt++; if (cnt>500) exit }
        ')

        echo "  ------------------------------------------------------------" >> "$temp_file"
        if [[ -n "$disasm_out" ]]; then
            echo "$disasm_out" >> "$temp_file"
            ok_count=$((ok_count+1))
        else
            echo "  (未能反汇编该函数: 符号未找到或地址无效)" >> "$temp_file"
        fi
        echo "" >> "$temp_file"
    done

    echo "============================================================" >> "$temp_file"
    echo "汇编代码采集完成: 共反汇编 $ok_count/${#pairs[@]} 个函数" >> "$temp_file"
    echo "============================================================" >> "$temp_file"

    if [[ $ok_count -gt 0 ]]; then
        mv "$temp_file" "$assembly_file"
        log_success "√ 汇编代码采集完成，结果保存至: $assembly_file ($ok_count/${#pairs[@]})"
    else
        cat "$temp_file" >> "$error_log" 2>/dev/null
        rm -f "$temp_file"
        log_warning "汇编代码采集全部失败，未生成 $assembly_file"
    fi
}


# ========== os/collect_container_info.sh ==========

collect_container_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：容器资源监控采集"
    
    local CONTAINER_FILE="${output_dir}/container_info.txt"
    
    > "$CONTAINER_FILE"
    {
        echo "============================================================"
        echo "容器资源监控采集"
        echo "采集时间: $(date)"
        echo "Cgroup 版本检测中..."
        echo "============================================================"
        echo ""

        detect_cgroup_version() {
            if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
                echo "v2"
            elif [ -f "/sys/fs/cgroup/unified/cgroup.controllers" ]; then
                echo "v2_unified_mount"
            else
                echo "v1"
            fi
        }
        get_cgroup_root() {
            if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
                echo "/sys/fs/cgroup"
            elif [ -f "/sys/fs/cgroup/unified/cgroup.controllers" ]; then
                echo "/sys/fs/cgroup/unified"
            else
                echo ""
            fi
        }
        CGROUP_VER=$(detect_cgroup_version)
        CGROUP_V2_ROOT=$(get_cgroup_root)
        echo "Cgroup 版本: $CGROUP_VER"
        [ -n "$CGROUP_V2_ROOT" ] && echo "Cgroup v2 根: $CGROUP_V2_ROOT"
        echo ""

        extract_container_id() {
            local basename="$1"
            local name="${basename%.scope}"
            if [[ "$name" == docker-* ]]; then
                name="${name#docker-}"
            elif [[ "$name" == containerd-* ]]; then
                name="${name#containerd-}"
            elif [[ "$name" == cri-containerd-* ]]; then
                name="${name#cri-containerd-}"
            elif [[ "$name" == libpod-* ]]; then
                name="${name#libpod-}"
            fi
            [ -n "$name" ] && echo "$name" || echo "$basename"
        }

        get_cgroup_path() {
            local subsys="$1"
            local cid="$2"
            local path
            if [ -n "$CGROUP_V2_ROOT" ]; then
                for scope_dir in \
                    "${CGROUP_V2_ROOT}/system.slice/${cid}" \
                    "${CGROUP_V2_ROOT}/kubepods.slice"/*/"${cid}"; do
                    if [ -d "$scope_dir" ]; then
                        echo "$scope_dir"
                        return 0
                    fi
                done
                while IFS= read -r d; do
                    if [ -d "$d" ] && [ "$(basename "$d")" = "$cid" ]; then
                        echo "$d"
                        return 0
                    fi
                done < <(find "${CGROUP_V2_ROOT}/kubepods.slice" -type d -name "$cid" 2>/dev/null)
                return 0
            fi
            local base="/sys/fs/cgroup/${subsys}"
            [ -d "$base" ] || return 0
            for path in \
                "${base}/docker/${cid}" \
                "${base}/system.slice/${cid}" \
                "${base}/kubepods/${cid}" \
                "${base}/kubepods.slice/${cid}" \
                "${base}/kubepods.slice/"*"/${cid}"; do
                if [ -d "$path" ]; then
                    echo "$path"
                    return 0
                fi
            done
            if [ -d "${base}/kubepods" ]; then
                while IFS= read -r d; do
                    if [ -d "$d" ] && [ "$(basename "$d")" = "$cid" ]; then
                        echo "$d"
                        return 0
                    fi
                done < <(find "${base}/kubepods" -mindepth 2 -maxdepth 4 -type d -name "$cid" 2>/dev/null)
            fi
            return 0
        }

        echo "=== 容器发现 ==="
        CONTAINER_IDS=()
        discover_containers() {
            local cids=()
            if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                local base="$CGROUP_V2_ROOT"
                for scope in "$base"/system.slice/docker-*.scope \
                             "$base"/system.slice/containerd-*.scope \
                             "$base"/system.slice/libpod-*.scope; do
                    [ -d "$scope" ] || continue
                    cids+=("$(basename "$scope")")
                done
                while IFS= read -r d; do
                    [ -d "$d" ] || continue
                    cids+=("$(basename "$d")")
                done < <(find "$base/kubepods.slice" -name "*.scope" -type d 2>/dev/null)
            else
                for subsys in cpu blkio memory; do
                    local base="/sys/fs/cgroup/$subsys"
                    [ -d "$base" ] || continue
                    if [ -d "$base/docker" ]; then
                        for d in "$base/docker"/*/; do
                            [ -d "$d" ] || continue
                            cids+=("$(basename "$d")")
                        done
                    fi
                    for scope in "$base"/system.slice/docker-*.scope \
                                 "$base"/system.slice/containerd-*.scope \
                                 "$base"/system.slice/libpod-*.scope; do
                        [ -d "$scope" ] || continue
                        cids+=("$(basename "$scope")")
                    done
                    if [ -d "$base/kubepods" ]; then
                        while IFS= read -r d; do
                            [ -d "$d" ] || continue
                            cids+=("$(basename "$d")")
                        done < <(find "$base/kubepods" -mindepth 2 -maxdepth 4 -type d 2>/dev/null)
                    fi
                    for scope in "$base"/kubepods.slice/*.slice/*.scope \
                                 "$base"/kubepods.slice/*.scope; do
                        [ -d "$scope" ] || continue
                        cids+=("$(basename "$scope")")
                    done
                done
            fi
            printf '%s\n' "${cids[@]}" | sort -u
        }

        while IFS= read -r cid; do
            [ -n "$cid" ] && CONTAINER_IDS+=("$cid")
        done < <(discover_containers)

        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            docker_ids=$(docker ps --no-trunc -q 2>/dev/null || true)
            for dcid in $docker_ids; do
                FOUND=0
                for cid in "${CONTAINER_IDS[@]}"; do
                    pure_cid=$(extract_container_id "$cid")
                    if [ "$pure_cid" = "$dcid" ]; then
                        FOUND=1
                        break
                    fi
                done
                if [ "$FOUND" -eq 0 ]; then
                    possible_scope="docker-${dcid}.scope"
                    path_found=0
                    for subsys in cpu memory blkio; do
                        if [ -d "/sys/fs/cgroup/${subsys}/system.slice/${possible_scope}" ] || \
                           [ -d "/sys/fs/cgroup/${subsys}/docker/${dcid}" ]; then
                            path_found=1
                            break
                        fi
                    done
                    if [ "$path_found" -eq 0 ] && [ -n "$CGROUP_V2_ROOT" ]; then
                        if [ -d "${CGROUP_V2_ROOT}/system.slice/${possible_scope}" ]; then
                            path_found=1
                        fi
                    fi
                    CONTAINER_IDS+=("$possible_scope")
                fi
            done
        fi

        if [ ${#CONTAINER_IDS[@]} -gt 0 ]; then
            echo "发现 ${#CONTAINER_IDS[@]} 个容器"
            printf '%s\n' "${CONTAINER_IDS[@]}"
        else
            echo "未发现运行中的容器"
        fi
        echo ""

        echo "## 宿主机 /proc/stat (cpu 行)"
        cat /proc/stat | grep '^cpu '
        echo ""

        for CID in "${CONTAINER_IDS[@]}"; do
            echo "===== 容器: $CID ====="
            PURE_ID=$(extract_container_id "$CID")
            [ "$PURE_ID" != "$CID" ] && echo "（纯容器 ID: $PURE_ID）"

            CGROUP_CPU_PATH=$(get_cgroup_path cpu "$CID")
            CGROUP_MEM_PATH=$(get_cgroup_path memory "$CID")
            CGROUP_BLKIO_PATH=$(get_cgroup_path blkio "$CID")
            CGROUP_CPUSET_PATH=$(get_cgroup_path cpuset "$CID")
            CGROUP_CPUACCT_PATH=$(get_cgroup_path cpuacct "$CID")

            if [ -n "$CGROUP_CPU_PATH" ]; then
                echo "## CPU 限额"
                if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                    if [ -f "$CGROUP_CPU_PATH/cpu.max" ]; then
                        read max period < "$CGROUP_CPU_PATH/cpu.max"
                        echo "  cpu.max = $max $period"
                        if [ "$max" != "max" ] && [ "$period" -gt 0 ] 2>/dev/null; then
                            cpus=$(awk -v m="$max" -v p="$period" 'BEGIN { printf "%.2f", m/p }')
                            echo "  可用 CPU 数: $cpus"
                        else
                            echo "  可用 CPU 数: 无限制"
                        fi
                    fi
                    [ -f "$CGROUP_CPU_PATH/cpu.weight" ] && echo "  cpu.weight = $(cat "$CGROUP_CPU_PATH/cpu.weight")"
                else
                    for f in cpu.cfs_period_us cpu.cfs_quota_us cpu.cfs_burst_us cpu.shares cpu.stat; do
                        [ -f "$CGROUP_CPU_PATH/$f" ] && echo "  $f = $(cat "$CGROUP_CPU_PATH/$f")"
                    done
                    [ -f "$CGROUP_CPU_PATH/cpu.soft_domain" ] && echo "  cpu.soft_domain = $(cat "$CGROUP_CPU_PATH/cpu.soft_domain")"
                    if [ -f "$CGROUP_CPU_PATH/cpu.cfs_period_us" ] && [ -f "$CGROUP_CPU_PATH/cpu.cfs_quota_us" ]; then
                        period=$(cat "$CGROUP_CPU_PATH/cpu.cfs_period_us")
                        quota=$(cat "$CGROUP_CPU_PATH/cpu.cfs_quota_us")
                        if [ "$quota" -gt 0 ] 2>/dev/null; then
                            cpus=$(awk -v q="$quota" -v p="$period" 'BEGIN { if (p>0) printf "%.2f", q/p; else print "无限制" }')
                            echo "  可用 CPU 数: $cpus"
                        else
                            echo "  可用 CPU 数: 无限制 (quota=-1)"
                        fi
                    fi
                fi
            else
                echo "## CPU 限额 — 未找到 cgroup 路径"
            fi
            echo ""

            if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                if [ -n "$CGROUP_CPU_PATH" ] && [ -f "$CGROUP_CPU_PATH/cpu.stat" ]; then
                    echo "## CPU 累计使用 (cpu.stat)"
                    usage_usec=$(awk '/^usage_usec /{print $2}' "$CGROUP_CPU_PATH/cpu.stat" 2>/dev/null || true)
                    if [ -n "$usage_usec" ]; then
                        usage_ns=$(( usage_usec * 1000 ))
                        usage_s=$(awk -v ns="$usage_ns" 'BEGIN { printf "%.3f", ns/1000000000 }')
                        echo "  usage_usec = $usage_usec us  (≈ $usage_s s)"
                    fi
                    cat "$CGROUP_CPU_PATH/cpu.stat" 2>/dev/null || true
                fi
            else
                if [ -n "$CGROUP_CPUACCT_PATH" ]; then
                    echo "## CPU 累计使用 (cpuacct)"
                    if [ -f "$CGROUP_CPUACCT_PATH/cpuacct.usage" ]; then
                        USAGE_NS=$(cat "$CGROUP_CPUACCT_PATH/cpuacct.usage" 2>/dev/null || echo 0)
                        USAGE_S=$(awk -v ns="$USAGE_NS" 'BEGIN { printf "%.3f", ns/1000000000 }')
                        echo "  cpuacct.usage = $USAGE_NS ns ($USAGE_S s)"
                    fi
                    [ -f "$CGROUP_CPUACCT_PATH/cpuacct.usage_percpu" ] && echo "  usage_percpu (ns): $(cat "$CGROUP_CPUACCT_PATH/cpuacct.usage_percpu")"
                fi
            fi
            echo ""

            if [ -n "$CGROUP_CPUSET_PATH" ]; then
                echo "## NUMA/CPU 亲和性"
                if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                    for f in cpuset.cpus cpuset.mems cpuset.cpus.effective cpuset.mems.effective; do
                        [ -f "$CGROUP_CPUSET_PATH/$f" ] && echo "  $f = $(cat "$CGROUP_CPUSET_PATH/$f")"
                    done
                else
                    for f in cpuset.cpus cpuset.mems cpuset.cpu_exclusive cpuset.mem_exclusive cpuset.memory_migrate cpuset.sched_relax_domain_level; do
                        [ -f "$CGROUP_CPUSET_PATH/$f" ] && echo "  $f = $(cat "$CGROUP_CPUSET_PATH/$f")"
                    done
                fi
            fi
            echo ""

            if [ -n "$CGROUP_MEM_PATH" ]; then
                echo "## 内存配置与使用"
                if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                    [ -f "$CGROUP_MEM_PATH/memory.max" ] && echo "  memory.max = $(cat "$CGROUP_MEM_PATH/memory.max")"
                    if [ -f "$CGROUP_MEM_PATH/memory.current" ]; then
                        usage=$(cat "$CGROUP_MEM_PATH/memory.current")
                        echo "  memory.current = $usage"
                        limit=$(cat "$CGROUP_MEM_PATH/memory.max" 2>/dev/null || echo "max")
                        if [ "$limit" != "max" ] && [ "$limit" -gt 0 ] 2>/dev/null; then
                            LIMIT_GB=$(awk -v l="$limit" 'BEGIN { printf "%.2f", l/1073741824 }')
                            USAGE_GB=$(awk -v u="$usage" 'BEGIN { printf "%.2f", u/1073741824 }')
                            echo "  内存限额: $LIMIT_GB GB, 使用: $USAGE_GB GB"
                        else
                            echo "  内存限额: 无限制"
                        fi
                    fi
                    [ -f "$CGROUP_MEM_PATH/memory.stat" ] && { echo "  memory.stat (前5行):"; head -5 "$CGROUP_MEM_PATH/memory.stat"; }
                else
                    for f in memory.limit_in_bytes memory.usage_in_bytes memory.max_usage_in_bytes memory.stat memory.kmem.usage_in_bytes memory.kmem.limit_in_bytes memory.oom_control; do
                        [ -f "$CGROUP_MEM_PATH/$f" ] && echo "  $f = $(cat "$CGROUP_MEM_PATH/$f" | head -5)"
                    done
                    if [ -f "$CGROUP_MEM_PATH/memory.limit_in_bytes" ] && [ -f "$CGROUP_MEM_PATH/memory.usage_in_bytes" ]; then
                        LIMIT=$(cat "$CGROUP_MEM_PATH/memory.limit_in_bytes")
                        USAGE=$(cat "$CGROUP_MEM_PATH/memory.usage_in_bytes")
                        if [ "$LIMIT" -gt 0 ] 2>/dev/null && [ "$LIMIT" != "9223372036854771712" ]; then
                            LIMIT_GB=$(awk -v l="$LIMIT" 'BEGIN { printf "%.2f", l/1073741824 }')
                            USAGE_GB=$(awk -v u="$USAGE" 'BEGIN { printf "%.2f", u/1073741824 }')
                            echo "  内存限额: $LIMIT_GB GB, 使用: $USAGE_GB GB"
                        else
                            echo "  内存限额: 无限制"
                        fi
                    fi
                fi
            fi
            echo ""

            if [ -n "$CGROUP_BLKIO_PATH" ]; then
                echo "## blkio 限速"
                if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                    [ -f "$CGROUP_BLKIO_PATH/io.max" ] && echo "  io.max = $(cat "$CGROUP_BLKIO_PATH/io.max")"
                else
                    for f in blkio.throttle.read_bps_device blkio.throttle.write_bps_device blkio.throttle.read_iops_device blkio.throttle.write_iops_device blkio.io_service_bytes blkio.io_serviced blkio.weight; do
                        [ -f "$CGROUP_BLKIO_PATH/$f" ] && echo "  $f = $(cat "$CGROUP_BLKIO_PATH/$f" | head -5)"
                    done
                fi
            fi
            echo ""

            if [ -n "$CGROUP_CPU_PATH" ]; then
                tasks_file=""
                [ -f "$CGROUP_CPU_PATH/cgroup.threads" ] && tasks_file="$CGROUP_CPU_PATH/cgroup.threads"
                [ -z "$tasks_file" ] && [ -f "$CGROUP_CPU_PATH/tasks" ] && tasks_file="$CGROUP_CPU_PATH/tasks"
                if [ -n "$tasks_file" ]; then
                    TASK_COUNT=$(wc -l < "$tasks_file" 2>/dev/null || echo 0)
                    echo "## 任务列表"
                    echo "  线程总数: $TASK_COUNT"
                    echo "  前20个TID映射:"
                    head -20 "$tasks_file" 2>/dev/null | while read tid; do
                        comm=$(cat "/proc/$tid/comm" 2>/dev/null || echo "?")
                        tpid=$(awk '/^Tgid:/{print $2}' "/proc/$tid/status" 2>/dev/null || echo "?")
                        echo "    TID=$tid COMM=$comm PID=$tpid"
                    done || true
                fi
            fi
            echo ""
        done

        if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
            echo "## Docker Daemon 信息"
            docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup Driver|Cgroup Version|Total Memory|Operating System" || true
            echo ""
            for CID in "${CONTAINER_IDS[@]}"; do
                PURE_ID=$(extract_container_id "$CID")
                echo "## 容器元数据 (ID: $PURE_ID)"
                if docker inspect "$PURE_ID" >/dev/null 2>&1; then
                    docker inspect "$PURE_ID" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)[0]
name = data.get('Name', '?').lstrip('/')
s = data.get('State', {})
print(f'Name: {name}')
print(f'Image: {data.get(\"Config\", {}).get(\"Image\", \"?\")}')
print(f'Status: {s.get(\"Status\", \"?\")}')
hc = data.get('HostConfig', {})
print(f'CpuQuota: {hc.get(\"CpuQuota\", \"N/A\")}')
print(f'CpuPeriod: {hc.get(\"CpuPeriod\", \"N/A\")}')
print(f'CpuShares: {hc.get(\"CpuShares\", \"N/A\")}')
print(f'NanoCpus: {hc.get(\"NanoCpus\", \"N/A\")}')
print(f'CpusetCpus: {hc.get(\"CpusetCpus\", \"N/A\")}')
print(f'Memory: {hc.get(\"Memory\", \"N/A\")}')
" || {
                        echo "python 解析失败"
                        docker inspect "$PURE_ID" >> "$CONTAINER_FILE" 2>/dev/null || true
                    }
                fi
                echo ""
            done
        fi

        if [ ${#CONTAINER_IDS[@]} -gt 0 ]; then
            OBS_WINDOW=${duration:-10}
            SAMP_INT=2
            NUM_SAMPLES=$(( OBS_WINDOW / SAMP_INT + 1 ))
            [ "$NUM_SAMPLES" -lt 2 ] && NUM_SAMPLES=2

            echo "## 容器 CPU 多采样观测 (${OBS_WINDOW}s, ${SAMP_INT}s 间隔)"
            for ((i=1; i<=NUM_SAMPLES; i++)); do
                TS_EPOCH=$(date +%s.%N)
                echo "=== SAMPLE $i ==="
                echo "=== TIMESTAMP $TS_EPOCH ==="
                for CID in "${CONTAINER_IDS[@]}"; do
                    CGROUP_CPU_PATH=$(get_cgroup_path cpu "$CID")
                    if [ "$CGROUP_VER" = "v2" ] || [ "$CGROUP_VER" = "v2_unified_mount" ]; then
                        USAGE_NS="0"
                        PERIOD_US="0"
                        QUOTA_US="0"
                        SOFT_QUOTA=0
                        if [ -n "$CGROUP_CPU_PATH" ]; then
                            if [ -f "$CGROUP_CPU_PATH/cpu.max" ]; then
                                read max period < "$CGROUP_CPU_PATH/cpu.max" 2>/dev/null || true
                                PERIOD_US="$period"
                                QUOTA_US="$max"
                                if [ "$max" != "max" ] && [ "$period" -gt 0 ] 2>/dev/null; then
                                    if [ -f "$CGROUP_CPU_PATH/cpu.max.burst" ]; then
                                        BURST_US=$(cat "$CGROUP_CPU_PATH/cpu.max.burst" 2>/dev/null || echo 0)
                                        [ -n "$BURST_US" ] && [ "$BURST_US" -gt 0 ] 2>/dev/null && SOFT_QUOTA=1
                                    fi
                                fi
                            fi
                            if [ -f "$CGROUP_CPU_PATH/cpu.stat" ]; then
                                usec=$(awk '/^usage_usec /{print $2}' "$CGROUP_CPU_PATH/cpu.stat" 2>/dev/null || echo 0)
                                [ -n "$usec" ] && USAGE_NS=$(( usec * 1000 ))
                            fi
                        fi
                    else
                        CGROUP_CPUACCT_PATH=$(get_cgroup_path cpuacct "$CID")
                        PERIOD_US=""
                        QUOTA_US=""
                        USAGE_NS=""
                        SOFT_QUOTA=0
                        if [ -n "$CGROUP_CPU_PATH" ]; then
                            [ -f "$CGROUP_CPU_PATH/cpu.cfs_period_us" ] && PERIOD_US=$(cat "$CGROUP_CPU_PATH/cpu.cfs_period_us")
                            [ -f "$CGROUP_CPU_PATH/cpu.cfs_quota_us" ] && QUOTA_US=$(cat "$CGROUP_CPU_PATH/cpu.cfs_quota_us")
                            if [ -f "$CGROUP_CPU_PATH/cpu.soft_quota" ]; then
                                SOFT_QUOTA=$(cat "$CGROUP_CPU_PATH/cpu.soft_quota")
                            elif [ -f "$CGROUP_CPU_PATH/cpu.cfs_burst_us" ]; then
                                BURST_US=$(cat "$CGROUP_CPU_PATH/cpu.cfs_burst_us" 2>/dev/null || echo 0)
                                [ -n "$BURST_US" ] && [ "$BURST_US" -gt 0 ] 2>/dev/null && SOFT_QUOTA=1
                            fi
                        fi
                        if [ -n "$CGROUP_CPUACCT_PATH" ] && [ -f "$CGROUP_CPUACCT_PATH/cpuacct.usage" ]; then
                            USAGE_NS=$(cat "$CGROUP_CPUACCT_PATH/cpuacct.usage" 2>/dev/null || echo 0)
                        fi
                    fi
                    echo "--- CONTAINER ---"
                    echo "id=$CID"
                    echo "cfs_period_us=${PERIOD_US:-0}"
                    echo "cfs_quota_us=${QUOTA_US:-0}"
                    echo "cpuacct_usage=${USAGE_NS:-0}"
                    echo "soft_quota=$SOFT_QUOTA"
                    echo "timestamp=$TS_EPOCH"
                    echo "--- END CONTAINER ---"
                done
                echo ""
                if [ "$i" -lt "$NUM_SAMPLES" ]; then
                    sleep "$SAMP_INT"
                fi
            done
        fi
    } >> "$CONTAINER_FILE"

    log_success "容器资源监控采集完成"
}


# ========== os/collect_cpu_detail_info.sh ==========

collect_cpu_detail_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：CPU 深度信息采集"
    
    local CPU_DETAIL_FILE="${output_dir}/cpu_detail_info.txt"
    
    > "$CPU_DETAIL_FILE"
    echo "============================================================" >> "$CPU_DETAIL_FILE"
    echo "CPU 深度信息采集" >> "$CPU_DETAIL_FILE"
    echo "采集时间: $(date)" >> "$CPU_DETAIL_FILE"
    echo "============================================================" >> "$CPU_DETAIL_FILE"
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== 在线 CPU 核心列表 ===" >> "$CPU_DETAIL_FILE"
    if [ -f /sys/devices/system/cpu/online ]; then
        echo "CPU 在线列表: $(cat /sys/devices/system/cpu/online)" >> "$CPU_DETAIL_FILE"
        COUNT=$(tr ',' '\n' < /sys/devices/system/cpu/online | while read -r r; do
            if [[ "$r" == *-* ]]; then
                seq "${r%-*}" "${r#*-}" || true
            else
                echo "$r"
            fi
        done | wc -l)
        echo "在线CPU数量: $COUNT" >> "$CPU_DETAIL_FILE"
    else
        echo "警告: /sys/devices/system/cpu/online 不存在" >> "$CPU_DETAIL_FILE"
        echo "在线CPU数量: $(nproc)" >> "$CPU_DETAIL_FILE"
    fi
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== /proc/cpuinfo ===" >> "$CPU_DETAIL_FILE"
    cat /proc/cpuinfo >> "$CPU_DETAIL_FILE" 2>/dev/null || true
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== NUMA 节点 sysfs 详情 ===" >> "$CPU_DETAIL_FILE"
    if [ -d /sys/devices/system/node ]; then
        for node in /sys/devices/system/node/node*; do
            if [ -d "$node" ]; then
                node_name=$(basename "$node")
                echo "--- $node_name ---" >> "$CPU_DETAIL_FILE"
                [ -f "$node/cpulist" ] && echo "CPU列表: $(cat "$node/cpulist")" >> "$CPU_DETAIL_FILE"
                [ -f "$node/distance" ] && echo "距离: $(cat "$node/distance")" >> "$CPU_DETAIL_FILE"
            fi
        done
        echo "" >> "$CPU_DETAIL_FILE"
        for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
            cpu_name=$(basename "$cpu_dir")
            if [ -f "$cpu_dir/topology/physical_package_id" ]; then
                socket_id=$(cat "$cpu_dir/topology/physical_package_id" 2>/dev/null || echo '?')
                echo "$cpu_name socket=$socket_id" >> "$CPU_DETAIL_FILE"
            fi
        done
    else
        echo "警告: /sys/devices/system/node 不存在" >> "$CPU_DETAIL_FILE"
    fi
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== SMT 超线程状态 ===" >> "$CPU_DETAIL_FILE"
    if [ -f /sys/devices/system/cpu/smt/active ]; then
        echo "SMT active: $(cat /sys/devices/system/cpu/smt/active)" >> "$CPU_DETAIL_FILE"
    else
        echo "SMT active: unknown" >> "$CPU_DETAIL_FILE"
    fi
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_name=$(basename "$cpu_dir")
        if [ -f "$cpu_dir/topology/thread_siblings_list" ]; then
            siblings=$(cat "$cpu_dir/topology/thread_siblings_list" 2>/dev/null || echo '?')
            echo "$cpu_name siblings=$siblings" >> "$CPU_DETAIL_FILE"
        fi
    done
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== CPU 频率信息 ===" >> "$CPU_DETAIL_FILE"
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
            if [ -d "$cpu" ]; then
                cpu_name=$(basename "$(dirname "$cpu")")
                echo "$cpu_name:" >> "$CPU_DETAIL_FILE"
                cat "$cpu/scaling_cur_freq" 2>/dev/null | awk '{printf "  当前频率: %s kHz\n", $1}' >> "$CPU_DETAIL_FILE" || true
                cat "$cpu/scaling_max_freq" 2>/dev/null | awk '{printf "  最大频率: %s kHz\n", $1}' >> "$CPU_DETAIL_FILE" || true
                cat "$cpu/cpuinfo_max_freq" 2>/dev/null | awk '{printf "  硬件最大频率: %s kHz\n", $1}' >> "$CPU_DETAIL_FILE" || true
                cat "$cpu/scaling_min_freq" 2>/dev/null | awk '{printf "  最小频率: %s kHz\n", $1}' >> "$CPU_DETAIL_FILE" || true
                cat "$cpu/scaling_governor" 2>/dev/null | awk '{printf "  调频策略: %s\n", $1}' >> "$CPU_DETAIL_FILE" || true
            fi
        done
    else
        echo "注意: cpufreq 不可用" >> "$CPU_DETAIL_FILE"
    fi
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== 硬件 CPPC 支持 ===" >> "$CPU_DETAIL_FILE"
    if grep -qi "cppc" /proc/cpuinfo 2>/dev/null; then
        echo "yes" >> "$CPU_DETAIL_FILE"
    else
        echo "no" >> "$CPU_DETAIL_FILE"
    fi
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== /proc/interrupts ===" >> "$CPU_DETAIL_FILE"
    head -20 /proc/interrupts >> "$CPU_DETAIL_FILE" 2>/dev/null || true
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== /proc/stat 解析 ===" >> "$CPU_DETAIL_FILE"
    awk '/cpu[0-9]+/ {
        cpu=$1; gsub(/cpu/,"",cpu);
        printf "cpu%-3d user=%-10s nice=%-10s system=%-10s idle=%-10s iowait=%-10s irq=%-8s softirq=%-8s steal=%-8s\n",cpu,$2,$3,$4,$5,$6,$7,$8,$9
    }
    /^cpu / {
        printf "cpu_total user=%-10s nice=%-10s system=%-10s idle=%-10s iowait=%-10s irq=%-8s softirq=%-8s steal=%-8s\n",$2,$3,$4,$5,$6,$7,$8,$9
    }' /proc/stat >> "$CPU_DETAIL_FILE" || true
    echo "" >> "$CPU_DETAIL_FILE"

    echo "=== /proc/stat 多采样观测 (${duration}秒) ===" >> "$CPU_DETAIL_FILE"
    NUM_SAMPLES=$(( duration / 1 + 1 ))
    [ "$NUM_SAMPLES" -lt 2 ] && NUM_SAMPLES=2
    for ((i=1; i<=NUM_SAMPLES; i++)); do
        TS_EPOCH=$(date +%s.%N)
        {
            echo "=== SAMPLE $i ==="
            echo "=== TIMESTAMP $TS_EPOCH ==="
            echo "=== HOST_STAT ==="
            grep '^cpu ' /proc/stat
            echo "=== END_HOST_STAT ==="
            echo ""
        } >> "$CPU_DETAIL_FILE"
        if [ "$i" -lt "$NUM_SAMPLES" ]; then
            sleep 1
        fi
    done
    echo "总轮次: $NUM_SAMPLES" >> "$CPU_DETAIL_FILE"
    echo "" >> "$CPU_DETAIL_FILE"

    log_success "CPU 深度信息采集完成"
}


# ========== os/collect_global_bottleneck.sh ==========

collect_global_bottleneck() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：全局资源瓶颈识别"

    bottleneck_success=false

    temp_bottleneck_file="${output_dir}/global_bottleneck.txt.tmp"

    echo "============================================================" > "$temp_bottleneck_file"
    echo "Phase 2.1: Global Resource Bottleneck Identification" >> "$temp_bottleneck_file"
    echo "============================================================" >> "$temp_bottleneck_file"
    echo "" >> "$temp_bottleneck_file"

    echo "========== CPU Bottleneck Indicators ==========" >> "$temp_bottleneck_file"

    if command -v mpstat &> /dev/null; then
        echo "--- CPU Utilization Per Core (5s sample, skip 100% idle) ---" >> "$temp_bottleneck_file"
        mpstat -P ALL 1 5 2>/dev/null | grep 'Average' | awk 'NR==1 || $3=="all" || $NF != "100.00"' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "--- CPU Utilization Per Core: mpstat not available (install sysstat) ---" >> "$temp_bottleneck_file"
        log_warning "mpstat not available, CPU utilization info skipped"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Load Average vs CPU Count ---" >> "$temp_bottleneck_file"
    if [ -r /proc/loadavg ]; then
        cat /proc/loadavg >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "Cannot read /proc/loadavg" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Context Switches and Interrupts (5s interval) ---" >> "$temp_bottleneck_file"
    if command -v vmstat &> /dev/null; then
        vmstat 5 2 2>/dev/null | awk 'NR<=2{print; next} NR==3{next} {print; exit}' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "vmstat not available" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Top 30 Context Switch Tasks (by cswch/s) ---" >> "$temp_bottleneck_file"
    if command -v pidstat &> /dev/null; then
        {
            echo "      UID       PID   cswch/s nvcswch/s  Command"
            pidstat -w 1 5 2>/dev/null | grep 'Average' | grep -v "UID" | sort -k4 -rn | head -30
        } >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "pidstat not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "========== Memory Bottleneck Indicators ==========" >> "$temp_bottleneck_file"

    echo "--- Swap Usage and Pressure ---" >> "$temp_bottleneck_file"
    if command -v free &> /dev/null; then
        free -h >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "free not available" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Key Swap Metrics ---" >> "$temp_bottleneck_file"
    if [ -r /proc/meminfo ]; then
        cat /proc/meminfo | grep -E "SwapTotal|SwapFree|SwapCached|CommitLimit|Committed_AS" >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "Cannot read /proc/meminfo" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Page Faults - Top 20 by majflt/s ---" >> "$temp_bottleneck_file"
    if command -v pidstat &> /dev/null; then
        {
            echo "      UID       PID  minflt/s  majflt/s     VSZ     RSS   %MEM  Command"
            pidstat -r 1 5 2>/dev/null | grep 'Average' | grep -v "UID" | sort -k5 -rn | head -20
        } >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "pidstat not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Slab Memory Usage ---" >> "$temp_bottleneck_file"
    if [ -r /proc/meminfo ]; then
        cat /proc/meminfo | grep -E "Slab|SReclaimable|SUnreclaim" >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "Cannot read /proc/meminfo" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "========== I/O Bottleneck Indicators ==========" >> "$temp_bottleneck_file"

    echo "--- Disk Utilization (5s sample, skip 0% util) ---" >> "$temp_bottleneck_file"
    if command -v iostat &> /dev/null; then
        iostat -xz 5 2 2>/dev/null | awk '/^avg-cpu/{report++; if(report==2) print; next} /^Device/{if(report==2) print; next} /^$/{next} /Linux/{next} report==2 {if(/^[[:space:]]*[0-9]/){print; next} if(/^[a-z]/ && $NF+0>0){print; next}}' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "iostat not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Queue Depth (inflight_IO, instantaneous) ---" >> "$temp_bottleneck_file"
    if [ -r /proc/diskstats ]; then
        echo "major minor device inflight_IO" >> "$temp_bottleneck_file"
        cat /proc/diskstats | awk '{print $1, $2, $3, $12}' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "Cannot read /proc/diskstats" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- df -h ---" >> "$temp_bottleneck_file"
    df -h >> "$temp_bottleneck_file" 2>/dev/null

    echo "" >> "$temp_bottleneck_file"
    echo "--- Top 20 I/O Processes by kB_wr/s ---" >> "$temp_bottleneck_file"
    if command -v pidstat &> /dev/null; then
        {
            echo "      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command"
            pidstat -d 1 5 2>/dev/null | grep 'Average' | grep -v "UID" | sort -k5 -rn | head -20
        } >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "pidstat not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "========== Network Bottleneck Indicators ==========" >> "$temp_bottleneck_file"

    echo "--- Network Interface Stats (5s sample, skip idle) ---" >> "$temp_bottleneck_file"
    if command -v sar &> /dev/null; then
        sar -n DEV 1 5 2>/dev/null | grep 'Average' | awk 'NR==1 || $5+0>0 || $6+0>0' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "sar not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Network Error Stats (skip all-zero errors) ---" >> "$temp_bottleneck_file"
    if command -v sar &> /dev/null; then
        sar -n EDEV 1 5 2>/dev/null | grep 'Average' | awk 'NR==1{print; next} {for(i=3;i<=NF;i++) if($i+0>0){print; next}}' >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "sar not available (install sysstat)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- TCP Retransmissions and Drops (5s two-snapshot delta) ---" >> "$temp_bottleneck_file"
    if command -v nstat &> /dev/null; then
        nstat -az 2>/dev/null | grep -E "^(TcpOutSegs|TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtListenOverflows|TcpExtListenDrops)" | awk '{print $1,$2}' > /tmp/nstat_before.txt
        sleep 5
        nstat -az 2>/dev/null | grep -E "^(TcpOutSegs|TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtListenOverflows|TcpExtListenDrops)" | awk '{print $1,$2}' > /tmp/nstat_after.txt
        if [ -s /tmp/nstat_before.txt ] && [ -s /tmp/nstat_after.txt ]; then
            echo "counter delta rate/s" >> "$temp_bottleneck_file"
            join /tmp/nstat_before.txt /tmp/nstat_after.txt | awk -v s=5 '{printf "%-40s %8d %8.1f\n", $1, $3-$2, ($3-$2)/s}' >> "$temp_bottleneck_file"
            bottleneck_success=true
        else
            echo "nstat: insufficient data collected" >> "$temp_bottleneck_file"
        fi
        rm -f /tmp/nstat_before.txt /tmp/nstat_after.txt
    else
        echo "nstat not available (install iproute2)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Connection Backlog ---" >> "$temp_bottleneck_file"
    if command -v ss &> /dev/null; then
        echo "TIME_WAIT connections:" >> "$temp_bottleneck_file"
        ss -tan state time-wait 2>/dev/null | wc -l >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "ss not available (install iproute2)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"

    echo "--- Top 10 Ports by Established Connections ---" >> "$temp_bottleneck_file"
    if command -v ss &> /dev/null; then
        {
            echo "count port"
            ss -tn state established 2>/dev/null | awk '{print $4}' | awk -F: '{print $NF}' | sort | uniq -c | sort -rn | head -10
        } >> "$temp_bottleneck_file"
        bottleneck_success=true
    else
        echo "ss not available (install iproute2)" >> "$temp_bottleneck_file"
    fi

    echo "" >> "$temp_bottleneck_file"
    echo "============================================================" >> "$temp_bottleneck_file"
    echo "Phase 2.1: Global Resource Bottleneck Identification Complete" >> "$temp_bottleneck_file"
    echo "============================================================" >> "$temp_bottleneck_file"

    if [ "$bottleneck_success" = true ]; then
        mv "$temp_bottleneck_file" "$output_dir/global_bottleneck.txt"
        log_success "√ 全局资源瓶颈识别完成，结果保存至: $output_dir/global_bottleneck.txt"
    else
        rm -f "$temp_bottleneck_file"
        log_warning "全局资源瓶颈识别全部失败，未生成 $output_dir/global_bottleneck.txt"
    fi
}


# ========== os/collect_hotspot_analysis.sh ==========

collect_hotspot_analysis() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [[ -f "$output_dir/devkit_hotspot.txt" ]]; then
        log_info "检测到 devkit hotspot 已成功采集，跳过热点函数分析 (避免重复采集)"
        return 0
    fi

    if [[ -z "$pids" ]]; then
        log_warning "未指定进程，跳过热点函数分析"
        return
    fi

    hotspot_analysis_success=false

    IFS=',' read -ra pid_array <<< "$pids"
    for single_pid in "${pid_array[@]}"; do
        single_pid=$(echo "$single_pid" | xargs)

        log_info "执行：热点函数分析 (PID=$single_pid)"

        temp_hotspot_file="${output_dir}/hotspot_analysis.txt.tmp.${single_pid}"

        echo "============================================================" > "$temp_hotspot_file"
        echo "Phase 3.1: Hotspot Function Analysis (PID=$single_pid)" >> "$temp_hotspot_file"
        echo "============================================================" >> "$temp_hotspot_file"
        echo "" >> "$temp_hotspot_file"

        if ! check_command perf; then
            echo "错误: perf命令未找到，跳过热点函数分析" >> "$temp_hotspot_file"
            log_error "perf命令未找到"

            cat "$temp_hotspot_file" >> "$output_dir/err_log.txt"

            rm -f "$temp_hotspot_file"
            return
        fi

        local perf_success=false
        local perf_data_file="/tmp/perf_phase3_${single_pid}.data"
        local perf_fg_file="/tmp/perf_phase3_${single_pid}_fg.data"

        echo "--- perf record (30s sampling) ---" >> "$temp_hotspot_file"
        echo "执行命令: perf record -p $single_pid -g -o $perf_data_file -- sleep 30" >> "$temp_hotspot_file"

        if perf_output=$(timeout 35 perf record -p "$single_pid" -g -o "$perf_data_file" -- sleep 30 2>&1); then
            echo "✓ perf record 执行成功" >> "$temp_hotspot_file"
            echo "" >> "$temp_hotspot_file"

            echo "--- perf report ---" >> "$temp_hotspot_file"
            if perf_report=$(perf report -i "$perf_data_file" --stdio --percent-limit 1 2>&1); then
                echo "$perf_report" >> "$temp_hotspot_file"
                echo "" >> "$temp_hotspot_file"
                perf_success=true
            else
                echo "警告: perf report 生成失败" >> "$temp_hotspot_file"
                echo "错误信息: $perf_report" >> "$temp_hotspot_file"
                echo "" >> "$temp_hotspot_file"
            fi

            rm -f "$perf_data_file"
        else
            local perf_exit_code=$?
            echo "错误: perf record 执行失败 (退出码=$perf_exit_code)" >> "$temp_hotspot_file"
            echo "错误详情: $perf_output" >> "$temp_hotspot_file"
            echo "" >> "$temp_hotspot_file"

            if echo "$perf_output" | grep -q "Permission denied"; then
                echo "原因: 权限不足" >> "$temp_hotspot_file"
            elif echo "$perf_output" | grep -q "No such process"; then
                echo "原因: 进程不存在或已退出" >> "$temp_hotspot_file"
            elif [ $perf_exit_code -eq 124 ]; then
                echo "原因: 超时 (可能进程在采样期间退出了)" >> "$temp_hotspot_file"
            fi
        fi

        if [ "$perf_success" = true ]; then
            echo "--- perf record for flamegraph (99Hz, 30s) ---" >> "$temp_hotspot_file"
            echo "执行命令: perf record -F 99 -p $single_pid -g -o $perf_fg_file -- sleep 30" >> "$temp_hotspot_file"

            if perf_fg_output=$(perf record -F 99 -p "$single_pid" -g -o "$perf_fg_file" -- sleep 30 2>&1); then
                echo "✓ perf record (flamegraph) 执行成功" >> "$temp_hotspot_file"
                echo "" >> "$temp_hotspot_file"
                echo "--- Generating flamegraph ---" >> "$temp_hotspot_file"

                local flamegraph_success=false
                if command -v stackcollapse-perf.pl && command -v flamegraph.pl; then
                    local flamegraph_file="$output_dir/hotspot_flamegraph_${single_pid}.svg"
                    if perf script -i "$perf_fg_file" 2>/dev/null | stackcollapse-perf.pl 2>/dev/null | flamegraph.pl > "$flamegraph_file" 2>/dev/null; then
                        echo "✓ Flamegraph saved to $flamegraph_file" >> "$temp_hotspot_file"
                        flamegraph_success=true
                    else
                        echo "警告: Flamegraph generation failed" >> "$temp_hotspot_file"
                    fi
                else
                    log_warning "提示: stackcollapse-perf.pl 或 flamegraph.pl 未安装，跳过火焰图生成"
                    log_warning "安装方法: git clone https://github.com/brendangregg/FlameGraph.git"
                fi

                if [ "$flamegraph_success" = true ] || [ "$perf_success" = true ]; then
                    hotspot_analysis_success=true
                fi

                rm -f "$perf_fg_file"
            else
                echo "警告: perf record (flamegraph) 执行失败，跳过火焰图生成" >> "$temp_hotspot_file"
                echo "错误信息: $perf_fg_output" >> "$temp_hotspot_file"
                if [ "$perf_success" = true ]; then
                    hotspot_analysis_success=true
                fi
            fi
        fi

        if [ "$hotspot_analysis_success" = true ]; then
            if [ ! -f "$output_dir/hotspot_analysis.txt" ]; then
                cat "$temp_hotspot_file" > "$output_dir/hotspot_analysis.txt"
            else
                cat "$temp_hotspot_file" >> "$output_dir/hotspot_analysis.txt"
            fi
            log_success "热点函数分析成功 (PID=$single_pid)"
        else
            log_error "热点函数分析失败 (PID=$single_pid)"
            cat "$temp_hotspot_file" >> "$output_dir/err_log.txt"
        fi

        rm -f "$temp_hotspot_file"

        rm -f /tmp/perf_phase3_${single_pid}*.data
    done

    if [ "$hotspot_analysis_success" = true ]; then
        echo "" >> "$output_dir/hotspot_analysis.txt"
        echo "============================================================" >> "$output_dir/hotspot_analysis.txt"
        echo "Phase 3.1: Hotspot Function Analysis Complete (PIDS=$pids)" >> "$output_dir/hotspot_analysis.txt"
        echo "============================================================" >> "$output_dir/hotspot_analysis.txt"
        log_success "√ 热点函数分析完成，结果保存至: $output_dir/hotspot_analysis.txt"
    else
        if [ -f "$output_dir/hotspot_analysis.txt" ]; then
            rm -f "$output_dir/hotspot_analysis.txt"
            log_warning "所有热点函数分析均失败，未生成 $output_dir/hotspot_analysis.txt"
        else
            log_warning "热点函数分析全部失败，未生成输出文件"
        fi
    fi
}


# ========== os/collect_io_metrics.sh ==========

collect_io_metrics() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：I/O Metrics 深度分析"

    io_metrics_success=false

    temp_io_file="${output_dir}/io_metrics_analysis.txt.tmp"

    echo "============================================================" > "$temp_io_file"
    echo "Phase: I/O Metrics for Bottleneck Analysis" >> "$temp_io_file"
    echo "============================================================" >> "$temp_io_file"
    echo "采集时间: $(date)" >> "$temp_io_file"
    echo "持续时间: ${duration}秒" >> "$temp_io_file"
    if [[ -n "$pids" ]]; then
        echo "目标进程: $pids" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    echo "=== System Overview ===" >> "$temp_io_file"
    echo "Kernel: $(uname -r)" >> "$temp_io_file"
    echo "CPU Count: $(nproc)" >> "$temp_io_file"
    echo "Memory Total: $(free -h | awk '/^Mem:/{print $2}')" >> "$temp_io_file"
    echo "" >> "$temp_io_file"
    io_metrics_success=true

    echo "=== Disk Devices ===" >> "$temp_io_file"
    if lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null | grep -E 'disk|nvme' >> "$temp_io_file" 2>/dev/null; then
        echo "✓ Disk devices collected" >> "$temp_io_file"
    else
        echo "⚠ No disk devices found or lsblk not available" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    echo "=== I/O Scheduler Configuration ===" >> "$temp_io_file"
    local scheduler_collected=false
    for dev in $(lsblk -d -n -o NAME 2>/dev/null | grep -E '^vd|^sd|^nvme' | head -5); do
        if [ -r "/sys/block/$dev/queue/scheduler" ]; then
            echo "--- /dev/$dev ---" >> "$temp_io_file"
            echo "scheduler: $(cat /sys/block/$dev/queue/scheduler 2>/dev/null | grep -o '\[.*\]' || echo 'N/A')" >> "$temp_io_file"
            echo "nr_requests: $(cat /sys/block/$dev/queue/nr_requests 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            echo "read_ahead_kb: $(cat /sys/block/$dev/queue/read_ahead_kb 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            echo "max_sectors_kb: $(cat /sys/block/$dev/queue/max_sectors_kb 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            echo "rotational: $(cat /sys/block/$dev/queue/rotational 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            echo "nomerges: $(cat /sys/block/$dev/queue/nomerges 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            scheduler_collected=true
        fi
    done
    if [ "$scheduler_collected" = false ]; then
        echo "⚠ No I/O scheduler information available (可能需要 root 权限)" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    echo "=== Memory/Page Cache Settings ===" >> "$temp_io_file"
    local mem_settings_collected=false
    for setting in vfs_cache_pressure swappiness dirty_background_ratio dirty_ratio dirty_writeback_centisecs dirty_expire_centisecs min_free_kbytes; do
        if [ -r "/proc/sys/vm/$setting" ]; then
            echo "$setting: $(cat /proc/sys/vm/$setting 2>/dev/null || echo 'N/A')" >> "$temp_io_file"
            mem_settings_collected=true
        fi
    done
    if [ "$mem_settings_collected" = false ]; then
        echo "⚠ Memory settings not accessible (可能需要 root 权限)" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    local process_io_collected=false
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            if [ -d "/proc/$single_pid" ]; then
                echo "=== Process I/O Configuration (PID $single_pid) ===" >> "$temp_io_file"

                echo "--- IO Priority ---" >> "$temp_io_file"
                if ionice -p $single_pid >> "$temp_io_file" 2>&1; then
                    process_io_collected=true
                else
                    echo "  ionice not available or permission denied" >> "$temp_io_file"
                fi

                echo "--- IO Statistics ---" >> "$temp_io_file"
                if [ -f "/proc/$single_pid/io" ] && cat "/proc/$single_pid/io" >> "$temp_io_file" 2>/dev/null; then
                    process_io_collected=true
                else
                    echo "  /proc/$single_pid/io not available (可能需要 root 权限)" >> "$temp_io_file"
                fi

                echo "--- Open Files Limit ---" >> "$temp_io_file"
                if [ -r "/proc/$single_pid/limits" ]; then
                    soft=$(awk '/Max open files/ {print $4}' /proc/$single_pid/limits 2>/dev/null)
                    hard=$(awk '/Max open files/ {print $5}' /proc/$single_pid/limits 2>/dev/null)
                    echo "  soft=$soft  hard=$hard" >> "$temp_io_file"
                    process_io_collected=true
                else
                    echo "  Cannot read process limits (可能需要 root 权限)" >> "$temp_io_file"
                fi

                if [ -d "/proc/$single_pid/fd" ]; then
                    fd_count=$(ls /proc/$single_pid/fd/ 2>/dev/null | wc -l)
                    [ "$fd_count" -gt 0 ] && echo "  open_fds=$fd_count" >> "$temp_io_file"
                    process_io_collected=true
                fi

                echo "" >> "$temp_io_file"
            else
                echo "=== Process PID=$single_pid does not exist ===" >> "$temp_io_file"
                echo "" >> "$temp_io_file"
            fi
        done
    fi

    echo "=== System-wide I/O Limits ===" >> "$temp_io_file"
    local system_limits_collected=false

    echo "--- AIO Limits ---" >> "$temp_io_file"
    if [ -r "/proc/sys/fs/aio-max-nr" ]; then
        echo "aio-max-nr: $(cat /proc/sys/fs/aio-max-nr 2>/dev/null)" >> "$temp_io_file"
        system_limits_collected=true
    else
        echo "aio-max-nr: N/A (不可访问)" >> "$temp_io_file"
    fi

    if [ -r "/proc/sys/fs/aio-nr" ]; then
        echo "aio-nr: $(cat /proc/sys/fs/aio-nr 2>/dev/null)" >> "$temp_io_file"
        system_limits_collected=true
    else
        echo "aio-nr: N/A (不可访问)" >> "$temp_io_file"
    fi

    if [ -r /proc/sys/fs/aio-max-nr ] && [ -r /proc/sys/fs/aio-nr ]; then
        max=$(cat /proc/sys/fs/aio-max-nr 2>/dev/null)
        cur=$(cat /proc/sys/fs/aio-nr 2>/dev/null)
        if [ -n "$max" ] && [ -n "$cur" ] && [ "$max" -gt 0 ]; then
            pct=$((cur * 100 / max))
            [ "$pct" -gt 80 ] && echo "  WARNING: AIO usage at ${pct}%" >> "$temp_io_file"
            system_limits_collected=true
        fi
    fi

    echo "--- File Handle Limits ---" >> "$temp_io_file"
    if [ -r "/proc/sys/fs/file-max" ]; then
        echo "file-max: $(cat /proc/sys/fs/file-max 2>/dev/null)" >> "$temp_io_file"
        system_limits_collected=true
    fi

    if [ -r "/proc/sys/fs/file-nr" ]; then
        awk '{printf "file-nr:  allocated=%s  free=%s  max=%s\n", $1, $2, $3}' /proc/sys/fs/file-nr 2>/dev/null >> "$temp_io_file"
        system_limits_collected=true
    fi

    if [ -r "/proc/sys/fs/nr_open" ]; then
        echo "nr_open: $(cat /proc/sys/fs/nr_open 2>/dev/null)" >> "$temp_io_file"
        system_limits_collected=true
    fi
    echo "" >> "$temp_io_file"

    echo "=== I/O Performance Data Collection (${duration} seconds) ===" >> "$temp_io_file"

    VMSTAT_TMP="/tmp/vmstat_io_$$.txt"
    IOSTAT_TMP="/tmp/iostat_io_$$.txt"
    local realtime_collected=false

    local vmstat_success=false
    if command -v vmstat &> /dev/null; then
        vmstat 1 $duration > "$VMSTAT_TMP" 2>&1 &
        VMSTAT_PID=$!
        vmstat_success=true
    else
        echo "⚠ vmstat command not found" >> "$temp_io_file"
    fi

    local iostat_success=false
    if command -v iostat &> /dev/null; then
        iostat -x 1 $duration > "$IOSTAT_TMP" 2>&1 &
        IOSTAT_PID=$!
        iostat_success=true
    else
        echo "⚠ iostat command not found (install sysstat package)" >> "$temp_io_file"
    fi

    if [ "$vmstat_success" = true ]; then
        wait $VMSTAT_PID 2>/dev/null
        if [ -s "$VMSTAT_TMP" ]; then
            echo "--- VMStat Analysis ---" >> "$temp_io_file"
            awk 'NR<=2 || /^[[:space:]]*[0-9]/' "$VMSTAT_TMP" | head -15 >> "$temp_io_file"
            echo "" >> "$temp_io_file"
            realtime_collected=true
            io_metrics_success=true
        else
            echo "⚠ VMStat data collection failed" >> "$temp_io_file"
        fi
    fi

    if [ "$iostat_success" = true ]; then
        wait $IOSTAT_PID 2>/dev/null
        if [ -s "$IOSTAT_TMP" ]; then
            echo "--- Disk Utilization Summary ---" >> "$temp_io_file"
            awk '$1 ~ /^[a-z]/ && $NF+0 > 0 {
                printf "%-10s util=%s%%  r/s=%s  w/s=%s  rKB/s=%s  wKB/s=%s  await=%s\n", $1, $NF, $2, $9, $3, $10, $5
            }' "$IOSTAT_TMP" | head -20 >> "$temp_io_file"
            echo "" >> "$temp_io_file"

            echo "--- I/O Pattern Analysis (Sequential vs Random) ---" >> "$temp_io_file"
            awk '$1 ~ /^[a-z]/ && (($4+0)>0 || ($5+0)>0) {
                ratio = ($4+$5)/($4+$5+$6+$7+0.1)*100
                printf "  %s: merge=%.1f%%  avg_req=%d sect  pattern=", $1, ratio, $8
                if (ratio > 30 && $8 > 32) print "SEQUENTIAL"
                else if (ratio < 10 && $8 < 16) print "RANDOM"
                else print "MIXED"
            }' "$IOSTAT_TMP" | head -10 >> "$temp_io_file"
            echo "" >> "$temp_io_file"
            realtime_collected=true
            io_metrics_success=true
        else
            echo "⚠ iostat data collection failed" >> "$temp_io_file"
        fi
    fi

    if [ "$realtime_collected" = false ]; then
        echo "⚠ No real-time I/O data collected (vmstat/iostat failed)" >> "$temp_io_file"
    fi

    echo "=== Filesystem Mount Options ===" >> "$temp_io_file"
    if mount 2>/dev/null | grep -E '^/dev| type ext[234]| type xfs| type btrfs' | head -10 >> "$temp_io_file"; then
        io_metrics_success=true
    else
        echo "⚠ No filesystem mount information available" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    echo "=== NFS/CIFS Mount Options ===" >> "$temp_io_file"
    nfs_mounts=$(mount 2>/dev/null | grep -E 'type nfs|type cifs' | head -10)
    if [ -n "$nfs_mounts" ]; then
        echo "$nfs_mounts" >> "$temp_io_file"
        io_metrics_success=true
    else
        echo "No NFS/CIFS mounts found" >> "$temp_io_file"
    fi
    echo "" >> "$temp_io_file"

    rm -f "$VMSTAT_TMP" "$IOSTAT_TMP"

    echo "============================================================" >> "$temp_io_file"
    echo "I/O Metrics Analysis Complete" >> "$temp_io_file"
    echo "============================================================" >> "$temp_io_file"

    if [ "$io_metrics_success" = true ]; then
        mv "$temp_io_file" "$output_dir/io_metrics_analysis.txt"
        log_success "√ I/O Metrics 深度分析完成，结果保存至: $output_dir/io_metrics_analysis.txt"
    else
        rm -f "$temp_io_file"
        log_warning "I/O Metrics 深度分析全部失败，未生成 $output_dir/io_metrics_analysis.txt"
    fi
}


# ========== os/collect_java_info.sh ==========
collect_java_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [[ -z "$pids" ]]; then
        log_warning "未指定进程，跳过Java信息采集"
        return
    fi

    log_info "执行：Java信息采集"

    IFS=',' read -ra pid_array <<< "$pids"
    for single_pid in "${pid_array[@]}"; do
        single_pid=$(echo "$single_pid" | xargs)
        _collect_java_info_for_pid "$single_pid"
    done
}

_run_jcmd() {
    local jcmd_path="$1"
    shift
    local pid="$1"
    shift

    if [[ $EUID -eq 0 ]]; then
        local proc_user=""
        proc_user=$(ps -o user= -p "$pid" 2>/dev/null | xargs)
        if [[ -n "$proc_user" && "$proc_user" != "root" ]]; then
            su - "$proc_user" -c "$jcmd_path $pid $*" 2>&1
        else
            "$jcmd_path" "$pid" "$@" 2>&1
        fi
    else
        "$jcmd_path" "$pid" "$@" 2>&1
    fi
}

# ============================================================
# async-profiler 火焰图采集（折叠栈 collapsed 文本，便于 LLM 读取）
# ============================================================

# 查找 async-profiler 启动器 asprof（旧版回退 profiler.sh）及 agent 库 libasyncProfiler.so
# 优先级：ASYNC_PROFILER 环境变量 > PATH(asprof/profiler/profiler.sh) > 常见安装目录 > 当前目录递归
# 成功返回 0 并设置 JAVA_ASYNC_PROFILER(启动器) 与 JAVA_ASYNC_PROFILER_LIB(agent .so)；否则返回 1
_java_find_async_profiler() {
    if [[ -n "${JAVA_ASYNC_PROFILER:-}" && -x "$JAVA_ASYNC_PROFILER" ]]; then
        :
    elif [[ -n "${ASYNC_PROFILER:-}" && -x "$ASYNC_PROFILER" ]]; then
        JAVA_ASYNC_PROFILER="$ASYNC_PROFILER"
    else
        local p=""
        p=$(command -v asprof 2>/dev/null)
        [[ -z "$p" ]] && p=$(command -v profiler 2>/dev/null)
        [[ -z "$p" ]] && p=$(command -v profiler.sh 2>/dev/null)
        if [[ -z "$p" ]]; then
            local try
            for try in \
                "$PWD"/async-profiler*/bin/asprof \
                "$PWD"/async-profiler*/asprof \
                "$PWD"/async-profiler*/profiler.sh \
                "$PWD"/*/async-profiler*/bin/asprof \
                /opt/async-profiler*/bin/asprof \
                /opt/async-profiler*/asprof \
                /opt/async-profiler*/profiler.sh \
                /usr/local/async-profiler*/bin/asprof \
                /usr/local/async-profiler*/asprof \
                /usr/local/async-profiler*/profiler.sh \
                "$HOME"/async-profiler*/bin/asprof \
                "$HOME"/async-profiler*/asprof \
                "$HOME"/async-profiler*/profiler.sh; do
                [[ -e "$try" ]] && { p="$try"; break; }
            done
        fi
        if [[ -z "$p" ]]; then
            local found
            found=$(find "$PWD" -maxdepth 3 -type f \( -name asprof -o -name profiler.sh \) 2>/dev/null | head -1)
            [[ -n "$found" ]] && p="$found"
        fi
        [[ -z "$p" ]] && return 1
        JAVA_ASYNC_PROFILER=$(readlink -f "$p" 2>/dev/null || echo "$p")
    fi

    # 定位 agent 库 libasyncProfiler.so（容器注入必需）
    if [[ -z "${JAVA_ASYNC_PROFILER_LIB:-}" || ! -e "$JAVA_ASYNC_PROFILER_LIB" ]]; then
        local ap_dir lib="" cand
        ap_dir=$(dirname "$JAVA_ASYNC_PROFILER")
        for cand in \
            "$ap_dir/lib/libasyncProfiler.so" \
            "$ap_dir/libasyncProfiler.so" \
            "$ap_dir/../lib/libasyncProfiler.so" \
            "$ap_dir/../libasyncProfiler.so"; do
            [[ -e "$cand" ]] && { lib="$cand"; break; }
        done
        if [[ -z "$lib" ]]; then
            lib=$(find "$ap_dir" "$ap_dir/.." -maxdepth 2 -type f -name 'libasyncProfiler*.so' 2>/dev/null | head -1)
        fi
        [[ -n "$lib" ]] && JAVA_ASYNC_PROFILER_LIB=$(readlink -f "$lib" 2>/dev/null || echo "$lib")
    fi
    return 0
}

# 通过 async-profiler 采集火焰图（折叠栈 collapsed 纯文本，便于 LLM 解析热点）
# 事件默认 cpu；可用 ASYNC_PROF_EVENTS=cpu,alloc,lock 自定义（逗号分隔）
# 时长默认 30s；可用 ASYNC_PROF_DURATION 调整
# 容器目标：将 libasyncProfiler.so 复制到容器内 /tmp/.asyncprof-<pid>，asprof 以 --libpath
#   指定容器内路径注入（JVM 在自身挂载命名空间解析该路径），采集完成后清理容器内副本
# 输出：
#   java_async_<event>_<pid>.collapsed  纯折叠栈数据（每行 "帧1;帧2;...;帧N 采样数"）
#   java_async_<event>_<pid>.top.txt     最热叶子帧 Top30 摘要（带格式说明，直接供 LLM 读取）
_collect_async_profiler() {
    local single_pid="$1"
    local events="${ASYNC_PROF_EVENTS:-cpu}"
    local duration="${ASYNC_PROF_DURATION:-30}"

    if ! _java_find_async_profiler; then
        log_info "未找到 async-profiler (asprof)，跳过 async-profiler 火焰图采集（可用 ASYNC_PROFILER=/path/to/asprof 指定）"
        return 1
    fi
    local prof="$JAVA_ASYNC_PROFILER"
    local lib="${JAVA_ASYNC_PROFILER_LIB:-}"
    log_info "检测到 async-profiler: $prof${lib:+ (agent: $lib)}"

    local is_container=false
    [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 ]] && is_container=true
    if [[ "$is_container" == "true" && -z "$lib" ]]; then
        log_error "目标位于容器，但未找到 libasyncProfiler.so，无法注入容器（请确保 async-profiler 完整安装）"
        return 1
    fi

    # asprof 采集时会切换到目标 pid/mount 命名空间并以目标用户身份写 -f 输出文件，
    # 故 -f 必须是目标可见且可写的路径（容器内即容器内 /tmp；宿主机即 /tmp），
    # 统一暂存到 /tmp/.asyncprof-<pid>/，采集后拷回 output_dir，避免 "Could not open output file"
    local staging_ctr="/tmp/.asyncprof-${single_pid}"
    local staging_host
    if [[ "$is_container" == "true" ]]; then
        staging_host=$(ctr_to_host "$staging_ctr")
        if [[ "$staging_host" == "$staging_ctr" ]]; then
            log_warning "无法将 $staging_ctr 映射到宿主机路径（缺少容器根映射），容器注入可能失败"
        fi
    else
        staging_host="$staging_ctr"
    fi
    mkdir -p "$staging_host" 2>/dev/null
    chmod 1777 "$staging_host" 2>/dev/null   # 目标用户（可能非 root）需可写输出

    if [[ "$is_container" == "true" ]]; then
        if ! cp "$lib" "$staging_host/libasyncProfiler.so" 2>/dev/null; then
            log_error "无法将 libasyncProfiler.so 复制到容器路径 $staging_host"
            rm -rf "$staging_host" 2>/dev/null
            return 1
        fi
        chmod 644 "$staging_host/libasyncProfiler.so" 2>/dev/null
        log_info "已将 agent 复制到容器内: ${staging_ctr}/libasyncProfiler.so (宿主机侧: ${staging_host}/libasyncProfiler.so)"
    fi
    log_info "采集输出暂存于目标可见路径 ${staging_ctr}/ (宿主机侧: ${staging_host}/)"

    local -a ev_arr
    IFS=',' read -ra ev_arr <<< "$events"
    local ev
    for ev in "${ev_arr[@]}"; do
        ev="${ev// /}"
        [[ -z "$ev" ]] && continue
        local out="${output_dir}/java_async_${ev}_${single_pid}.collapsed"
        local top="${output_dir}/java_async_${ev}_${single_pid}.top.txt"
        local ctr_out="${staging_ctr}/out_${ev}.collapsed"    # asprof -f：目标命名空间内可见路径
        local host_out="${staging_host}/out_${ev}.collapsed"   # 宿主机侧同文件（采集后拷回）
        log_info "采集 async-profiler [$ev] 折叠栈 (PID=$single_pid, ${duration}s, LLM友好文本格式)"

        local ap_out ap_exit
        if [[ "$is_container" == "true" ]]; then
            ap_out=$(timeout $((duration + 15)) "$prof" -d "$duration" -e "$ev" -o collapsed -f "$ctr_out" --libpath "${staging_ctr}/libasyncProfiler.so" "$single_pid" 2>&1)
        else
            ap_out=$(timeout $((duration + 15)) "$prof" -d "$duration" -e "$ev" -o collapsed -f "$ctr_out" "$single_pid" 2>&1)
        fi
        ap_exit=$?

        if [[ $ap_exit -ne 0 || ! -s "$host_out" ]]; then
            log_error "async-profiler [$ev] 采集失败 (退出码=$ap_exit): $ap_out"
            echo "async-profiler [$ev] 采集失败 (退出码=$ap_exit): $ap_out" >> "${output_dir}/err_log.txt"
            rm -f "$out" "$top" "$host_out"
            continue
        fi

        # 拷回 output_dir（asprof 在目标命名空间内写到暂存路径，此处切回宿主机侧读取）
        if ! cp "$host_out" "$out" 2>/dev/null; then
            log_error "无法将采集结果 $host_out 拷回 $out"
            rm -f "$host_out"
            continue
        fi
        rm -f "$host_out"

        # 生成最热叶子帧 Top30 摘要（直接供 LLM 读取）
        {
            echo "# async-profiler 折叠栈摘要 | PID=$single_pid 事件=$ev 时长=${duration}s"
            echo "# .collapsed 格式: 每行一条调用栈，';' 分隔帧，行尾数字=采样数（越大越热）；栈底(入口)在前，栈顶(叶子)在后"
            echo "# 下表为按叶子帧聚合的最热 Top30（采样数  叶帧），可直接定位热点方法"
            echo "# 完整数据见 java_async_${ev}_${single_pid}.collapsed（可用 sort -nr -k2 取最热栈，或用 async-profiler 转 HTML）"
            echo "------------------------------------------------------------"
            printf "%-12s %s\n" "采样数" "叶子帧(热点方法)"
            echo "------------------------------------------------------------"
            awk '{ if (NF>=2) { n=split($1,a,";"); leaf=a[n]; cnt[leaf]+=$2 } } END { for(l in cnt) print cnt[l], l }' "$out" \
                | sort -nr | head -30 | awk '{ printf "%-12s %s\n", $1, $2 }'
        } > "$top"

        log_success "async-profiler [$ev] 采集成功: $out ($(wc -l < "$out" | tr -d ' ') 行, $(du -h "$out" | cut -f1)); 摘要: $top"
    done

    # 清理采集暂存目录（容器内 agent + 暂存输出 / 非容器的 /tmp 暂存）
    if [[ -n "$staging_host" && -d "$staging_host" ]]; then
        rm -rf "$staging_host" 2>/dev/null
        log_info "已清理采集暂存目录: $staging_ctr"
    fi
    return 0
}

_collect_java_info_for_pid() {
    local single_pid="$1"
    local java_info_file="${output_dir}/java_info_${single_pid}.txt"
    local thread_file="${output_dir}/java_thread_${single_pid}.txt"
    local heap_info_file="${output_dir}/java_heap_info_${single_pid}.txt"
    local class_histogram_file="${output_dir}/java_class_histogram_${single_pid}.txt"
    local gc_log_dir="${output_dir}/gc_log_${single_pid}"
    local error_log="${output_dir}/err_log.txt"

    log_info "Java信息采集 (PID=$single_pid)"

    # ---- 1. 判断是否Java进程 ----
    # 获取 exe 路径：优先 readlink /proc/pid/exe（仅取链接目标字符串，不做 -f 规范化，
    # 容器进程的 exe 目标是容器内路径，在宿主机上不存在，-f 会因 ENOENT 失败）。
    # 容器进程或 ptrace 权限受限时该链接可能无法访问，回退到 /proc/pid/cmdline 首段
    # （通常即 java 可执行路径）；两者皆空才视为不可访问。
    local exe_path=""
    exe_path=$(readlink "/proc/${single_pid}/exe" 2>/dev/null)

    local cmdline=""
    cmdline=$(tr '\0' ' ' < "/proc/${single_pid}/cmdline" 2>/dev/null)

    if [[ -z "$exe_path" && -n "$cmdline" ]]; then
        exe_path=$(echo "$cmdline" | awk '{print $1}')
        [[ -n "$exe_path" ]] && log_warning "无法 readlink /proc/${single_pid}/exe（权限或命名空间隔离），从 cmdline 首段解析 exe: $exe_path"
    fi

    if [[ -z "$exe_path" && -z "$cmdline" ]]; then
        log_error "无法读取 /proc/${single_pid}（exe 与 cmdline 均不可访问），进程可能已退出或无权限"
        return
    fi

    local is_java=false
    if [[ -n "$exe_path" ]] && basename "$exe_path" 2>/dev/null | grep -qi "java"; then
        is_java=true
    fi
    if [[ "$is_java" == "false" ]] && echo "$cmdline" | grep -qi "java\|tomcat\|jboss\|spring\|glassfish\|weblogic\|websphere"; then
        is_java=true
    fi

    if [[ "$is_java" == "false" ]]; then
        log_info "PID=$single_pid 不是Java进程，跳过Java信息采集"
        return
    fi

    # ---- 1.5 容器环境检测：跨挂载命名空间时建立 容器->宿主机 路径映射 ----
    setup_container_env "$single_pid"

    # 跨命名空间时将 exe 路径替换为宿主机路径
    if [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 && -n "$exe_path" ]]; then
        local exe_path_host
        exe_path_host=$(ctr_to_host "$exe_path")
        if [[ "$exe_path_host" != "$exe_path" ]]; then
            log_info "PID=$single_pid exe路径 容器->宿主机: $exe_path -> $exe_path_host"
            exe_path="$exe_path_host"
        fi
    fi
    # 规范化 exe 路径（解析符号链接）：此时已是宿主机路径（容器场景下经映射得到），可在宿主机上解析
    if [[ -n "$exe_path" ]]; then
        local exe_canon
        exe_canon=$(readlink -f "$exe_path" 2>/dev/null)
        if [[ -n "$exe_canon" && "$exe_canon" != "$exe_path" ]]; then
            log_info "PID=$single_pid exe路径规范化: $exe_path -> $exe_canon"
            exe_path="$exe_canon"
        fi
    fi

    {
        echo "============================================================"
        echo "Java信息采集 (PID=$single_pid)"
        echo "采集时间: $(date)"
        echo "============================================================"
        echo ""
        echo "=== Java版本 (通过 /proc/pid/exe) ==="
        echo "Java可执行文件: $exe_path"
    } > "$java_info_file"

    # ---- 2. 通过/proc/pid/exe判断Java版本，记录完整路径 ----
    local java_home_dir=""
    if [[ -n "$exe_path" ]]; then
        java_home_dir=$(dirname "$exe_path")
    fi

    {
        echo "Java主目录: $java_home_dir"
    } >> "$java_info_file"


    # ---- 3. 查找jcmd ----
    local jcmd_path=""
    if [[ -n "$java_home_dir" && -x "${java_home_dir}/jcmd" ]]; then
        jcmd_path="${java_home_dir}/jcmd"
        log_info "在Java主目录找到jcmd: $jcmd_path"
    else
        jcmd_path=$(which jcmd 2>/dev/null)
        if [[ -n "$jcmd_path" ]]; then
            log_info "通过which找到jcmd: $jcmd_path"
        fi
    fi

    # ---- 4. 通过jcmd VM.system_properties确认JDK厂商和版本 ----
    local java_vendor=""
    local java_version=""
    if [[ -n "$jcmd_path" ]]; then
        local sys_props=""
        sys_props=$(_run_jcmd "$jcmd_path" "$single_pid" VM.system_properties)
        java_vendor=$(echo "$sys_props" | grep -E "^java\.vendor=" | head -1 | awk -F= '{print $2}')
        java_version=$(echo "$sys_props" | grep -E "^java\.version=" | head -1 | awk -F= '{print $2}')
    fi
    {
        if [[ -n "$java_vendor" && -n "$java_version" ]]; then
            echo ""
            echo "=== JDK厂商和版本 ==="
            echo "JDK厂商: $java_vendor"
            echo "JDK版本: $java_version"
        else
            if [[ -n "$exe_path" ]]; then
                local java_version_output=""
                java_version_output=$("$exe_path" -version 2>&1)
                echo "Java版本信息:"
                echo "$java_version_output"
            else
                echo "Java版本信息: exe 路径不可访问，无法执行 -version（参考 jcmd VM.system_properties 输出）"
            fi
        fi
    } >> "$java_info_file"

    # ---- 5. 通过jcmd记录VM.command_line和VM.flag ----
    if [[ -n "$jcmd_path" ]]; then
        log_info "采集 VM.command_line 和 VM.flags (PID=$single_pid)"

        local cmd_line_output=""
        cmd_line_output=$(_run_jcmd "$jcmd_path" "$single_pid" VM.command_line)

        local flag_output=""
        flag_output=$(_run_jcmd "$jcmd_path" "$single_pid" VM.flags)

        {
            echo ""
            echo "=== VM.command_line ==="
            echo "$cmd_line_output"
            echo ""
            echo "=== VM.flags ==="
            echo "$flag_output"
        } >> "$java_info_file"
    fi

    # ---- 6. 通过jcmd采集Thread.print、GC.heap_info、GC.class_histogram ----
    if [[ -n "$jcmd_path" ]]; then
        # 6.1 Thread.print
        log_info "采集 jcmd Thread.print (PID=$single_pid)"
        {
            echo "============================================================"
            echo "Java线程信息 (PID=$single_pid)"
            echo "采集时间: $(date)"
            echo "============================================================"
            echo ""
            _run_jcmd "$jcmd_path" "$single_pid" Thread.print >> "$thread_file"
        } > "$thread_file"

        # 6.2 GC.heap_info 采集5次，15秒内（间隔3秒）
        log_info "采集 jcmd GC.heap_info x5 (PID=$single_pid, 间隔3秒)"
        {
            echo "============================================================"
            echo "Java堆信息 (PID=$single_pid)"
            echo "采集时间: $(date)"
            echo "共5次采样，间隔3秒"
            echo "============================================================"
        } > "$heap_info_file"

        local heap_iter=1
        while [[ $heap_iter -le 5 ]]; do
            {
                echo ""
                echo "=== 第${heap_iter}次采样 ($(date)) ==="
                _run_jcmd "$jcmd_path" "$single_pid" GC.heap_info >> "$heap_info_file"
            } >> "$heap_info_file"
            [[ $heap_iter -lt 5 ]] && sleep 3
            heap_iter=$((heap_iter + 1))
        done

        # 6.3 GC.class_histogram
        log_info "采集 jcmd GC.class_histogram (PID=$single_pid)"
        {
            echo "============================================================"
            echo "Java类直方图 (PID=$single_pid)"
            echo "采集时间: $(date)"
            echo "============================================================"
            echo ""
            _run_jcmd "$jcmd_path" "$single_pid" GC.class_histogram >> "$class_histogram_file"
        } > "$class_histogram_file"
    else
        log_warning "jcmd不可用，跳过 Thread.print / GC.heap_info / GC.class_histogram 采集"
        {
            echo ""
            echo "=== 注意 ==="
            echo "jcmd不可用，以下数据未采集:"
            echo "  - Thread.print"
            echo "  - GC.heap_info"
            echo "  - GC.class_histogram"
        } >> "$java_info_file"
    fi

    # ---- 7. 采集GC日志 ----
    log_info "采集GC日志 (PID=$single_pid)"
    _collect_gc_log "$single_pid" "$jcmd_path"

    # ---- 8. async-profiler 火焰图采集（折叠栈 collapsed 文本，便于 LLM 读取）----
    _collect_async_profiler "$single_pid"

    {
        echo ""
        echo "============================================================"
        echo "Java信息采集完成 (PID=$single_pid)"
        echo "============================================================"
    } >> "$java_info_file"

    log_success "√ Java信息采集完成 (PID=$single_pid)"
}

_collect_gc_log() {
    local single_pid="$1"
    local jcmd_path="$2"
    local gc_log_dir="${output_dir}/gc_log_${single_pid}"
    local gc_log_archive="${output_dir}/gc_log_${single_pid}.tar.gz"

    # 从VM.command_line中获取GC日志参数
    local gc_log_opts=""
    local cmd_line_content=""
    if [[ -n "$jcmd_path" ]]; then
        cmd_line_content=$(_run_jcmd "$jcmd_path" "$single_pid" VM.command_line)
    fi
    if [[ -z "$cmd_line_content" && -f "${output_dir}/java_command_line_${single_pid}.txt" ]]; then
        cmd_line_content=$(cat "${output_dir}/java_command_line_${single_pid}.txt" 2>/dev/null)
    fi

    gc_log_opts=$(echo "$cmd_line_content" | grep -oE '\-Xlog(:gc[^ ]*|:gc[^ ]*)|\-XX:\+PrintGCDetails|\-XX:\+PrintGC|\-Xloggc:[^ ]+|\-XX:GCLogFileSize=[^ ]+|\-XX:NumberOfGCLogFiles=[^ ]+|\-XX:\+UseGCLogFileRotation' 2>/dev/null)

    if [[ -z "$gc_log_opts" ]]; then
        log_info "PID=$single_pid 未配置GC日志参数，跳过GC日志采集。如需启用: JDK8: -XX:+PrintGCDetails -Xloggc:<path> -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=20M; JDK9+: -Xlog:gc*:file=<path>:filecount=5,filesize=20M"
        return
    fi

    log_info "PID=$single_pid GC日志相关JVM参数: $gc_log_opts"

    # 判断是否启用了滚动日志
    local has_rotation=false
    # JDK8: -XX:+UseGCLogFileRotation
    if echo "$gc_log_opts" | grep -q 'UseGCLogFileRotation'; then
        has_rotation=true
    fi
    # JDK9+: -Xlog:gc*:file=...:filecount=N,filesize=M
    local xlog_full=""
    xlog_full=$(echo "$cmd_line_content" | grep -oE '\-Xlog:gc[^ ]*' 2>/dev/null)
    if echo "$xlog_full" | grep -q 'filecount='; then
        has_rotation=true
    fi

    # 获取进程工作目录用于解析相对路径
    local proc_cwd=""
    proc_cwd=$(readlink "/proc/${single_pid}/cwd" 2>/dev/null)
    if [[ -z "$proc_cwd" ]]; then
        proc_cwd="/"
        log_warning "无法读取 /proc/${single_pid}/cwd（权限或命名空间隔离），使用 / 作为基准路径"
    fi
    # 跨命名空间时将进程工作目录映射到宿主机（用于相对GC日志路径解析）
    if [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 && -n "$proc_cwd" ]]; then
        local proc_cwd_host
        proc_cwd_host=$(ctr_to_host "$proc_cwd")
        if [[ "$proc_cwd_host" != "$proc_cwd" ]]; then
            log_info "PID=$single_pid 进程工作目录 容器->宿主机: $proc_cwd -> $proc_cwd_host"
            proc_cwd="$proc_cwd_host"
        fi
    fi

    # 解析GC日志路径
    local gc_log_path=""
    local gc_log_path_xlog=""

    # -Xloggc:<path> (JDK8)
    gc_log_path=$(echo "$gc_log_opts" | grep -oE '\-Xloggc:[^ ]+' | sed 's/^-Xloggc://')
    # -Xlog:gc*:file=<path> (JDK9+)
    if [[ -z "$gc_log_path" ]]; then
        gc_log_path_xlog=$(echo "$xlog_full" | grep -oE 'file=[^ ,:]+' | sed 's/^file=//')
        gc_log_path="$gc_log_path_xlog"
    fi

    if [[ -z "$gc_log_path" ]]; then
        log_warning "PID=$single_pid 无法解析GC日志路径"
        return
    fi

    log_info "PID=$single_pid GC日志路径(原始): $gc_log_path"

    # 处理相对路径
    local resolved_path="$gc_log_path"
    if [[ "$gc_log_path" != /* ]]; then
        resolved_path="${proc_cwd}/${gc_log_path}"
        resolved_path=$(cd "$(dirname "$resolved_path")" 2>/dev/null && pwd)/$(basename "$resolved_path")
        log_info "PID=$single_pid GC日志路径(相对路径解析): $resolved_path"
    else
        # 绝对路径：跨命名空间时映射到宿主机路径
        if [[ ${#CONTAINER_PATH_MAP_CTR[@]} -gt 0 ]]; then
            local gc_path_host
            gc_path_host=$(ctr_to_host "$gc_log_path")
            if [[ "$gc_path_host" != "$gc_log_path" ]]; then
                log_info "PID=$single_pid GC日志路径 容器->宿主机: $gc_log_path -> $gc_path_host"
                resolved_path="$gc_path_host"
            fi
        fi
    fi

    # 支持%p和%t替换
    # 注意：%p 由 JVM 在其自身 PID 命名空间内解析。容器内 JVM 写出的文件名用的是容器内 PID，
    # 故此处需用目标进程在最内层 PID 命名空间的 PID（容器内 PID），而非宿主机侧的 single_pid
    local gc_log_pid
    gc_log_pid=$(ctr_get_innermost_pid "$single_pid")
    if [[ "$gc_log_pid" != "$single_pid" ]]; then
        log_info "PID=$single_pid GC日志 %%p 使用容器内PID: $gc_log_pid（宿主机PID=$single_pid）"
    fi

    local has_percent_p=false
    local has_percent_t=false
    if echo "$resolved_path" | grep -q '%p'; then
        has_percent_p=true
        resolved_path=$(echo "$resolved_path" | sed "s/%p/${gc_log_pid}/g")
    fi
    if echo "$resolved_path" | grep -q '%t'; then
        has_percent_t=true
        resolved_path=$(echo "$resolved_path" | sed 's/%t/[0-9]*/g')
    fi

    if [[ "$has_percent_p" == "true" ]]; then
        log_info "PID=$single_pid GC日志路径(已替换 %p -> $gc_log_pid): $resolved_path"
    fi
    if [[ "$has_percent_t" == "true" ]]; then
        log_info "PID=$single_pid GC日志路径(已替换 %t 为时间戳正则匹配): $resolved_path"
    fi

    # 查找GC日志文件
    # search_pattern 已将 %p 替换为容器内PID、%t 替换为 [0-9]*（供 find -name 通配）
    # 始终先匹配"当前日志"（无滚动后缀），再在启用滚动时匹配带 .N 后缀的滚动文件，
    # 这样 %t + 滚动 同时存在时也能采集到全部滚动日志（原 if/else 互斥导致只采到一个）
    local gc_files=()
    local search_dir=""
    local search_pattern=""
    search_dir=$(dirname "$resolved_path")
    search_pattern=$(basename "$resolved_path")

    if [[ -d "$search_dir" ]]; then
        # 1) 当前日志文件
        local _gc_cur_tmp
        _gc_cur_tmp=$(mktemp)
        find "$search_dir" -maxdepth 1 -name "$search_pattern" -type f 2>/dev/null | sort > "$_gc_cur_tmp"
        while IFS= read -r f; do
            gc_files+=("$f")
        done < "$_gc_cur_tmp"
        rm -f "$_gc_cur_tmp"

        # 2) 滚动日志：附加 ".*" 匹配 .0/.1/.../.current 等后缀
        #    JDK8 UseGCLogFileRotation: name.0, name.1, name.0.current 等
        #    JDK9+ filecount: name.0, name.1, ... 等（%t 场景下 name 含 [0-9]* 时间戳通配）
        if [[ "$has_rotation" == "true" ]]; then
            local _gc_rot_tmp
            _gc_rot_tmp=$(mktemp)
            find "$search_dir" -maxdepth 1 -name "${search_pattern}.*" -type f 2>/dev/null | sort > "$_gc_rot_tmp"
            while IFS= read -r f; do
                gc_files+=("$f")
            done < "$_gc_rot_tmp"
            rm -f "$_gc_rot_tmp"
        fi
    fi

    if [[ ${#gc_files[@]} -eq 0 ]]; then
        log_warning "PID=$single_pid 未找到GC日志文件 (搜索路径: $resolved_path)"
        return
    fi

    log_info "PID=$single_pid 找到 ${#gc_files[@]} 个GC日志文件"

    # 过滤：不超过20分钟、不超过100M
    local time_limit=$((20 * 60))
    local size_limit=$((100 * 1024 * 1024))
    local now_epoch=$(date +%s)

    mkdir -p "$gc_log_dir"
    local valid_count=0
    local need_filter=true
    if [[ ${#gc_files[@]} -eq 1 ]]; then
        need_filter=false
    fi

    for f in "${gc_files[@]}"; do
        if [[ "$need_filter" == "true" ]]; then
            local file_size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
            local file_mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
            local file_age=$((now_epoch - file_mtime))

            if [[ $file_age -gt $time_limit ]]; then
                log_info "PID=$single_pid 跳过 (超过20分钟): $f (文件年龄: ${file_age}s)"
                continue
            fi

            if [[ $file_size -gt $size_limit ]]; then
                log_info "PID=$single_pid 跳过 (超过100M): $f (文件大小: ${file_size} bytes)"
                continue
            fi
        fi

        cp "$f" "$gc_log_dir/" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            valid_count=$((valid_count + 1))
        else
            log_warning "复制GC日志文件失败: $f"
        fi
    done

    if [[ $valid_count -eq 0 ]]; then
        log_warning "PID=$single_pid GC日志文件均不满足采集条件"
        rm -rf "$gc_log_dir"
        return
    fi

    # 按时间排序并重命名为 gc0.log, gc1.log, ...
    local rename_idx=0
    local _gc_sort_tmp
    _gc_sort_tmp=$(mktemp)
    find "$gc_log_dir" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}' > "$_gc_sort_tmp"
    while IFS= read -r f; do
        if [[ "$f" != "gc${rename_idx}.log" ]]; then
            mv "$f" "${gc_log_dir}/gc${rename_idx}.log" 2>/dev/null
        fi
        rename_idx=$((rename_idx + 1))
    done < "$_gc_sort_tmp"
    rm -f "$_gc_sort_tmp"

    # 打包为 gc_log.tar.gz
    tar -czf "$gc_log_archive" -C "$gc_log_dir" . 2>/dev/null
    if [[ $? -eq 0 ]]; then
        rm -rf "$gc_log_dir"
        log_success "PID=$single_pid GC日志采集打包完成: $gc_log_archive (有效文件数: $valid_count, 大小: $(du -h "$gc_log_archive" | cut -f1))"
    else
        log_error "PID=$single_pid GC日志打包失败"
    fi
}


# ========== os/collect_kernel_config_info.sh ==========

collect_kernel_config_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：内核深度诊断信息采集"
    
    local KERNEL_CONFIG_FILE="${output_dir}/kernel_config_info.txt"
    
    > "$KERNEL_CONFIG_FILE"
    echo "============================================================" >> "$KERNEL_CONFIG_FILE"
    echo "内核深度诊断信息采集" >> "$KERNEL_CONFIG_FILE"
    echo "采集时间: $(date)" >> "$KERNEL_CONFIG_FILE"
    echo "============================================================" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 全量内核参数 (sysctl -a) ===" >> "$KERNEL_CONFIG_FILE"
    if command -v sysctl &>/dev/null; then
        sysctl -a 2>/dev/null | sort >> "$KERNEL_CONFIG_FILE"
    fi
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 关键内核参数补充 ===" >> "$KERNEL_CONFIG_FILE"

    echo "--- 网络核心参数 ---" >> "$KERNEL_CONFIG_FILE"
    sysctl -a 2>/dev/null | grep -E "^net\.core\.|^net\.ipv4\.tcp_|^net\.ipv4\.udp_|^net\.ipv4\.ip_|^net\.nf" >> "$KERNEL_CONFIG_FILE" || echo "无匹配" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 网络缓冲区 ---" >> "$KERNEL_CONFIG_FILE"
    sysctl -a 2>/dev/null | grep -E "^net\.core\.(r|w)mem|^net\.core\.netdev|^net\.core\.somaxconn|^net\.core\.optmem" >> "$KERNEL_CONFIG_FILE" || echo "无匹配" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 用户命名空间限制 ---" >> "$KERNEL_CONFIG_FILE"
    sysctl -a 2>/dev/null | grep "^user\.max_" >> "$KERNEL_CONFIG_FILE" || echo "无匹配" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 内核启动参数特殊项 ===" >> "$KERNEL_CONFIG_FILE"
    if [ -f /proc/cmdline ]; then
        grep -qo 'xcall' /proc/cmdline 2>/dev/null && echo "xcall: yes" >> "$KERNEL_CONFIG_FILE" || echo "xcall: no" >> "$KERNEL_CONFIG_FILE"
        grep -qo 'sched_steal_node_limit' /proc/cmdline 2>/dev/null && echo "sched_steal_node_limit: yes" >> "$KERNEL_CONFIG_FILE" || echo "sched_steal_node_limit: no" >> "$KERNEL_CONFIG_FILE"
    else
        echo "/proc/cmdline 不可用" >> "$KERNEL_CONFIG_FILE"
    fi
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 调度特性 ===" >> "$KERNEL_CONFIG_FILE"
    SCHED_FEAT=""
    [ -f /sys/kernel/debug/sched_features ] && SCHED_FEAT="/sys/kernel/debug/sched_features"
    [ -f /sys/kernel/debug/sched/features ] && SCHED_FEAT="/sys/kernel/debug/sched/features"
    if [ -n "$SCHED_FEAT" ]; then
        cat "$SCHED_FEAT" >> "$KERNEL_CONFIG_FILE" 2>/dev/null || echo "无法读取" >> "$KERNEL_CONFIG_FILE"
        [ -w "$SCHED_FEAT" ] && echo "writable" >> "$KERNEL_CONFIG_FILE" || echo "not writable" >> "$KERNEL_CONFIG_FILE"
        grep -ow 'SOFT_DOMAIN' "$SCHED_FEAT" >/dev/null 2>&1 && echo "SOFT_DOMAIN: present" >> "$KERNEL_CONFIG_FILE" || echo "SOFT_DOMAIN: NOT present" >> "$KERNEL_CONFIG_FILE"
        grep -ow 'KEEP_ON_CORE' "$SCHED_FEAT" >/dev/null 2>&1 && echo "KEEP_ON_CORE: present" >> "$KERNEL_CONFIG_FILE" || echo "KEEP_ON_CORE: NOT present" >> "$KERNEL_CONFIG_FILE"
        grep -ow 'PARAL' "$SCHED_FEAT" >/dev/null 2>&1 && echo "PARAL: present" >> "$KERNEL_CONFIG_FILE" || echo "PARAL: NOT present" >> "$KERNEL_CONFIG_FILE"
    else
        echo "调度特性文件不可用" >> "$KERNEL_CONFIG_FILE"
    fi
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 特殊调度参数 ===" >> "$KERNEL_CONFIG_FILE"
    cat /proc/sys/kernel/sched_cluster 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "sched_cluster: not exist" >> "$KERNEL_CONFIG_FILE"
    cat /proc/sys/kernel/sched_util_ratio 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "sched_util_ratio: not exist" >> "$KERNEL_CONFIG_FILE"
    cat /proc/sys/kernel/sched_util_low_pct 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "sched_util_low_pct: not exist" >> "$KERNEL_CONFIG_FILE"
    if [ -f /proc/sys/kernel/sched_soft_runtime_ratio ]; then
        echo "Docker CPU Burst: yes, value=$(cat /proc/sys/kernel/sched_soft_runtime_ratio)" >> "$KERNEL_CONFIG_FILE"
    else
        echo "Docker CPU Burst: no" >> "$KERNEL_CONFIG_FILE"
    fi
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 完整内核模块列表 (lsmod) ===" >> "$KERNEL_CONFIG_FILE"
    lsmod 2>/dev/null >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 内核版本与详细编译选项 ===" >> "$KERNEL_CONFIG_FILE"
    uname -a >> "$KERNEL_CONFIG_FILE"
    cat /proc/version 2>/dev/null >> "$KERNEL_CONFIG_FILE"
    KERNEL_VER=$(uname -r)
    if [ -f /boot/config-${KERNEL_VER} ]; then
        grep -E "CONFIG_IKCONFIG|CONFIG_HZ|CONFIG_PREEMPT|CONFIG_NR_CPUS|CONFIG_HUGETLB|CONFIG_TRANSPARENT|CONFIG_CGROUP|CONFIG_NAMESPACE|CONFIG_SCHED_STEAL|CONFIG_SCHED_SMT" \
            /boot/config-${KERNEL_VER} 2>/dev/null >> "$KERNEL_CONFIG_FILE"
    elif [ -f /proc/config.gz ]; then
        zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_IKCONFIG|CONFIG_HZ|CONFIG_PREEMPT|CONFIG_NR_CPUS|CONFIG_HUGETLB|CONFIG_TRANSPARENT|CONFIG_CGROUP|CONFIG_SCHED_STEAL|CONFIG_SCHED_SMT" >> "$KERNEL_CONFIG_FILE"
    else
        echo "未找到内核 config 文件" >> "$KERNEL_CONFIG_FILE"
    fi
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 系统诊断 ===" >> "$KERNEL_CONFIG_FILE"

    echo "--- 内核 taint ---" >> "$KERNEL_CONFIG_FILE"
    cat /proc/sys/kernel/tainted 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "无法读取" >> "$KERNEL_CONFIG_FILE"
    echo "(0=未污染)" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 内核 Oops/Panic (dmesg) ---" >> "$KERNEL_CONFIG_FILE"
    dmesg 2>/dev/null | grep -i -E "Oops|panic|BUG|Call Trace|WARNING" | tail -20 >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 活跃内核线程 (前20) ---" >> "$KERNEL_CONFIG_FILE"
    ps -eo pid,comm --no-headers 2>/dev/null | awk '$2 ~ /^\[.*\]$/ {print}' | head -20 >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 透明大页 defrag ---" >> "$KERNEL_CONFIG_FILE"
    cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "不可用" >> "$KERNEL_CONFIG_FILE"
    echo "THP enabled writable: $(test -w /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && echo writable || echo 'not writable')" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 内核特性与模块诊断 ===" >> "$KERNEL_CONFIG_FILE"
    echo "--- /proc/1/xcall ---" >> "$KERNEL_CONFIG_FILE"
    test -f /proc/1/xcall && echo "exists" >> "$KERNEL_CONFIG_FILE"

    echo "--- irqbalance ---" >> "$KERNEL_CONFIG_FILE"
    systemctl is-active irqbalance 2>/dev/null >> "$KERNEL_CONFIG_FILE"

    echo "--- oenetcls ---" >> "$KERNEL_CONFIG_FILE"
    modinfo oenetcls >> "$KERNEL_CONFIG_FILE" 2>/dev/null && echo "available" >> "$KERNEL_CONFIG_FILE"

    echo "--- SMC ---" >> "$KERNEL_CONFIG_FILE"
    if lsmod 2>/dev/null | grep -qi smc; then
        echo "loaded" >> "$KERNEL_CONFIG_FILE"
        lsmod 2>/dev/null | grep -i smc >> "$KERNEL_CONFIG_FILE"
    else
        echo "not loaded" >> "$KERNEL_CONFIG_FILE"
    fi

    echo "--- ism ---" >> "$KERNEL_CONFIG_FILE"
    lsmod 2>/dev/null | grep -qi ism && echo "loaded" >> "$KERNEL_CONFIG_FILE" && lsmod 2>/dev/null | grep -i ism >> "$KERNEL_CONFIG_FILE" || echo "not loaded" >> "$KERNEL_CONFIG_FILE"

    echo "--- cpufreq_seep / oenetcls in /proc/modules ---" >> "$KERNEL_CONFIG_FILE"
    grep -E 'oenetcls|cpufreq_seep' /proc/modules 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "(无匹配)" >> "$KERNEL_CONFIG_FILE"

    echo "--- xcall_numa 参数 ---" >> "$KERNEL_CONFIG_FILE"
    ls /proc/sys/kernel/xcall_numa* 2>/dev/null >> "$KERNEL_CONFIG_FILE" || echo "xcall_numa* not exist" >> "$KERNEL_CONFIG_FILE"

    echo "--- debugfs 挂载 ---" >> "$KERNEL_CONFIG_FILE"
    mount 2>/dev/null | grep debugfs >> "$KERNEL_CONFIG_FILE" || echo "debugfs not mounted" >> "$KERNEL_CONFIG_FILE"

    echo "--- numafast ---" >> "$KERNEL_CONFIG_FILE"
    rpm -qa 2>/dev/null | grep numafast >> "$KERNEL_CONFIG_FILE" || echo "not installed" >> "$KERNEL_CONFIG_FILE"

    echo "--- ARM SPE ---" >> "$KERNEL_CONFIG_FILE"
    perf list 2>/dev/null | grep -qi arm_spe && echo "available" >> "$KERNEL_CONFIG_FILE" || echo "not available" >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "=== 其他系统诊断 ===" >> "$KERNEL_CONFIG_FILE"
    echo "--- /proc/filesystems ---" >> "$KERNEL_CONFIG_FILE"
    cat /proc/filesystems 2>/dev/null >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- SECCOMP 进程 (strict) ---" >> "$KERNEL_CONFIG_FILE"
    grep -l "Seccomp:.*2" /proc/[0-9]*/status 2>/dev/null | head -5 | while read f; do
        pid=$(echo "$f" | grep -oP '/\K\d+')
        comm=$(cat /proc/$pid/comm 2>/dev/null || echo "?")
        echo "PID=$pid COMM=$comm SECCOMP=strict" >> "$KERNEL_CONFIG_FILE"
    done
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 文件描述符使用 Top5 ---" >> "$KERNEL_CONFIG_FILE"
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | head -200); do
        if [ -d "/proc/$pid/fd" ]; then
            comm=$(cat /proc/$pid/comm 2>/dev/null || echo "?")
            count=$(ls -1 /proc/$pid/fd 2>/dev/null | wc -l)
            echo "$pid $comm $count"
        fi
    done 2>/dev/null | sort -t' ' -k3 -rn | head -5 >> "$KERNEL_CONFIG_FILE"
    echo "" >> "$KERNEL_CONFIG_FILE"

    echo "--- 关键系统服务 PID ---" >> "$KERNEL_CONFIG_FILE"
    for svc in systemd sshd dmsetup auditd dbus udevd chronyd crond; do
        if command -v pgrep &>/dev/null; then
            pids=$(pgrep -x "$svc" 2>/dev/null || echo "")
            [ -n "$pids" ] && echo "$svc: PID=$pids" >> "$KERNEL_CONFIG_FILE"
        fi
    done
    echo "" >> "$KERNEL_CONFIG_FILE"

    log_success "内核深度诊断信息采集完成"
}


# ========== os/collect_lock_trace.sh ==========

collect_lock_trace() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：Lock Trace 深度分析"

    lock_trace_success=false

    temp_lock_file="${output_dir}/lock_trace_analysis.txt.tmp"

    echo "============================================================" > "$temp_lock_file"
    echo "Phase: Lock Trace Analysis for Bottleneck Identification" >> "$temp_lock_file"
    echo "============================================================" >> "$temp_lock_file"
    echo "采集时间: $(date)" >> "$temp_lock_file"
    echo "持续时间: ${duration}秒" >> "$temp_lock_file"
    if [[ -n "$pids" ]]; then
        echo "目标进程: $pids" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Lock Tracing Prerequisites ===" >> "$temp_lock_file"
    local prereq_success=false
    for setting in perf_event_paranoid lock_stat sched_schedstats; do
        if [ -r "/proc/sys/kernel/$setting" ]; then
            echo "$setting: $(cat /proc/sys/kernel/$setting 2>/dev/null || echo 'N/A')" >> "$temp_lock_file"
            prereq_success=true
        else
            echo "$setting: N/A (不可访问)" >> "$temp_lock_file"
        fi
    done
    if [ "$prereq_success" = true ]; then
        lock_trace_success=true
    fi
    echo "" >> "$temp_lock_file"

    echo "=== System Lock Configuration ===" >> "$temp_lock_file"
    local sysconfig_success=false
    for setting in futex_wake_mac futex_ping_latency sched_autogroup_enabled sched_child_runs_first \
                    sched_latency_ns sched_min_granularity_ns sched_wakeup_granularity_ns sched_tunable_scaling; do
        if [ -r "/proc/sys/kernel/$setting" ]; then
            echo "$setting: $(cat /proc/sys/kernel/$setting 2>/dev/null || echo 'N/A')" >> "$temp_lock_file"
            sysconfig_success=true
        fi
    done
    if [ "$sysconfig_success" = true ]; then
        lock_trace_success=true
    fi
    echo "" >> "$temp_lock_file"

    echo "=== RCU Configuration ===" >> "$temp_lock_file"
    local rcu_success=false
    for setting in rcu_cpu_stall_suppress rcu_normal; do
        if [ -r "/proc/sys/kernel/$setting" ]; then
            echo "$setting: $(cat /proc/sys/kernel/$setting 2>/dev/null || echo 'N/A')" >> "$temp_lock_file"
            rcu_success=true
        fi
    done
    if [ "$rcu_success" = true ]; then
        lock_trace_success=true
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Lockup Detection ===" >> "$temp_lock_file"
    local lockup_success=false
    for setting in softlockup_panic nmi_watchdog; do
        if [ -r "/proc/sys/kernel/$setting" ]; then
            echo "$setting: $(cat /proc/sys/kernel/$setting 2>/dev/null || echo 'N/A')" >> "$temp_lock_file"
            lockup_success=true
        fi
    done
    if [ "$lockup_success" = true ]; then
        lock_trace_success=true
    fi
    echo "" >> "$temp_lock_file"

    echo "=== CPU Isolation ===" >> "$temp_lock_file"
    if [ -r "/proc/cmdline" ]; then
        cmdline=$(cat /proc/cmdline 2>/dev/null)
        isolcpus=$(echo "$cmdline" | grep -o 'isolcpus=[^ ]*' || echo 'N/A')
        nohz_full=$(echo "$cmdline" | grep -o 'nohz_full=[^ ]*' || echo 'N/A')
        echo "isolcpus: $isolcpus" >> "$temp_lock_file"
        echo "nohz_full: $nohz_full" >> "$temp_lock_file"
        if [ "$isolcpus" != "N/A" ] || [ "$nohz_full" != "N/A" ]; then
            lock_trace_success=true
        fi
    else
        echo "isolcpus: N/A (无法读取 /proc/cmdline)" >> "$temp_lock_file"
        echo "nohz_full: N/A" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Kernel Lock Statistics ===" >> "$temp_lock_file"
    if [ -r "/proc/lock_stat" ] && [ -s "/proc/lock_stat" ]; then
        head -50 /proc/lock_stat >> "$temp_lock_file"
        lock_trace_success=true
    else
        echo "lock_stat: not available (enable via: echo 1 > /proc/sys/kernel/lock_stat)" >> "$temp_lock_file"
        echo "" >> "$temp_lock_file"
        echo "Note: To enable lock statistics, run as root:" >> "$temp_lock_file"
        echo "  echo 1 > /proc/sys/kernel/lock_stat" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "=== File Locks ===" >> "$temp_lock_file"
    if [ -r "/proc/locks" ] && [ -s "/proc/locks" ]; then
        head -50 /proc/locks >> "$temp_lock_file"
        lock_trace_success=true
    else
        echo "locks: not available or empty" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Softirq Activity ===" >> "$temp_lock_file"
    if [ -r "/proc/softirqs" ] && [ -s "/proc/softirqs" ]; then
        head -50 /proc/softirqs >> "$temp_lock_file"
        lock_trace_success=true
    else
        echo "softirqs: not available" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    local process_info_success=false
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            if [ -d "/proc/$single_pid" ]; then
                echo "=== Target Process Info (PID: $single_pid) ===" >> "$temp_lock_file"

                echo "--- Thread Information ---" >> "$temp_lock_file"
                if ps -T -p $single_pid >> "$temp_lock_file" 2>&1; then
                    process_info_success=true
                else
                    echo "Process not found" >> "$temp_lock_file"
                fi

                echo "" >> "$temp_lock_file"
                echo "--- Process Status ---" >> "$temp_lock_file"
                if grep -E "State|Threads|VmRSS" "/proc/$single_pid/status" >> "$temp_lock_file" 2>/dev/null; then
                    process_info_success=true
                else
                    echo "Cannot read process status" >> "$temp_lock_file"
                fi

                echo "" >> "$temp_lock_file"
                echo "--- Wait Channel (wchan) ---" >> "$temp_lock_file"
                if [ -r "/proc/$single_pid/wchan" ]; then
                    echo "wchan: $(cat /proc/$single_pid/wchan 2>/dev/null || echo 'N/A')" >> "$temp_lock_file"
                    process_info_success=true
                fi

                echo "" >> "$temp_lock_file"
                echo "--- Kernel Stack (first 20 lines) ---" >> "$temp_lock_file"
                if [ -r "/proc/$single_pid/stack" ]; then
                    head -20 /proc/$single_pid/stack >> "$temp_lock_file" 2>/dev/null
                    process_info_success=true
                else
                    echo "Cannot read stack (need root)" >> "$temp_lock_file"
                fi

                echo "" >> "$temp_lock_file"
            else
                echo "=== Process PID=$single_pid does not exist ===" >> "$temp_lock_file"
                echo "" >> "$temp_lock_file"
            fi
        done
    fi
    if [ "$process_info_success" = true ]; then
        lock_trace_success=true
    fi

    echo "=== Real-time Lock Contention Detection ===" >> "$temp_lock_file"
    local perf_lock_success=false

    if command -v perf &> /dev/null && [[ -n "$pids" ]]; then
        echo "--- Perf lock analysis (${duration} seconds) ---" >> "$temp_lock_file"

        if perf lock -h &> /dev/null; then
            IFS=',' read -ra pid_array <<< "$pids"
            for single_pid in "${pid_array[@]}"; do
                single_pid=$(echo "$single_pid" | xargs)

                echo "Analyzing locks for PID $single_pid..." >> "$temp_lock_file"

                PERF_LOCK_TMP="/tmp/perf_lock_${single_pid}_$$.data"
                if timeout $duration perf lock record -p $single_pid -o "$PERF_LOCK_TMP" -- sleep $duration 2>&1 | head -20 >> "$temp_lock_file"; then
                    if [ -f "$PERF_LOCK_TMP" ] && [ -s "$PERF_LOCK_TMP" ]; then
                        echo "" >> "$temp_lock_file"
                        echo "--- Lock Contention Report ---" >> "$temp_lock_file"
                        if perf lock report -i "$PERF_LOCK_TMP" --stdio 2>&1 | head -50 >> "$temp_lock_file"; then
                            perf_lock_success=true
                        fi
                        rm -f "$PERF_LOCK_TMP"
                    fi
                else
                    echo "perf lock record failed for PID $single_pid" >> "$temp_lock_file"
                fi
            done
        else
            echo "perf lock subcommand not available (need perf built with libtraceevent)" >> "$temp_lock_file"
        fi
    else
        echo "perf lock analysis skipped (perf not available or no PID specified)" >> "$temp_lock_file"
    fi
    if [ "$perf_lock_success" = true ]; then
        lock_trace_success=true
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Blocked Processes Analysis ===" >> "$temp_lock_file"
    local blocked_success=false

    echo "--- Blocked Processes (D=uninterruptible, S=interruptible) ---" >> "$temp_lock_file"
    if ps -eo state,wchan:32,pid,comm 2>/dev/null | awk '/^[DS]/ {print}' | sort | uniq -c | sort -rn | head -20 >> "$temp_lock_file"; then
        blocked_success=true
    else
        echo "无法获取阻塞进程信息" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "--- Wait Channel Breakdown ---" >> "$temp_lock_file"
    if ps -eo state,wchan:32 2>/dev/null | awk '/^[DS]/ {print $2}' | sort | uniq -c | sort -rn | head -20 >> "$temp_lock_file"; then
        blocked_success=true
    fi
    echo "" >> "$temp_lock_file"

    if [ "$blocked_success" = true ]; then
        lock_trace_success=true
    fi

    if [ -r "/proc/lock_stat" ] && [ -s "/proc/lock_stat" ]; then
        echo "=== Lock Hold Time Analysis ===" >> "$temp_lock_file"
        echo "Top 10 locks by contention (hold time):" >> "$temp_lock_file"
        if awk '/->/ && /lock/ {print $1, $2, $3, $4, $5}' /proc/lock_stat 2>/dev/null | sort -k5 -rn | head -10 >> "$temp_lock_file"; then
            lock_trace_success=true
        fi
        echo "" >> "$temp_lock_file"
    fi

    echo "=== Futex Contention Detection ===" >> "$temp_lock_file"
    local futex_success=false

    if [[ -n "$pids" ]] && command -v strace &> /dev/null; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            echo "Checking futex syscall for PID $single_pid (5s sample)..." >> "$temp_lock_file"
            if timeout ${duration} strace -p $single_pid -c -e trace=futex 2>&1 | grep -E "futex|% time" >> "$temp_lock_file"; then
                futex_success=true
            fi
            echo "" >> "$temp_lock_file"
        done
    else
        echo "Futex detection skipped (strace not available or no PID specified)" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    if [ "$futex_success" = true ]; then
        lock_trace_success=true
    fi

    echo "=== Spinlock Statistics ===" >> "$temp_lock_file"
    if [ -r "/proc/lock_stat" ] && [ -s "/proc/lock_stat" ]; then
        echo "lock_stat is enabled. Current spinlock contention:" >> "$temp_lock_file"
        if grep "spinlock" /proc/lock_stat 2>/dev/null | head -20 >> "$temp_lock_file"; then
            lock_trace_success=true
        fi
    else
        echo "spinlock statistics not available (lock_stat not enabled)" >> "$temp_lock_file"
        echo "To enable: echo 1 > /proc/sys/kernel/lock_stat (requires root)" >> "$temp_lock_file"
    fi
    echo "" >> "$temp_lock_file"

    echo "=== Recommendations and Optimization Hints ===" >> "$temp_lock_file"

    blocked_count=$(ps -eo state 2>/dev/null | grep -c '^[DS]' || echo "0")
    if [ "$blocked_count" -gt 10 ] 2>/dev/null; then
        echo "⚠ WARNING: $blocked_count blocked processes detected. High lock contention possible." >> "$temp_lock_file"
        lock_trace_success=true
    fi

    if [ ! -f /proc/lock_stat ] || [ ! -s /proc/lock_stat ]; then
        echo "💡 TIP: Enable kernel lock statistics for detailed analysis:" >> "$temp_lock_file"
        echo "   echo 1 > /proc/sys/kernel/lock_stat" >> "$temp_lock_file"
    fi

    if command -v perf &> /dev/null; then
        if ! perf lock -h &> /dev/null; then
            echo "💡 TIP: Rebuild perf with libtraceevent support for lock analysis" >> "$temp_lock_file"
        fi
    fi

    echo "" >> "$temp_lock_file"
    echo "============================================================" >> "$temp_lock_file"
    echo "Lock Trace Analysis Complete" >> "$temp_lock_file"
    echo "============================================================" >> "$temp_lock_file"

    if [ "$lock_trace_success" = true ]; then
        mv "$temp_lock_file" "$output_dir/lock_trace_analysis.txt"
        log_success "√ Lock Trace 深度分析完成，结果保存至: $output_dir/lock_trace_analysis.txt"
    else
        rm -f "$temp_lock_file"
        log_warning "Lock Trace 深度分析全部失败，未生成 $output_dir/lock_trace_analysis.txt"
    fi
}


# ========== os/collect_mem_metrics.sh ==========

collect_mem_metrics() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：Memory Metrics 深度分析"
    
    local MEM_METRICS_FILE="${output_dir}/memory_metrics_analysis.txt"
    
    mem_metrics_success=false
    
    temp_mem_file="${MEM_METRICS_FILE}.tmp"
    
    echo "============================================================" > "$temp_mem_file"
    echo "Phase: Memory Metrics for Bottleneck Analysis" >> "$temp_mem_file"
    echo "============================================================" >> "$temp_mem_file"
    echo "采集时间: $(date)" >> "$temp_mem_file"
    if [[ -n "$pids" ]]; then
        echo "目标进程: $pids" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== System Overview ===" >> "$temp_mem_file"
    echo "Kernel: $(uname -r)" >> "$temp_mem_file"
    echo "CPU Count: $(nproc)" >> "$temp_mem_file"
    echo "Memory Total: $(free -h | awk '/^Mem:/{print $2}')" >> "$temp_mem_file"
    echo "" >> "$temp_mem_file"
    mem_metrics_success=true
    
    echo "=== Memory Pressure (PSI) ===" >> "$temp_mem_file"
    if [ -f /proc/pressure/mem ] && [ -r /proc/pressure/mem ]; then
        cat /proc/pressure/mem >> "$temp_mem_file" 2>/dev/null && mem_metrics_success=true
    else
        echo "/proc/pressure/mem not available." >> "$temp_mem_file"
        echo "To enable: Add psi=1 to kernel boot params in /etc/default/grub," >> "$temp_mem_file"
        echo "           then run: grub2-mkconfig -o /boot/grub2/grub.cfg && reboot" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Usage ===" >> "$temp_mem_file"
    if free -h >> "$temp_mem_file" 2>/dev/null; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== VM OOM Stats ===" >> "$temp_mem_file"
    if [ -r /proc/vmstat ]; then
        oom_stats=$(cat /proc/vmstat 2>/dev/null | grep -E 'oom_kill|pgmajfault')
        if [ -n "$oom_stats" ]; then
            echo "$oom_stats" >> "$temp_mem_file"
            mem_metrics_success=true
        else
            echo "No OOM kills or major page faults recorded" >> "$temp_mem_file"
        fi
    else
        echo "Cannot read /proc/vmstat" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Swap Configuration ===" >> "$temp_mem_file"
    if swapon -s >> "$temp_mem_file" 2>/dev/null || cat /proc/swaps >> "$temp_mem_file" 2>/dev/null; then
        mem_metrics_success=true
    else
        echo "No swap configured or cannot read swap info" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Slab Info ===" >> "$temp_mem_file"
    if [ -r /proc/slabinfo ]; then
        head -30 /proc/slabinfo >> "$temp_mem_file" 2>/dev/null && mem_metrics_success=true
    else
        echo "/proc/slabinfo not readable (requires root)" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Vmalloc Region ===" >> "$temp_mem_file"
    if cat /proc/meminfo 2>/dev/null | grep -E "VmallocTotal|VmallocUsed" >> "$temp_mem_file"; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Allocation/Reclaim Stats ===" >> "$temp_mem_file"
    if cat /proc/vmstat 2>/dev/null | grep -E "pgfault|pgmajflt|pgalloc|pgfree|pgscank|pgscand|pgsteal|pgrotated" | head -20 >> "$temp_mem_file"; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Details (meminfo) ===" >> "$temp_mem_file"
    if cat /proc/meminfo 2>/dev/null | grep -E "Active:|Inactive:|SReclaimable|SUnreclaim|Shmem:|VmallocUsed:|Committed_AS:" >> "$temp_mem_file"; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== HugePages Configuration ===" >> "$temp_mem_file"
    local hugepage_success=false
    if [ -r /proc/sys/vm/nr_hugepages ]; then
        echo "nr_hugepages: $(cat /proc/sys/vm/nr_hugepages 2>/dev/null)" >> "$temp_mem_file"
        hugepage_success=true
    fi
    if cat /proc/meminfo 2>/dev/null | grep -E "HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize:" >> "$temp_mem_file"; then
        hugepage_success=true
    fi
    if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "transparent_hugepage: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" >> "$temp_mem_file"
        hugepage_success=true
    fi
    if [ "$hugepage_success" = true ]; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== OOM Configuration ===" >> "$temp_mem_file"
    local oom_config_success=false
    if [ -r /proc/sys/vm/oom_kill_allocating_task ]; then
        echo "oom_kill_allocating_task: $(cat /proc/sys/vm/oom_kill_allocating_task 2>/dev/null)" >> "$temp_mem_file"
        oom_config_success=true
    fi
    if [ -r /proc/sys/vm/oom_dump_tasks ]; then
        echo "oom_dump_tasks: $(cat /proc/sys/vm/oom_dump_tasks 2>/dev/null)" >> "$temp_mem_file"
        oom_config_success=true
    fi
    if [ "$oom_config_success" = true ]; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== KSM Configuration ===" >> "$temp_mem_file"
    if [ -f /sys/kernel/mm/ksm/run ] && [ -r /sys/kernel/mm/ksm/run ]; then
        echo "ksm.run: $(cat /sys/kernel/mm/ksm/run 2>/dev/null)" >> "$temp_mem_file"
        echo "ksm.pages_shared: $(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo 'N/A')" >> "$temp_mem_file"
        echo "ksm.pages_sharing: $(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 'N/A')" >> "$temp_mem_file"
        mem_metrics_success=true
    else
        echo "KSM not available" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== NUMA Balancing ===" >> "$temp_mem_file"
    if [ -r /proc/sys/kernel/numa_balancing ]; then
        echo "numa_balancing: $(cat /proc/sys/kernel/numa_balancing 2>/dev/null)" >> "$temp_mem_file"
        mem_metrics_success=true
    else
        echo "numa_balancing: N/A" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory CGroup Limits ===" >> "$temp_mem_file"
    local cgroup_success=false
    if [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        echo "memory.limit_in_bytes: $(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)" >> "$temp_mem_file"
        echo "memory.soft_limit_in_bytes: $(cat /sys/fs/cgroup/memory/memory.soft_limit_in_bytes 2>/dev/null)" >> "$temp_mem_file"
        echo "memory.usage_in_bytes: $(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)" >> "$temp_mem_file"
        cgroup_success=true
    elif [ -f /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.max ]; then
        echo "memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null)" >> "$temp_mem_file"
        echo "memory.current: $(cat /sys/fs/cgroup/memory.current 2>/dev/null)" >> "$temp_mem_file"
        echo "memory.low: $(cat /sys/fs/cgroup/memory.low 2>/dev/null)" >> "$temp_mem_file"
        cgroup_success=true
    else
        echo "Memory cgroup limits not available" >> "$temp_mem_file"
    fi
    if [ "$cgroup_success" = true ]; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Watermarks ===" >> "$temp_mem_file"
    local watermark_success=false
    if [ -r /proc/sys/vm/watermark_scale_factor ]; then
        echo "watermark_scale_factor: $(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)" >> "$temp_mem_file"
        watermark_success=true
    fi
    if [ -r /proc/sys/vm/watermark_boost_factor ]; then
        echo "watermark_boost_factor: $(cat /proc/sys/vm/watermark_boost_factor 2>/dev/null)" >> "$temp_mem_file"
        watermark_success=true
    fi
    if [ "$watermark_success" = true ]; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Zone Info (per node) ===" >> "$temp_mem_file"
    if [ -r /proc/zoneinfo ]; then
        cat /proc/zoneinfo 2>/dev/null | grep -E "Node|zone" | head -30 >> "$temp_mem_file"
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== jemalloc Configuration ===" >> "$temp_mem_file"
    local jemalloc_success=false
    
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            if [ -f "/proc/$single_pid/maps" ] && [ -r "/proc/$single_pid/maps" ]; then
                jemap=$(grep -i jemalloc /proc/$single_pid/maps 2>/dev/null | head -1)
                if [ -n "$jemap" ]; then
                    echo "jemalloc detected in target process (PID $single_pid):" >> "$temp_mem_file"
                    echo "$jemap" >> "$temp_mem_file"
                    jemalloc_success=true
                else
                    echo "Target process $single_pid does NOT use jemalloc" >> "$temp_mem_file"
                fi
            elif [ -n "$single_pid" ]; then
                echo "Target process /proc/$single_pid/maps not available" >> "$temp_mem_file"
            fi
        done
    else
        echo "No target PID provided; skipping process mapping check" >> "$temp_mem_file"
    fi
    
    echo "" >> "$temp_mem_file"
    echo "--- jemalloc Environment Variables ---" >> "$temp_mem_file"
    echo "MALLOC_ARENA_MAX: ${MALLOC_ARENA_MAX:-not set}" >> "$temp_mem_file"
    echo "MALLOC_CONF: ${MALLOC_CONF:-not set}" >> "$temp_mem_file"
    
    if [ -n "$MALLOC_CONF" ]; then
        echo "" >> "$temp_mem_file"
        echo "--- MALLOC_CONF breakdown ---" >> "$temp_mem_file"
        for key in background_thread dirty_decay_ms muzzy_decay_ms narenas percpu_arena \
                   oversize_threshold metadata_thp lg_extent_max_active_fit \
                   tcache lg_tcache_max prof prof_active stats_print; do
            val=$(echo "$MALLOC_CONF" | grep -oP "${key}:\K[^,]+" 2>/dev/null)
            if [ -n "$val" ]; then
                echo "  $key=$val" >> "$temp_mem_file"
                jemalloc_success=true
            fi
        done
    fi
    if [ "$jemalloc_success" = true ]; then
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== NUMA Statistics (system-wide) ===" >> "$temp_mem_file"
    if [ -r /proc/vmstat ]; then
        if cat /proc/vmstat 2>/dev/null | grep -E "numa_hit|numa_miss|numa_foreign|numa_local|numa_other" | head -20 >> "$temp_mem_file"; then
            mem_metrics_success=true
        fi
    fi
    echo "" >> "$temp_mem_file"
    
    local numa_proc_success=false
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            if [ -d "/proc/$single_pid" ]; then
                echo "=== Process NUMA Memory Distribution (PID: $single_pid) ===" >> "$temp_mem_file"
                if command -v numastat &> /dev/null; then
                    if numastat -p $single_pid >> "$temp_mem_file" 2>/dev/null; then
                        numa_proc_success=true
                    else
                        echo "numastat failed" >> "$temp_mem_file"
                    fi
                elif [ -f "/proc/$single_pid/numa_maps" ] && [ -r "/proc/$single_pid/numa_maps" ]; then
                    echo "numastat not available, see /proc/$single_pid/numa_maps for details" >> "$temp_mem_file"
                    numa_proc_success=true
                else
                    echo "numastat not available" >> "$temp_mem_file"
                fi
                
                if [ -f "/proc/$single_pid/numa_maps" ] && [ -r "/proc/$single_pid/numa_maps" ]; then
                    dom=$(awk '{
                        for(i=1;i<=NF;i++) if($i ~ "^N[0-9]+=") {
                            split($i,a,"="); sum[a[1]]+=a[2]
                        }
                    } END {
                        for(n in sum) if(sum[n] > max) {max=sum[n]; dom=n}
                        print dom
                    }' /proc/$single_pid/numa_maps 2>/dev/null)
                    cpu_node=$(awk '$1==pid {print $NF}' pid=$single_pid /proc/$single_pid/stat 2>/dev/null)
                    numa_of_cpu="unknown"
                    if [ -n "$cpu_node" ] && command -v lscpu &> /dev/null; then
                        numa_of_cpu=$(lscpu -p=cpu,node 2>/dev/null | awk -F, -v cpu="$cpu_node" '$1==cpu {print $2}')
                    fi
                    dom_num=$(echo "$dom" | sed 's/^N//')
                    echo "" >> "$temp_mem_file"
                    echo "  Memory dominant node: ${dom_num:-?}  |  CPU node: ${numa_of_cpu:-?}  |  CPU: ${cpu_node:-?}" >> "$temp_mem_file"
                    if [ -n "$dom_num" ] && [ "$numa_of_cpu" != "unknown" ] && [ "$dom_num" != "$numa_of_cpu" ]; then
                        echo "  WARNING: memory on node $dom_num but process on node $numa_of_cpu (remote access)" >> "$temp_mem_file"
                    fi
                    numa_proc_success=true
                fi
                echo "" >> "$temp_mem_file"
            fi
        done
    fi
    if [ "$numa_proc_success" = true ]; then
        mem_metrics_success=true
    fi
    
    echo "=== NUMA Node Layout ===" >> "$temp_mem_file"
    if command -v numactl &> /dev/null; then
        if numactl --hardware >> "$temp_mem_file" 2>/dev/null; then
            mem_metrics_success=true
        fi
        echo "" >> "$temp_mem_file"
        echo "=== NUMA Current Policy ===" >> "$temp_mem_file"
        if numactl --show >> "$temp_mem_file" 2>/dev/null; then
            mem_metrics_success=true
        fi
    else
        echo "numactl not available" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== NUMA Nodes ===" >> "$temp_mem_file"
    if command -v lscpu &> /dev/null; then
        if lscpu 2>/dev/null | grep "NUMA" >> "$temp_mem_file"; then
            mem_metrics_success=true
        fi
    else
        echo "lscpu not available" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory per NUMA Node ===" >> "$temp_mem_file"
    if [ -r /proc/buddyinfo ]; then
        cat /proc/buddyinfo >> "$temp_mem_file" 2>/dev/null && mem_metrics_success=true
    else
        echo "Cannot read /proc/buddyinfo" >> "$temp_mem_file"
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Recent OOM Events ===" >> "$temp_mem_file"
    local oom_events_success=false
    if command -v dmesg &> /dev/null; then
        oom_events=$(dmesg -T 2>/dev/null | grep -iE 'out of memory|oom kill' | tail -10)
        if [ -n "$oom_events" ]; then
            echo "$oom_events" >> "$temp_mem_file"
            oom_events_success=true
        fi
    fi
    if [ "$oom_events_success" = false ] && command -v journalctl &> /dev/null; then
        oom_events=$(journalctl -k 2>/dev/null | grep -iE 'out of memory|oom kill' | tail -10)
        if [ -n "$oom_events" ]; then
            echo "$oom_events" >> "$temp_mem_file"
            oom_events_success=true
        fi
    fi
    if [ "$oom_events_success" = false ]; then
        echo "No recent OOM events found" >> "$temp_mem_file"
    else
        mem_metrics_success=true
    fi
    echo "" >> "$temp_mem_file"
    
    echo "=== Memory Optimization Recommendations ===" >> "$temp_mem_file"
    local recommendations_success=false
    
    if command -v free &> /dev/null; then
        swap_used=$(free 2>/dev/null | awk '/^Swap:/ {print $3}')
        swap_total=$(free 2>/dev/null | awk '/^Swap:/ {print $2}')
        if [ -n "$swap_used" ] && [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] 2>/dev/null; then
            swap_pct=$((swap_used * 100 / swap_total))
            if [ "$swap_pct" -gt 50 ]; then
                echo "WARNING: High swap usage ($swap_pct%). Consider increasing memory or reducing memory pressure." >> "$temp_mem_file"
                recommendations_success=true
            fi
        fi
    fi
    
    if [ -r /proc/vmstat ]; then
        oom_kills=$(cat /proc/vmstat 2>/dev/null | grep oom_kill | awk '{print $2}')
        if [ -n "$oom_kills" ] && [ "$oom_kills" -gt 0 ] 2>/dev/null; then
            echo "WARNING: $oom_kills OOM kills detected. System is memory constrained." >> "$temp_mem_file"
            recommendations_success=true
        fi
    fi
    
    if [ -r /proc/meminfo ]; then
        hugepage_total=$(cat /proc/meminfo 2>/dev/null | grep HugePages_Total | awk '{print $2}')
        if [ -n "$hugepage_total" ] && [ "$hugepage_total" -gt 0 ] 2>/dev/null; then
            hugepage_free=$(cat /proc/meminfo 2>/dev/null | grep HugePages_Free | awk '{print $2}')
            hugepage_used=$((hugepage_total - hugepage_free))
            if [ "$hugepage_used" -eq 0 ] 2>/dev/null; then
                echo "TIP: HugePages configured but not used. Check application support or adjust allocation." >> "$temp_mem_file"
                recommendations_success=true
            fi
        fi
    fi
    
    if [ -r /proc/sys/kernel/numa_balancing ]; then
        numa_balancing=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)
        if [ "$numa_balancing" = "0" ]; then
            echo "INFO: NUMA balancing is disabled. For NUMA systems, consider enabling (echo 1 > /proc/sys/kernel/numa_balancing)" >> "$temp_mem_file"
            recommendations_success=true
        fi
    fi
    
    if [ "$recommendations_success" = true ]; then
        mem_metrics_success=true
    fi

    echo "" >> "$MEM_METRICS_FILE"
    echo "=== 完整 /proc/meminfo ===" >> "$MEM_METRICS_FILE"
    cat /proc/meminfo >> "$MEM_METRICS_FILE" 2>/dev/null || echo "无法读取 /proc/meminfo" >> "$MEM_METRICS_FILE"

    echo "" >> "$MEM_METRICS_FILE"
    echo "=== 完整 /proc/vmstat ===" >> "$MEM_METRICS_FILE"
    cat /proc/vmstat >> "$MEM_METRICS_FILE" 2>/dev/null || echo "无法读取 /proc/vmstat" >> "$MEM_METRICS_FILE"
    
    echo "" >> "$MEM_METRICS_FILE"
    echo "=== 系统内存页大小 ===" >> "$MEM_METRICS_FILE"
    if command -v getconf &>/dev/null; then
        getconf PAGE_SIZE >> "$MEM_METRICS_FILE" 2>/dev/null || echo "获取失败" >> "$MEM_METRICS_FILE"
    fi

    echo "" >> "$MEM_METRICS_FILE"
    echo "=== 大页目录详情 ===" >> "$MEM_METRICS_FILE"
    if [ -d /sys/kernel/mm/hugepages ]; then
        for d in /sys/kernel/mm/hugepages/hugepages-*; do
            [ -d "$d" ] && echo "$(basename "$d"): nr_hugepages=$(cat "$d/nr_hugepages" 2>/dev/null || echo "?"), free=$(cat "$d/free_hugepages" >> "$MEM_METRICS_FILE" 2>/dev/null || echo "?")" >> "$MEM_METRICS_FILE"
        done
    else
        echo "hugepages 目录不存在" >> "$MEM_METRICS_FILE"
    fi

    echo "" >> "$MEM_METRICS_FILE"
    echo "=== NUMA 节点内存详情 ===" >> "$MEM_METRICS_FILE"
    if [ -d /sys/devices/system/node ]; then
        for node in /sys/devices/system/node/node*; do
            [ -d "$node" ] || continue
            node_name=$(basename "$node")
            echo "--- $node_name ---" >> "$MEM_METRICS_FILE"
            [ -f "$node/meminfo" ] && grep -E "MemTotal|MemFree|Active|Inactive|Dirty|Writeback|FilePages|Mapped|AnonPages|Shmem|KernelStack|PageTables" "$node/meminfo" >> "$MEM_METRICS_FILE" 2>/dev/null || echo "meminfo 不可用" >> "$MEM_METRICS_FILE"
        done
    else
        echo "NUMA 节点信息不可用" >> "$MEM_METRICS_FILE"
    fi
    
    echo "" >> "$temp_mem_file"
    echo "============================================================" >> "$temp_mem_file"
    echo "Memory Metrics Analysis Complete" >> "$temp_mem_file"
    echo "============================================================" >> "$temp_mem_file"
    
    if [ "$mem_metrics_success" = true ]; then
        mv "$temp_mem_file" "$MEM_METRICS_FILE"
        log_success "Memory Metrics 深度分析完成，结果保存至: $MEM_METRICS_FILE"
    else
        rm -f "$temp_mem_file"
        log_warning "Memory Metrics 深度分析全部失败，未生成 $MEM_METRICS_FILE"
    fi
}


# ========== os/collect_microarch_analysis.sh ==========

collect_microarch_analysis() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    if [[ -f "$output_dir/devkit_topdown.txt" ]]; then
        log_info "检测到 devkit topdown 已成功采集，跳过微架构瓶颈分析 (避免重复采集)"
        return 0
    fi

    if [[ -z "$pids" ]]; then
        log_warning "未指定进程ID，跳过微架构瓶颈分析"
        return
    fi

    microarch_analysis_success=false

    IFS=',' read -ra pid_array <<< "$pids"
    for single_pid in "${pid_array[@]}"; do
        single_pid=$(echo "$single_pid" | xargs)

        log_info "执行：微架构瓶颈分析 (PID=$single_pid)"

        temp_microarch_file="${output_dir}/microarch_analysis.txt.tmp.${single_pid}"

        echo "============================================================" > "$temp_microarch_file"
        echo "Phase 4: Microarchitecture Bottleneck Analysis (PID=$single_pid)" >> "$temp_microarch_file"
        echo "============================================================" >> "$temp_microarch_file"
        echo "" >> "$temp_microarch_file"

        if ! check_command perf; then
            echo "错误: perf命令未找到，跳过微架构瓶颈分析" >> "$temp_microarch_file"
            log_error "perf命令未找到"

            cat "$temp_microarch_file" >> "$output_dir/err_log.txt"

            rm -f "$temp_microarch_file"
            continue
        fi
        echo "--- Checking perf permissions ---" >> "$temp_microarch_file"
        if ! timeout 2 perf stat -p "$single_pid" -e cycles sleep 0.1 2>/dev/null; then
            echo "错误: 权限不足，无法使用 perf 分析进程 PID=$single_pid" >> "$temp_microarch_file"
            echo "" >> "$temp_microarch_file"
            echo "解决方案:" >> "$temp_microarch_file"
            echo "1. 以 root 用户运行脚本" >> "$temp_microarch_file"
            echo "2. 或调整系统设置: echo 0 > /proc/sys/kernel/perf_event_paranoid" >> "$temp_microarch_file"
            echo "3. 或在容器中添加 CAP_PERFMON 或 SYS_ADMIN capability" >> "$temp_microarch_file"
            log_error "权限不足，无法使用 perf 分析进程 PID=$single_pid"

            cat "$temp_microarch_file" >> "$output_dir/err_log.txt"

            rm -f "$temp_microarch_file"
            continue
        fi

        local pid_analysis_success=false
        local analysis_output=""

        echo "========== CPU Cache Analysis ==========" >> "$temp_microarch_file"

        echo "--- Cache Miss Rates (${duration}s) ---" >> "$temp_microarch_file"
        if cache_output=$(timeout $((duration + 5)) perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses -p "$single_pid" -- sleep "$duration" 2>&1); then
            echo "$cache_output" >> "$temp_microarch_file"
            pid_analysis_success=true
            echo "✓ Cache analysis completed" >> "$temp_microarch_file"
        else
            echo "警告: Cache analysis failed (可能需要 root 权限或硬件不支持)" >> "$temp_microarch_file"
            echo "错误信息: $cache_output" >> "$temp_microarch_file"
        fi
        echo "" >> "$temp_microarch_file"

        echo "--- TLB Miss Statistics (${duration}s, tolerate if unavailable) ---" >> "$temp_microarch_file"
        if tlb_output=$(timeout $((duration + 5)) perf stat -e dTLB-load-misses,iTLB-load-misses -p "$single_pid" -- sleep "$duration" 2>&1); then
            echo "$tlb_output" >> "$temp_microarch_file"
            pid_analysis_success=true
        else
            echo "提示: TLB analysis failed (可能硬件不支持)" >> "$temp_microarch_file"
            echo "错误信息: $tlb_output" >> "$temp_microarch_file"
        fi
        echo "" >> "$temp_microarch_file"

        echo "========== Branch Prediction and Pipeline Analysis ==========" >> "$temp_microarch_file"

        echo "--- Branch Misprediction Rate (${duration}s, tolerate if unavailable) ---" >> "$temp_microarch_file"
        if branch_output=$(timeout $((duration + 5)) perf stat -e branches,branch-misses -p "$single_pid" -- sleep "$duration" 2>&1); then
            echo "$branch_output" >> "$temp_microarch_file"
            pid_analysis_success=true
        else
            echo "提示: Branch analysis failed (可能硬件不支持)" >> "$temp_microarch_file"
            echo "错误信息: $branch_output" >> "$temp_microarch_file"
        fi
        echo "" >> "$temp_microarch_file"

        echo "--- Pipeline Stall Analysis (${duration}s) ---" >> "$temp_microarch_file"
        if stall_output=$(timeout $((duration + 5)) perf stat -e stalled-cycles-frontend,stalled-cycles-backend,cycles,instructions -p "$single_pid" -- sleep "$duration" 2>&1); then
            echo "$stall_output" >> "$temp_microarch_file"
            pid_analysis_success=true
        else
            echo "警告: Pipeline stall analysis failed (可能需要 root 权限)" >> "$temp_microarch_file"
            echo "错误信息: $stall_output" >> "$temp_microarch_file"
        fi
        echo "" >> "$temp_microarch_file"

        echo "========== Top-Down Microarchitecture Analysis ==========" >> "$temp_microarch_file"

        echo "--- Portable Pipeline Metrics (${duration}s) ---" >> "$temp_microarch_file"
        if topdown_output=$(timeout $((duration + 5)) perf stat -e cycles,instructions -p "$single_pid" -- sleep "$duration" 2>&1); then
            echo "$topdown_output" >> "$temp_microarch_file"
            pid_analysis_success=true
        else
            echo "警告: Top-down analysis failed" >> "$temp_microarch_file"
            echo "错误信息: $topdown_output" >> "$temp_microarch_file"
        fi
        echo "" >> "$temp_microarch_file"

        if grep -q "model name.*Intel\|model name.*AMD" /proc/cpuinfo 2>/dev/null; then
            echo "========== Vendor-Specific Analysis ==========" >> "$temp_microarch_file"

            echo "--- Intel uops Metrics (${duration}s, tolerate if unavailable) ---" >> "$temp_microarch_file"
            if uops_output=$(timeout $((duration + 5)) perf stat -e uops_executed,uops_retired -p "$single_pid" -- sleep "$duration" 2>&1); then
                echo "$uops_output" >> "$temp_microarch_file"
                pid_analysis_success=true
            else
                echo "提示: uops analysis failed (可能硬件不支持或需要 root 权限)" >> "$temp_microarch_file"
                echo "错误信息: $uops_output" >> "$temp_microarch_file"
            fi
            echo "" >> "$temp_microarch_file"

            echo "--- Intel pmu-tools Top-Down (tolerate if not installed) ---" >> "$temp_microarch_file"
            if check_command toplev; then
                if toplev_output=$(timeout $((duration + 5)) toplev -p "$single_pid" --sleep "$duration" 2>&1); then
                    echo "$toplev_output" >> "$temp_microarch_file"
                    pid_analysis_success=true
                else
                    echo "警告: toplev analysis failed" >> "$temp_microarch_file"
                    echo "错误信息: $toplev_output" >> "$temp_microarch_file"
                fi
            else
                echo "提示: toplev 未安装，跳过高级 Top-Down 分析" >> "$temp_microarch_file"
                echo "安装方法: https://github.com/andikleen/pmu-tools" >> "$temp_microarch_file"
            fi
            echo "" >> "$temp_microarch_file"

            echo "========== Memory Bandwidth and NUMA ==========" >> "$temp_microarch_file"

            echo "--- NUMA Locality (${duration}s, tolerate if unavailable) ---" >> "$temp_microarch_file"
            if numa_output=$(timeout $((duration + 5)) perf stat -e node_loads,node_stores,local_loads,remote_loads -p "$single_pid" -- sleep "$duration" 2>&1); then
                echo "$numa_output" >> "$temp_microarch_file"
                pid_analysis_success=true
            else
                echo "提示: NUMA analysis failed (可能系统不是 NUMA 架构或硬件不支持)" >> "$temp_microarch_file"
                echo "错误信息: $numa_output" >> "$temp_microarch_file"
            fi
            echo "" >> "$temp_microarch_file"
        fi

        echo "============================================================" >> "$temp_microarch_file"
        if [ "$pid_analysis_success" = true ]; then
            echo "✓ Microarchitecture analysis completed for PID=$single_pid" >> "$temp_microarch_file"
            log_success "微架构瓶颈分析成功 (PID=$single_pid)"

            if [ ! -f "$output_dir/microarch_analysis.txt" ]; then
                cat "$temp_microarch_file" > "$output_dir/microarch_analysis.txt"
            else
                cat "$temp_microarch_file" >> "$output_dir/microarch_analysis.txt"
            fi
            microarch_analysis_success=true
        else
            echo "✗ Microarchitecture analysis failed for PID=$single_pid" >> "$temp_microarch_file"
            log_error "微架构瓶颈分析失败 (PID=$single_pid)"

            cat "$temp_microarch_file" >> "$output_dir/err_log.txt"
        fi
        echo "============================================================" >> "$temp_microarch_file"

        rm -f "$temp_microarch_file"
    done

    if [ "$microarch_analysis_success" = true ]; then
        echo "" >> "$output_dir/microarch_analysis.txt"
        echo "============================================================" >> "$output_dir/microarch_analysis.txt"
        echo "Phase 4: Microarchitecture Bottleneck Analysis Complete (PIDS=$pids)" >> "$output_dir/microarch_analysis.txt"
        echo "============================================================" >> "$output_dir/microarch_analysis.txt"
        log_success "√ 微架构瓶颈分析完成，结果保存至: $output_dir/microarch_analysis.txt"
    else
        if [ -f "$output_dir/microarch_analysis.txt" ]; then
            rm -f "$output_dir/microarch_analysis.txt"
            log_warning "所有微架构瓶颈分析均失败，未生成 $output_dir/microarch_analysis.txt"
        else
            log_warning "微架构瓶颈分析全部失败，未生成输出文件"
        fi
    fi
}


# ========== os/collect_net_metrics.sh ==========

collect_net_metrics() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：Network Metrics 深度分析"
    
    local NET_METRICS_FILE="${output_dir}/network_metrics_analysis.txt"
    
    net_metrics_success=false
    
    temp_net_file="${NET_METRICS_FILE}.tmp"
    
    echo "============================================================" > "$temp_net_file"
    echo "Phase: Network Metrics for Bottleneck Analysis" >> "$temp_net_file"
    echo "============================================================" >> "$temp_net_file"
    echo "采集时间: $(date)" >> "$temp_net_file"
    echo "持续时间: ${duration}秒" >> "$temp_net_file"
    echo "" >> "$temp_net_file"
    
    echo "=== Network Interfaces ===" >> "$temp_net_file"
    if ip -br link show >> "$temp_net_file" 2>/dev/null; then
        net_metrics_success=true
    else
        echo "Cannot get network interface list" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    
    echo "=== Network Sysctl Configuration ===" >> "$temp_net_file"
    local sysctl_success=false
    for key in tcp_tw_reuse tcp_timestamps tcp_sack tcp_window_scaling tcp_congestion_control \
               tcp_rmem tcp_wmem tcp_mem tcp_max_syn_backlog tcp_fin_timeout ip_local_port_range \
               netdev_max_backlog netdev_budget somaxconn rmem_default rmem_max wmem_default wmem_max; do
        if [ -r "/proc/sys/net/ipv4/${key}" ] 2>/dev/null; then
            echo "${key}: $(cat /proc/sys/net/ipv4/${key} 2>/dev/null)" >> "$temp_net_file"
            sysctl_success=true
        elif [ -r "/proc/sys/net/core/${key}" ] 2>/dev/null; then
            echo "${key}: $(cat /proc/sys/net/core/${key} 2>/dev/null)" >> "$temp_net_file"
            sysctl_success=true
        else
            if [[ "$key" == "tcp_congestion_control" ]]; then
                if [ -r "/proc/sys/net/ipv4/tcp_congestion_control" ]; then
                    echo "${key}: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" >> "$temp_net_file"
                    sysctl_success=true
                fi
            else
                echo "${key}: N/A" >> "$temp_net_file"
            fi
        fi
    done
    if [ "$sysctl_success" = true ]; then
        net_metrics_success=true
    fi
    echo "" >> "$temp_net_file"
    
    echo "=== NIC Configuration ===" >> "$temp_net_file"
    local nic_config_success=false
    ACTIVE_IFACES=$(ip -br link show 2>/dev/null | awk '$2=="UP" {print $1}' | grep -v lo | head -5)
    
    if [ -z "$ACTIVE_IFACES" ]; then
        echo "No active network interfaces found (excluding lo)" >> "$temp_net_file"
    else
        for iface in $ACTIVE_IFACES; do
            echo "--- $iface ---" >> "$temp_net_file"
            
            if command -v ethtool &> /dev/null; then
                echo "Link Info:" >> "$temp_net_file"
                if ethtool $iface 2>/dev/null | grep -E "Speed|Duplex|Link detected|Auto-negotiation" | sed 's/^\t*//' >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "Driver Info:" >> "$temp_net_file"
                if ethtool -i $iface 2>/dev/null | grep -E "driver|version|firmware|bus-info" | sed 's/^[^:]*: //' | paste -sd, - >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "[Queue/Channel Configuration]" >> "$temp_net_file"
                if ethtool -l $iface 2>/dev/null >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "[Ring Buffer]" >> "$temp_net_file"
                if ethtool -g $iface 2>/dev/null >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "[Coalesce Settings]" >> "$temp_net_file"
                if ethtool -c $iface 2>/dev/null >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "[Pause Frame]" >> "$temp_net_file"
                if ethtool -a $iface 2>/dev/null >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                echo "" >> "$temp_net_file"
                echo "[Offload Features]" >> "$temp_net_file"
                if ethtool -k $iface 2>/dev/null | head -30 >> "$temp_net_file"; then
                    nic_config_success=true
                fi
                
                BUS_INFO=$(ethtool -i $iface 2>/dev/null | grep 'bus-info' | awk '{print $2}')
                if [ -n "$BUS_INFO" ]; then
                    echo "" >> "$temp_net_file"
                    echo "--- IRQ Affinity ---" >> "$temp_net_file"
                    if grep "$BUS_INFO" /proc/interrupts 2>/dev/null | while read -r line; do
                        IRQ=$(echo "$line" | awk '{print $1}' | tr -d ':')
                        AFFINITY=$(cat /proc/irq/$IRQ/smp_affinity 2>/dev/null || echo 'N/A')
                        DESC=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
                        echo "IRQ $IRQ: $AFFINITY  ($DESC)" >> "$temp_net_file"
                    done; then
                        nic_config_success=true
                    fi
                fi
            else
                echo "ethtool not available for detailed NIC info" >> "$temp_net_file"
            fi
            echo "" >> "$temp_net_file"
        done
    fi
    if [ "$nic_config_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== Network Performance Data Collection (${duration} seconds) ===" >> "$temp_net_file"
    
    ACTIVE_IFACES=$(ip -br link show 2>/dev/null | awk '$2=="UP" && $1!="lo" {print $1}' | head -5 | paste -sd,)
    
    SAR_DEV_TMP="/tmp/sar_dev_$$.txt"
    SAR_EDEV_TMP="/tmp/sar_edeve_$$.txt"
    local sar_success=false
    
    if command -v sar &> /dev/null; then
        if [ -n "$ACTIVE_IFACES" ]; then
            sar -n DEV 1 $duration --iface="$ACTIVE_IFACES" > "$SAR_DEV_TMP" 2>&1 &
            SAR_DEV_PID=$!
            
            sar -n EDEV 1 $duration --iface="$ACTIVE_IFACES" > "$SAR_EDEV_TMP" 2>&1 &
            SAR_EDEV_PID=$!
            
            wait $SAR_DEV_PID $SAR_EDEV_PID 2>/dev/null
            
            echo "--- Network Device Stats (sar -n DEV) ---" >> "$temp_net_file"
            if [ -f "$SAR_DEV_TMP" ] && [ -s "$SAR_DEV_TMP" ]; then
                tail -n +4 "$SAR_DEV_TMP" >> "$temp_net_file"
                sar_success=true
            else
                echo "No data collected" >> "$temp_net_file"
            fi
            echo "" >> "$temp_net_file"
            
            echo "--- Network Error Stats (sar -n EDEV) ---" >> "$temp_net_file"
            if [ -f "$SAR_EDEV_TMP" ] && [ -s "$SAR_EDEV_TMP" ]; then
                tail -n +4 "$SAR_EDEV_TMP" >> "$temp_net_file"
                sar_success=true
            else
                echo "No data collected" >> "$temp_net_file"
            fi
            echo "" >> "$temp_net_file"
            
            rm -f "$SAR_DEV_TMP" "$SAR_EDEV_TMP"
        else
            echo "No active network interfaces for sar monitoring" >> "$temp_net_file"
            echo "" >> "$temp_net_file"
        fi
    else
        echo "sar not available (install sysstat package)" >> "$temp_net_file"
        echo "" >> "$temp_net_file"
    fi
    if [ "$sar_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== Latency Tests ===" >> "$temp_net_file"
    local latency_success=false
    
    GATEWAY=$(ip route 2>/dev/null | grep default | awk '{print $3}' | head -1)
    if [ -n "$GATEWAY" ]; then
        echo "Default gateway: $GATEWAY" >> "$temp_net_file"
        PING_GW_TMP="/tmp/ping_gw_$$.txt"
        if ping -c 5 "$GATEWAY" 2>/dev/null > "$PING_GW_TMP"; then
            if [ -s "$PING_GW_TMP" ]; then
                tail -2 "$PING_GW_TMP" >> "$temp_net_file"
                latency_success=true
            else
                echo "Gateway unreachable or ping failed" >> "$temp_net_file"
            fi
        else
            echo "Gateway ping failed" >> "$temp_net_file"
        fi
        rm -f "$PING_GW_TMP"
    else
        echo "No default gateway found" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    
    echo "--- Loopback Latency Test ---" >> "$temp_net_file"
    PING_LO_TMP="/tmp/ping_lo_$$.txt"
    if ping -c 5 127.0.0.1 2>/dev/null > "$PING_LO_TMP"; then
        if [ -s "$PING_LO_TMP" ]; then
            tail -2 "$PING_LO_TMP" >> "$temp_net_file"
            latency_success=true
        fi
    else
        echo "Loopback ping failed" >> "$temp_net_file"
    fi
    rm -f "$PING_LO_TMP"
    echo "" >> "$temp_net_file"
    
    if [ "$latency_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== TCP Statistics ===" >> "$temp_net_file"
    local tcp_stats_success=false
    if command -v netstat &> /dev/null; then
        if netstat -s 2>/dev/null | sed -n '/^Tcp:/,/^$/p' | head -50 >> "$temp_net_file"; then
            tcp_stats_success=true
        else
            echo "netstat command failed" >> "$temp_net_file"
        fi
    else
        echo "netstat not available" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    if [ "$tcp_stats_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== Socket Summary ===" >> "$temp_net_file"
    local socket_summary_success=false
    if command -v ss &> /dev/null; then
        if ss -s 2>/dev/null >> "$temp_net_file"; then
            socket_summary_success=true
        fi
    else
        echo "ss not available" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    if [ "$socket_summary_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== Socket Memory ===" >> "$temp_net_file"
    if [ -r /proc/net/sockstat ]; then
        cat /proc/net/sockstat >> "$temp_net_file" 2>/dev/null && net_metrics_success=true
    else
        echo "Cannot read /proc/net/sockstat" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    
    echo "=== TCP Connection States Distribution ===" >> "$temp_net_file"
    local tcp_states_success=false
    if command -v ss &> /dev/null; then
        if ss -tan 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 >> "$temp_net_file"; then
            tcp_states_success=true
        fi
    else
        echo "ss not available" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    if [ "$tcp_states_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "=== Network Queue Statistics ===" >> "$temp_net_file"
    if [ -r /proc/net/netstat ]; then
        echo "--- TCP Queue Info ---" >> "$temp_net_file"
        if cat /proc/net/netstat 2>/dev/null | grep -E "TcpExt|IpExt" | head -5 >> "$temp_net_file"; then
            net_metrics_success=true
        fi
    else
        echo "Cannot read /proc/net/netstat" >> "$temp_net_file"
    fi
    echo "" >> "$temp_net_file"
    
    echo "=== Network Optimization Recommendations ===" >> "$temp_net_file"
    local recommendations_success=false
    
    if [ -r /proc/sys/net/ipv4/tcp_mem ]; then
        tcp_mem=$(cat /proc/sys/net/ipv4/tcp_mem 2>/dev/null)
        if [ -n "$tcp_mem" ]; then
            low_pressure=$(echo "$tcp_mem" | awk '{print $1}')
            pressure=$(echo "$tcp_mem" | awk '{print $2}')
            if [ -n "$pressure" ] && [ -n "$low_pressure" ] && [ "$pressure" -gt "$((low_pressure * 2))" ] 2>/dev/null; then
                echo "WARNING: TCP memory under pressure. Consider increasing tcp_mem or reducing connections." >> "$temp_net_file"
                recommendations_success=true
            fi
        fi
    fi
    
    if command -v ss &> /dev/null; then
        timewait_count=$(ss -tan 2>/dev/null | grep -c TIME-WAIT)
        if [ -n "$timewait_count" ]; then
            if [ "$timewait_count" -gt 10000 ] 2>/dev/null; then
                echo "WARNING: High number of TIME_WAIT connections ($timewait_count). Consider adjusting tcp_tw_reuse and tcp_fin_timeout." >> "$temp_net_file"
                recommendations_success=true
            elif [ "$timewait_count" -gt 5000 ] 2>/dev/null; then
                echo "INFO: Moderate TIME_WAIT connections ($timewait_count). Consider optimizing if sustained." >> "$temp_net_file"
                recommendations_success=true
            fi
        fi
    fi
    
    if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
        port_range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
        if [ -n "$port_range" ]; then
            start_port=$(echo "$port_range" | awk '{print $1}')
            end_port=$(echo "$port_range" | awk '{print $2}')
            total_ports=$((end_port - start_port + 1))
            if command -v ss &> /dev/null; then
                used_ports=$(ss -tan 2>/dev/null | grep -c "ESTAB\|TIME_WAIT")
                if [ -n "$used_ports" ] && [ -n "$total_ports" ] && [ "$used_ports" -gt "$((total_ports * 80 / 100))" ] 2>/dev/null; then
                    echo "WARNING: Port range nearly exhausted (${used_ports}/${total_ports} used). Consider widening ip_local_port_range." >> "$temp_net_file"
                    recommendations_success=true
                fi
            fi
        fi
    fi
    
    if command -v ethtool &> /dev/null && [ -n "$ACTIVE_IFACES" ]; then
        for iface in $ACTIVE_IFACES; do
            combined=$(ethtool -l $iface 2>/dev/null | grep -A5 "Current" | grep Combined | awk '{print $2}')
            if [ -n "$combined" ] && [ "$combined" -eq 1 ] 2>/dev/null; then
                echo "INFO: Interface $iface has only 1 combined queue. Consider increasing for better SMP performance." >> "$temp_net_file"
                recommendations_success=true
                break
            fi
        done
    fi

    echo "" >> "$NET_METRICS_FILE"

    echo "=== 接口详细状态 (/sys/class/net) ===" >> "$NET_METRICS_FILE"
    for iface_dir in /sys/class/net/*; do
        iface_name=$(basename "$iface_dir")
        ifindex=$(cat "$iface_dir/ifindex" 2>/dev/null || echo "N/A")
        operstate=$(cat "$iface_dir/operstate" 2>/dev/null || echo "N/A")
        carrier=$(cat "$iface_dir/carrier" 2>/dev/null || echo "N/A")
        mtu=$(cat "$iface_dir/mtu" 2>/dev/null || echo "N/A")
        speed=$(cat "$iface_dir/speed" 2>/dev/null || echo "N/A")
        duplex=$(cat "$iface_dir/duplex" 2>/dev/null || echo "N/A")
        echo "$iface_name: ifindex=$ifindex operstate=$operstate carrier=$carrier mtu=$mtu speed=$speed duplex=$duplex" >> "$NET_METRICS_FILE"
    done
    echo "" >> "$NET_METRICS_FILE"

    echo "=== ip addr show ===" >> "$NET_METRICS_FILE"
    ip addr show 2>/dev/null >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 路由表 (ip route show) ===" >> "$NET_METRICS_FILE"
    ip route show 2>/dev/null >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== ARP 表 ===" >> "$NET_METRICS_FILE"
    arp -n 2>/dev/null >> "$NET_METRICS_FILE" || cat /proc/net/arp 2>/dev/null >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 网络统计 (netstat -s) 完整版 ===" >> "$NET_METRICS_FILE"
    netstat -s 2>/dev/null >> "$NET_METRICS_FILE" || { cat /proc/net/netstat 2>/dev/null >> "$NET_METRICS_FILE"; cat /proc/net/snmp 2>/dev/null >> "$NET_METRICS_FILE"; }
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 监听端口 (ss -tlnp) ===" >> "$NET_METRICS_FILE"
    ss -tlnp 2>/dev/null >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 网卡队列与 RPS 配置 ===" >> "$NET_METRICS_FILE"
    for iface_dir in /sys/class/net/*; do
        iface_name=$(basename "$iface_dir")
        if [ "$iface_name" != "lo" ] && [ -d "$iface_dir/queues" ]; then
            rx_count=$(ls -d "$iface_dir/queues/rx-"* 2>/dev/null | wc -l)
            tx_count=$(ls -d "$iface_dir/queues/tx-"* 2>/dev/null | wc -l)
            echo "$iface_name: RX队列=$rx_count, TX队列=$tx_count" >> "$NET_METRICS_FILE"
            if [ -f "$iface_dir/queues/rx-0/rps_cpus" ]; then
                echo "  RPS cpus (rx-0): $(cat "$iface_dir/queues/rx-0/rps_cpus")" >> "$NET_METRICS_FILE"
            fi
            if [ -f "$iface_dir/queues/rx-0/rps_flow_cnt" ]; then
                echo "  RPS flow_cnt (rx-0): $(cat "$iface_dir/queues/rx-0/rps_flow_cnt")" >> "$NET_METRICS_FILE"
            fi
        fi
    done
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 网卡 ntuple 支持 ===" >> "$NET_METRICS_FILE"
    for iface_dir in /sys/class/net/*; do
        iface_name=$(basename "$iface_dir")
        [ "$iface_name" = "lo" ] && continue
        if command -v ethtool &>/dev/null; then
            ntuple_info=$(ethtool -k "$iface_name" 2>/dev/null | grep ntuple || echo 'ntuple: unknown')
            echo "$iface_name: $ntuple_info" >> "$NET_METRICS_FILE"
        fi
    done
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 网络排队规则 (tc qdisc show) ===" >> "$NET_METRICS_FILE"
    tc qdisc show 2>/dev/null >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== /proc/net/dev ===" >> "$NET_METRICS_FILE"
    cat /proc/net/dev 2>/dev/null >> "$NET_METRICS_FILE" || echo "不可用" >> "$NET_METRICS_FILE"
    echo "" >> "$NET_METRICS_FILE"

    echo "=== 常见进程名列表 (Top 30) ===" >> "$NET_METRICS_FILE"
    ps -eo comm --no-headers 2>/dev/null | sort -u | head -30 >> "$NET_METRICS_FILE"
    
    if [ "$recommendations_success" = true ]; then
        net_metrics_success=true
    fi
    
    echo "" >> "$temp_net_file"
    echo "============================================================" >> "$temp_net_file"
    echo "Network Metrics Analysis Complete" >> "$temp_net_file"
    echo "============================================================" >> "$temp_net_file"
    
    rm -f /tmp/sar_*_$$.txt /tmp/ping_*_$$.txt
    
    if [ "$net_metrics_success" = true ]; then
        mv "$temp_net_file" "$NET_METRICS_FILE"
        log_success "Network Metrics 深度分析完成，结果保存至: $NET_METRICS_FILE"
    else
        rm -f "$temp_net_file"
        log_warning "Network Metrics 深度分析全部失败，未生成 $NET_METRICS_FILE"
    fi
}


# ========== os/collect_process_detail_info.sh ==========

_collect_thread_poll() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：线程生命周期轮询 (${duration}s, 间隔1s)"
    
    local PROCESS_DETAIL_INFO_FILE="${output_dir}/process_detail_info.txt"
    
    > "$PROCESS_DETAIL_INFO_FILE"
    echo "============================================================" >> "$PROCESS_DETAIL_INFO_FILE"
    echo "线程生命周期轮询采集" >> "$PROCESS_DETAIL_INFO_FILE"
    echo "采集时长: ${duration}s, 采样间隔: 1s" >> "$PROCESS_DETAIL_INFO_FILE"
    echo "============================================================" >> "$PROCESS_DETAIL_INFO_FILE"
    echo "" >> "$PROCESS_DETAIL_INFO_FILE"

    local tmpd="${output_dir}/.thread_poll_tmp"
    mkdir -p "$tmpd"
    local event_log="$tmpd/events.log"
    > "$event_log"

    collect_snapshot() {
        local ts="$1"
        local snap="$tmpd/thread_ts_${ts}.txt"
        echo "=== TIMESTAMP $ts ===" > "$snap"
        for pid_dir in /proc/[0-9]*/task; do
            [ -d "$pid_dir" ] || continue
            for tid_dir in "$pid_dir"/*; do
                [ -d "$tid_dir" ] || continue
                local tid=$(basename "$tid_dir")
                local comm=$(cat "$tid_dir/comm" 2>/dev/null || echo "?")
                local mtime=$(stat -c "%Y" "$tid_dir" 2>/dev/null || echo "0")
                echo "TID=$tid COMM=$comm MTIME=$mtime" >> "$snap"
            done
        done
        echo "$snap"
    }

    local round=0
    local start_ts=$(date +%s)

    while [ $(( $(date +%s) - start_ts )) -lt "$duration" ]; do
        round=$((round + 1))
        local current_ts=$(date +%s)
        local snap_file=$(collect_snapshot "$current_ts")
        local thread_count=$(grep -c '^TID=' "$snap_file" 2>/dev/null || echo 0)
        log_info "线程轮询 第${round}轮: $thread_count 线程"

        local current_tids="$tmpd/current_tids.txt"
        awk -F'[= ]' '/^TID=/{print $2" "$6}' "$snap_file" > "$current_tids"

        if [ "$round" -gt 1 ]; then
            local prev_tids="$tmpd/prev_tids.txt"
            while read -r prev_tid prev_mtime; do
                local new_mtime=$(awk -v tid="$prev_tid" '$1 == tid {print $2}' "$current_tids")
                [ -z "$new_mtime" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] THREAD_EXIT TID=$prev_tid" >> "$event_log"
            done < "$prev_tids"
            while read -r cur_tid cur_mtime; do
                local old_mtime=$(awk -v tid="$cur_tid" '$1 == tid {print $2}' "$prev_tids")
                [ -z "$old_mtime" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] THREAD_CREATE TID=$cur_tid" >> "$event_log"
            done < "$current_tids"
        fi

        cp "$current_tids" "$tmpd/prev_tids.txt"

        if [ $(( $(date +%s) - start_ts )) -lt "$duration" ]; then
            sleep 1
        fi
    done

    local total_creates=$(grep -c "THREAD_CREATE" "$event_log" 2>/dev/null || echo 0)
    local total_exits=$(grep -c "THREAD_EXIT" "$event_log" 2>/dev/null || echo 0)
    {
        echo "=== 轮询统计 ==="
        echo "采样轮次: $round"
        echo "线程创建事件: $total_creates 次"
        echo "线程销毁事件: $total_exits 次"
        echo ""
        echo "--- 线程创建事件 (前50条) ---"
        grep "THREAD_CREATE" "$event_log" 2>/dev/null | head -50
        echo ""
        echo "--- 线程销毁事件 (前50条) ---"
        grep "THREAD_EXIT" "$event_log" 2>/dev/null | head -50
        echo ""
        echo "--- 当前线程总数 ---"
        if [ -f "$current_tids" ]; then
            wc -l < "$current_tids"
        else
            echo "无法获取"
        fi
    } >> "$PROCESS_DETAIL_INFO_FILE"

    rm -rf "$tmpd"
    log_success "线程生命周期轮询完成"
}

collect_process_detail_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：进程/线程详细信息采集"
    
    local PROCESS_DETAIL_INFO_FILE="${output_dir}/process_detail_info.txt"
    
    > "$PROCESS_DETAIL_INFO_FILE"
    {
        echo "============================================================"
        echo "进程/线程详细信息采集"
        echo "采集时间: $(date)"
        echo "============================================================"
        echo ""

        echo "--- 系统整体进程/线程数 ---"
        echo "进程总数: $(ps -e --no-headers 2>/dev/null | wc -l)"
        echo "线程总数: $(ps -eLf --no-headers 2>/dev/null | wc -l)"
        echo ""

        echo "=== 进程状态分布 ==="
        ps -eo stat --no-headers 2>/dev/null | sed 's/\(.\).*/\1/' | sort | uniq -c | sort -rn
        echo ""

        if command -v pidstat &>/dev/null; then
            echo "=== pidstat CPU 采样 (${duration}秒) ==="
            pidstat -u 1 "$duration" 2>/dev/null || echo "pidstat -u 失败"
            echo ""

            echo "=== pidstat 内存快照 (1秒) ==="
            pidstat -r 1 1 2>/dev/null || echo "pidstat -r 失败"
            echo ""

            echo "=== pidstat I/O 快照 (1秒) ==="
            pidstat -d 1 1 2>/dev/null || echo "pidstat -d 失败"
            echo ""

            echo "=== 线程级 CPU 统计 (pidstat -t -u 1 3) ==="
            pidstat -t -u 1 3 2>/dev/null || echo "线程级 pidstat 不支持"
            echo ""
        fi

        echo "=== 线程最多的进程 (Top 10) ==="
        ps -eo pid,comm,nlwp --sort=-nlwp 2>/dev/null | head -11
        echo ""

        echo "=== Top CPU 进程线程详情 ==="
        TOP_PIDS=$(ps -eo pid --sort=-%cpu --no-headers 2>/dev/null | head -5 | tr '\n' ' ')
        for pid in $TOP_PIDS; do
            if [ -d "/proc/$pid/task" ]; then
                comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
                thread_count=$(ls "/proc/$pid/task" 2>/dev/null | wc -l)
                echo "PID=$pid ($comm): $thread_count 线程"
                echo "TID 列表 (前20):"
                ls "/proc/$pid/task/" 2>/dev/null | head -20
                echo ""
            fi
        done

        echo "=== /proc/schedstat (前20行) ==="
        head -20 /proc/schedstat 2>/dev/null || echo "不可用"
        echo ""

        echo "=== 系统 PID/线程限制 ==="
        cat /proc/sys/kernel/pid_max 2>/dev/null | awk '{print "pid_max: " $1}' || echo "pid_max: 不可用"
        cat /proc/sys/kernel/threads-max 2>/dev/null | awk '{print "threads-max: " $1}' || echo "threads-max: 不可用"
        echo ""

        echo "=== 关键进程检查 ==="
        pgrep -a redis-server 2>/dev/null || echo "redis-server 未运行"
        echo ""
    } >> "$PROCESS_DETAIL_INFO_FILE"

    _collect_thread_poll

    log_success "进程/线程详细信息采集完成"
}


# ========== os/collect_sched_trace.sh ==========

collect_sched_trace() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：Scheduler Trace 深度分析"
    
    local SCHED_TRACE_FILE="${output_dir}/scheduler_trace_analysis.txt"
    
    sched_trace_success=false
    
    temp_sched_file="${SCHED_TRACE_FILE}.tmp"
    
    echo "============================================================" > "$temp_sched_file"
    echo "Phase: Scheduler Trace for Latency and Scheduling Analysis" >> "$temp_sched_file"
    echo "============================================================" >> "$temp_sched_file"
    echo "采集时间: $(date)" >> "$temp_sched_file"
    echo "持续时间: ${duration}秒" >> "$temp_sched_file"
    if [[ -n "$pids" ]]; then
        echo "目标进程: $pids" >> "$temp_sched_file"
    fi
    echo "" >> "$temp_sched_file"
    
    echo "=== Prerequisites ===" >> "$temp_sched_file"
    local prereq_success=false
    if [ -r /proc/sys/kernel/perf_event_paranoid ]; then
        echo "perf_event_paranoid: $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" >> "$temp_sched_file"
        prereq_success=true
    else
        echo "perf_event_paranoid: N/A" >> "$temp_sched_file"
    fi
    if [ -r /proc/sys/kernel/sched_schedstats ]; then
        echo "sched_schedstats: $(cat /proc/sys/kernel/sched_schedstats 2>/dev/null)" >> "$temp_sched_file"
        prereq_success=true
    else
        echo "sched_schedstats: N/A" >> "$temp_sched_file"
    fi
    if [ "$prereq_success" = true ]; then
        sched_trace_success=true
    fi
    echo "" >> "$temp_sched_file"
    
    echo "=== Scheduler Configuration ===" >> "$temp_sched_file"
    local sched_config_success=false
    
    sched_latency="N/A"
    if [ -f /proc/sys/kernel/sched_latency_ns ] && [ -r /proc/sys/kernel/sched_latency_ns ]; then
        sched_latency=$(cat /proc/sys/kernel/sched_latency_ns 2>/dev/null)
        echo "sched_latency_ns: $sched_latency" >> "$temp_sched_file"
        sched_config_success=true
    elif [ -f /sys/kernel/debug/sched/base_slice_ns ] && [ -r /sys/kernel/debug/sched/base_slice_ns ]; then
        sched_latency=$(cat /sys/kernel/debug/sched/base_slice_ns 2>/dev/null)
        echo "base_slice_ns: $sched_latency" >> "$temp_sched_file"
        sched_config_success=true
    else
        echo "sched_latency_ns (base_slice_ns): N/A" >> "$temp_sched_file"
    fi
    
    if [ -f /proc/sys/kernel/sched_min_granularity_ns ] && [ -r /proc/sys/kernel/sched_min_granularity_ns ]; then
        echo "sched_min_granularity_ns: $(cat /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    else
        echo "sched_min_granularity_ns: N/A (implicit on 6.x, ~0.75 * base_slice_ns)" >> "$temp_sched_file"
    fi
    
    if [ -f /proc/sys/kernel/sched_wakeup_granularity_ns ] && [ -r /proc/sys/kernel/sched_wakeup_granularity_ns ]; then
        echo "sched_wakeup_granularity_ns: $(cat /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    else
        echo "sched_wakeup_granularity_ns: N/A (implicit on 6.x, ~1.0 * base_slice_ns)" >> "$temp_sched_file"
    fi
    
    if [ -f /proc/sys/kernel/sched_tunable_scaling ] && [ -r /proc/sys/kernel/sched_tunable_scaling ]; then
        echo "sched_tunable_scaling: $(cat /proc/sys/kernel/sched_tunable_scaling 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    elif [ -f /sys/kernel/debug/sched/tunable_scaling ] && [ -r /sys/kernel/debug/sched/tunable_scaling ]; then
        echo "sched_tunable_scaling: $(cat /sys/kernel/debug/sched/tunable_scaling 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    else
        echo "sched_tunable_scaling: N/A" >> "$temp_sched_file"
    fi
    
    if [ -f /proc/sys/kernel/sched_migration_cost_ns ] && [ -r /proc/sys/kernel/sched_migration_cost_ns ]; then
        echo "sched_migration_cost_ns: $(cat /proc/sys/kernel/sched_migration_cost_ns 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    elif [ -f /sys/kernel/debug/sched/migration_cost_ns ] && [ -r /sys/kernel/debug/sched/migration_cost_ns ]; then
        echo "sched_migration_cost_ns: $(cat /sys/kernel/debug/sched/migration_cost_ns 2>/dev/null)" >> "$temp_sched_file"
        sched_config_success=true
    fi
    
    for key in sched_autogroup_enabled sched_child_runs_first sched_rt_period_us sched_rt_runtime_us; do
        if [ -r "/proc/sys/kernel/$key" ]; then
            echo "$key: $(cat /proc/sys/kernel/$key 2>/dev/null)" >> "$temp_sched_file"
            sched_config_success=true
        fi
    done
    
    if [ -r /proc/cmdline ]; then
        cmdline=$(cat /proc/cmdline 2>/dev/null)
        isolcpus=$(echo "$cmdline" | grep -o 'isolcpus=[^ ]*' || echo 'N/A')
        nohz_full=$(echo "$cmdline" | grep -o 'nohz_full=[^ ]*' || echo 'N/A')
        echo "isolcpus: $isolcpus" >> "$temp_sched_file"
        echo "nohz_full: $nohz_full" >> "$temp_sched_file"
        if [ "$isolcpus" != "N/A" ] || [ "$nohz_full" != "N/A" ]; then
            sched_config_success=true
        fi
    fi
    
    if [ "$sched_config_success" = true ]; then
        sched_trace_success=true
    fi
    echo "" >> "$temp_sched_file"
    
    echo "=== Run Queue Status ===" >> "$temp_sched_file"
    if command -v vmstat &> /dev/null; then
        if vmstat 1 2 2>/dev/null | tail -1 | awk '{print "running:", $1, "blocked:", $2}' >> "$temp_sched_file"; then
            sched_trace_success=true
        else
            echo "vmstat command failed" >> "$temp_sched_file"
        fi
    else
        echo "vmstat not available" >> "$temp_sched_file"
    fi
    echo "" >> "$temp_sched_file"
    
    local process_info_success=false
    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)
            if ps -p "$single_pid" > /dev/null 2>&1; then
                echo "=== Target Process Info (PID: $single_pid) ===" >> "$temp_sched_file"
                if ps -p $single_pid -o pid,comm,state,pri,ni,nlwp --no-headers 2>/dev/null >> "$temp_sched_file"; then
                    process_info_success=true
                fi
                
                if command -v taskset &> /dev/null; then
                    echo "CPU Affinity:" >> "$temp_sched_file"
                    if taskset -pc $single_pid >> "$temp_sched_file" 2>/dev/null; then
                        process_info_success=true
                    fi
                fi
                
                if command -v chrt &> /dev/null; then
                    policy=$(chrt -p $single_pid 2>/dev/null | grep policy | awk '{print $NF}')
                    priority=$(chrt -p $single_pid 2>/dev/null | grep priority | awk '{print $NF}')
                    if [ -n "$policy" ]; then
                        echo "Scheduler Policy: $policy" >> "$temp_sched_file"
                        echo "RT Priority: $priority" >> "$temp_sched_file"
                        process_info_success=true
                    fi
                fi
                echo "" >> "$temp_sched_file"
            fi
        done
    fi
    if [ "$process_info_success" = true ]; then
        sched_trace_success=true
    fi
    
    echo "=== Recording perf sched data (timeout ${duration}s) ===" >> "$temp_sched_file"
    
    PERF_EVENTS="sched:sched_switch,sched:sched_wakeup,sched:sched_wakeup_new,sched:sched_migrate_task"
    local perf_sched_success=false
    
    if command -v perf &> /dev/null; then
        if [[ $EUID -ne 0 ]]; then
            log_warning "非root用户运行perf可能限制调度事件采集"
        fi
        
        local perf_data_file="${output_dir}/sched_perf.data"
        local perf_record_output=$(mktemp)
        
        if perf sched record -a -e $PERF_EVENTS -o "$perf_data_file" sleep ${duration} 2>&1 > "$perf_record_output"; then
            if [ -f "$perf_data_file" ] && [ -s "$perf_data_file" ]; then
                PERF_SIZE=$(du -h "$perf_data_file" 2>/dev/null | cut -f1)
                echo "sched_perf.data created: $PERF_SIZE" >> "$temp_sched_file"
                echo "" >> "$temp_sched_file"
                perf_sched_success=true
                
                echo "=== Scheduling Latency (sorted by max/avg delay) ===" >> "$temp_sched_file"
                if perf sched latency --sort max,avg 2>&1 | head -30 >> "$temp_sched_file"; then
                    perf_sched_success=true
                fi
                echo "" >> "$temp_sched_file"
                
                echo "=== Scheduling Latency (sorted by runtime) ===" >> "$temp_sched_file"
                if perf sched latency 2>&1 | head -30 >> "$temp_sched_file"; then
                    perf_sched_success=true
                fi
                echo "" >> "$temp_sched_file"
                
                echo "=== Time History (first 50 lines) ===" >> "$temp_sched_file"
                if perf sched timehist 2>&1 | head -50 >> "$temp_sched_file"; then
                    perf_sched_success=true
                fi
                echo "" >> "$temp_sched_file"
                
                if [[ -n "$pids" ]]; then
                    IFS=',' read -ra pid_array <<< "$pids"
                    for single_pid in "${pid_array[@]}"; do
                        single_pid=$(echo "$single_pid" | xargs)
                        
                        echo "=== Target Process Analysis (PID: $single_pid) ===" >> "$temp_sched_file"
                        
                        SCHED_SCRIPT="/tmp/perf_sched_script_${single_pid}_$$.txt"
                        if perf sched script > "$SCHED_SCRIPT" 2>&1; then
                            SWITCH_COUNT=$(grep -c "sched_switch: .*:${single_pid} \[.*\] . ==> " "$SCHED_SCRIPT" 2>/dev/null || echo "0")
                            echo "Schedule Out Events: $SWITCH_COUNT" >> "$temp_sched_file"
                            if [ "$SWITCH_COUNT" -gt 0 ] 2>/dev/null && [ "$duration" -gt 0 ] 2>/dev/null; then
                                FREQ=$(echo "scale=2; $SWITCH_COUNT / $duration" | bc 2>/dev/null)
                                if [ -n "$FREQ" ] && [ "$FREQ" != "0" ]; then
                                    echo "Frequency: ${FREQ} events/s" >> "$temp_sched_file"
                                else
                                    echo "Frequency: N/A" >> "$temp_sched_file"
                                fi
                            fi
                            echo "" >> "$temp_sched_file"
                            
                            echo "=== Preemptors (processes that ran before target, top 10 cnts) ===" >> "$temp_sched_file"
                            grep "==> .*:${single_pid} \[" "$SCHED_SCRIPT" 2>/dev/null | \
                                sed 's/.*sched_switch: //' | sed 's/ ==> .*//' | awk '{print $1}' | \
                                sort | uniq -c | sort -rn | head -10 >> "$temp_sched_file"
                            echo "" >> "$temp_sched_file"
                            
                            echo "=== Successors (processes that ran after target, top 10 cnts) ===" >> "$temp_sched_file"
                            grep "sched_switch: .*:${single_pid} \[.*\] . ==> " "$SCHED_SCRIPT" 2>/dev/null | \
                                sed 's/.*==> //' | awk '{print $1}' | \
                                sort | uniq -c | sort -rn | head -10 >> "$temp_sched_file"
                            echo "" >> "$temp_sched_file"
                            
                            perf_sched_success=true
                        fi
                        
                        echo "=== Time History for Target ===" >> "$temp_sched_file"
                        if perf sched timehist --tid $single_pid 2>&1 | head -50 >> "$temp_sched_file"; then
                            perf_sched_success=true
                        fi
                        echo "" >> "$temp_sched_file"
                        
                        echo "=== Wakeup Latency for Target ===" >> "$temp_sched_file"
                        SCHED_TIMEHIST_TARGET="/tmp/perf_sched_timehist_${single_pid}_$$.txt"
                        if perf sched timehist --tid $single_pid > "$SCHED_TIMEHIST_TARGET" 2>&1; then
                            awk 'NR>3 && NF>=6 {wait+=$4; delay+=$5; if($4>max_w) max_w=$4; if($5>max_d) max_d=$5; n++} END {if(n>0) printf "Avg wait: %.3f ms, sch_delay: %.3f ms, Max wait: %.3f ms, Max delay: %.3f ms (samples: %d)\n", wait/n, delay/n, max_w, max_d, n}' "$SCHED_TIMEHIST_TARGET" >> "$temp_sched_file"
                            perf_sched_success=true
                        fi
                        echo "" >> "$temp_sched_file"
                        
                        rm -f "$SCHED_SCRIPT" "$SCHED_TIMEHIST_TARGET"
                    done
                fi
                
                log_info "sched_perf.data 文件已保存在: ${output_dir}/sched_perf.data"
            else
                echo "Error: sched_perf.data not created or empty" >> "$temp_sched_file"
                log_error "sched_perf.data 创建失败"
            fi
        else
            echo "Error: perf sched record failed" >> "$temp_sched_file"
            if [ -f "$perf_record_output" ] && [ -s "$perf_record_output" ]; then
                echo "Error details:" >> "$temp_sched_file"
                cat "$perf_record_output" >> "$temp_sched_file"
            fi
            log_error "perf sched record 执行失败"
        fi
        rm -f "$perf_record_output"
    else
        echo "perf command not available" >> "$temp_sched_file"
        log_error "perf命令未找到"
    fi
    
    if [ "$perf_sched_success" = true ]; then
        sched_trace_success=true
    fi
    
    echo "" >> "$temp_sched_file"
    
    echo "=== Scheduler Optimization Recommendations ===" >> "$temp_sched_file"
    local recommendations_success=false
    
    if [ -n "$sched_latency" ] && [ "$sched_latency" -gt 8000000 ] 2>/dev/null; then
        echo "INFO: High scheduler latency (${sched_latency}ns > 8ms). Consider reducing for better responsiveness." >> "$temp_sched_file"
        recommendations_success=true
    fi
    
    if [ -r /proc/sys/kernel/sched_rt_runtime_us ]; then
        rt_runtime=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null)
        if [ -n "$rt_runtime" ] && [ "$rt_runtime" -eq 0 ] 2>/dev/null; then
            echo "INFO: sched_rt_runtime_us=0 (RT tasks unlimited). Consider setting to 950000 to reserve 5% for SCHED_OTHER." >> "$temp_sched_file"
            recommendations_success=true
        fi
    fi
    
    if [ -r /proc/cmdline ] && grep -q "isolcpus" /proc/cmdline 2>/dev/null; then
        echo "INFO: CPU isolation detected. Ensure target process is pinned to isolated CPUs for best performance." >> "$temp_sched_file"
        recommendations_success=true
    fi
    
    if [ -r /proc/cmdline ] && grep -q "nohz_full" /proc/cmdline 2>/dev/null; then
        echo "INFO: nohz_full enabled. Reduces timer interrupts on specified CPUs." >> "$temp_sched_file"
        recommendations_success=true
    fi
    
    if [ -r /proc/sys/kernel/perf_event_paranoid ]; then
        perf_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)
        if [ -n "$perf_paranoid" ] && [ "$perf_paranoid" -gt 1 ] 2>/dev/null; then
            echo "TIP: perf_event_paranoid=${perf_paranoid} may limit profiling. Set to 1 or 0 for more data: echo 1 > /proc/sys/kernel/perf_event_paranoid" >> "$temp_sched_file"
            recommendations_success=true
        fi
    fi
    
    if [ "$recommendations_success" = true ]; then
        sched_trace_success=true
    fi
    
    echo "" >> "$temp_sched_file"
    echo "============================================================" >> "$temp_sched_file"
    echo "Scheduler Trace Analysis Complete" >> "$temp_sched_file"
    echo "============================================================" >> "$temp_sched_file"
    
    if [ "$sched_trace_success" = true ]; then
        mv "$temp_sched_file" "$SCHED_TRACE_FILE"
        log_success "Scheduler Trace 深度分析完成，结果保存至: $SCHED_TRACE_FILE"
    else
        rm -f "$temp_sched_file"
        log_warning "Scheduler Trace 深度分析全部失败，未生成 $SCHED_TRACE_FILE"
    fi
}


# ========== os/collect_static_info.sh ==========

collect_static_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：系统环境静态信息收集"

    echo "============================================================" > "$output_dir/static_info.txt"
    echo "Phase 1: System Environment Static Information Collection" >> "$output_dir/static_info.txt"
    echo "============================================================" >> "$output_dir/static_info.txt"
    echo "" >> "$output_dir/static_info.txt"

    echo "========== Hardware Specifications ==========" >> "$output_dir/static_info.txt"

    echo "--- CPU Model, Sockets, Cores, Threads, Cache ---" >> "$output_dir/static_info.txt"
    lscpu >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- NUMA Topology ---" >> "$output_dir/static_info.txt"
    numactl --hardware 2>/dev/null >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Memory DIMM Info ---" >> "$output_dir/static_info.txt"
    dmidecode -t memory 2>/dev/null | grep -E "Size|Speed|Type|Locator" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Physical Memory Summary ---" >> "$output_dir/static_info.txt"
    cat /proc/meminfo | grep -E "MemTotal|SwapTotal|HugePages_Total|HugePages_Free" >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Disk Devices and Topology (ROTA=1=HDD, ROTA=0=SSD) ---" >> "$output_dir/static_info.txt"
    lsblk -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- SCSI Device Info ---" >> "$output_dir/static_info.txt"
    cat /proc/scsi/scsi 2>/dev/null >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- NIC Models ---" >> "$output_dir/static_info.txt"
    lspci | grep -i eth >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- NIC Driver and Firmware ---" >> "$output_dir/static_info.txt"
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        echo "=== $iface ===" >> "$output_dir/static_info.txt"
        ethtool -i "$iface" 2>/dev/null >> "$output_dir/static_info.txt" || true
    done

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Hardware Model ---" >> "$output_dir/static_info.txt"
    cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null >> "$output_dir/static_info.txt" || true
    dmidecode -t system 2>/dev/null | grep -E "Manufacturer|Product Name|Version" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- CPU Frequency Scaling ---" >> "$output_dir/static_info.txt"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null >> "$output_dir/static_info.txt" || true
    cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "========== Software Versions ==========" >> "$output_dir/static_info.txt"

    echo "--- OS Release ---" >> "$output_dir/static_info.txt"
    cat /etc/os-release >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Kernel Version ---" >> "$output_dir/static_info.txt"
    uname -r >> "$output_dir/static_info.txt" && uname -v >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- GCC Version ---" >> "$output_dir/static_info.txt"
    gcc --version 2>/dev/null | head -1 >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- glibc Version ---" >> "$output_dir/static_info.txt"
    ldd --version 2>/dev/null | head -1 >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "========== Kernel Boot Parameters ==========" >> "$output_dir/static_info.txt"

    echo "--- Kernel Command Line ---" >> "$output_dir/static_info.txt"
    cat /proc/cmdline >> "$output_dir/static_info.txt"

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Performance-Related sysctl: vm.* ---" >> "$output_dir/static_info.txt"
    sysctl -a 2>/dev/null | grep -E "^vm\.(swappiness|dirty_ratio|dirty_background_ratio|dirty_writeback_centisecs|min_free_kbytes|vfs_cache_pressure|overcommit_memory|overcommit_ratio|nr_hugepages|zone_reclaim_mode|numa_balancing)" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Performance-Related sysctl: net.* ---" >> "$output_dir/static_info.txt"
    sysctl -a 2>/dev/null | grep -E "^net\.(core\.(somaxconn|netdev_max_backlog|netdev_budget|rmem_max|wmem_max)|ipv4\.(tcp_tw_reuse|tcp_max_syn_backlog|tcp_rmem|tcp_wmem|tcp_syncookies|tcp_fin_timeout|tcp_fastopen))" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Performance-Related sysctl: kernel.sched*/numa/threads ---" >> "$output_dir/static_info.txt"
    sysctl -a 2>/dev/null | grep -E "^kernel\.(sched_(min_granularity_ns|wakeup_granularity_ns|migration_cost_ns|cfs_bandwidth_slice_us|autogroup_enabled)|numa_balancing|threads-max)" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Performance-Related sysctl: fs.* ---" >> "$output_dir/static_info.txt"
    sysctl -a 2>/dev/null | grep -E "^fs\.(file-max|aio-max-nr|nr_open|inotify\.)" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Performance-Relevant Kernel Modules ---" >> "$output_dir/static_info.txt"
    lsmod 2>/dev/null | grep -iE "kvm|nvme|mlx|io_uring|dpdk|vfio|iommu|intel_cstate|intel_uncore|acpi_cpufreq|cpufreq|tuned" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Kernel Tickless / nohz / Preempt Config ---" >> "$output_dir/static_info.txt"
    cat /boot/config-$(uname -r) 2>/dev/null | grep -E "NO_HZ|HZ_1000|PREEMPT" >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Transparent Hugepage Status ---" >> "$output_dir/static_info.txt"
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- I/O Scheduler per Block Device ---" >> "$output_dir/static_info.txt"
    for dev in $(ls /sys/block/); do
        echo "$dev: $(cat /sys/block/$dev/queue/scheduler 2>/dev/null)" >> "$output_dir/static_info.txt"
    done || true

    echo "" >> "$output_dir/static_info.txt"
    echo "--- Default IRQ Affinity ---" >> "$output_dir/static_info.txt"
    cat /proc/irq/default_smp_affinity 2>/dev/null >> "$output_dir/static_info.txt" || true

    echo "" >> "$output_dir/static_info.txt"
    echo "============================================================" >> "$output_dir/static_info.txt"
    echo "Phase 1: Static Information Collection Complete" >> "$output_dir/static_info.txt"
    echo "============================================================" >> "$output_dir/static_info.txt"

    log_success "√ 系统环境静态信息收集完成"
}


# ========== os/collect_syscall_analysis.sh ==========

collect_syscall_analysis() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    if [[ -z "$pids" ]]; then
        log_warning "未指定进程ID，跳过系统调用分析"
        return
    fi

    syscall_analysis_success=false
    content_written=false

    IFS=',' read -ra pid_array <<< "$pids"
    for single_pid in "${pid_array[@]}"; do
        single_pid=$(echo "$single_pid" | xargs)
        log_info "执行：系统调用分析 (PID=$single_pid)"

        temp_syscall_file="${output_dir}/syscall_analysis.txt.tmp.${single_pid}"

        echo "============================================================" > "$temp_syscall_file"
        echo "Phase 3.2: Syscall Analysis (PID=$single_pid)" >> "$temp_syscall_file"
        echo "============================================================" >> "$temp_syscall_file"
        echo "" >> "$temp_syscall_file"

        if check_command strace; then
            echo "--- strace -c: Syscall summary with counts and errors ---" >> "$temp_syscall_file"
            local strace_output
            timeout $duration strace -p "$single_pid" -c -f >> "$temp_syscall_file" 2>&1
            local strace_exit_code=$?
            if [ $strace_exit_code -eq 124 ];then
                echo "" >> "$temp_syscall_file"
                echo "✓ strace 执行成功 (PID=$single_pid)" >> "$temp_syscall_file"
                syscall_analysis_success=true
                content_written=true
                log_success "系统调用分析成功 (PID=$single_pid)"

                if [ ! -f "$output_dir/syscall_analysis.txt" ]; then
                    cat "$temp_syscall_file" > "$output_dir/syscall_analysis.txt"
                else
                    cat "$temp_syscall_file" >> "$output_dir/syscall_analysis.txt"
                fi
                rm -f "$temp_syscall_file"
            else
                 echo "错误: strace 执行失败 (PID=$single_pid, 退出码=$strace_exit_code)" >> "$temp_syscall_file"
                echo "错误详情:" >> "$temp_syscall_file"
                echo "$strace_output" >> "$temp_syscall_file"
                echo "" >> "$temp_syscall_file"

                if echo "$strace_output" | grep -q "Operation not permitted"; then
                    echo "原因: 权限不足" >> "$temp_syscall_file"
                    echo "解决方案:" >> "$temp_syscall_file"
                    echo "  1. 以 root 用户运行脚本" >> "$temp_syscall_file"
                    echo "  2. 或添加 SYS_PTRACE capability: --cap-add=SYS_PTRACE" >> "$temp_syscall_file"
                    echo "  3. 或调整 ptrace_scope: echo 0 > /proc/sys/kernel/yama/ptrace_scope" >> "$temp_syscall_file"
                elif echo "$strace_output" | grep -q "No such process"; then
                    echo "原因: 进程不存在或已退出" >> "$temp_syscall_file"

                else
                    echo "原因: 未知错误" >> "$temp_syscall_file"
                fi

                log_error "系统调用分析失败 (PID=$single_pid)"

                echo "============================================================" >> "$temp_syscall_file"
                echo "Phase 3.2: Syscall Analysis Failed for PID=$single_pid" >> "$temp_syscall_file"
                echo "============================================================" >> "$temp_syscall_file"

                cat "$temp_syscall_file"

                rm -f "$temp_syscall_file"
                continue
            fi
        else
            echo "错误: strace命令未找到，跳过系统调用分析" >> "$temp_syscall_file"
            log_error "strace命令未找到"

            cat "$temp_syscall_file"    
            rm -f "$temp_syscall_file"
            break
        fi
    done

    if [ "$syscall_analysis_success" = true ]; then
        echo "" >> "$output_dir/syscall_analysis.txt"
        echo "============================================================" >> "$output_dir/syscall_analysis.txt"
        echo "Phase 3.2: Syscall Analysis Complete (PIDS=$pids)" >> "$output_dir/syscall_analysis.txt"
        echo "============================================================" >> "$output_dir/syscall_analysis.txt"
        log_success "√ 系统调用分析完成，结果保存至: $output_dir/syscall_analysis.txt"
    else
        if [ -f "$output_dir/syscall_analysis.txt" ]; then
            rm -f "$output_dir/syscall_analysis.txt"
            log_warning "所有系统调用分析均失败，未生成 $output_dir/syscall_analysis.txt"
        else
            log_warning "系统调用分析全部失败，未生成输出文件"
        fi
    fi
}


# ========== os/collect_system_detail_info.sh ==========

collect_system_detail_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：系统详细信息采集"
    
    local SYSTEM_DETAIL_INFO_FILE="${output_dir}/system_detail_info.txt"
    
    > "$SYSTEM_DETAIL_INFO_FILE"
    {
        echo "============================================================"
        echo "系统详细信息"
        echo "采集时间: $(date)"
        echo "============================================================"
        echo ""

        echo "=== 系统概况补充 ==="
        echo "--- 启动时间 ---"
        uptime 2>/dev/null || echo "无法获取"
        echo ""

        echo "--- 虚拟化检测 ---"
        if command -v systemd-detect-virt &>/dev/null; then
            VIRT=$(systemd-detect-virt --vm 2>/dev/null || echo "none")
            if [ "$VIRT" = "none" ]; then
                echo "physical"
            else
                echo "vm ($VIRT)"
            fi
        else
            if [ -f /sys/class/dmi/id/product_name ]; then
                PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
                case "$PRODUCT" in
                    *KVM*|*QEMU*|*VMware*|*VirtualBox*|*Xen*)
                        echo "vm ($PRODUCT)" ;;
                    *)
                        echo "physical (product: $PRODUCT)" ;;
                esac
            else
                echo "unknown"
            fi
        fi
        echo ""

        echo "--- 当前用户 ---"
        echo "用户: $(whoami), UID: $(id -u), root: $(if [ "$(id -u)" -eq 0 ]; then echo yes; else echo no; fi)"
        echo ""

        echo "=== sar 实时采集 (${duration}次, 间隔1s) ==="
        if command -v sar &>/dev/null; then
            local sar_tmp="${output_dir}/.sar_tmp"
            mkdir -p "$sar_tmp"
            local sar_pids=()

            declare -A SAR_MAP=(
                ["cpu"]="-u 1 ${duration}"
                ["cpu_all"]="-P ALL 1 ${duration}"
                ["memory"]="-r 1 ${duration}"
                ["swap"]="-S 1 ${duration}"
                ["paging"]="-B 1 ${duration}"
                ["io"]="-b 1 ${duration}"
                ["sock"]="-n SOCK 1 ${duration}"
                ["load"]="-q 1 ${duration}"
                ["ctxsw"]="-w 1 ${duration}"
                ["task"]="-y 1 ${duration}"
                ["hugepages"]="-H 1 ${duration}"
                ["intr"]="-I SUM 1 ${duration}"
            )

            for name in "${!SAR_MAP[@]}"; do
                (
                    sar ${SAR_MAP[$name]} 2>/dev/null > "$sar_tmp/$name" || true
                ) &
                sar_pids+=($!)
            done

            for pid in "${sar_pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done

            for name in "${!SAR_MAP[@]}"; do
                echo "--- sar ${name} ---"
                if [ -s "$sar_tmp/$name" ]; then
                    cat "$sar_tmp/$name"
                else
                    echo "  (无数据)"
                fi
                echo ""
            done

            rm -rf "$sar_tmp"
        fi

        echo "=== sadf 历史数据提取 ==="
        local sadf_day=$(date '+%d')
        local sadf_file="/var/log/sa/sa${sadf_day}"
        if command -v sadf &>/dev/null && [ -f "$sadf_file" ]; then
            echo "--- CPU 历史 (前3行) ---"
            sadf -d "$sadf_file" -- -u 2>/dev/null | head -3 || echo "无数据"
            echo ""
            echo "--- 内存历史 (前3行) ---"
            sadf -d "$sadf_file" -- -r 2>/dev/null | head -3 || echo "无数据"
            echo ""
            echo "--- /var/log/sa 今日文件 ---"
            find /var/log/sa -name "sa*" -mtime -1 2>/dev/null || echo "无"
        fi
        echo ""

        echo "=== PSI 压力指标补充 ==="
        echo "--- /proc/pressure/cpu ---"
        cat /proc/pressure/cpu 2>/dev/null || echo "不可用"
        echo ""
        echo "--- /proc/pressure/io ---"
        cat /proc/pressure/io 2>/dev/null || echo "不可用"
        echo ""
    } >> "$SYSTEM_DETAIL_INFO_FILE"

    log_success "系统详细信息采集完成"
}


# ========== os/collect_top_processes.sh ==========

collect_top_processes() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}
    log_info "执行：顶级资源进程识别"

    temp_top_proc_file="${output_dir}/top_processes.txt.tmp"

    echo "============================================================" > "$temp_top_proc_file"
    echo "Phase 2.2: Top Resource Process Identification" >> "$temp_top_proc_file"
    echo "============================================================" >> "$temp_top_proc_file"
    echo "" >> "$temp_top_proc_file"

    local has_output=false

    echo "--- Top 20 CPU Processes ---" >> "$temp_top_proc_file"
    if command -v ps &> /dev/null; then
        ps aux --sort=-%cpu 2>/dev/null | head -20 >> "$temp_top_proc_file"
        has_output=true
    else
        echo "⚠ ps command not available (install procps)" >> "$temp_top_proc_file"
    fi

    echo "" >> "$temp_top_proc_file"

    echo "--- Top 20 Memory Processes ---" >> "$temp_top_proc_file"
    if command -v ps &> /dev/null; then
        ps aux --sort=-%mem 2>/dev/null | head -20 >> "$temp_top_proc_file"
        has_output=true
    else
        echo "⚠ ps command not available" >> "$temp_top_proc_file"
    fi

    echo "" >> "$temp_top_proc_file"

    echo "--- Top 20 I/O Processes by iotop (requires root) ---" >> "$temp_top_proc_file"
    if command -v iotop &> /dev/null; then
        local iotop_temp=$(mktemp)
        {
            echo "    PID  PRIO  USER     DISK READ  DISK WRITE  SWAPIN      IO    COMMAND"
            iotop -oP -b -n 5 -d 1 2>/dev/null | grep -E "^\s*[0-9]" | head -20
        } > "$iotop_temp" 2>/dev/null

        local data_lines=$(grep -c -E "^\s*[0-9]" "$iotop_temp" 2>/dev/null)
        if [ -s "$iotop_temp" ] && [ "${data_lines:-0}" -gt 0 ]; then
            cat "$iotop_temp" >> "$temp_top_proc_file"
            has_output=true
        else
            echo "  ℹ No I/O activity detected (may need root privileges)" >> "$temp_top_proc_file"
        fi
        rm -f "$iotop_temp"
    else
        echo "⚠ iotop not available (install: apt-get install iotop / yum install iotop)" >> "$temp_top_proc_file"
    fi

    echo "" >> "$temp_top_proc_file"

    echo "--- Top 20 I/O Processes by pidstat (by kB_wr/s) ---" >> "$temp_top_proc_file"
    if command -v pidstat &> /dev/null; then
        local pidstat_temp=$(mktemp)
        {
            echo "      UID       PID   kB_rd/s   kB_wr/s kB_ccwr/s iodelay  Command"
            pidstat -d 1 5 2>/dev/null | grep 'Average' | grep -v "UID" | sort -k5 -rn | head -20
        } > "$pidstat_temp" 2>/dev/null

        local pidstat_data_lines=$(grep -c -E "^\s*[0-9]" "$pidstat_temp" 2>/dev/null)
        if [ -s "$pidstat_temp" ] && [ "${pidstat_data_lines:-0}" -gt 1 ]; then
            cat "$pidstat_temp" >> "$temp_top_proc_file"
            has_output=true
        else
            echo "  ℹ No I/O activity detected" >> "$temp_top_proc_file"
        fi
        rm -f "$pidstat_temp"
    else
        echo "⚠ pidstat not available (install sysstat)" >> "$temp_top_proc_file"
    fi

    echo "" >> "$temp_top_proc_file"
    echo "============================================================" >> "$temp_top_proc_file"
    echo "Phase 2.2: Top Resource Process Identification Complete" >> "$temp_top_proc_file"
    echo "============================================================" >> "$temp_top_proc_file"

    if [ "$has_output" = true ]; then
        mv "$temp_top_proc_file" "$output_dir/top_processes.txt"
        log_success "√ 顶级资源进程识别完成，结果保存至: $output_dir/top_processes.txt"
    else
        rm -f "$temp_top_proc_file"
        log_warning "顶级资源进程识别全部失败，未生成 $output_dir/top_processes.txt"
    fi
}


# ========== devkit/collect_devkit_hotspot.sh ==========

collect_devkit_hotspot() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：devkit hotspot数据采集"

    hotspot_success=false

    if ! check_command devkit; then
        log_warning "devkit命令未找到，跳过hotspot采集"
        return
    fi

    local hotspot_file="$output_dir/devkit_hotspot.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_hotspot_file="${hotspot_file}.tmp"

    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)

            log_info "运行devkit tuner hotspot，监控进程 $single_pid, 持续${duration}秒..."

            if [ ! -f "$temp_hotspot_file" ]; then
                echo "运行devkit tuner hotspot，监控进程 $single_pid, 持续${duration}秒..." > "$temp_hotspot_file"
            else
                echo "" >> "$temp_hotspot_file"
                echo "运行devkit tuner hotspot，监控进程 $single_pid, 持续${duration}秒..." >> "$temp_hotspot_file"
            fi

            local devkit_exit_code=0
            local devkit_temp_output=$(mktemp)
            local devkit_start_time=$(date +%s)

            timeout $((duration + timeout_duration)) devkit tuner hotspot -d "$duration" -p "$single_pid" > "$devkit_temp_output" 2>&1
            devkit_exit_code=$?
            local devkit_end_time=$(date +%s)
            local devkit_duration=$((devkit_end_time - devkit_start_time))

            if [ $devkit_exit_code -eq 0 ]; then
                cat "$devkit_temp_output" >> "$temp_hotspot_file"
                echo "" >> "$temp_hotspot_file"
                echo "✓ devkit hotspot 执行成功 (PID=$single_pid, 实际运行时长=${devkit_duration}秒)" >> "$temp_hotspot_file"
                log_success "devkit hotspot 数据采集成功 (PID=$single_pid)"
                hotspot_success=true
            else
                echo "错误: devkit hotspot 执行失败 (PID=$single_pid, 退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_hotspot_file"
                echo "错误详情:" >> "$temp_hotspot_file"
                cat "$devkit_temp_output" >> "$temp_hotspot_file"
                echo "" >> "$temp_hotspot_file"

                if [ $devkit_exit_code -eq 124 ]; then
                    echo "原因: timeout 超时 (devkit 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 执行超时 (PID=$single_pid)"
                elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 权限不足" >> "$temp_hotspot_file"
                    echo "解决方案:" >> "$temp_hotspot_file"
                    echo "  1. 以 root 用户运行脚本" >> "$temp_hotspot_file"
                    echo "  2. 检查进程属主和权限" >> "$temp_hotspot_file"
                    echo "  3. 调整 perf_event_paranoid: echo 1 > /proc/sys/kernel/perf_event_paranoid" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 权限不足 (PID=$single_pid)"
                elif grep -q "no such process\|No such process\|invalid pid" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 进程不存在或已退出" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 进程不存在 (PID=$single_pid)"
                elif grep -q "connection refused\|Connection refused" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: devkit 服务连接失败" >> "$temp_hotspot_file"
                    echo "解决方案:" >> "$temp_hotspot_file"
                    echo "  1. 检查 devkit 服务是否运行" >> "$temp_hotspot_file"
                    echo "  2. 检查网络连接" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 连接失败 (PID=$single_pid)"
                elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 当前平台或CPU不支持 hotspot 分析" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 平台不支持 (PID=$single_pid)"
                elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: devkit 版本不支持 hotspot 子命令或参数" >> "$temp_hotspot_file"
                    echo "解决方案:" >> "$temp_hotspot_file"
                    echo "  1. 检查 devkit 版本: devkit --version" >> "$temp_hotspot_file"
                    echo "  2. 查看支持的子命令: devkit tuner --help" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 子命令不支持 (PID=$single_pid)"
                else
                    echo "原因: 未知错误" >> "$temp_hotspot_file"
                    log_error "devkit hotspot 执行失败 (PID=$single_pid, 退出码=$devkit_exit_code)"
                fi

                if [ -n "$error_log" ]; then
                    cat "$temp_hotspot_file" >> "$error_log" 2>/dev/null
                fi
            fi

            rm -f "$devkit_temp_output"
        done
    else
        log_info "运行devkit tuner hotspot (系统整体)，持续${duration}秒..."

        echo "运行devkit tuner hotspot (系统整体)，持续${duration}秒..." > "$temp_hotspot_file"

        local devkit_exit_code=0
        local devkit_temp_output=$(mktemp)
        local devkit_start_time=$(date +%s)

        timeout $((duration + timeout_duration)) devkit tuner hotspot -d "$duration" > "$devkit_temp_output" 2>&1
        devkit_exit_code=$?
        local devkit_end_time=$(date +%s)
        local devkit_duration=$((devkit_end_time - devkit_start_time))

        if [ $devkit_exit_code -eq 0 ]; then
            cat "$devkit_temp_output" >> "$temp_hotspot_file"
            echo "" >> "$temp_hotspot_file"
            echo "✓ devkit hotspot 执行成功 (实际运行时长=${devkit_duration}秒)" >> "$temp_hotspot_file"
            log_success "devkit hotspot 系统整体数据采集成功"
            hotspot_success=true
        else
            echo "错误: devkit hotspot 执行失败 (退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_hotspot_file"
            echo "错误详情:" >> "$temp_hotspot_file"
            cat "$devkit_temp_output" >> "$temp_hotspot_file"

            if [ $devkit_exit_code -eq 124 ]; then
                echo "原因: timeout 超时" >> "$temp_hotspot_file"
                log_error "devkit hotspot 执行超时"
            elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 权限不足" >> "$temp_hotspot_file"
                log_error "devkit hotspot 权限不足"
            elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 当前平台或CPU不支持 hotspot 分析" >> "$temp_hotspot_file"
                log_error "devkit hotspot 平台不支持"
            elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: devkit 版本不支持 hotspot 子命令" >> "$temp_hotspot_file"
                log_error "devkit hotspot 子命令不支持"
            else
                echo "原因: 未知错误" >> "$temp_hotspot_file"
                log_error "devkit hotspot 执行失败 (退出码=$devkit_exit_code)"
            fi

            if [ -n "$error_log" ]; then
                cat "$temp_hotspot_file" >> "$error_log" 2>/dev/null
            fi
        fi

        rm -f "$devkit_temp_output"
    fi

    if [ "$hotspot_success" = true ]; then
        echo "" >> "$temp_hotspot_file"
        echo "============================================================" >> "$temp_hotspot_file"
        echo "devkit hotspot 数据采集完成 (PIDS=${pids:-system})" >> "$temp_hotspot_file"
        echo "============================================================" >> "$temp_hotspot_file"

        mv "$temp_hotspot_file" "$hotspot_file"
        log_success "√ devkit hotspot 数据采集完成，结果保存至: $hotspot_file"
    else
        rm -f "$temp_hotspot_file"
        log_warning "devkit hotspot 数据采集全部失败，未生成 $hotspot_file"
    fi
}


# ========== devkit/collect_devkit_memory.sh ==========

collect_devkit_memory() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：devkit memory数据采集"

    if ! check_command devkit; then
        log_warning "devkit命令未找到，跳过memory采集"
        return
    fi

    local memory_file="$output_dir/devkit_memory.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_memory_file="${memory_file}.tmp"

    echo "运行devkit tuner memory，持续${duration}秒" > "$temp_memory_file"
    log_info "运行devkit tuner memory，持续${duration}秒..."

    local devkit_exit_code=0
    local devkit_temp_output=$(mktemp)
    local devkit_start_time=$(date +%s)

    timeout $((duration + timeout_duration)) devkit tuner memory -d "$duration" > "$devkit_temp_output" 2>&1
    devkit_exit_code=$?
    local devkit_end_time=$(date +%s)
    local devkit_duration=$((devkit_end_time - devkit_start_time))

    if [ $devkit_exit_code -eq 0 ]; then
        cat "$devkit_temp_output" >> "$temp_memory_file"
        echo "" >> "$temp_memory_file"
        echo "✓ devkit memory 执行成功 (实际运行时长=${devkit_duration}秒)" >> "$temp_memory_file"
        echo "" >> "$temp_memory_file"
        echo "============================================================" >> "$temp_memory_file"
        echo "devkit memory 数据采集完成" >> "$temp_memory_file"
        echo "============================================================" >> "$temp_memory_file"

        mv "$temp_memory_file" "$memory_file"
        log_success "√ devkit memory数据采集完成，结果保存至: $memory_file"

    else
        echo "错误: devkit memory 执行失败 (退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_memory_file"
        echo "错误详情:" >> "$temp_memory_file"
        cat "$devkit_temp_output" >> "$temp_memory_file"
        echo "" >> "$temp_memory_file"

        if [ $devkit_exit_code -eq 124 ]; then
            echo "原因: timeout 超时 (devkit 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_memory_file"
            log_error "devkit memory 执行超时 (${duration}+${timeout_duration}秒)"
        elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: 权限不足" >> "$temp_memory_file"
            echo "解决方案:" >> "$temp_memory_file"
            echo "  1. 以 root 用户运行脚本" >> "$temp_memory_file"
            echo "  2. 检查 devkit 命令权限" >> "$temp_memory_file"
            log_error "devkit memory 权限不足"
        elif grep -q "connection refused\|Connection refused" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: devkit 服务连接失败" >> "$temp_memory_file"
            echo "解决方案:" >> "$temp_memory_file"
            echo "  1. 检查 devkit 服务是否运行" >> "$temp_memory_file"
            echo "  2. 检查网络连接" >> "$temp_memory_file"
            log_error "devkit memory 连接失败"
        elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: devkit 版本不支持 memory 子命令或参数" >> "$temp_memory_file"
            echo "解决方案:" >> "$temp_memory_file"
            echo "  1. 检查 devkit 版本: devkit --version" >> "$temp_memory_file"
            echo "  2. 查看支持的子命令: devkit tuner --help" >> "$temp_memory_file"
            log_error "devkit memory 子命令不支持"
        elif grep -q "not found\|No such file" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: 依赖组件缺失" >> "$temp_memory_file"
            log_error "devkit memory 依赖缺失"
        else
            echo "原因: 未知错误" >> "$temp_memory_file"
            log_error "devkit memory 执行失败 (退出码=$devkit_exit_code)"
        fi

        if [ -n "$error_log" ]; then
            cat "$temp_memory_file" >> "$error_log" 2>/dev/null
        fi

        rm -f "$temp_memory_file"
        log_warning "devkit memory 数据采集失败，未生成 $memory_file"
    fi

    rm -f "$devkit_temp_output"
}


# ========== devkit/collect_devkit_numafast.sh ==========

collect_devkit_numafast() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：devkit numafast数据采集"

    numafast_success=false

    if ! check_command devkit; then
        log_warning "devkit命令未找到，跳过numafast采集"
        return
    fi

    local numafast_file="$output_dir/devkit_numafast.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_numafast_file="${numafast_file}.tmp"

    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)

            log_info "运行devkit tuner numafast，监控进程 $single_pid, 持续${duration}秒..."

            if [ ! -f "$temp_numafast_file" ]; then
                echo "运行devkit tuner numafast，监控进程 $single_pid, 持续${duration}秒..." > "$temp_numafast_file"
            else
                echo "" >> "$temp_numafast_file"
                echo "运行devkit tuner numafast，监控进程 $single_pid, 持续${duration}秒..." >> "$temp_numafast_file"
            fi

            local devkit_exit_code=0
            local devkit_temp_output=$(mktemp)
            local devkit_start_time=$(date +%s)

            devkit tuner numafast -d "$duration" -p "$single_pid" > "$devkit_temp_output" 2>&1
            devkit_exit_code=$?
            local devkit_end_time=$(date +%s)
            local devkit_duration=$((devkit_end_time - devkit_start_time))

            if [ $devkit_exit_code -eq 0 ]; then
                cat "$devkit_temp_output" >> "$temp_numafast_file"
                echo "" >> "$temp_numafast_file"
                echo "✓ devkit numafast 执行成功 (PID=$single_pid, 实际运行时长=${devkit_duration}秒)" >> "$temp_numafast_file"
                log_success "devkit numafast 数据采集成功 (PID=$single_pid)"
                numafast_success=true
            else
                echo "错误: devkit numafast 执行失败 (PID=$single_pid, 退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_numafast_file"
                echo "错误详情:" >> "$temp_numafast_file"
                cat "$devkit_temp_output" >> "$temp_numafast_file"
                echo "" >> "$temp_numafast_file"

                if [ $devkit_exit_code -eq 124 ]; then
                    echo "原因: timeout 超时 (devkit 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_numafast_file"
                    log_error "devkit numafast 执行超时 (PID=$single_pid)"
                elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 权限不足" >> "$temp_numafast_file"
                    echo "解决方案:" >> "$temp_numafast_file"
                    echo "  1. 以 root 用户运行脚本" >> "$temp_numafast_file"
                    echo "  2. 检查进程属主和权限" >> "$temp_numafast_file"
                    log_error "devkit numafast 权限不足 (PID=$single_pid)"
                elif grep -q "no such process\|No such process\|invalid pid" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 进程不存在或已退出" >> "$temp_numafast_file"
                    log_error "devkit numafast 进程不存在 (PID=$single_pid)"
                elif grep -q "connection refused\|Connection refused" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: devkit 服务连接失败" >> "$temp_numafast_file"
                    echo "解决方案:" >> "$temp_numafast_file"
                    echo "  1. 检查 devkit 服务是否运行" >> "$temp_numafast_file"
                    echo "  2. 检查网络连接" >> "$temp_numafast_file"
                    log_error "devkit numafast 连接失败 (PID=$single_pid)"
                elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 当前平台或CPU不支持 numafast 分析 (可能需要 NUMA 架构)" >> "$temp_numafast_file"
                    log_error "devkit numafast 平台不支持 (PID=$single_pid)"
                elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: devkit 版本不支持 numafast 子命令或参数" >> "$temp_numafast_file"
                    echo "解决方案:" >> "$temp_numafast_file"
                    echo "  1. 检查 devkit 版本: devkit --version" >> "$temp_numafast_file"
                    echo "  2. 查看支持的子命令: devkit tuner --help" >> "$temp_numafast_file"
                    log_error "devkit numafast 子命令不支持 (PID=$single_pid)"
                elif grep -q "numa not available\|NUMA not supported" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 系统不支持 NUMA 架构" >> "$temp_numafast_file"
                    log_error "devkit numafast 需要 NUMA 支持 (PID=$single_pid)"
                else
                    echo "原因: 未知错误" >> "$temp_numafast_file"
                    log_error "devkit numafast 执行失败 (PID=$single_pid, 退出码=$devkit_exit_code)"
                fi

                if [ -n "$error_log" ]; then
                    cat "$temp_numafast_file" >> "$error_log" 2>/dev/null
                fi
            fi

            rm -f "$devkit_temp_output"
        done
    else
        log_info "运行devkit tuner numafast (系统整体)，持续${duration}秒..."

        echo "运行devkit tuner numafast (系统整体)，持续${duration}秒..." > "$temp_numafast_file"

        local devkit_exit_code=0
        local devkit_temp_output=$(mktemp)
        local devkit_start_time=$(date +%s)

        devkit tuner numafast -d "$duration" > "$devkit_temp_output" 2>&1
        devkit_exit_code=$?
        local devkit_end_time=$(date +%s)
        local devkit_duration=$((devkit_end_time - devkit_start_time))

        if [ $devkit_exit_code -eq 0 ]; then
            cat "$devkit_temp_output" >> "$temp_numafast_file"
            echo "" >> "$temp_numafast_file"
            echo "✓ devkit numafast 执行成功 (实际运行时长=${devkit_duration}秒)" >> "$temp_numafast_file"
            log_success "devkit numafast 系统整体数据采集成功"
            numafast_success=true
        else
            echo "错误: devkit numafast 执行失败 (退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_numafast_file"
            echo "错误详情:" >> "$temp_numafast_file"
            cat "$devkit_temp_output" >> "$temp_numafast_file"

            if [ $devkit_exit_code -eq 124 ]; then
                echo "原因: timeout 超时" >> "$temp_numafast_file"
                log_error "devkit numafast 执行超时"
            elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 权限不足" >> "$temp_numafast_file"
                log_error "devkit numafast 权限不足"
            elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 当前平台不支持 numafast 分析" >> "$temp_numafast_file"
                log_error "devkit numafast 平台不支持"
            elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: devkit 版本不支持 numafast 子命令" >> "$temp_numafast_file"
                log_error "devkit numafast 子命令不支持"
            elif grep -q "numa not available\|NUMA not supported" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 系统不支持 NUMA 架构" >> "$temp_numafast_file"
                log_error "devkit numafast 需要 NUMA 支持"
            else
                echo "原因: 未知错误" >> "$temp_numafast_file"
                log_error "devkit numafast 执行失败 (退出码=$devkit_exit_code)"
            fi

            if [ -n "$error_log" ]; then
                cat "$temp_numafast_file" >> "$error_log" 2>/dev/null
            fi
        fi

        rm -f "$devkit_temp_output"
    fi

    if [ "$numafast_success" = true ]; then
        echo "" >> "$temp_numafast_file"
        echo "============================================================" >> "$temp_numafast_file"
        echo "devkit numafast 数据采集完成 (PIDS=${pids:-system})" >> "$temp_numafast_file"
        echo "============================================================" >> "$temp_numafast_file"

        mv "$temp_numafast_file" "$numafast_file"
        log_success "√ devkit numafast 数据采集完成，结果保存至: $numafast_file"
    else
        rm -f "$temp_numafast_file"
        log_warning "devkit numafast 数据采集全部失败，未生成 $numafast_file"
    fi
}


# ========== devkit/collect_devkit_topdown.sh ==========

collect_devkit_topdown() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行: devkit topdown数据采集"

    topdown_success=false

    if ! check_command devkit; then
        log_warning "devkit命令未找到，跳过topdown采集"
        return
    fi

    local topdown_file="$output_dir/devkit_topdown.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_topdown_file="${topdown_file}.tmp"

    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)

            log_info "运行devkit tuner top-down，监控进程 $single_pid, 持续${duration}秒..."

            if [ ! -f "$temp_topdown_file" ]; then
                echo "运行devkit tuner top-down，监控进程 $single_pid, 持续${duration}秒..." > "$temp_topdown_file"
            else
                echo "" >> "$temp_topdown_file"
                echo "运行devkit tuner top-down，监控进程 $single_pid, 持续${duration}秒..." >> "$temp_topdown_file"
            fi

            local devkit_output
            local devkit_exit_code=0
            local devkit_temp_output=$(mktemp)
            local devkit_start_time=$(date +%s)

            timeout $((duration + timeout_duration)) devkit tuner top-down -d "$duration" -p "$single_pid" > "$devkit_temp_output" 2>&1
            devkit_exit_code=$?
            local devkit_end_time=$(date +%s)
            local devkit_duration=$((devkit_end_time - devkit_start_time))

            if [ $devkit_exit_code -eq 0 ]; then
                cat "$devkit_temp_output" >> "$temp_topdown_file"
                echo "" >> "$temp_topdown_file"
                echo "✓ devkit topdown 执行成功 (PID=$single_pid, 实际运行时长=${devkit_duration}秒)" >> "$temp_topdown_file"
                log_success "devkit topdown 数据采集成功 (PID=$single_pid)"
                topdown_success=true
            else
                echo "错误: devkit topdown 执行失败 (PID=$single_pid, 退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_topdown_file"
                echo "错误详情:" >> "$temp_topdown_file"
                cat "$devkit_temp_output" >> "$temp_topdown_file"
                echo "" >> "$temp_topdown_file"

                if [ $devkit_exit_code -eq 124 ]; then
                    echo "原因: timeout 超时 (devkit 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_topdown_file"
                elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 权限不足" >> "$temp_topdown_file"
                    echo "解决方案:" >> "$temp_topdown_file"
                    echo "  1. 以 root 用户运行脚本" >> "$temp_topdown_file"
                    echo "  2. 检查进程属主和权限" >> "$temp_topdown_file"
                elif grep -q "no such process\|No such process\|invalid pid" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 进程不存在或已退出" >> "$temp_topdown_file"
                elif grep -q "connection refused\|Connection refused" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: devkit 服务连接失败" >> "$temp_topdown_file"
                    echo "解决方案:" >> "$temp_topdown_file"
                    echo "  1. 检查 devkit 服务是否运行" >> "$temp_topdown_file"
                    echo "  2. 检查网络连接" >> "$temp_topdown_file"
                elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                    echo "原因: 当前平台或CPU不支持 top-down 分析" >> "$temp_topdown_file"
                else
                    echo "原因: 未知错误" >> "$temp_topdown_file"
                fi

                log_error "devkit topdown 数据采集失败 (PID=$single_pid, 退出码=$devkit_exit_code)"

                if [ -n "$error_log" ]; then
                    cat "$temp_topdown_file" >> "$error_log" 2>/dev/null
                fi
            fi

            rm -f "$devkit_temp_output"
        done
    else
        log_info "运行devkit tuner top-down，持续${duration}秒..."

        echo "运行devkit tuner top-down (系统整体)，持续${duration}秒..." > "$temp_topdown_file"

        local devkit_output
        local devkit_exit_code=0
        local devkit_temp_output=$(mktemp)
        local devkit_start_time=$(date +%s)

        timeout $((duration + timeout_duration)) devkit tuner top-down -d "$duration" > "$devkit_temp_output" 2>&1
        devkit_exit_code=$?
        local devkit_end_time=$(date +%s)
        local devkit_duration=$((devkit_end_time - devkit_start_time))

        if [ $devkit_exit_code -eq 0 ]; then
            cat "$devkit_temp_output" >> "$temp_topdown_file"
            echo "" >> "$temp_topdown_file"
            echo "✓ devkit topdown 执行成功 (实际运行时长=${devkit_duration}秒)" >> "$temp_topdown_file"
            log_success "devkit topdown 系统整体数据采集成功"
            topdown_success=true
        else
            echo "错误: devkit topdown 执行失败 (退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_topdown_file"
            echo "错误详情:" >> "$temp_topdown_file"
            cat "$devkit_temp_output" >> "$temp_topdown_file"

            if [ $devkit_exit_code -eq 124 ]; then
                echo "原因: timeout 超时" >> "$temp_topdown_file"
            elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 权限不足" >> "$temp_topdown_file"
            elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
                echo "原因: 当前平台或CPU不支持 top-down 分析" >> "$temp_topdown_file"
            fi

            log_error "devkit topdown 系统整体数据采集失败 (退出码=$devkit_exit_code)"

            if [ -n "$error_log" ]; then
                cat "$temp_topdown_file" >> "$error_log" 2>/dev/null
            fi
        fi

        rm -f "$devkit_temp_output"
    fi

    if [ "$topdown_success" = true ]; then
        echo "" >> "$temp_topdown_file"
        echo "============================================================" >> "$temp_topdown_file"
        echo "devkit topdown 数据采集完成 (PIDS=${pids:-system})" >> "$temp_topdown_file"
        echo "============================================================" >> "$temp_topdown_file"

        mv "$temp_topdown_file" "$topdown_file"
        log_success "√ devkit topdown 数据采集完成，结果保存至: $topdown_file"
    else
        rm -f "$temp_topdown_file"
        log_warning "devkit topdown 数据采集全部失败，未生成 $topdown_file"
    fi
}


# ========== devkit/collect_devkit_turbostat.sh ==========

collect_devkit_turbostat() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：devkit turbostat数据采集"

    if ! check_command devkit; then
        log_warning "devkit命令未找到，跳过turbostat采集"
        return
    fi

    local turbostat_file="$output_dir/devkit_turbostat.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_turbostat_file="${turbostat_file}.tmp"

    echo "运行devkit tuner turbostat，持续${duration}秒" > "$temp_turbostat_file"
    log_info "运行devkit tuner turbostat，持续${duration}秒..."

    local devkit_exit_code=0
    local devkit_temp_output=$(mktemp)
    local devkit_start_time=$(date +%s)

    timeout $((duration + timeout_duration)) devkit tuner turbostat -d "$duration" > "$devkit_temp_output" 2>&1
    devkit_exit_code=$?
    local devkit_end_time=$(date +%s)
    local devkit_duration=$((devkit_end_time - devkit_start_time))

    if [ $devkit_exit_code -eq 0 ]; then
        local has_valid_data=false

        if grep -q "Total Server Power (W): N/A" "$devkit_temp_output" && \
           grep -q "Total CPU Power (W): N/A" "$devkit_temp_output" && \
           grep -q "Total Memory Power (W): N/A" "$devkit_temp_output" && \
           grep -q "Inlet Temperature (C): N/A" "$devkit_temp_output" && \
           grep -q "Outlet Temperature (C): N/A" "$devkit_temp_output"; then
           has_valid_data=false
           log_warning "turbostat 输出所有功率和温度指标均为 N/A，可能硬件不支持或需要 root 权限"
        else
            if grep -q -E "(Total Server Power \(W\):|Total CPU Power \(W\):|Total Memory Power \(W\):|Inlet Temperature \(C\):|Outlet Temperature \(C\):)\s+[0-9]+" "$devkit_temp_output"; then
                has_valid_data=true
            fi
        fi

        local data_lines=$(grep -c -E "(Total Server Power|Total CPU Power|Total Memory Power|Inlet Temperature|Outlet Temperature)" "$devkit_temp_output" 2>/dev/null || echo "0")
        if [ "$data_lines" -gt 0 ] && [ "$has_valid_data" = false ]; then
            log_warning "turbostat 检测到功率/温度指标但数据不可用 (N/A)"
        fi

        if [ "$has_valid_data" = true ]; then
            cat "$devkit_temp_output" >> "$temp_turbostat_file"
            echo "" >> "$temp_turbostat_file"
            echo "✓ devkit turbostat 执行成功 (实际运行时长=${devkit_duration}秒)" >> "$temp_turbostat_file"
            echo "" >> "$temp_turbostat_file"
            echo "============================================================" >> "$temp_turbostat_file"
            echo "devkit turbostat 数据采集完成" >> "$temp_turbostat_file"
            echo "============================================================" >> "$temp_turbostat_file"

            mv "$temp_turbostat_file" "$turbostat_file"
            log_success "√ devkit turbostat数据采集完成，结果保存至: $turbostat_file"
        else
            rm -f "$temp_turbostat_file"
            log_warning "devkit turbostat 未检测到有效的功率/温度数据，未生成 $turbostat_file"

            if [ -n "$error_log" ] && [ -f "$error_log" ] && [ -w "$error_log" ]; then
                {
                    echo "========================================"
                    echo "时间: $(date)"
                    echo "命令: devkit tuner turbostat -d $duration"
                    echo "退出码: $devkit_exit_code"
                    echo "输出内容 (无有效数据):"
                    cat "$devkit_temp_output"
                    echo "========================================"
                } >> "$error_log" 2>/dev/null
            fi
        fi
    else
        echo "错误: devkit turbostat 执行失败 (退出码=$devkit_exit_code, 运行时长=${devkit_duration}秒)" >> "$temp_turbostat_file"
        echo "错误详情:" >> "$temp_turbostat_file"
        cat "$devkit_temp_output" >> "$temp_turbostat_file"
        echo "" >> "$temp_turbostat_file"

        if [ $devkit_exit_code -eq 124 ]; then
            echo "原因: timeout 超时 (devkit 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_turbostat_file"
            log_error "devkit turbostat 执行超时 (${duration}+${timeout_duration}秒)"
        elif grep -q "permission denied\|Permission denied" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: 权限不足" >> "$temp_turbostat_file"
            echo "解决方案:" >> "$temp_turbostat_file"
            echo "  1. 以 root 用户运行脚本" >> "$temp_turbostat_file"
            echo "  2. 检查 devkit 命令权限" >> "$temp_turbostat_file"
            echo "  3. 调整 perf_event_paranoid: echo 1 > /proc/sys/kernel/perf_event_paranoid" >> "$temp_turbostat_file"
            log_error "devkit turbostat 权限不足"
        elif grep -q "connection refused\|Connection refused" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: devkit 服务连接失败" >> "$temp_turbostat_file"
            echo "解决方案:" >> "$temp_turbostat_file"
            echo "  1. 检查 devkit 服务是否运行" >> "$temp_turbostat_file"
            echo "  2. 检查网络连接" >> "$temp_turbostat_file"
            log_error "devkit turbostat 连接失败"
        elif grep -q "invalid option\|unrecognized option" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: devkit 版本不支持 turbostat 子命令或参数" >> "$temp_turbostat_file"
            echo "解决方案:" >> "$temp_turbostat_file"
            echo "  1. 检查 devkit 版本: devkit --version" >> "$temp_turbostat_file"
            echo "  2. 查看支持的子命令: devkit tuner --help" >> "$temp_turbostat_file"
            log_error "devkit turbostat 子命令不支持"
        elif grep -q "not supported\|unsupported" "$devkit_temp_output" 2>/dev/null; then
            echo "原因: 当前平台或CPU不支持 turbostat 分析" >> "$temp_turbostat_file"
            echo "说明: turbostat 通常需要 Intel CPU 或特定硬件支持" >> "$temp_turbostat_file"
            log_error "devkit turbostat 平台不支持"
        else
            echo "原因: 未知错误" >> "$temp_turbostat_file"
            log_error "devkit turbostat 执行失败 (退出码=$devkit_exit_code)"
        fi

        if [ -n "$error_log" ] && [ -f "$error_log" ] && [ -w "$error_log" ]; then
            {
                echo "========================================"
                echo "时间: $(date)"
                echo "命令: devkit tuner turbostat -d $duration"
                echo "退出码: $devkit_exit_code"
                echo "错误输出:"
                cat "$devkit_temp_output"
                echo "========================================"
            } >> "$error_log" 2>/dev/null
        fi

        rm -f "$temp_turbostat_file"
        log_warning "devkit turbostat 数据采集失败，未生成 $turbostat_file"
    fi

    rm -f "$devkit_temp_output"
}


# ========== devkit/collect_kspect.sh ==========

collect_kspect() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：健康度检查"

    if ! check_command kspect; then
        log_warning "kspect命令未找到，跳过健康度检查"
        return
    fi

    local kspect_file="$output_dir/devkit_kspect.txt"
    local error_log="$output_dir/err_log.txt"
    local temp_kspect_file="${kspect_file}.tmp"

    echo "==================== 健康度检查 ====================" > "$temp_kspect_file"

    local kspect_exit_code=0
    local kspect_temp_output=$(mktemp)
    local kspect_start_time=$(date +%s)

    kspect -s all > "$kspect_temp_output" 2>&1
    kspect_exit_code=$?
    local kspect_end_time=$(date +%s)
    local kspect_duration=$((kspect_end_time - kspect_start_time))

    if [ $kspect_exit_code -eq 0 ]; then
        cat "$kspect_temp_output" >> "$temp_kspect_file"

        sed -i 's/\x1b\[[0-9;]*m//g' "$temp_kspect_file"

        echo "" >> "$temp_kspect_file"
        echo "✓ kspect 执行成功 (实际运行时长=${kspect_duration}秒)" >> "$temp_kspect_file"
        echo "" >> "$temp_kspect_file"
        echo "============================================================" >> "$temp_kspect_file"
        echo "健康度检查完成" >> "$temp_kspect_file"
        echo "============================================================" >> "$temp_kspect_file"

        mv "$temp_kspect_file" "$kspect_file"
        log_success "√ 健康度检查完成，结果保存至: $kspect_file"

    else
        echo "错误: kspect 执行失败 (退出码=$kspect_exit_code, 运行时长=${kspect_duration}秒)" >> "$temp_kspect_file"
        echo "错误详情:" >> "$temp_kspect_file"
        cat "$kspect_temp_output" >> "$temp_kspect_file"
        echo "" >> "$temp_kspect_file"

        if [ $kspect_exit_code -eq 124 ]; then
            echo "原因: timeout 超时" >> "$temp_kspect_file"
            log_error "kspect 执行超时"
        elif grep -q "permission denied\|Permission denied" "$kspect_temp_output" 2>/dev/null; then
            echo "原因: 权限不足" >> "$temp_kspect_file"
            echo "解决方案:" >> "$temp_kspect_file"
            echo "  1. 以 root 用户运行脚本" >> "$temp_kspect_file"
            echo "  2. 检查 kspect 命令权限" >> "$temp_kspect_file"
            log_error "kspect 权限不足"
        elif grep -q "connection refused\|Connection refused" "$kspect_temp_output" 2>/dev/null; then
            echo "原因: kspect 服务连接失败" >> "$temp_kspect_file"
            echo "解决方案:" >> "$temp_kspect_file"
            echo "  1. 检查 kspect 服务是否运行" >> "$temp_kspect_file"
            echo "  2. 检查网络连接" >> "$temp_kspect_file"
            log_error "kspect 连接失败"
        elif grep -q "invalid option\|unrecognized option" "$kspect_temp_output" 2>/dev/null; then
            echo "原因: kspect 版本不支持 -s all 参数" >> "$temp_kspect_file"
            echo "解决方案:" >> "$temp_kspect_file"
            echo "  1. 检查 kspect 版本: kspect --version" >> "$temp_kspect_file"
            echo "  2. 查看支持的参数: kspect --help" >> "$temp_kspect_file"
            log_error "kspect 参数不支持"
        elif grep -q "not found\|No such file" "$kspect_temp_output" 2>/dev/null; then
            echo "原因: 依赖组件缺失" >> "$temp_kspect_file"
            log_error "kspect 依赖缺失"
        elif grep -q "timeout\|timed out" "$kspect_temp_output" 2>/dev/null; then
            echo "原因: 健康检查超时" >> "$temp_kspect_file"
            log_error "kspect 健康检查超时"
        else
            echo "原因: 未知错误" >> "$temp_kspect_file"
            log_error "kspect 执行失败 (退出码=$kspect_exit_code)"
        fi

        if [ -n "$error_log" ]; then
            sed 's/\x1b\[[0-9;]*m//g' "$temp_kspect_file" >> "$error_log" 2>/dev/null
        fi

        rm -f "$temp_kspect_file"
        log_warning "健康度检查失败，未生成 $kspect_file"
    fi

    rm -f "$kspect_temp_output"
}


# ========== devkit/collect_ksys.sh ==========

collect_ksys() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：devkit ksys数据采集"

    if ! check_command ksys; then
        log_warning "ksys命令未找到，跳过数据采集"
        return
    fi

    ksys_analysis_success=false

    local ksys_file="$output_dir/devkit_ksys.txt"
    local error_log="$output_dir/err_log.txt"

    if [[ -n "$pids" ]]; then
        IFS=',' read -ra pid_array <<< "$pids"
        for single_pid in "${pid_array[@]}"; do
            single_pid=$(echo "$single_pid" | xargs)

            log_info "运行devkit ksys，监控进程 $single_pid, 持续${duration}秒..."

            temp_ksys_file="${ksys_file}.tmp.${single_pid}"

            echo "运行devkit ksys，监控进程 $single_pid, 持续${duration}秒..." > "$temp_ksys_file"

            local ksys_output
            local ksys_exit_code=0
            local ksys_start_time=$(date +%s)

            local ksys_temp_output=$(mktemp)

            timeout $((duration + timeout_duration)) ksys collect -d "$duration" -p "$single_pid" -o "$output_dir" > "$ksys_temp_output" 2>&1
            ksys_exit_code=$?
            local ksys_end_time=$(date +%s)
            local ksys_duration=$((ksys_end_time - ksys_start_time))

            if [ $ksys_exit_code -eq 0 ]; then
                cat "$ksys_temp_output" >> "$temp_ksys_file"
                echo "" >> "$temp_ksys_file"
                echo "✓ ksys 执行成功 (PID=$single_pid, 实际运行时长=${ksys_duration}秒)" >> "$temp_ksys_file"
                log_success "devkit ksys 数据采集成功 (PID=$single_pid)"

                if [ ! -f "$ksys_file" ]; then
                    cat "$temp_ksys_file" > "$ksys_file"
                else
                    cat "$temp_ksys_file" >> "$ksys_file"
                fi
                ksys_analysis_success=true
                rm -f "$temp_ksys_file"
            else
                echo "错误: ksys 执行失败 (PID=$single_pid, 退出码=$ksys_exit_code, 运行时长=${ksys_duration}秒)" >> "$temp_ksys_file"
                echo "错误详情:" >> "$temp_ksys_file"
                cat "$ksys_temp_output" >> "$temp_ksys_file"
                echo "" >> "$temp_ksys_file"

                if [ $ksys_exit_code -eq 124 ]; then
                    echo "原因: timeout 超时 (ksys 执行超过 ${duration}+${timeout_duration} 秒)" >> "$temp_ksys_file"
                elif grep -q "permission denied\|Permission denied" "$ksys_temp_output" 2>/dev/null; then
                    echo "原因: 权限不足" >> "$temp_ksys_file"
                    echo "解决方案:" >> "$temp_ksys_file"
                    echo "  1. 以 root 用户运行脚本" >> "$temp_ksys_file"
                    echo "  2. 检查进程属主和权限" >> "$temp_ksys_file"
                elif grep -q "no such process\|No such process" "$ksys_temp_output" 2>/dev/null; then
                    echo "原因: 进程不存在或已退出" >> "$temp_ksys_file"
                elif grep -q "connection refused\|Connection refused" "$ksys_temp_output" 2>/dev/null; then
                    echo "原因: devkit 服务连接失败" >> "$temp_ksys_file"
                    echo "解决方案:" >> "$temp_ksys_file"
                    echo "  1. 检查 devkit 服务是否运行" >> "$temp_ksys_file"
                    echo "  2. 检查网络连接" >> "$temp_ksys_file"
                else
                    echo "原因: 未知错误" >> "$temp_ksys_file"
                fi

                log_error "devkit ksys 数据采集失败 (PID=$single_pid, 退出码=$ksys_exit_code)"

                if [ -n "$error_log" ]; then
                    cat "$temp_ksys_file" >> "$error_log"
                fi

                rm -f "$temp_ksys_file"
            fi

            rm -f "$ksys_temp_output"
        done
    else
        log_info "运行devkit tuner ksys，持续${duration}秒..."

        temp_ksys_file="${ksys_file}.tmp.system"

        echo "devkit ksys系统整体数据采集" > "$temp_ksys_file"
        echo "采集时长: ${duration}秒" >> "$temp_ksys_file"
        echo "" >> "$temp_ksys_file"

        local ksys_output
        local ksys_exit_code=0
        local ksys_temp_output=$(mktemp)
        local ksys_start_time=$(date +%s)

        timeout $((duration + timeout_duration)) ksys collect -d "$duration" -o "$output_dir" > "$ksys_temp_output" 2>&1
        ksys_exit_code=$?
        local ksys_end_time=$(date +%s)
        local ksys_duration=$((ksys_end_time - ksys_start_time))

        if [ $ksys_exit_code -eq 0 ]; then
            cat "$ksys_temp_output" >> "$temp_ksys_file"
            echo "" >> "$temp_ksys_file"
            echo "✓ ksys 执行成功 (实际运行时长=${ksys_duration}秒)" >> "$temp_ksys_file"
            log_success "devkit ksys 系统整体数据采集成功"

            mv "$temp_ksys_file" "$ksys_file"
            ksys_analysis_success=true
        else
            echo "错误: ksys 执行失败 (退出码=$ksys_exit_code, 运行时长=${ksys_duration}秒)" >> "$temp_ksys_file"
            echo "错误详情:" >> "$temp_ksys_file"
            cat "$ksys_temp_output" >> "$temp_ksys_file"

            if [ $ksys_exit_code -eq 124 ]; then
                echo "原因: timeout 超时" >> "$temp_ksys_file"
            elif grep -q "permission denied\|Permission denied" "$ksys_temp_output" 2>/dev/null; then
                echo "原因: 权限不足" >> "$temp_ksys_file"
            fi

            log_error "devkit ksys 系统整体数据采集失败 (退出码=$ksys_exit_code)"

            if [ -n "$error_log" ]; then
                cat "$temp_ksys_file" >> "$error_log"
            fi

            rm -f "$temp_ksys_file"
        fi

        rm -f "$ksys_temp_output"
    fi

    if [ "$ksys_analysis_success" = true ]; then
        echo "" >> "$ksys_file"
        echo "============================================================" >> "$ksys_file"
        echo "devkit ksys数据采集完成 (PIDS=${pids:-system})" >> "$ksys_file"
        echo "============================================================" >> "$ksys_file"
        log_success "√ devkit ksys数据采集完成，结果保存至: $ksys_file"
    else
        if [ -f "$ksys_file" ]; then
            rm -f "$ksys_file"
            log_warning "所有 ksys 数据采集均失败，未生成 $ksys_file"
        else
            log_warning "ksys 数据采集全部失败，未生成输出文件"
        fi
    fi
}


# ========== devkit/collect_pmu_info.sh ==========

collect_pmu_info() {
    local duration=${DURATION:-10}
    local pids=${PIDS:-}
    local output_dir=${OUTPUT_DIR:-.}
    local timeout_duration=${TIMEOUT_DURATION:-60}

    log_info "执行：PMU 远程访问与 HHA 分析"

    local pmu_info_file="$output_dir/pmu_info.txt"

    > "$pmu_info_file"
    echo "============================================================" >> "$pmu_info_file"
    echo "PMU 远程访问与 HHA 分析" >> "$pmu_info_file"
    echo "采集时间: $(date)" >> "$pmu_info_file"
    echo "============================================================" >> "$pmu_info_file"
    echo "" >> "$pmu_info_file"

    echo "=== 1. HHA 设备检测 ===" >> "$pmu_info_file"
    HHA_DEVICES=$(ls -d /sys/devices/hha* 2>/dev/null || true)
    if [ -n "$HHA_DEVICES" ]; then
        echo "$HHA_DEVICES" >> "$pmu_info_file"
    else
        echo "未检测到 HHA 设备" >> "$pmu_info_file"
    fi
    echo "" >> "$pmu_info_file"

    echo "=== 2. PMU 事件列表 (rx_ops/rx_outer/rx_sccl/uncore) ===" >> "$pmu_info_file"
    if command -v perf &>/dev/null; then
        set +o pipefail
        perf list 2>/dev/null | grep -iE -m 50 'hha|rx_ops|rx_outer|rx_sccl|uncore' >> "$pmu_info_file" 2>/dev/null || true
        set -o pipefail
    fi
    echo "" >> "$pmu_info_file"

    echo "=== 3. perf stat 远程访问统计 (${duration}秒) ===" >> "$pmu_info_file"
    if command -v perf &>/dev/null; then
        RX_OPS_EVENT=$(perf list 2>/dev/null | grep -iE 'rx_ops' | head -1 | awk -F'[' '{print $1}' | awk '{print $1}')
        RX_OUTER_EVENT=$(perf list 2>/dev/null | grep -iE 'rx_outer' | head -1 | awk -F'[' '{print $1}' | awk '{print $1}')
        RX_SCCL_EVENT=$(perf list 2>/dev/null | grep -iE 'rx_sccl' | head -1 | awk -F'[' '{print $1}' | awk '{print $1}')

        if [ -n "$RX_OPS_EVENT" ] && [ -n "$RX_OUTER_EVENT" ] && [ -n "$RX_SCCL_EVENT" ]; then
            perf stat -e "$RX_OPS_EVENT" -e "$RX_OUTER_EVENT" -e "$RX_SCCL_EVENT" -a sleep "$duration" >> "$pmu_info_file" 2>&1
        else
            echo "未找到完整的 PMU 事件 (rx_ops/rx_outer/rx_sccl)" >> "$pmu_info_file"
        fi
    fi
    echo "" >> "$pmu_info_file"

    echo "=== 4. 速率与远程访问占比 ===" >> "$pmu_info_file"
    if command -v perf &>/dev/null && [ -n "${RX_OPS_EVENT:-}" ]; then
        OPS_TOTAL=$(grep -E "$RX_OPS_EVENT" "$pmu_info_file" 2>/dev/null | grep -oE '[0-9,]+' | head -1 | tr -d ',' || echo "0")
        OUTER_TOTAL=$(grep -E "$RX_OUTER_EVENT" "$pmu_info_file" 2>/dev/null | grep -oE '[0-9,]+' | head -1 | tr -d ',' || echo "0")
        SCCL_TOTAL=$(grep -E "$RX_SCCL_EVENT" "$pmu_info_file" 2>/dev/null | grep -oE '[0-9,]+' | head -1 | tr -d ',' || echo "0")

        awk -v o="${OPS_TOTAL:-0}" -v x="${OUTER_TOTAL:-0}" -v s="${SCCL_TOTAL:-0}" -v d="$duration" \
            'BEGIN {
                if (d <= 0) d = 10
                rps = o / d
                pct = (o > 0) ? (x + s) / o * 100 : 0
                printf "ops_per_sec=%.0f remote_ratio=%.2f%%\n", rps, pct
            }' >> "$pmu_info_file"
    else
        echo "无法计算" >> "$pmu_info_file"
    fi
    echo "" >> "$pmu_info_file"

    echo "=== 5. perf list 输出开头 ===" >> "$pmu_info_file"
    if command -v perf &>/dev/null; then
        set +o pipefail
        perf list 2>/dev/null | head -20 >> "$pmu_info_file" 2>/dev/null
        set -o pipefail
    fi
    echo "" >> "$pmu_info_file"

    log_success "√ PMU 远程访问分析完成"
}


# ========== Main Entry ==========

ARCH_TARGET="aarch64"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH_TARGET="x86_64" ;;
    aarch64|arm64) ARCH_TARGET="aarch64" ;;
esac

DURATION=10
INTERVAL=1
TIMEOUT_DURATION=60
PIDS=""
OUTPUT_DIR=""
CHECK_ONLY=false

KSPECT_FILE=""; TOPDOWN_FILE=""; NUMAFAST_FILE=""; HOTSPOT_FILE=""
MEMORY_FILE=""; TURBOSTAT_FILE=""; KSYS_FILE=""; STATIC_FILE=""
BOTTLENECK_FILE=""; TOP_PROC_FILE=""; HOTSPOT_ANALYSIS_FILE=""
SYSCALL_FILE=""; MICROARCH_FILE=""; IO_METRICS_FILE=""
LOCK_TRACE_FILE=""; MEM_METRICS_FILE=""; NET_METRICS_FILE=""
SCHED_TRACE_FILE=""; CPU_DETAIL_FILE=""; KERNEL_CONFIG_FILE=""
PMU_INFO_FILE=""; PROCESS_DETAIL_INFO_FILE=""; SYSTEM_DETAIL_INFO_FILE=""
CONTAINER_FILE=""; CRC32_FILE=""; CHECK_64K_FILE=""; KRAIO_FILE=""; ERROR_LOG=""; SUPPLE_FILE=""; SOFTWARE_FILE=""; JAVA_INFO_FILE=""; ASSEMBLY_FILE=""

AVAILABLE_COMMANDS=(
    "collect_ksys"
    "collect_syscall_analysis"
    "collect_global_bottleneck"
    "collect_top_processes"
    "collect_process_detail_info"
    "collect_container_info"
    "check_arm_crc32"
    "collect_io_metrics"
    "collect_lock_trace"
    "collect_mem_metrics"
    "collect_net_metrics"
    "collect_sched_trace"
    "collect_kernel_config_info"
    "collect_cpu_detail_info"
    "collect_system_detail_info"
    "collect_static_info"
    "collect_java_info"
)

if [[ "${ARCH_TARGET}" = "aarch64" ]]; then
    AVAILABLE_COMMANDS+=(
        "collect_devkit_topdown"
        "collect_devkit_memory"
        "collect_devkit_hotspot"
        "collect_devkit_numafast"
        "collect_devkit_turbostat"
        "collect_kspect"
        "collect_pmu_info"
        "check_64k_opt"
        "check_kraio"
    )
fi
AVAILABLE_COMMANDS+=("collect_microarch_analysis" "collect_hotspot_analysis" "collect_assembly_analysis")

SELECTED_COMMANDS=()

set_output_file() {
    KSPECT_FILE="${OUTPUT_DIR}/devkit_kspect.txt"
    TOPDOWN_FILE="${OUTPUT_DIR}/devkit_topdown.txt"
    NUMAFAST_FILE="${OUTPUT_DIR}/devkit_numafast.txt"
    HOTSPOT_FILE="${OUTPUT_DIR}/devkit_hotspot.txt"
    MEMORY_FILE="${OUTPUT_DIR}/devkit_memory.txt"
    TURBOSTAT_FILE="${OUTPUT_DIR}/devkit_turbostat.txt"
    KSYS_FILE="${OUTPUT_DIR}/devkit_ksys.txt"
    STATIC_FILE="${OUTPUT_DIR}/static_info.txt"
    BOTTLENECK_FILE="${OUTPUT_DIR}/global_bottleneck.txt"
    TOP_PROC_FILE="${OUTPUT_DIR}/top_processes.txt"
    HOTSPOT_ANALYSIS_FILE="${OUTPUT_DIR}/hotspot_analysis.txt"
    SYSCALL_FILE="${OUTPUT_DIR}/syscall_analysis.txt"
    MICROARCH_FILE="${OUTPUT_DIR}/microarch_analysis.txt"
    IO_METRICS_FILE="${OUTPUT_DIR}/io_metrics_analysis.txt"
    LOCK_TRACE_FILE="${OUTPUT_DIR}/lock_trace_analysis.txt"
    MEM_METRICS_FILE="${OUTPUT_DIR}/memory_metrics_analysis.txt"
    NET_METRICS_FILE="${OUTPUT_DIR}/network_metrics_analysis.txt"
    SCHED_TRACE_FILE="${OUTPUT_DIR}/scheduler_trace_analysis.txt"
    CPU_DETAIL_FILE="${OUTPUT_DIR}/cpu_detail_info.txt"
    KERNEL_CONFIG_FILE="${OUTPUT_DIR}/kernel_config_info.txt"
    PMU_INFO_FILE="${OUTPUT_DIR}/pmu_info.txt"
    PROCESS_DETAIL_INFO_FILE="${OUTPUT_DIR}/process_detail_info.txt"
    SYSTEM_DETAIL_INFO_FILE="${OUTPUT_DIR}/system_detail_info.txt"
    CONTAINER_FILE="${OUTPUT_DIR}/container_info.txt"
    CRC32_FILE="${OUTPUT_DIR}/check_arm_crc32.txt"
    CHECK_64K_FILE="${OUTPUT_DIR}/check_64k_opt.txt"
    KRAIO_FILE="${OUTPUT_DIR}/check_kraio.txt"
    ERROR_LOG="${OUTPUT_DIR}/err_log.txt"
    SUPPLE_FILE="${OUTPUT_DIR}/supple_data.txt"
    SOFTWARE_FILE="${OUTPUT_DIR}/software.txt"
    JAVA_INFO_FILE="${OUTPUT_DIR}/java_info.txt"
    ASSEMBLY_FILE="${OUTPUT_DIR}/assembly_analysis.txt"
}

show_usage() {
    cat << HELP
用法: $0 -d <持续时间> -p <进程ID> [-o <输出目录>] [-c <采集项目>] [-t <超时缓冲>] [-C] [-h]

参数说明:
    -d <持续时间>    采集持续时间（秒）
    -p <进程ID>      监控进程ID（多个用逗号分隔）
    -o <输出目录>    数据输出目录（可选）
    -c <采集项目>    采集项目，多个用逗号分隔（可选）
    -t <超时缓冲>    命令超时缓冲（秒），默认60
    -C              仅前置检查
    -h              帮助

可用采集项目:
    collect_ksys                  - devkit ksys分析
    collect_io_metrics            - I/O分析
    collect_lock_trace            - 锁跟踪分析
    collect_mem_metrics           - 内存指标分析
    collect_net_metrics           - 网络指标分析
    collect_sched_trace           - 调度器跟踪分析
    collect_cpu_detail_info       - CPU详细信息
    collect_kernel_config_info    - Kernel配置信息
    collect_process_detail_info   - 进程详细信息
    collect_system_detail_info    - 系统详细信息
    collect_container_info        - 容器信息
    check_arm_crc32               - ARM CRC32 指令加速检测（需指定pid）
    collect_hotspot_analysis      - 热点函数分析（需指定pid）
    collect_syscall_analysis      - 系统调用分析（需指定pid）
    collect_microarch_analysis    - 微架构瓶颈分析（需指定pid）
    collect_global_bottleneck     - 全局资源瓶颈
    collect_top_processes         - top资源消耗进程
    collect_static_info           - 静态配置信息
    collect_java_info             - Java信息采集（需指定pid）
    collect_assembly_analysis     - 汇编代码采集（需指定pid，依赖 collect_hotspot_analysis 或 collect_devkit_hotspot 产生的热点数据）
AARCH64才支持的项目:
    collect_devkit_topdown        - devkit topdown
    collect_devkit_memory         - devkit memory
    collect_devkit_hotspot        - devkit hotspot
    collect_devkit_numafast       - devkit numafast
    collect_devkit_turbostat      - devkit turbostat
    collect_kspect                - devkit kspect
    collect_pmu_info              - pmu info
    check_64k_opt                 - ARM 64K页大小检测
    check_kraio                   - KRAIO网络异步优化检测
HELP
}

validate_pids() {
    local pids_str="$1"
    if [[ "$pids_str" =~ , ]]; then
        IFS=',' read -ra pid_array <<< "$pids_str"
        for pid in "${pid_array[@]}"; do
            pid=$(echo "$pid" | xargs)
            if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
                log_error "进程ID必须是数字，发现无效PID: $pid"; return 1
            fi
            if ! ps -p "$pid" > /dev/null 2>&1; then
                log_warning "进程ID $pid 不存在或已终止"
            fi
        done
    else
        local pid=$(echo "$pids_str" | xargs)
        if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
            log_error "进程ID必须是数字: $pid"; return 1
        fi
        if ! ps -p "$pid" > /dev/null 2>&1; then
            log_warning "进程ID $pid 不存在或已终止"
        fi
    fi
    return 0
}

validate_output_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ -w "$dir" ]]; then
            log_info "输出目录已存在且可写: $dir"; return 0
        else
            log_error "输出目录已存在但不可写: $dir"; return 1
        fi
    fi
    if mkdir -p "$dir" 2>/dev/null; then
        log_info "成功创建输出目录: $dir"; return 0
    else
        log_error "无法创建输出目录: $dir"; return 1
    fi
}

validate_collect_commands() {
    local invalid_cmds=() valid_cmds=()
    declare -A valid_map
    for cmd in "${AVAILABLE_COMMANDS[@]}"; do valid_map["$cmd"]=1; done
    for cmd in "$@"; do
        if [[ -n "${valid_map[$cmd]}" ]]; then valid_cmds+=("$cmd")
        else invalid_cmds+=("$cmd"); fi
    done
    if [[ ${#invalid_cmds[@]} -gt 0 ]]; then
        log_error "无效的采集项目: ${invalid_cmds[*]}"
        log_error "可用的采集项目: ${AVAILABLE_COMMANDS[*]}"; return 1
    fi
    SELECTED_COMMANDS=("${valid_cmds[@]}")
    return 0
}

parse_arguments() {
    while getopts "d:p:o:c:t:Ch" opt; do
        case ${opt} in
            d) if [[ "$OPTARG" =~ ^[0-9]+$ ]]; then DURATION=$OPTARG
               else log_error "持续时间必须是数字"; show_usage; exit 1; fi ;;
            p) PIDS="$OPTARG"; validate_pids "$PIDS" || exit 1 ;;
            o) OUTPUT_DIR="$OPTARG"; validate_output_dir "$OUTPUT_DIR" || exit 1; set_output_file ;;
            c) IFS=',' read -ra SELECTED_COMMANDS <<< "$OPTARG"; validate_collect_commands "${SELECTED_COMMANDS[@]}" || exit 1 ;;
            t) if [[ "$OPTARG" =~ ^[0-9]+$ ]]; then TIMEOUT_DURATION=$OPTARG
               else log_error "超时缓冲时间必须是数字"; show_usage; exit 1; fi ;;
            C) CHECK_ONLY=true ;;
            h) show_usage; exit 0 ;;
            \?) log_error "无效选项"; show_usage; exit 1 ;;
            :) log_error "选项 -$OPTARG 需要参数"; show_usage; exit 1 ;;
        esac
    done
    if [[ "$CHECK_ONLY" = false ]] && [[ -z "$DURATION" ]]; then
        log_error "缺少必需参数: -d <持续时间>"; show_usage; exit 1
    fi
    if [[ "$CHECK_ONLY" = true ]]; then
        [[ ${#SELECTED_COMMANDS[@]} -eq 0 ]] && SELECTED_COMMANDS=("${AVAILABLE_COMMANDS[@]}")
        return 0
    fi
    if [[ ${#SELECTED_COMMANDS[@]} -eq 0 ]]; then
        SELECTED_COMMANDS=("${AVAILABLE_COMMANDS[@]}")
        log_info "未指定采集项目，将采集所有可用项目 (共 ${#SELECTED_COMMANDS[@]} 项)"
    fi
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="profiling_data_${ARCH_TARGET}_$(date +%Y%m%d_%H%M%S)"
        validate_output_dir "$OUTPUT_DIR" || exit 1
        set_output_file
    fi
}

ensure_devkit_command() {
    local test_cmd="$1"
    local package_url=""
    local package_name=""
    local package_patterns=""

    case "$test_cmd" in
        "devkit")
            package_url="https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit/Kunpeng%20DevKit%2026.0.RC1/DevKit-Tuner-CLI-26.0.RC1-Linux-aarch64.tar.gz"
            package_name="devkit-tuner"
            package_patterns="devkit*tuner*.tar.gz DevKit*Tuner*.tar.gz"
            ;;
        "ksys")
            package_url="https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit/Kunpeng%20DevKit%2026.0.RC1/ksys-26.0.RC1-Linux-${ARCH_TARGET}.tar.gz"
            package_name="devkit-ksys"
            package_patterns="ksys*.tar.gz devkit*ksys*.tar.gz"
            ;;
        "kspect")
            package_url="https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit/Kunpeng%20DevKit%2026.0.RC1/devkit-kspect-26.0.RC1-Linux-aarch64.tar.gz"
            package_name="devkit-kspect"
            package_patterns="kspect*.tar.gz devkit*kspect*.tar.gz"
            ;;
        "asprof")
            if [[ "$ARCH_TARGET" == "aarch64" ]]; then
                package_url="https://github.com/async-profiler/async-profiler/releases/download/v4.5/async-profiler-4.5-linux-arm64.tar.gz"
                package_patterns="async-profiler*arm64*.tar.gz"
            else
                package_url="https://github.com/async-profiler/async-profiler/releases/download/v4.5/async-profiler-4.5-linux-x64.tar.gz"
                package_patterns="async-profiler*x64*.tar.gz"
            fi
            package_name="async-profiler"
            ;;
        *)
            return 1
            ;;
    esac

    local found_exec=""
    local found_dir=""

    found_exec=$(find "$PWD" -maxdepth 3 -type f -executable -name "$test_cmd" 2>/dev/null | head -1)
    if [[ -n "$found_exec" ]]; then
        found_dir=$(dirname "$found_exec")
        export PATH="$found_dir:$PATH"
        log_info "在当前目录找到 $test_cmd: $found_exec，已添加到PATH"
        if command -v "$test_cmd" &> /dev/null; then
            log_success "命令 $test_cmd 已可用"
            return 0
        fi
    fi

    local pkg_file=""
    for pattern in $package_patterns; do
        for f in "$PWD"/$pattern; do
            if [[ -f "$f" ]]; then
                pkg_file="$f"
                break 2
            fi
        done
    done

    if [[ -n "$pkg_file" ]]; then
        log_info "在当前目录找到安装包: $pkg_file"
        log_info "开始解压到当前目录..."
        tar -xzf "$pkg_file" -C "$PWD"
        if [[ $? -eq 0 ]]; then
            log_info "解压完成"
            found_exec=$(find "$PWD" -maxdepth 3 -type f -executable -name "$test_cmd" 2>/dev/null | head -1)
            if [[ -n "$found_exec" ]]; then
                found_dir=$(dirname "$found_exec")
                export PATH="$found_dir:$PATH"
                log_info "已添加到PATH: $found_dir"
                if command -v "$test_cmd" &> /dev/null; then
                    log_success "命令 $test_cmd 已可用"
                    return 0
                fi
            fi
        else
            log_error "解压失败: $pkg_file"
        fi
    fi

    log_info "开始下载 $package_name 到当前目录..."
    local download_file="$PWD/${package_name}-${ARCH_TARGET}.tar.gz"

    if command -v wget &> /dev/null; then
        wget -O "$download_file" "$package_url"
    elif command -v curl &> /dev/null; then
        curl -L -o "$download_file" "$package_url"
    else
        log_error "未找到wget或curl下载工具，请先安装其中一个"
        return 1
    fi

    if [[ $? -ne 0 ]]; then
        log_error "下载 $package_name 失败，请检查网络连接或URL"
        rm -f "$download_file"
        return 1
    fi

    log_info "下载完成，开始解压到当前目录..."
    tar -xzf "$download_file" -C "$PWD"
    if [[ $? -ne 0 ]]; then
        log_error "解压 $package_name 失败"
        rm -f "$download_file"
        return 1
    fi

    found_exec=$(find "$PWD" -maxdepth 3 -type f -executable -name "$test_cmd" 2>/dev/null | head -1)
    if [[ -n "$found_exec" ]]; then
        found_dir=$(dirname "$found_exec")
        export PATH="$found_dir:$PATH"
        log_info "已添加到PATH: $found_dir"
        if command -v "$test_cmd" &> /dev/null; then
            log_success "命令 $test_cmd 已可用"
            return 0
        fi
    fi

    log_warning "$package_name 已下载并解压，但未找到可执行文件 $test_cmd"
    log_info "请手动查看当前目录下的解压内容，并将可执行文件所在目录添加到PATH"
    return 1
}

check_command_prefix() {
    local cmd="$1"
    local test_cmd="$2"
    if [[ -z $test_cmd ]];then
        test_cmd=$cmd
    fi

    if ! command -v "$test_cmd" &> /dev/null; then
        log_error "命令 $test_cmd 未找到"

        if [[ "$test_cmd" =~ ^(devkit|ksys|kspect|asprof)$ ]]; then
            ensure_devkit_command "$test_cmd"
            return $?
        fi

        echo "是否尝试通过yum安装 $cmd? (Y/N)"
        read -r user_choice < /dev/tty

        case "${user_choice^^}" in
            "Y"|"YES")
                log_info "尝试通过yum安装 $cmd..."
                if command -v yum &> /dev/null; then
                    if command -v sudo &> /dev/null; then
                        if sudo -n true 2>/dev/null; then
                            sudo yum install -y "$cmd"
                            if [ $? -eq 0 ]; then
                                log_info "$cmd 安装成功"
                                return 0
                            else
                                log_error "yum安装 $cmd 失败"
                            fi
                        else
                            log_warning "没有 sudo 权限，尝试直接安装..."
                            yum install -y "$cmd"
                            if [ $? -eq 0 ]; then
                                log_info "$cmd 安装成功"
                                return 0
                            else
                                log_error "yum安装 $cmd 失败（可能需要 root 权限）"
                            fi
                        fi
                    else
                        log_warning "sudo 命令不可用，尝试直接安装..."
                        yum install -y "$cmd"
                        if [ $? -eq 0 ]; then
                            log_info "$cmd 安装成功"
                            return 0
                        else
                            log_error "yum安装 $cmd 失败（可能需要 root 权限）"
                        fi
                    fi
                else
                    log_error "未找到yum包管理器"
                fi
                ;;
            "N"|"NO"|*)
                log_info "用户选择手动安装"
                echo "请手动安装 $cmd:"
                echo "1. 可通过yum安装: sudo yum install $cmd"
                echo "2. 或从官方源下载安装包"
                echo "3. 若已安装，请确保已添加到PATH环境变量"
                ;;
        esac
        return 1
    else
        log_info "命令 $cmd 已存在"
        return 0
    fi
}

check_commands() {
    log_info "开始命令前置检查"

    local needed_commands=()
   
    for selected in "${SELECTED_COMMANDS[@]}"; do
        case "$selected" in
            collect_devkit*)
                needed_commands+=("devkit" "kspect")
                ;;
            collect_ksys)
                needed_commands+=("ksys")
                ;;
            collect_hotspot_analysis|collect_syscall_analysis|collect_microarch_analysis|collect_pmu_info)
                needed_commands+=("perf")
                ;;
            collect_top_process)
                needed_commands+=("iotop")
                ;;
            collect_static_info)
                needed_commands+=("pciutils lspci" "ethtool" "gcc" "dmidecode" "numactl")
                ;;
            collect_net_metrics)
                needed_commands+=("net-tools netstat" "iputils ping" "iproute ip" "ethtool")
                ;;
            collect_sched_trace)
                needed_commands+=("util-linux taskset")
                ;;
            collect_syscall_analysis|collect_lock_trace)
                needed_commands+=("strace")
                ;;
            collect_mem_metrics)
                needed_commands+=("numactl")
                ;;
            check_arm_crc32)
                needed_commands+=("objdump" "readelf" "file")
                ;;
            collect_assembly_analysis)
                needed_commands+=("binutils objdump" "binutils nm")
                ;;
            collect_java_info)
                needed_commands+=("asprof")
                ;;
        esac
    done

    if [[ ${#needed_commands[@]} -gt 0 ]]; then
        while read cmd; do
            check_command_prefix $cmd
        done < <(printf "%s\n" "${needed_commands[@]}" | sort -u)
    fi

    check_command_prefix sysstat pidstat
    check_command_prefix util-linux lscpu
    log_success "前置命令检查完成"
}

preflight_check() {
    local missing_commands=() installed_commands=() optional_missing=()
    echo -e "${BLUE}=== 基础系统命令检查 ===${NC}"
    for cmd in ps top free df uptime date cat grep awk sed head tail wc sort uniq find xargs mkdir rm mv cp chmod chown tar; do
        if command -v "$cmd" &> /dev/null; then
            echo -e "  ${GREEN}✓ $cmd${NC}"; installed_commands+=("$cmd")
        else
            echo -e "  ${RED}✗ $cmd${NC}"; missing_commands+=("$cmd")
        fi
    done
    echo ""
    echo -e "${BLUE}=== 性能分析工具检查 (sysstat) ===${NC}"
    local s=0; for c in mpstat vmstat pidstat iostat sar; do command -v "$c" &>/dev/null && s=$((s+1)); done
    [[ $s -ge 3 ]] && echo -e "  ${GREEN}✓ sysstat${NC}" || echo -e "  ${YELLOW}○ sysstat 未完整安装${NC}"
    echo ""
    echo -e "${BLUE}=== perf工具检查 ===${NC}"
    command -v perf &>/dev/null && echo -e "  ${GREEN}✓ perf${NC}" || echo -e "  ${YELLOW}○ perf 缺失${NC}"
    echo ""
    if [[ ${#missing_commands[@]} -eq 0 ]]; then
        log_success "✓ 前置检查通过"; return 0
    else
        log_error "✗ 前置检查失败"; return 1
    fi
}

main() {
    parse_arguments "$@"
    if [[ "$CHECK_ONLY" = true ]]; then
        check_root; preflight_check; local ret=$?
        [[ $ret -eq 0 ]] && log_success "✓ 所有必需依赖已安装" || log_error "✗ 前置检查失败"
        exit $ret
    fi
    log_info "开始服务器数据采集..."
    log_info "阶段性步骤采集持续时间: ${DURATION}秒"
    [[ -n "$PIDS" ]] && log_info "监控进程: $PIDS"
    check_root

    echo "================================================"
    echo "服务器数据采集报告"
    echo "采集时间: $(date)"
    echo "主机名: $(hostname)"
    echo "阶段性步骤采集持续时间: ${DURATION}秒"
    if [[ -n "$PIDS" ]]; then
        echo "监控进程ID: $PIDS"
        IFS=',' read -ra pid_array <<< "$PIDS"
        for pid in "${pid_array[@]}"; do
            pid=$(echo "$pid" | xargs)
            if ps -p "$pid" > /dev/null 2>&1; then
                echo "进程名称: $(ps -p $pid -o comm=)"
            else
                echo "进程状态: 不存在或已终止"
            fi
        done
    fi
    echo "================================================"
    echo ""

    check_commands

    export DURATION PIDS OUTPUT_DIR TIMEOUT_DURATION
    declare -A COLLECT_TIMING=()
    COLLECT_TIMING_NAMES=()
    local _t_start _t_end _elapsed
    for cmd in "${SELECTED_COMMANDS[@]}"; do
        _t_start=$(date +%s.%N)
        $cmd
        _t_end=$(date +%s.%N)
        _elapsed=$(awk "BEGIN{printf \"%.2f\", $_t_end - $_t_start}")
        COLLECT_TIMING_NAMES+=("$cmd")
        COLLECT_TIMING["$cmd"]="${_elapsed}"
        log_info "[计时] ${cmd} 耗时 ${_elapsed} 秒"
    done

    echo "==================== 采集总结 ===================="
    echo "数据采集完成时间: $(date)"
    echo "阶段性采集持续时间: ${DURATION}秒"
    [[ -n "$PIDS" ]] && echo "监控进程: $PIDS"
    echo "================================================"
    log_success "数据采集完成!"

    echo ""
    echo "==================== 采集耗时统计 ===================="
    printf "%-35s %10s\n" "采集项目" "耗时(秒)"
    printf "%-35s %10s\n" "-----------------------------------" "----------"
    local _sum_t=0
    local _c _t
    for _c in "${COLLECT_TIMING_NAMES[@]}"; do
        _t="${COLLECT_TIMING[$_c]}"
        printf "%-35s %10s\n" "$_c" "$_t"
        _sum_t=$(awk "BEGIN{printf \"%.2f\", $_sum_t + $_t}")
    done
    printf "%-35s %10s\n" "-----------------------------------" "----------"
    printf "%-35s %10s\n" "合计" "${_sum_t}"
    echo "====================================================="

    local reports=()
    [[ -f "$KSYS_FILE" ]] && reports+=("devkit ksys数据报告:$KSYS_FILE")
    [[ -f "$STATIC_FILE" ]] && reports+=("系统环境静态信息:$STATIC_FILE")
    [[ -f "$BOTTLENECK_FILE" ]] && reports+=("全局资源瓶颈识别:$BOTTLENECK_FILE")
    [[ -f "$TOP_PROC_FILE" ]] && reports+=("顶级资源进程识别:$TOP_PROC_FILE")
    [[ -f "$HOTSPOT_ANALYSIS_FILE" ]] && reports+=("热点函数分析:$HOTSPOT_ANALYSIS_FILE")
    [[ -f "$SYSCALL_FILE" ]] && reports+=("系统调用分析:$SYSCALL_FILE")
    [[ -f "$MICROARCH_FILE" ]] && reports+=("微架构瓶颈分析:$MICROARCH_FILE")
    [[ -f "$IO_METRICS_FILE" ]] && reports+=("I/O深度分析:$IO_METRICS_FILE")
    [[ -f "$LOCK_TRACE_FILE" ]] && reports+=("锁跟踪分析:$LOCK_TRACE_FILE")
    [[ -f "$MEM_METRICS_FILE" ]] && reports+=("内存指标深度分析:$MEM_METRICS_FILE")
    [[ -f "$NET_METRICS_FILE" ]] && reports+=("网络指标深度分析:$NET_METRICS_FILE")
    [[ -f "$SCHED_TRACE_FILE" ]] && reports+=("调度器跟踪分析:$SCHED_TRACE_FILE")
    [[ -f "$CPU_DETAIL_FILE" ]] && reports+=("CPU深度信息:$CPU_DETAIL_FILE")
    [[ -f "$KERNEL_CONFIG_FILE" ]] && reports+=("内核深度诊断:$KERNEL_CONFIG_FILE")
    [[ -f "$PROCESS_DETAIL_INFO_FILE" ]] && reports+=("进程/线程详细信息:$PROCESS_DETAIL_INFO_FILE")
    [[ -f "$SYSTEM_DETAIL_INFO_FILE" ]] && reports+=("系统详细信息:$SYSTEM_DETAIL_INFO_FILE")
    [[ -f "$CONTAINER_FILE" ]] && reports+=("容器资源监控:$CONTAINER_FILE")
    [[ -f "$CRC32_FILE" ]] && reports+=("ARM CRC32 指令加速检测:$CRC32_FILE")
    [[ -f "$CHECK_64K_FILE" ]] && reports+=("ARM 64K 页大小检测:$CHECK_64K_FILE")
    [[ -f "$KRAIO_FILE" ]] && reports+=("KRAIO 网络异步优化检测:$KRAIO_FILE")
    [[ -f "$TOPDOWN_FILE" ]] && reports+=("devkit topdown数据:$TOPDOWN_FILE")
    [[ -f "$NUMAFAST_FILE" ]] && reports+=("devkit numafast数据:$NUMAFAST_FILE")
    [[ -f "$MEMORY_FILE" ]] && reports+=("devkit memory数据:$MEMORY_FILE")
    [[ -f "$HOTSPOT_FILE" ]] && reports+=("devkit hotspot数据:$HOTSPOT_FILE")
    [[ -f "$TURBOSTAT_FILE" ]] && reports+=("devkit turbostat数据:$TURBOSTAT_FILE")
    [[ -f "$KSPECT_FILE" ]] && reports+=("devkit健康度检查:$KSPECT_FILE")
    [[ -f "$PMU_INFO_FILE" ]] && reports+=("PMU远程访问分析:$PMU_INFO_FILE")
    [[ -f "$JAVA_INFO_FILE" ]] && reports+=("Java信息采集:$JAVA_INFO_FILE")
    [[ -f "$ASSEMBLY_FILE" ]] && reports+=("汇编代码分析:$ASSEMBLY_FILE")

    echo ""
    echo "采集完成！以下文件已生成："
    local num=0
    for entry in "${reports[@]}"; do
        num=$((num + 1))
        IFS=':' read -r desc fpath <<< "$entry"
        echo "$num. $desc: $(cd "$OUTPUT_DIR" && pwd)/$(basename "$fpath")"
    done
    echo ""

    get_software "$SOFTWARE_FILE"
    supple_data "$SUPPLE_FILE"
    echo ""
}

main "$@"

if [[ "$CHECK_ONLY" = false ]] && [[ -d "$OUTPUT_DIR" ]]; then
    ARCHIVE_NAME="${OUTPUT_DIR}.tar.gz"
    log_info "正在打包输出目录为 ${ARCHIVE_NAME} ..."
    tar -czf "$ARCHIVE_NAME" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null
    if [ $? -eq 0 ]; then
        log_success "打包完成: $(pwd)/${ARCHIVE_NAME}"
        log_info "打包文件大小: $(du -h "$ARCHIVE_NAME" | cut -f1)"
    else
        log_error "打包失败"
    fi
fi
