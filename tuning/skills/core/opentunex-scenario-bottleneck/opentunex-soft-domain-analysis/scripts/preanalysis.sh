#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 soft-domain-analysis 所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 static_info.txt、kernel_config_info.txt 等文件）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-soft-domain-analysis_collect
# 说明: 本脚本仅解析已有文本文件，不执行任何采集命令

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# ============================================================
# 工具函数
# ============================================================

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# ============================================================
# 数据提取函数
# ============================================================

# 从 static_info.txt 提取: ARCH, NUMA_NODES, CPU_PER_NUMA, KERNEL_VER
extract_static_info() {
    local sfile="$1"
    local arch="x86_64"
    local numa_nodes=1
    local cpu_per_numa=0
    local kernel_ver=""

    [[ ! -f "$sfile" ]] && { echo "$arch $numa_nodes $cpu_per_numa $kernel_ver"; return; }

    # ARCH: 搜索 Architecture: 后的值
    arch=$(grep -E 'Architecture:' "$sfile" | head -1 | awk '{print $2}' | tr -d '[:space:]' || true)
    [[ -z "$arch" ]] && arch=$(grep -E 'uname -m' "$sfile" | head -1 | awk '{print $NF}' | tr -d '[:space:]' || true)
    [[ -z "$arch" ]] && arch="x86_64"

    # NUMA_NODES: 搜索 NUMA Topology 节中 node X cpus: 出现次数
    numa_nodes=$(sed -n '/^--- NUMA Topology ---$/,/^--- /p' "$sfile" | grep -cE '^node [0-9]+ cpus?:' 2>/dev/null || true)
    if ((numa_nodes == 0)); then
        # 回退: 搜索 NUMA node(s) 后的数字
        numa_nodes=$(grep -oP 'NUMA node\(s\):\s+\K\d+' "$sfile" 2>/dev/null || true)
        numa_nodes=${numa_nodes:-1}
    fi

    # CPU_PER_NUMA: 第一个 node X cpus: 的 CPU 编号个数
    local first_node_line
    first_node_line=$(sed -n '/^--- NUMA Topology ---$/,/^--- /p' "$sfile" | grep -E '^node [0-9]+ cpus?:' | head -1 2>/dev/null || true)
    if [[ -n "$first_node_line" ]]; then
        # 提取冒号后的 CPU 编号列表，统计个数
        local cpu_list
        cpu_list=$(echo "$first_node_line" | sed 's/^node [0-9]* cpus\?:\s*//')
        cpu_per_numa=$(echo "$cpu_list" | awk '{print NF}' 2>/dev/null || true)
        cpu_per_numa=${cpu_per_numa:-0}
    fi
    if ((cpu_per_numa == 0)); then
        # 回退: 用 CPU(s) / NUMA_NODES 估算
        local total_cpus
        total_cpus=$(grep -oP 'CPU\(s\):\s+\K\d+' "$sfile" 2>/dev/null || true)
        if [[ -n "$total_cpus" && "$numa_nodes" -gt 0 ]]; then
            cpu_per_numa=$((total_cpus / numa_nodes))
        fi
    fi

    # KERNEL_VER: 搜索 Kernel: 或 uname -r 输出的内核版本号
    kernel_ver=$(grep -E 'Kernel:' "$sfile" | head -1 | awk '{for(i=2;i<=NF;i++) printf "%s ",$i; print ""}' | sed 's/[[:space:]]*$//' 2>/dev/null || true)
    [[ -z "$kernel_ver" ]] && kernel_ver=$(grep -E 'uname -r' "$sfile" | head -1 | awk '{print $NF}' | tr -d '[:space:]' 2>/dev/null || true)

    echo "$arch $numa_nodes $cpu_per_numa $(json_escape "$kernel_ver")"
}

