#!/bin/bash
# ==============================================================================
# collect_env.sh - Linux 环境信息采集脚本
# 支持物理机 / 虚拟机 / 容器场景
# 工作模式：读取 en.jsonc 模板，替换占位符，输出 en_info.jsonc
# ==============================================================================

# 如果不是 bash 环境，自动用 bash 重新执行（兼容 sh collect_env.sh 调用方式）
if [ -z "${BASH_VERSION:-}" ]; then
	exec bash "$0" "$@"
fi

# 注意：不使用 pipefail，因为采集脚本中大量使用 pipeline + head -1，
# pipefail 会导致 head 关闭管道时上游命令 SIGPIPE 退出码非零，
# 配合 set -e 在 $(...) 子shell中静默退出，无法被 ERR 陷阱捕获
set -eu

# ERR 错误陷阱：打印失败行号，便于排查
trap 'echo "错误：脚本在第 $LINENO 行执行失败" >&2' ERR

# ============================ 路径配置 ============================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/en.jsonc"
# 兼容两种部署方式：模板与脚本同目录（拷贝到工作目录执行）或位于 skill assets/ 目录（就地执行）
if [ ! -f "$TEMPLATE" ]; then
	TEMPLATE="${SCRIPT_DIR}/../assets/en.jsonc"
fi
# 默认输出到当前工作目录，可通过 --output-dir 覆盖
OUTPUT_DIR="$(pwd)"
OUTPUT="${OUTPUT_DIR}/en_info.jsonc"

# ============================ 日志控制 ============================

VERBOSE=0

log() {
	if [[ "$VERBOSE" -eq 1 ]]; then
		echo "$1"
	fi
}

# ============================ 全局变量 ============================

ENV_TYPE=""
IP_ADDR=""
ROLE=""

# CPU
CPU_ARCH=""
CPU_CORES=""
CPU_THREADS_PER_CORE=""
CPU_FREQ_MHZ=""
CPU_L1D_KB=""
CPU_L1I_KB=""
CPU_L2_KB=""
CPU_L3_MB=""

# 内存
MEM_TOTAL_GB=""
MEM_TYPE=""

# 存储
STORAGE_ITEMS=""

# 网络
NETWORK_ITEMS=""
NET_BANDWIDTH_MBPS=""
NET_LATENCY_MS=""

# 系统
OS_NAME=""
OS_VERSION=""
KERNEL=""
CONTAINER_RUNTIME=""
ORCHESTRATOR=""

# ============================ 工具函数 ============================

# JSON 字符串转义
json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"   # 反斜杠
	s="${s//\"/\\\"}"   # 双引号
	s="${s//$'\n'/\\n}" # 换行
	s="${s//$'\r'/\\r}" # 回车
	s="${s//$'\t'/\\t}" # 制表符
	printf '%s' "$s"
}

# 安全执行命令，失败时返回默认值
safe_exec() {
	local default="$1"; shift
	local result
	result=$("$@" 2>/dev/null) || result="$default"
	printf '%s' "$result"
}

# ============================ 环境类型检测 ============================

# 检测运行环境类型：physical / virtual / container
detect_env_type() {
	# 1. 容器检测
	if [[ -f /.dockerenv ]]; then
		printf 'container'
		return
	fi
	if grep -qaE 'docker|containerd|crio|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
		printf 'container'
		return
	fi
	if [[ -f /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -qE '^container='; then
		printf 'container'
		return
	fi

	# 2. 虚拟机检测（systemd-detect-virt 优先）
	if command -v systemd-detect-virt &>/dev/null; then
		local virt
		virt=$(systemd-detect-virt 2>/dev/null || printf '')
		case "$virt" in
			none|'') ;; # 不是虚拟机，继续判断
			*) printf 'virtual'; return ;;
		esac
	fi

	# 3. 通过 DMI 产品名判断
	local product
	product=$(safe_exec '' cat /sys/class/dmi/id/product_name 2>/dev/null || printf '')
	case "$product" in
		*VMware*|*VirtualBox*|*KVM*|*QEMU*|*Xen*|*Hyper-V*|*Parallels*|*BHYVE*)
			printf 'virtual'; return ;;
	esac

	# 4. 通过 /proc/cpuinfo hypervisor flag 判断
	if grep -q '^flags.*hypervisor' /proc/cpuinfo 2>/dev/null; then
		printf 'virtual'
		return
	fi

	printf 'physical'
}

