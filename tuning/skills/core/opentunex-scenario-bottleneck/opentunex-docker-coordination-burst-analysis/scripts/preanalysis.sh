#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 docker-coordination-burst-analysis 所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 cpu_detail_info.txt、kernel_config_info.txt、container_info.txt）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-docker-coordination-burst-analysis_collect
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

# 从 cpu_detail_info.txt 提取 HOST_CPU_UTIL 和 HOST_NCPUS
extract_host_cpu_info() {
    local cfile="$1"
    local host_cpu_util=0
    local host_ncpus=1

    [[ ! -f "$cfile" ]] && { echo "$host_cpu_util $host_ncpus"; return; }

    # ---- HOST_CPU_UTIL: 从 /proc/stat 多采样节计算 ----
    # 用 awk 状态跟踪跳过 === SAMPLE 块（sed 的 /^=== / 终止模式会误匹配 SAMPLE 标题行）
    local proc_stat_section
    proc_stat_section=$(awk '
        /\/proc\/stat.*多采样/            { in_section=1; next }
        in_section && /^=== / && !/^=== SAMPLE/ { exit }
        in_section                        { print }
    ' "$cfile" 2>/dev/null || true)
    if [[ -z "$proc_stat_section" ]]; then
        proc_stat_section=$(awk '
            /\/proc\/stat/                { in_section=1; next }
            in_section && /^=== / && !/^=== SAMPLE/ { exit }
            in_section                    { print }
        ' "$cfile" 2>/dev/null || true)
    fi

    if [[ -n "$proc_stat_section" ]]; then
        local -a utilizations=()
        local -a cpu_lines=()
        while IFS= read -r line; do
            if [[ "$line" =~ ^cpu\  ]]; then
                cpu_lines+=("$line")
            fi
        done <<< "$proc_stat_section"

        local i
        for ((i=1; i<${#cpu_lines[@]}; i++)); do
            local prev=(${cpu_lines[$((i-1))]})
            local curr=(${cpu_lines[$i]})
            local delta_total=0 delta_idle=0
            local j
            for ((j=1; j<8; j++)); do
                local d=$(( ${curr[$j]:-0} - ${prev[$j]:-0} ))
                ((delta_total += d))
                ((j == 4 || j == 5)) && ((delta_idle += d))
            done
            if ((delta_total > 0)); then
                local util
                util=$(awk "BEGIN {printf \"%.2f\", ($delta_total - $delta_idle) / $delta_total * 100}")
                utilizations+=("$util")
            fi
        done

        if ((${#utilizations[@]} > 0)); then
            local sum=0
            for u in "${utilizations[@]}"; do
                sum=$(awk "BEGIN {print $sum + $u}")
            done
            host_cpu_util=$(awk "BEGIN {printf \"%.2f\", $sum / ${#utilizations[@]}}")
        fi
    fi

    # 回退：从 mpstat Average: all 行
    if [[ "$host_cpu_util" == "0" || -z $(echo "$host_cpu_util" | tr -d '0.') ]]; then
        local avg_line
        avg_line=$(grep -E '^Average:\s+all' "$cfile" 2>/dev/null | head -1 || true)
        if [[ -n "$avg_line" ]]; then
            local idle
            idle=$(echo "$avg_line" | awk '{print $NF}')
            if [[ -n "$idle" ]]; then
                host_cpu_util=$(awk "BEGIN {printf \"%.2f\", 100 - $idle}")
            fi
        fi
    fi

    # ---- HOST_NCPUS ----
    local ncpu_line
    ncpu_line=$(grep -oP '在线CPU数量.*?\K[0-9]+' "$cfile" 2>/dev/null | head -1 || true)
    if [[ -z "$ncpu_line" ]]; then
        ncpu_line=$(grep -oP 'processor.*数量.*?\K[0-9]+' "$cfile" 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$ncpu_line" ]]; then
        ncpu_line=$(grep -oP 'CPU\(s\):\s+\K[0-9]+' "$cfile" 2>/dev/null | head -1 || true)
    fi
    host_ncpus=${ncpu_line:-1}

    echo "$host_cpu_util $host_ncpus"
}

# 从 kernel_config_info.txt 提取 BURST_SUPPORT
extract_burst_support() {
    local kfile="$1"
    local burst_support="不支持"

    [[ ! -f "$kfile" ]] && { echo "$burst_support"; return; }

    if grep -q 'Docker CPU Burst:\s*yes' "$kfile" 2>/dev/null; then
        burst_support="支持"
    elif grep -q 'sched_soft_runtime_ratio' "$kfile" 2>/dev/null; then
        if ! grep -q 'sched_soft_runtime_ratio.*not exist' "$kfile" 2>/dev/null; then
            burst_support="支持"
        fi
    fi

    echo "$burst_support"
}

# 从 container_info.txt 提取容器数据并计算使用率
extract_container_info() {
    local cfile="$1"
    local host_ncpus="$2"

    # 返回: container_count JSON
    local container_count=0
    local -a container_json_entries=()

    [[ ! -f "$cfile" ]] && { echo "$container_count"; echo "[]"; return; }

    # 解析 SAMPLE 块
    # 策略：按 === SAMPLE 分割，收集每个采样中的容器数据
    # 然后用首尾采样计算使用率

    local -A first_sample_data  # id -> "cpuacct_usage timestamp cfs_period_us cfs_quota_us soft_quota"
    local -A last_sample_data
    local first_ts=0 last_ts=0
    local in_container=false
    local current_id="" current_cfs_period="" current_cfs_quota="" current_usage="" current_soft_quota="" current_ts=""
    local sample_ts=0

    local -A all_container_ids=()

    while IFS= read -r line; do
        # 检测采样时间戳
        if [[ "$line" =~ ^===\ TIMESTAMP\ ([0-9.]+) ]]; then
            sample_ts="${BASH_REMATCH[1]}"
            # awk 浮点比较（bash (( )) 不支持小数）
            if (( $(awk "BEGIN {print ($sample_ts > 0 && $first_ts == 0) ? 1 : 0}") )); then
                first_ts=$sample_ts
            fi
            last_ts=$sample_ts
            continue
        fi

        # 容器块开始
        if [[ "$line" == "--- CONTAINER ---" ]]; then
            in_container=true
            current_id=""; current_cfs_period=""; current_cfs_quota=""
            current_usage=""; current_soft_quota=""; current_ts=""
            continue
        fi

        # 容器块结束
        if [[ "$line" == "--- END CONTAINER ---" ]]; then
            in_container=false
            if [[ -n "$current_id" ]]; then
                all_container_ids["$current_id"]=1
                # 始终记录到最后一次采样
                if grep -q '^c5b51' <<< "$current_id" 2>/dev/null; then
                    : # skip
                fi
                last_sample_data["${current_id}"]="${current_usage} ${current_ts} ${current_cfs_period} ${current_cfs_quota} ${current_soft_quota}"
                # 首次采样也记录
                if [[ -z "${first_sample_data[$current_id]}" ]]; then
                    first_sample_data["${current_id}"]="${current_usage} ${current_ts} ${current_cfs_period} ${current_cfs_quota} ${current_soft_quota}"
                fi
            fi
            continue
        fi

        # 解析容器字段
        if $in_container; then
            if [[ "$line" =~ ^id=(.+) ]]; then
                current_id="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^cfs_period_us=(.+) ]]; then
                current_cfs_period="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^cfs_quota_us=(.+) ]]; then
                current_cfs_quota="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^cpuacct_usage=(.+) ]]; then
                current_usage="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^soft_quota=(.+) ]]; then
                current_soft_quota="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^timestamp=(.+) ]]; then
                current_ts="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$cfile"

    container_count=${#all_container_ids[@]}

    # 2. 按 host_ncpus * cfs_period_us 回退
    local host_ncpus_float
    if [[ -z "$host_ncpus" || "$host_ncpus" == "0" ]]; then
        host_ncpus_float=1
    else
        host_ncpus_float=$host_ncpus
    fi

    # 计算每个容器的使用率
    for cid in "${!all_container_ids[@]}"; do
        local first_data="${first_sample_data[$cid]}"
        local last_data="${last_sample_data[$cid]}"

        [[ -z "$first_data" || -z "$last_data" ]] && continue

        read -r f_usage f_ts f_period f_quota f_soft <<< "$first_data"
        read -r l_usage l_ts l_period l_quota l_soft <<< "$last_data"

        # 计算时间间隔（纳秒）
        local interval_ns=0
        if [[ -n "$f_ts" && -n "$l_ts" ]]; then
            interval_ns=$(awk "BEGIN {printf \"%.0f\", ($l_ts - $f_ts) * 1e9}")
        fi

        # CPU 限制
        local cpu_limit=$host_ncpus_float
        if [[ -n "$l_quota" && "$l_quota" != "-1" && "$l_quota" != "0" && -n "$l_period" && "$l_period" != "0" ]]; then
            cpu_limit=$(awk "BEGIN {printf \"%.4f\", $l_quota / $l_period}")
        fi

        # 实际用量差值（纳秒）
        local delta_usage=0
        if [[ -n "$f_usage" && -n "$l_usage" ]]; then
            delta_usage=$(awk "BEGIN {printf \"%.0f\", $l_usage - $f_usage}")
        fi

        # 使用率 = delta_usage / (cpu_limit * interval_ns) * 100
        local usage=0
        if (( $(awk "BEGIN {print ($interval_ns > 0 && $cpu_limit > 0) ? 1 : 0}") )); then
            usage=$(awk "BEGIN {printf \"%.2f\", $delta_usage / ($cpu_limit * $interval_ns) * 100}")
        fi

        # 短 ID（前12位）
        local short_id="${cid:0:12}"

        local soft_label="未启用"
        [[ "$l_soft" == "1" ]] && soft_label="已启用"

        # 分类
        local classification="低负载"
        if (( $(awk "BEGIN {print ($usage > 95) ? 1 : 0}") )); then
            if [[ "$l_soft" == "1" ]]; then
                classification="已启用 burst"
            else
                classification="建议对象"
            fi
        fi

        container_json_entries+=("{\"id\":\"$(json_escape "$short_id")\",\"full_id\":\"$(json_escape "$cid")\",\"cpu_usage\":$usage,\"cpu_limit\":$cpu_limit,\"soft_quota\":\"$soft_label\",\"classification\":\"$classification\"}")
    done

    echo "$container_count"

    # 构建容器 JSON 数组
    local containers_json="["
    local first=1
    for entry in "${container_json_entries[@]}"; do
        ((first)) && first=0 || containers_json+=","
        containers_json+="$entry"
    done
    containers_json+="]"
    echo "$containers_json"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-docker-coordination-burst-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    local CFILE="${DATA_DIR}/cpu_detail_info.txt"
    local KFILE="${DATA_DIR}/kernel_config_info.txt"
    local CNTFILE="${DATA_DIR}/container_info.txt"

    # ---- 宿主机 CPU 信息 ----
    local host_cpu_util host_ncpus
    read -r host_cpu_util host_ncpus <<< "$(extract_host_cpu_info "$CFILE")"

    # ---- Burst 支持 ----
    local burst_support
    burst_support=$(extract_burst_support "$KFILE")

    # ---- 容器信息 ----
    local container_count containers_json
    {
        read -r container_count
        read -r containers_json
    } <<< "$(extract_container_info "$CNTFILE" "$host_ncpus")"

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "host_cpu_util": ${host_cpu_util:-0},
  "host_ncpus": ${host_ncpus:-1},
  "burst_support": "$(json_escape "$burst_support")",
  "container_count": ${container_count:-0},
  "containers": ${containers_json:-[]}
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"