# 从 kernel_config_info.txt 提取: SOFT_DOMAIN_EXIST, SOFT_DOMAIN_ENABLED, SCHED_FEATURES_WRITABLE, DEBUGFS_MOUNTED
extract_kernel_config() {
    local kfile="$1"
    local soft_domain_exist="不存在"
    local soft_domain_enabled="未启用"
    local sched_features_writable="不可写"
    local debugfs_mounted="未挂载"

    [[ ! -f "$kfile" ]] && { echo "$soft_domain_exist $soft_domain_enabled $sched_features_writable $debugfs_mounted"; return; }

    # 提取调度特性节
    local sched_section
    sched_section=$(sed -n '/^=== 调度特性 ===$/,/^=== /p' "$kfile" 2>/dev/null || true)

    # SOFT_DOMAIN_EXIST: 搜索 SOFT_DOMAIN 关键字
    if echo "$sched_section" | grep -q 'SOFT_DOMAIN' 2>/dev/null; then
        soft_domain_exist="存在"
    fi

    # SOFT_DOMAIN_ENABLED: 存在 SOFT_DOMAIN 且不含 NO_SOFT_DOMAIN → 已启用
    if [[ "$soft_domain_exist" == "存在" ]]; then
        if echo "$sched_section" | grep -q 'NO_SOFT_DOMAIN' 2>/dev/null; then
            soft_domain_enabled="未启用"
        else
            soft_domain_enabled="已启用"
        fi
    fi

    # SCHED_FEATURES_WRITABLE: 搜索 sched_features 可写（支持中英文字段名）
    if echo "$sched_section" | grep -qiE 'sched_features.*(可写|writable|write.*ok)|sched/features.*(可写|writable|write)' 2>/dev/null; then
        sched_features_writable="可写"
    elif echo "$sched_section" | grep -q '/sys/kernel/debug/sched/features' 2>/dev/null; then
        # 如果路径存在且提到可写
        if echo "$sched_section" | grep -qiE '可写|writable|write' 2>/dev/null; then
            sched_features_writable="可写"
        fi
    elif echo "$sched_section" | grep -qiE '(^|\s)writable(\s|$)' 2>/dev/null; then
        # 兜底：采集脚本输出裸词 writable 单独一行，无 sched_features 前缀
        sched_features_writable="可写"
    fi

    # DEBUGFS_MOUNTED: 搜索 debugfs 挂载信息
    if grep -qiE 'debugfs' "$kfile" 2>/dev/null; then
        # 检查是否有明确的挂载信息
        if grep -qiE 'debugfs.*mounted|debugfs on .*/sys/kernel/debug|/sys/kernel/debug.*debugfs' "$kfile" 2>/dev/null; then
            debugfs_mounted="已挂载"
        elif grep -q '/sys/kernel/debug/sched/features' "$kfile" 2>/dev/null; then
            # 如果能访问该路径，说明 debugfs 已挂载
            debugfs_mounted="已挂载"
        fi
    fi
    # 也检查 static_info.txt 中的 mount 信息（在主流程中处理）

    echo "$soft_domain_exist $soft_domain_enabled $sched_features_writable $debugfs_mounted"
}