# ============================ IP 地址获取 ============================

get_primary_ip() {
	# 优先使用 ip 命令
	if command -v ip &>/dev/null; then
		local ip_addr
		ip_addr=$(ip -4 -o addr show scope global 2>/dev/null \
			| awk '{print $4}' \
			| head -1 \
			| cut -d/ -f1)
		[[ -n "$ip_addr" ]] && { printf '%s' "$ip_addr"; return; }
	fi
	# 回退到 hostname
	safe_exec '' hostname -I 2>/dev/null | awk '{print $1}'
}

# ============================ 节点角色推断 ============================

detect_role() {
	# Kubernetes 环境下检测节点角色
	if [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]] && command -v kubectl &>/dev/null; then
		local node_name
		node_name=$(hostname 2>/dev/null)
		local node_role
		node_role=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels}' 2>/dev/null || printf '')
		if echo "$node_role" | grep -q 'node-role.kubernetes.io/master'; then
			printf 'master'
			return
		elif echo "$node_role" | grep -q 'node-role.kubernetes.io/worker'; then
			printf 'worker'
			return
		fi
	fi

	# 根据 hostname 推断
	local hostname
	hostname=$(hostname 2>/dev/null || printf '')
	case "$hostname" in
		*master*|*controller*) printf 'master' ;;
		*slave*|*backup*|*standby*) printf 'slave' ;;
		*proxy*|*haproxy*|*nginx*) printf 'proxy' ;;
		*) printf 'worker' ;;
	esac
}

# ============================ 容器资源限制采集 ============================