# 从 docker_info.txt 或 container_info.txt 提取: CONTAINER_COUNT, CONTAINER_QUOTA_LIST, SMALL_QUOTA_INSTANCES
extract_container_info() {
    local data_dir="$1"
    local cpu_per_numa="$2"

    local container_count=0
    local small_quota_instances=0
    local -a quota_entries=()

    local cfile=""
    if [[ -f "${data_dir}/docker_info.txt" ]]; then
        cfile="${data_dir}/docker_info.txt"
    elif [[ -f "${data_dir}/container_info.txt" ]]; then
        cfile="${data_dir}/container_info.txt"
    fi

    [[ -z "$cfile" ]] && { echo "$container_count $small_quota_instances"; echo "[]"; return; }

    # 统计容器数量: docker ps 输出中容器行数（排除表头 CONTAINER ID）
    container_count=$(sed -n '/^CONTAINER ID/,/^$/p' "$cfile" | grep -v '^CONTAINER ID' | grep -v '^$' | wc -l 2>/dev/null || true)
    container_count=${container_count:-0}
    if ((container_count == 0)); then
        # 回退: 统计非空非表头行
        container_count=$(grep -cE '^[a-f0-9]{12}' "$cfile" 2>/dev/null || true)
        container_count=${container_count:-0}
    fi

    # 提取每个容器的 CPU 配额
    # docker inspect 输出通常按容器分段
    local current_name=""
    local nano_cpus=""
    local cpu_quota=""
    local cpu_period=""
    local cpuset=""

    while IFS= read -r line; do
        # 容器名
        if [[ "$line" =~ \"Name\":.*\"(/[a-zA-Z0-9_.-]+)\" ]]; then
            current_name="${BASH_REMATCH[1]}"
            current_name="${current_name#/}"
        fi

        # NanoCpus
        if [[ "$line" =~ \"NanoCpus\":.*([0-9]+) ]]; then
            nano_cpus="${BASH_REMATCH[1]}"
        fi

        # CpuQuota
        if [[ "$line" =~ \"CpuQuota\":.*([0-9]+) ]]; then
            cpu_quota="${BASH_REMATCH[1]}"
        fi

        # CpuPeriod
        if [[ "$line" =~ \"CpuPeriod\":.*([0-9]+) ]]; then
            cpu_period="${BASH_REMATCH[1]}"
        fi

        # CpusetCpus
        if [[ "$line" =~ \"CpusetCpus\":.*\"([0-9,-]+)\" ]]; then
            cpuset="${BASH_REMATCH[1]}"
        fi

        # 容器结束标记（简单判断：遇到 } 且有 name）
        if [[ "$line" == *"}"* ]] && [[ -n "$current_name" ]]; then
            local quota_cpus="null"

            if [[ -n "$nano_cpus" && "$nano_cpus" != "0" ]]; then
                # NanoCpus → quota_cpus = NanoCpus / 1e9
                quota_cpus=$(awk "BEGIN {printf \"%.2f\", ${nano_cpus}/1e9}")
            elif [[ -n "$cpu_quota" && -n "$cpu_period" && "$cpu_period" != "0" ]]; then
                # CpuQuota/CpuPeriod → quota_cpus = CpuQuota / CpuPeriod
                quota_cpus=$(awk "BEGIN {printf \"%.2f\", ${cpu_quota}/${cpu_period}}")
            elif [[ -n "$cpuset" ]]; then
                # cpuset → 统计 CPU 数
                quota_cpus=$(count_cpuset "$cpuset")
            fi

            if [[ "$quota_cpus" != "null" ]]; then
                local is_small=false
                if (( $(awk "BEGIN {print ($quota_cpus <= $cpu_per_numa) ? 1 : 0}") )); then
                    is_small=true
                    ((small_quota_instances++))
                fi
                quota_entries+=("{\"name\":\"$(json_escape "$current_name")\",\"quota_cpus\":$quota_cpus,\"is_small\":$is_small}")
            fi

            # 重置
            current_name=""
            nano_cpus=""
            cpu_quota=""
            cpu_period=""
            cpuset=""
        fi
    done < "$cfile"

    # 兜底：如果 JSON 解析无结果，尝试 cgroup key=value 格式（cpu.cfs_quota_us = 800000）
    if ((${#quota_entries[@]} == 0)) && grep -q 'cpu\.cfs_quota_us' "$cfile" 2>/dev/null; then
        parse_container_cgroup "$cfile" "$cpu_per_numa"
        return
    fi

    # 输出: container_count small_quota_instances
    echo "$container_count $small_quota_instances"

    # 输出: quota_entries JSON 数组
    local quota_json="["
    local first=1
    for entry in "${quota_entries[@]}"; do
        ((first)) && first=0 || quota_json+=","
        quota_json+="$entry"
    done
    quota_json+="]"
    echo "$quota_json"
}

# 解析 cgroup v1 key=value 格式的容器信息（json 解析的兜底方案）
# 格式示例:
#   docker-16df4e3...  cpu.cfs_quota_us = 800000
#   docker-abc123...   cpu.cfs_quota_us = -1
# -1 表示无配额限制（unlimited），不纳入配额统计
parse_container_cgroup() {
    local cfile="$1"
    local cpu_per_numa="$2"

    local container_count=0
    local small_quota_instances=0
    local -a quota_entries=()

    while IFS= read -r line; do
        if [[ "$line" =~ cpu\.cfs_quota_us[[:space:]]*=[[:space:]]*(-?[0-9]+) ]]; then
            local quota="${BASH_REMATCH[1]}"
            # 从行首提取容器名（cpu.cfs_quota_us 之前的部分）
            local name="${line%%cpu.cfs_quota_us*}"
            name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -z "$name" ]]; then
                continue
            fi

            ((container_count++))

            if [[ "$quota" != "-1" ]]; then
                local quota_cpus
                quota_cpus=$(awk "BEGIN {printf \"%.2f\", ${quota}/100000}")
                local is_small=false
                if (( $(awk "BEGIN {print ($quota_cpus <= $cpu_per_numa) ? 1 : 0}") )); then
                    is_small=true
                    ((small_quota_instances++))
                fi
                quota_entries+=("{\"name\":\"$(json_escape "$name")\",\"quota_cpus\":$quota_cpus,\"is_small\":$is_small}")
            fi
        fi
    done < "$cfile"

    echo "$container_count $small_quota_instances"

    local quota_json="["
    local first=1
    for entry in "${quota_entries[@]}"; do
        ((first)) && first=0 || quota_json+=","
        quota_json+="$entry"
    done
    quota_json+="]"
    echo "$quota_json"
}

# 统计 cpuset 字符串中的 CPU 数量（如 "0-3,5,7-9" → 7）
count_cpuset() {
    local cpuset="$1"
    local count=0
    local IFS=','
    local part
    for part in $cpuset; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            count=$((count + BASH_REMATCH[2] - BASH_REMATCH[1] + 1))
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            ((count++))
        fi
    done
    echo "$count"
}

# 从 top_processes.txt 或 process_info.txt 提取: TARGET_PID, TARGET_CPUS_ALLOWED, TARGET_CPU_AFFINITY_SPAN
extract_process_info() {
    local data_dir="$1"
    local numa_cpu_map_json="$2"
    local target_pid="null"
    local target_cpus_allowed="null"
    local target_cpu_affinity_span=1

    local pfile=""
    if [[ -f "${data_dir}/top_processes.txt" ]]; then
        pfile="${data_dir}/top_processes.txt"
    elif [[ -f "${data_dir}/process_info.txt" ]]; then
        pfile="${data_dir}/process_info.txt"
    fi

    [[ -z "$pfile" ]] && { echo "$target_pid $target_cpus_allowed $target_cpu_affinity_span"; return; }

    # 搜索目标进程的 Cpus_allowed_list
    # 格式通常为: PID: <pid> ... Cpus_allowed_list: <list>
    local pid_line cpus_line
    while IFS= read -r line; do
        if [[ "$line" =~ PID:\ *([0-9]+) ]]; then
            target_pid="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ Cpus_allowed_list:\ *(.+) ]]; then
            target_cpus_allowed=$(echo "${BASH_REMATCH[1]}" | sed 's/[[:space:]]*$//')
        fi
    done < <(grep -E 'PID:|Cpus_allowed_list:' "$pfile" | head -20 2>/dev/null || true)

    # 如果没找到 Cpus_allowed_list，尝试其他格式
    if [[ "$target_cpus_allowed" == "null" ]]; then
        target_cpus_allowed=$(grep -oP 'Cpus_allowed_list:\s*\K[0-9,-]+' "$pfile" | head -1 2>/dev/null || true)
        [[ -z "$target_cpus_allowed" ]] && target_cpus_allowed="null"
    fi

    # 如果没找到 PID，尝试其他格式
    if [[ "$target_pid" == "null" ]]; then
        target_pid=$(grep -oP 'PID:\s*\K[0-9]+' "$pfile" | head -1 2>/dev/null || true)
        [[ -z "$target_pid" ]] && target_pid="null"
    fi

    # 计算 TARGET_CPU_AFFINITY_SPAN: 统计 Cpus_allowed_list 跨越的 NUMA 节点数
    if [[ "$target_cpus_allowed" != "null" && -n "$target_cpus_allowed" ]]; then
        target_cpu_affinity_span=$(count_numa_span "$target_cpus_allowed" "$numa_cpu_map_json")
    fi

    echo "$target_pid $(json_escape "$target_cpus_allowed") $target_cpu_affinity_span"
}

# 统计 CPU 列表跨越的 NUMA 节点数
count_numa_span() {
    local cpus_allowed="$1"
    local numa_map_json="$2"
    local span=1

    # 解析 cpus_allowed 列表（如 "0-3,5,7-9"）为 CPU 编号集合
    local -A cpu_set=()
    local IFS=','
    local part
    for part in $cpus_allowed; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            for ((i=start; i<=end; i++)); do
                cpu_set[$i]=1
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            cpu_set[$part]=1
        fi
    done

    # 从 numa_cpu_map_json 中查找每个 CPU 属于哪个 NUMA 节点
    # numa_map_json 格式: {"node0": [0,1,2,3], "node1": [4,5,6,7]}
    local -A numa_hit=()
    local node_name cpu_str
    # 用简单文本解析提取 node 和 CPU 列表
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        # pair 格式: "node0": [0, 1, 2, 3]
        node_name=$(echo "$pair" | grep -oP '"node[0-9]+"' | tr -d '"' || true)
        [[ -z "$node_name" ]] && continue
        # 提取 CPU 编号列表
        local node_cpus_str
        node_cpus_str=$(echo "$pair" | grep -oP '\[[\d\s,]+\]' | tr -d '[]' || true)
        [[ -z "$node_cpus_str" ]] && continue

        IFS=',' read -ra node_cpus <<< "$node_cpus_str"
        for cpu_str in "${node_cpus[@]}"; do
            cpu_str=$(echo "$cpu_str" | tr -d '[:space:]')
            [[ -z "$cpu_str" ]] && continue
            if [[ -n "${cpu_set[$cpu_str]+x}" ]]; then
                numa_hit["$node_name"]=1
            fi
        done
    done < <(echo "$numa_map_json" | grep -oP '"node[0-9]+":\s*\[[\d\s,]+\]')

    span=${#numa_hit[@]}
    ((span < 1)) && span=1
    echo "$span"
}

# 补充检查 debugfs 挂载状态（从 static_info.txt 的 mount 信息中）
check_debugfs_from_static() {
    local sfile="$1"
    [[ ! -f "$sfile" ]] && { echo "未挂载"; return; }

    # 搜索 mount 信息中的 debugfs
    if grep -qiE 'debugfs on /sys/kernel/debug|type debugfs' "$sfile" 2>/dev/null; then
        echo "已挂载"
    else
        echo "未挂载"
    fi
}

# 从 static_info.txt 提取 NUMA CPU 映射（JSON 格式）
extract_numa_cpu_map() {
    local sfile="$1"
    local cpu_map="{}"

    [[ ! -f "$sfile" ]] && { echo "$cpu_map"; return; }

    local -a node_mappings=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^node\ ([0-9]+)\ cpus?:\ (.+)$ ]]; then
            local node_id="${BASH_REMATCH[1]}"
            local cpu_list="${BASH_REMATCH[2]}"
            cpu_list=$(echo "$cpu_list" | tr '\n' ' ')
            local cpus_json
            cpus_json=$(echo "$cpu_list" | tr ' ' '\n' | grep -v '^$' | sed 's/^/"/;s/$/"/' | paste -sd ',' -)
            node_mappings+=("\"node${node_id}\": [${cpus_json}]")
        fi
    done < <(sed -n '/^--- NUMA Topology ---$/,/^--- /p' "$sfile")

    if ((${#node_mappings[@]} > 0)); then
        cpu_map="{"
        local first=1
        for m in "${node_mappings[@]}"; do
            ((first)) && first=0 || cpu_map+=", "
            cpu_map+="$m"
        done
        cpu_map+="}"
    fi

    echo "$cpu_map"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-soft-domain-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    local SFILE="${DATA_DIR}/static_info.txt"
    local KFILE="${DATA_DIR}/kernel_config_info.txt"

    # ---- 从 static_info.txt 提取 ----
    local arch numa_nodes cpu_per_numa kernel_ver
    read -r arch numa_nodes cpu_per_numa kernel_ver <<< "$(extract_static_info "$SFILE")"

    # NUMA CPU 映射（供进程亲和分析使用）
    local numa_cpu_map
    numa_cpu_map=$(extract_numa_cpu_map "$SFILE")

    # ---- 从 kernel_config_info.txt 提取 ----
    local soft_domain_exist soft_domain_enabled sched_features_writable debugfs_mounted
    read -r soft_domain_exist soft_domain_enabled sched_features_writable debugfs_mounted <<< "$(extract_kernel_config "$KFILE")"

    # 补充 debugfs 挂载检查（从 static_info.txt）
    if [[ "$debugfs_mounted" == "未挂载" ]]; then
        debugfs_mounted=$(check_debugfs_from_static "$SFILE")
    fi

    # ---- 从 docker_info.txt / container_info.txt 提取 ----
    local container_count small_quota_instances quota_list_json
    {
        read -r container_count small_quota_instances
        read -r quota_list_json
    } <<< "$(extract_container_info "$DATA_DIR" "$cpu_per_numa")"

    # ---- 从 top_processes.txt / process_info.txt 提取 ----
    local target_pid target_cpus_allowed target_cpu_affinity_span
    read -r target_pid target_cpus_allowed target_cpu_affinity_span <<< "$(extract_process_info "$DATA_DIR" "$numa_cpu_map")"

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "arch": "$(json_escape "$arch")",
  "numa_nodes": ${numa_nodes},
  "cpu_per_numa": ${cpu_per_numa},
  "kernel_ver": "$(json_escape "$kernel_ver")",
  "soft_domain_exist": "$(json_escape "$soft_domain_exist")",
  "soft_domain_enabled": "$(json_escape "$soft_domain_enabled")",
  "sched_features_writable": "$(json_escape "$sched_features_writable")",
  "debugfs_mounted": "$(json_escape "$debugfs_mounted")",
  "container_count": ${container_count},
  "small_quota_instances": ${small_quota_instances},
  "container_quota_list": ${quota_list_json},
  "target_pid": ${target_pid},
  "target_cpus_allowed": "$(json_escape "$target_cpus_allowed")",
  "target_cpu_affinity_span": ${target_cpu_affinity_span},
  "numa_cpu_map": ${numa_cpu_map}
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"