# 获取容器 CPU 限制（核数），无限制时返回空字符串
# 支持 cgroup v1 / v2，并兼容嵌套 cgroup 路径（如 Kubernetes Pod）
get_container_cpu_limit() {
	local quota period

	# --- cgroup v2：/sys/fs/cgroup/cpu.max 格式为 "quota period" 或 "max period" ---
	if [[ -f /sys/fs/cgroup/cpu.max ]]; then
		read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null
		if [[ "$quota" != "max" && "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
			# 向下取整，容器可用的完整 CPU 核数
			awk "BEGIN {printf \"%d\", $quota / $period}"
			return
		fi
	fi

	# --- cgroup v1：cpu.cfs_quota_us / cpu.cfs_period_us ---
	if [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
		quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
		period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
		# quota == -1 表示无限制
		if [[ -n "$quota" && "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
			awk "BEGIN {printf \"%d\", $quota / $period}"
			return
		fi
	fi

	# --- 从 /proc/self/cgroup 解析嵌套 cgroup 路径 ---
	if [[ -f /proc/self/cgroup ]]; then
		if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
			# cgroup v2 嵌套路径
			local cg_path
			cg_path=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup 2>/dev/null)
			if [[ -n "$cg_path" ]]; then
				local full_path="/sys/fs/cgroup${cg_path}"
				if [[ -f "${full_path}/cpu.max" ]]; then
					read -r quota period < "${full_path}/cpu.max" 2>/dev/null
					if [[ "$quota" != "max" && "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
						awk "BEGIN {printf \"%d\", $quota / $period}"
						return
					fi
				fi
			fi
		else
			# cgroup v1 嵌套路径
			local cg_path
			cg_path=$(awk -F: '$2 ~ /(^|,)cpu(,|$)/ {print $3}' /proc/self/cgroup 2>/dev/null | head -1)
			if [[ -n "$cg_path" ]]; then
				local full_path="/sys/fs/cgroup/cpu${cg_path}"
				if [[ -f "${full_path}/cpu.cfs_quota_us" ]]; then
					quota=$(cat "${full_path}/cpu.cfs_quota_us" 2>/dev/null)
					period=$(cat "${full_path}/cpu.cfs_period_us" 2>/dev/null)
					if [[ -n "$quota" && "$quota" =~ ^[0-9]+$ && "$quota" -gt 0 && "$period" =~ ^[0-9]+$ && "$period" -gt 0 ]]; then
						awk "BEGIN {printf \"%d\", $quota / $period}"
						return
					fi
				fi
			fi
		fi
	fi
}

# 获取容器内存限制（字节），无限制时返回空字符串
# 支持 cgroup v1 / v2，并兼容嵌套 cgroup 路径（如 Kubernetes Pod）
get_container_mem_limit() {
	# --- cgroup v2：/sys/fs/cgroup/memory.max ---
	if [[ -f /sys/fs/cgroup/memory.max ]]; then
		local mem_max
		mem_max=$(tr -d '[:space:]' < /sys/fs/cgroup/memory.max 2>/dev/null)
		if [[ "$mem_max" != "max" && "$mem_max" =~ ^[0-9]+$ ]]; then
			printf '%s' "$mem_max"
			return
		fi
	fi

	# --- cgroup v1：/sys/fs/cgroup/memory/memory.limit_in_bytes ---
	if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
		local mem_limit
		mem_limit=$(tr -d '[:space:]' < /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
		# cgroup v1 无限制时值为 9223372036854771712（2^63 - 4096，页对齐）
		if [[ -n "$mem_limit" && "$mem_limit" =~ ^[0-9]+$ && "$mem_limit" -lt 9223372036854771712 ]]; then
			printf '%s' "$mem_limit"
			return
		fi
	fi

	# --- 从 /proc/self/cgroup 解析嵌套 cgroup 路径 ---
	if [[ -f /proc/self/cgroup ]]; then
		if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
			# cgroup v2 嵌套路径
			local cg_path
			cg_path=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup 2>/dev/null)
			if [[ -n "$cg_path" ]]; then
				local full_path="/sys/fs/cgroup${cg_path}"
				if [[ -f "${full_path}/memory.max" ]]; then
					local mem_max
					mem_max=$(tr -d '[:space:]' < "${full_path}/memory.max" 2>/dev/null)
					if [[ "$mem_max" != "max" && "$mem_max" =~ ^[0-9]+$ ]]; then
						printf '%s' "$mem_max"
						return
					fi
				fi
			fi
		else
			# cgroup v1 嵌套路径
			local cg_path
			cg_path=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3}' /proc/self/cgroup 2>/dev/null | head -1)
			if [[ -n "$cg_path" ]]; then
				local full_path="/sys/fs/cgroup/memory${cg_path}"
				if [[ -f "${full_path}/memory.limit_in_bytes" ]]; then
					local mem_limit
					mem_limit=$(tr -d '[:space:]' < "${full_path}/memory.limit_in_bytes" 2>/dev/null)
					if [[ -n "$mem_limit" && "$mem_limit" =~ ^[0-9]+$ && "$mem_limit" -lt 9223372036854771712 ]]; then
						printf '%s' "$mem_limit"
						return
					fi
				fi
			fi
		fi
	fi
}

# ============================ CPU 信息采集 ============================

collect_cpu() {
	CPU_ARCH=""
	CPU_CORES=""
	CPU_THREADS_PER_CORE=""
	CPU_FREQ_MHZ=""
	CPU_L1D_KB=0
	CPU_L1I_KB=0
	CPU_L2_KB=0
	CPU_L3_MB=0

	# 架构
	CPU_ARCH=$(safe_exec '' uname -m)

	# 使用 lscpu 获取核心信息
	if command -v lscpu &>/dev/null; then
		CPU_CORES=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket:/ {gsub(/ /,"",$2); print $2}' | head -1)
		[[ -z "$CPU_CORES" || "$CPU_CORES" == "0" ]] && CPU_CORES=$(lscpu 2>/dev/null | awk -F: '/^CPU\(s\):/ {gsub(/ /,"",$2); print $2}' | head -1)

		local sockets
		sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\):/ {gsub(/ /,"",$2); print $2}' | head -1)
		[[ -n "$sockets" && "$sockets" =~ ^[0-9]+$ && -n "$CPU_CORES" && "$CPU_CORES" =~ ^[0-9]+$ ]] && \
			CPU_CORES=$((CPU_CORES * sockets))

		CPU_THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core:/ {gsub(/ /,"",$2); print $2}' | head -1)
		[[ -z "$CPU_THREADS_PER_CORE" ]] && CPU_THREADS_PER_CORE=1

		# CPU 主频
		CPU_FREQ_MHZ=$(lscpu 2>/dev/null | awk -F: '/^CPU max MHz:/ {gsub(/ /,"",$2); printf "%d", $2}' | head -1)
		[[ -z "$CPU_FREQ_MHZ" ]] && CPU_FREQ_MHZ=$(lscpu 2>/dev/null | awk -F: '/^CPU MHz:/ {gsub(/ /,"",$2); printf "%d", $2}' | head -1)

		# 缓存信息（使用 sed 替代 grep -oP 以提高兼容性）
		CPU_L1D_KB=$(lscpu 2>/dev/null | awk -F: '/^L1d cache:/ {gsub(/ /,"",$2); print $2}' | sed 's/[^0-9]//g' | head -1)
		CPU_L1I_KB=$(lscpu 2>/dev/null | awk -F: '/^L1i cache:/ {gsub(/ /,"",$2); print $2}' | sed 's/[^0-9]//g' | head -1)
		CPU_L2_KB=$(lscpu 2>/dev/null | awk -F: '/^L2 cache:/ {gsub(/ /,"",$2); print $2}' | sed 's/[^0-9]//g' | head -1)
		CPU_L3_MB=$(lscpu 2>/dev/null | awk -F: '/^L3 cache:/ {
			gsub(/ /,"",$2); s=$2;
			if (s ~ /[Mm]/) { gsub(/[^0-9]/,"",s); print s+0 }
			else { gsub(/[^0-9]/,"",s); printf "%d", (s+0)/1024 }
		}' | head -1)
	fi

	# 回退到 /proc/cpuinfo
	if [[ -z "$CPU_CORES" || "$CPU_CORES" == "0" ]]; then
		CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '0')
	fi
	if [[ -z "$CPU_FREQ_MHZ" || "$CPU_FREQ_MHZ" == "0" ]]; then
		CPU_FREQ_MHZ=$(awk -F: '/^cpu MHz/ {gsub(/ /,"",$2); printf "%d", $2; exit}' /proc/cpuinfo 2>/dev/null)
	fi
	# 回退到 /sys 获取频率
	if [[ -z "$CPU_FREQ_MHZ" || "$CPU_FREQ_MHZ" == "0" ]]; then
		CPU_FREQ_MHZ=$(safe_exec 0 cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
		[[ -n "$CPU_FREQ_MHZ" && "$CPU_FREQ_MHZ" =~ ^[0-9]+$ ]] && CPU_FREQ_MHZ=$((CPU_FREQ_MHZ / 1000))
	fi

	# 补充缓存信息：从 sysfs 获取
	[[ -z "$CPU_L1D_KB" || "$CPU_L1D_KB" == "0" ]] && CPU_L1D_KB=$(safe_exec 0 bash -c 'cat /sys/devices/system/cpu/cpu0/cache/index0/size 2>/dev/null | sed "s/[^0-9]//g"' || printf '0')
	[[ -z "$CPU_L1I_KB" || "$CPU_L1I_KB" == "0" ]] && CPU_L1I_KB=$(safe_exec 0 bash -c 'cat /sys/devices/system/cpu/cpu0/cache/index1/size 2>/dev/null | sed "s/[^0-9]//g"' || printf '0')
	[[ -z "$CPU_L2_KB" || "$CPU_L2_KB" == "0" ]] && CPU_L2_KB=$(safe_exec 0 bash -c 'cat /sys/devices/system/cpu/cpu0/cache/index2/size 2>/dev/null | sed "s/[^0-9]//g"' || printf '0')
	[[ -z "$CPU_L3_MB" || "$CPU_L3_MB" == "0" ]] && CPU_L3_MB=$(safe_exec 0 bash -c 'val=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null | sed "s/[^0-9]//g"); val=${val:-0}; echo $((val / 1024))' || printf '0')

	# 容器场景：使用 cgroup CPU 限制覆盖核心数
	if [[ "$ENV_TYPE" == "container" ]]; then
		local cgroup_cores
		cgroup_cores=$(get_container_cpu_limit)
		if [[ -n "$cgroup_cores" && "$cgroup_cores" =~ ^[0-9]+$ && "$cgroup_cores" -gt 0 ]]; then
			CPU_CORES="$cgroup_cores"
			log "  容器 CPU 限制：${cgroup_cores} 核"
		fi
	fi

	# 默认值
	: "${CPU_CORES:=0}"
	: "${CPU_THREADS_PER_CORE:=1}"
	: "${CPU_FREQ_MHZ:=0}"
	: "${CPU_L1D_KB:=0}"
	: "${CPU_L1I_KB:=0}"
	: "${CPU_L2_KB:=0}"
	: "${CPU_L3_MB:=0}"
}

# ============================ 内存信息采集 ============================

collect_memory() {
	# 总内存
	local total_bytes
	total_bytes=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
	total_bytes=${total_bytes:-0}
	# kB -> GB
	MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1024 / 1024}")

	# 内存类型（精确匹配行首 "Type:"，排除 "Error Correction Type:" 和 "Type Detail:"）
	MEM_TYPE="Unknown"
	if command -v dmidecode &>/dev/null; then
		local dmidecode_type
		dmidecode_type=$(safe_exec '' dmidecode -t memory 2>/dev/null \
			| awk -F: '/^[[:space:]]*Type:/ {gsub(/ /,"",$2); if ($2 != "Unknown" && $2 != "Empty") print $2}' \
			| head -1)
		[[ -n "$dmidecode_type" ]] && MEM_TYPE="$dmidecode_type"
	fi

	# 容器场景：使用 cgroup 内存限制覆盖总内存
	if [[ "$ENV_TYPE" == "container" ]]; then
		local mem_limit_bytes
		mem_limit_bytes=$(get_container_mem_limit)
		if [[ -n "$mem_limit_bytes" && "$mem_limit_bytes" =~ ^[0-9]+$ && "$mem_limit_bytes" -gt 0 ]]; then
			# bytes -> GB
			MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $mem_limit_bytes / 1024 / 1024 / 1024}")
			log "  容器内存限制：${MEM_TOTAL_GB}GB"
		fi
	fi
}

# ============================ 存储信息采集 ============================

collect_storage() {
	STORAGE_ITEMS=""
	local first=1

	# 使用 lsblk 获取块设备信息
	if command -v lsblk &>/dev/null; then
		while IFS= read -r line; do
			# 格式：device|type|size_bytes|mountpoint
			local dev dev_type size_bytes mount_point size_gb
			dev=$(echo "$line" | cut -d'|' -f1)
			dev_type=$(echo "$line" | cut -d'|' -f2)
			size_bytes=$(echo "$line" | cut -d'|' -f3)
			mount_point=$(echo "$line" | cut -d'|' -f4)

			[[ -z "$dev" || "$dev" == "null" ]] && continue
			[[ "$dev_type" == "loop" || "$dev_type" == "rom" ]] && continue

			# 转换为 GB
			if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
				size_gb=$(awk "BEGIN {printf \"%d\", $size_bytes / 1024 / 1024 / 1024}")
			else
				size_gb=0
			fi

			# 存储介质类型推断
			local storage_type="Unknown"
			[[ "$dev" == nvme* ]] && storage_type="NVMe"
			local rotational
			rotational=$(safe_exec '' cat "/sys/block/${dev}/queue/rotational" 2>/dev/null)
			if [[ "$rotational" == "0" ]]; then
				[[ "$storage_type" == "Unknown" ]] && storage_type="SSD"
			elif [[ "$rotational" == "1" ]]; then
				storage_type="HDD"
			fi
			if [[ "$storage_type" == "Unknown" ]]; then
				local trans
				trans=$(safe_exec '' cat "/sys/block/${dev}/device/transport" 2>/dev/null)
				case "$trans" in
					sata*|*ata*) storage_type="SATA" ;;
				esac
			fi
			[[ "$storage_type" == "Unknown" ]] && storage_type="SSD"

			[[ -z "$mount_point" || "$mount_point" == "null" ]] && mount_point=""

			# 追加到 STORAGE_ITEMS（6 tabs 缩进）
			[[ $first -eq 0 ]] && STORAGE_ITEMS+=$',\n'
			first=0
			local item
			item=$(printf '\t\t\t\t\t\t{\n\t\t\t\t\t\t\t"device": "%s",\n\t\t\t\t\t\t\t"type": "%s",\n\t\t\t\t\t\t\t"capacityGB": %s,\n\t\t\t\t\t\t\t"mountPoint": "%s"\n\t\t\t\t\t\t}' \
				"$(json_escape "/dev/$dev")" "$(json_escape "$storage_type")" "$size_gb" "$(json_escape "$mount_point")")
			STORAGE_ITEMS+="$item"
		done < <(lsblk -b -n -P -o NAME,TYPE,SIZE,MOUNTPOINT 2>/dev/null \
			| awk -F'"' '{name=$2; type=$4; size=$6; mp=$8; print name"|"type"|"size"|"mp}')
	fi

	# 如果 lsblk 不可用，回退到 /proc/mounts + df
	if [[ $first -eq 1 ]]; then
		while IFS= read -r line; do
			local device mount_point size_bytes size_gb
			device=$(echo "$line" | awk '{print $1}')
			mount_point=$(echo "$line" | awk '{print $2}')
			[[ "$device" != /dev/* ]] && continue
			[[ "$device" == /dev/loop* ]] && continue

			size_bytes=$(df -B1 "$mount_point" 2>/dev/null | awk 'NR==2 {print $2}')
			[[ -z "$size_bytes" ]] && size_bytes=0
			size_gb=$(awk "BEGIN {printf \"%d\", $size_bytes / 1024 / 1024 / 1024}")

			[[ $first -eq 0 ]] && STORAGE_ITEMS+=$',\n'
			first=0
			local item
			item=$(printf '\t\t\t\t\t\t{\n\t\t\t\t\t\t\t"device": "%s",\n\t\t\t\t\t\t\t"type": "%s",\n\t\t\t\t\t\t\t"capacityGB": %s,\n\t\t\t\t\t\t\t"mountPoint": "%s"\n\t\t\t\t\t\t}' \
				"$(json_escape "$device")" "SSD" "$size_gb" "$(json_escape "$mount_point")")
			STORAGE_ITEMS+="$item"
		done < /proc/mounts
	fi
}

# ============================ 网络信息采集 ============================

collect_network() {
	NETWORK_ITEMS=""
	local first=1
	local max_speed=0

	# 使用 ip 命令获取网络接口
	if command -v ip &>/dev/null; then
		while IFS= read -r iface; do
			[[ -z "$iface" ]] && continue
			[[ "$iface" == "lo" ]] && continue

			local ip_addr speed
			ip_addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null \
				| awk '{print $4}' | cut -d/ -f1 | head -1)
			[[ -z "$ip_addr" ]] && continue

			speed=$(safe_exec 0 cat "/sys/class/net/$iface/speed" 2>/dev/null)
			[[ ! "$speed" =~ ^[0-9]+$ ]] && speed=0
			[[ "$speed" -gt "$max_speed" ]] && max_speed="$speed"

			# 追加到 NETWORK_ITEMS（7 tabs 缩进）
			[[ $first -eq 0 ]] && NETWORK_ITEMS+=$',\n'
			first=0
			local item
			item=$(printf '\t\t\t\t\t\t\t{\n\t\t\t\t\t\t\t\t"name": "%s",\n\t\t\t\t\t\t\t\t"speedMbps": %s,\n\t\t\t\t\t\t\t\t"ipAddress": "%s"\n\t\t\t\t\t\t\t}' \
				"$(json_escape "$iface")" "$speed" "$(json_escape "$ip_addr")")
			NETWORK_ITEMS+="$item"
		done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}')
	fi

	# 回退到 /sys/class/net
	if [[ $first -eq 1 ]]; then
		for iface in /sys/class/net/*; do
			[[ ! -d "$iface" ]] && continue
			local name
			name=$(basename "$iface")
			[[ "$name" == "lo" ]] && continue

			local ip_addr
			ip_addr=$(safe_exec '' ip -4 -o addr show dev "$name" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
			[[ -z "$ip_addr" ]] && continue

			local speed
			speed=$(safe_exec 0 cat "$iface/speed" 2>/dev/null)
			[[ ! "$speed" =~ ^[0-9]+$ ]] && speed=0

			[[ $first -eq 0 ]] && NETWORK_ITEMS+=$',\n'
			first=0
			local item
			item=$(printf '\t\t\t\t\t\t\t{\n\t\t\t\t\t\t\t\t"name": "%s",\n\t\t\t\t\t\t\t\t"speedMbps": %s,\n\t\t\t\t\t\t\t\t"ipAddress": "%s"\n\t\t\t\t\t\t\t}' \
				"$(json_escape "$name")" "$speed" "$(json_escape "$ip_addr")")
			NETWORK_ITEMS+="$item"
		done
	fi

	# 回退到 ifconfig
	if [[ $first -eq 1 ]] && command -v ifconfig &>/dev/null; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local name ip_addr
			name=$(echo "$line" | awk '{print $1}' | tr -d ':')
			[[ "$name" == "lo" || -z "$name" ]] && continue

			ip_addr=$(ifconfig "$name" 2>/dev/null \
				| awk '/inet / && $1 != "inet6" {print $2}' \
				| head -1)
			[[ -z "$ip_addr" ]] && ip_addr=$(ifconfig "$name" 2>/dev/null \
				| awk -F: '/inet / {print $2}' | awk '{print $1}' | head -1)
			[[ -z "$ip_addr" ]] && continue

			local speed=0

			[[ $first -eq 0 ]] && NETWORK_ITEMS+=$',\n'
			first=0
			local item
			item=$(printf '\t\t\t\t\t\t\t{\n\t\t\t\t\t\t\t\t"name": "%s",\n\t\t\t\t\t\t\t\t"speedMbps": %s,\n\t\t\t\t\t\t\t\t"ipAddress": "%s"\n\t\t\t\t\t\t\t}' \
				"$(json_escape "$name")" "$speed" "$(json_escape "$ip_addr")")
			NETWORK_ITEMS+="$item"
		done < <(ifconfig -a 2>/dev/null | grep -E '^[a-zA-Z]')
	fi

	NET_BANDWIDTH_MBPS="$max_speed"
	NET_LATENCY_MS="0.5"
}

# ============================ 系统信息采集 ============================

collect_system() {
	# OS 信息
	if [[ -f /etc/os-release ]]; then
		OS_NAME=$(source /etc/os-release 2>/dev/null && printf '%s' "${NAME:-Unknown}")
		OS_VERSION=$(source /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-Unknown}")
	elif command -v lsb_release &>/dev/null; then
		OS_NAME=$(lsb_release -is 2>/dev/null || printf 'Unknown')
		OS_VERSION=$(lsb_release -rs 2>/dev/null || printf 'Unknown')
	else
		OS_NAME="Unknown"
		OS_VERSION="Unknown"
	fi
	KERNEL=$(uname -r 2>/dev/null || printf 'Unknown')

	# 容器运行时检测
	CONTAINER_RUNTIME=""
	if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
		CONTAINER_RUNTIME="docker"
	elif command -v containerd &>/dev/null && containerd --version &>/dev/null 2>&1; then
		CONTAINER_RUNTIME="containerd"
	elif command -v crio &>/dev/null && crio --version &>/dev/null 2>&1; then
		CONTAINER_RUNTIME="cri-o"
	elif [[ -f /.dockerenv ]]; then
		CONTAINER_RUNTIME="docker"
	elif grep -qaE 'docker|containerd|crio' /proc/1/cgroup 2>/dev/null; then
		if [[ -f /.dockerenv ]]; then
			CONTAINER_RUNTIME="docker"
		else
			CONTAINER_RUNTIME="containerd"
		fi
	fi

	# 编排器检测
	ORCHESTRATOR=""
	if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
		ORCHESTRATOR="kubernetes"
	elif [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
		ORCHESTRATOR="kubernetes"
	elif command -v docker &>/dev/null && docker info 2>/dev/null | grep -q 'Swarm: active'; then
		ORCHESTRATOR="swarm"
	elif command -v nomad &>/dev/null; then
		ORCHESTRATOR="nomad"
	fi
}

# ============================ 模板替换输出 ============================

generate_output() {
	if [[ ! -f "$TEMPLATE" ]]; then
		echo "错误：模板文件 $TEMPLATE 不存在" >&2
		exit 1
	fi

	# 确保输出目录存在
	mkdir -p "$OUTPUT_DIR" 2>/dev/null || true

	# 读取模板内容
	local template
	template=$(cat "$TEMPLATE")

	# 替换标量占位符（字符串类型，需加引号）
	template="${template//\{\{ip\}\}/$(json_escape "$IP_ADDR")}"
	template="${template//\{\{role\}\}/$(json_escape "$ROLE")}"
	template="${template//\{\{architecture\}\}/$(json_escape "$CPU_ARCH")}"
	template="${template//\{\{memType\}\}/$(json_escape "$MEM_TYPE")}"
	template="${template//\{\{osName\}\}/$(json_escape "$OS_NAME")}"
	template="${template//\{\{osVersion\}\}/$(json_escape "$OS_VERSION")}"
	template="${template//\{\{kernel\}\}/$(json_escape "$KERNEL")}"
	template="${template//\{\{containerRuntime\}\}/$(json_escape "$CONTAINER_RUNTIME")}"
	template="${template//\{\{orchestrator\}\}/$(json_escape "$ORCHESTRATOR")}"

	# 替换标量占位符（数值类型，不加引号）
	template="${template//\{\{cores\}\}/$CPU_CORES}"
	template="${template//\{\{threadsPerCore\}\}/$CPU_THREADS_PER_CORE}"
	template="${template//\{\{frequencyMHz\}\}/$CPU_FREQ_MHZ}"
	template="${template//\{\{l1dKB\}\}/$CPU_L1D_KB}"
	template="${template//\{\{l1iKB\}\}/$CPU_L1I_KB}"
	template="${template//\{\{l2KB\}\}/$CPU_L2_KB}"
	template="${template//\{\{l3MB\}\}/$CPU_L3_MB}"
	template="${template//\{\{totalGB\}\}/$MEM_TOTAL_GB}"
	template="${template//\{\{bandwidthMbps\}\}/$NET_BANDWIDTH_MBPS}"
	template="${template//\{\{latencyMs\}\}/$NET_LATENCY_MS}"

	# 替换多行占位符（数组内容）
	template="${template//\{\{storageItems\}\}/$STORAGE_ITEMS}"
	template="${template//\{\{networkInterfaces\}\}/$NETWORK_ITEMS}"

	# 写入输出文件
	printf '%s\n' "$template" > "$OUTPUT"
	echo "已生成：$OUTPUT"
}

# ============================ 主流程 ============================

main() {
	# 解析参数
	local OVERRIDE_ROLE=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--verbose|-v)
				VERBOSE=1
				shift
				;;
			--role)
				OVERRIDE_ROLE="$2"
				shift 2
				;;
			--output-dir)
				OUTPUT_DIR="$2"
				OUTPUT="${OUTPUT_DIR}/en_info.jsonc"
				shift 2
				;;
			--help|-h)
				echo "用法: bash collect_env.sh [--verbose|-v] [--role ROLE] [--output-dir DIR]"
				echo "  --verbose, -v       打印详细采集日志"
				echo "  --role ROLE         覆盖角色检测结果 (master/slave/worker/proxy)"
				echo "  --output-dir DIR    指定输出目录 (默认: 当前工作目录)"
				echo "  --help, -h          显示帮助信息"
				exit 0
				;;
			*)
				echo "未知参数: $1 (使用 --help 查看帮助)" >&2
				exit 1
				;;
		esac
	done

	# 1. 检测环境类型
	ENV_TYPE=$(detect_env_type)
	log "环境类型：$ENV_TYPE"

	# 2. 采集 IP 和角色
	IP_ADDR=$(get_primary_ip)
	[[ -z "$IP_ADDR" ]] && IP_ADDR="127.0.0.1"

	# 优先使用 --role 覆盖，否则自动检测
	if [[ -n "$OVERRIDE_ROLE" ]]; then
		ROLE="$OVERRIDE_ROLE"
		log "角色(覆盖): $ROLE"
	else
		ROLE=$(detect_role)
		log "IP: $IP_ADDR  角色: $ROLE"
	fi

	# 3. 采集硬件信息
	collect_cpu
	log "CPU: $CPU_ARCH ${CPU_CORES}核 ${CPU_FREQ_MHZ}MHz"
	collect_memory
	log "内存: ${MEM_TOTAL_GB}GB $MEM_TYPE"
	collect_storage
	log "存储设备: $([ -n "$STORAGE_ITEMS" ] && echo '已采集' || echo '无')"
	collect_network
	log "网络接口: $([ -n "$NETWORK_ITEMS" ] && echo '已采集' || echo '无')"

	# 4. 采集系统信息
	collect_system
	log "系统: $OS_NAME $OS_VERSION  内核: $KERNEL"

	# 5. 模板替换生成输出
	generate_output
}

main "$@"
