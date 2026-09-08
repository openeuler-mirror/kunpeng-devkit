#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 stealtask-analysis 所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 kernel_config_info.txt 等文件）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-stealtask-analysis_collect
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

# 从 kernel_config_info.txt 提取 STEAL 相关信息
extract_steal_info() {
    local kfile="$1"
    local config_sched_steal="未启用"
    local steal_support="不支持"
    local steal_enabled="未启用"
    local cmdline_steal_node_limit="未配置"

    [[ ! -f "$kfile" ]] && { echo "$config_sched_steal $steal_support $steal_enabled $cmdline_steal_node_limit"; return; }

    # CONFIG_SCHED_STEAL: 搜索 CONFIG_SCHED_STEAL=y
    if grep -q "CONFIG_SCHED_STEAL=y" "$kfile" 2>/dev/null; then
        config_sched_steal="已启用"
    fi

    # STEAL_SUPPORT: 搜索 STEAL 关键字
    if grep -qE '\bSTEAL\b|NO_STEAL' "$kfile" 2>/dev/null; then
        steal_support="支持"
    fi

    # STEAL_ENABLED: sched_features 中含 STEAL 且无 NO_STEAL
    local sched_section
    sched_section=$(sed -n '/=== 调度特性 ===/,/^=== /p' "$kfile" 2>/dev/null || true)
    if echo "$sched_section" | grep -q "STEAL" 2>/dev/null; then
        if ! echo "$sched_section" | grep -q "NO_STEAL" 2>/dev/null; then
            steal_enabled="已启用"
        fi
    fi

    # CMDLINE_STEAL_NODE_LIMIT: 搜索 sched_steal_node_limit:
    if grep -q 'sched_steal_node_limit:\s*yes' "$kfile" 2>/dev/null; then
        cmdline_steal_node_limit="已配置"
    fi

    # STEAL_VERSION: 通过 sched_max_steal_count 判断内核版本
    # 能正常输出值 → 旧版本；报错 "unknown key" → 新版本
    local steal_version="未知"
    if grep -qE 'sched_max_steal_count.*error|sched_max_steal_count.*unknown key|sched_max_steal_count.*不允许' "$kfile" 2>/dev/null; then
        steal_version="新版本"
    elif grep -qE 'sched_max_steal_count[=:]\s*[0-9]+' "$kfile" 2>/dev/null; then
        steal_version="旧版本"
    fi

    echo "$config_sched_steal $steal_support $steal_enabled $cmdline_steal_node_limit $steal_version"
}

# 从 global_bottleneck.txt 或 cpu_detail_info.txt 提取 CPU 指标
extract_cpu_metrics() {
    local data_dir="$1"
    local cpu_usage=0
    local cpu_imbalance=0
    local cs_rate=0

    local gfile="${data_dir}/global_bottleneck.txt"
    local cfile="${data_dir}/cpu_detail_info.txt"

    local cpu_source=""
    if [[ -f "$gfile" ]]; then
        cpu_source="$gfile"
    elif [[ -f "$cfile" ]]; then
        cpu_source="$cfile"
    fi

    [[ -z "$cpu_source" ]] && { echo "$cpu_usage $cpu_imbalance $cs_rate"; return; }

    # ---- CPU_USAGE ----
    # 优先从 mpstat "Average: all" 行: 100 - idle%
    local avg_line
    avg_line=$(grep -E '^Average:\s+all' "$cpu_source" 2>/dev/null | head -1 || true)
    if [[ -z "$avg_line" ]]; then
        avg_line=$(grep -E '^平均:\s+all' "$cpu_source" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$avg_line" ]]; then
        # mpstat 列: CPU %usr %nice %sys %iowait %irq %soft %steal %guest %gnice %idle
        # Average: all xxx xxx xxx xxx xxx xxx xxx xxx xxx xx.xx
        local idle
        idle=$(echo "$avg_line" | awk '{print $NF}' 2>/dev/null || true)
        if [[ -n "$idle" ]]; then
            cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100 - $idle}")
        fi
    fi

    # 回退：从 /proc/stat cpu 行计算
    if [[ "$cpu_usage" == "0" || -z $(echo "$cpu_usage" | tr -d '0.') ]]; then
        local proc_stat_section
        # 用 awk 状态跟踪跳过 === SAMPLE 块（sed 的 /^=== / 终止模式会误匹配 SAMPLE 标题行）
        proc_stat_section=$(awk '
            /\/proc\/stat.*多采样/            { in_section=1; next }
            in_section && /^=== / && !/^=== SAMPLE/ { exit }
            in_section                        { print }
        ' "$cpu_source" 2>/dev/null || true)
        if [[ -z "$proc_stat_section" ]]; then
            proc_stat_section=$(awk '
                /\/proc\/stat/                { in_section=1; next }
                in_section && /^=== / && !/^=== SAMPLE/ { exit }
                in_section                    { print }
            ' "$cpu_source" 2>/dev/null || true)
        fi
        if [[ -n "$proc_stat_section" ]]; then
            # 取两次采样的 cpu 行差值
            local -a cpu_samples
            while IFS= read -r line; do
                if [[ "$line" =~ ^cpu\  ]]; then
                    cpu_samples+=("$line")
                fi
            done <<< "$proc_stat_section"
            if ((${#cpu_samples[@]} >= 2)); then
                local s1=(${cpu_samples[-2]})
                local s2=(${cpu_samples[-1]})
                local delta_total=0 delta_idle=0
                local i
                for ((i=1; i<${#s1[@]}; i++)); do
                    local d=$(( ${s2[$i]:-0} - ${s1[$i]:-0} ))
                    ((delta_total += d))
                    ((i == 4)) && delta_idle=$d  # idle 是第 4 列
                done
                if ((delta_total > 0)); then
                    cpu_usage=$(awk "BEGIN {printf \"%.2f\", ($delta_total - $delta_idle) / $delta_total * 100}")
                fi
            fi
        fi
    fi

    # ---- CPU_IMBALANCE ----
    # 从各核心 Average 行计算 max - min
    # 仅匹配 "Average: <数字>" 的数据行（排除 "Average: all" 和注释/标题行）
    local -a core_usage=()
    while IFS= read -r line; do
        local core_id
        core_id=$(echo "$line" | awk '{print $2}')
        # 仅处理以 Average: 开头且第二列为纯数字的核级数据行
        [[ "$core_id" =~ ^[0-9]+$ ]] || continue
        local core_idle
        core_idle=$(echo "$line" | awk '{print $NF}')
        if [[ -n "$core_idle" && "$core_idle" =~ ^[0-9.]+$ ]]; then
            local core_use
            core_use=$(awk "BEGIN {printf \"%.2f\", 100 - $core_idle}")
            core_usage+=("$core_use")
        fi
    done < <(grep -E '^Average:[[:space:]]+[0-9]+' "$cpu_source" 2>/dev/null || true)

    if ((${#core_usage[@]} >= 2)); then
        local max_use=0 min_use=100
        for u in "${core_usage[@]}"; do
            if (( $(awk "BEGIN {print ($u > $max_use) ? 1 : 0}") )); then
                max_use=$u
            fi
            if (( $(awk "BEGIN {print ($u < $min_use) ? 1 : 0}") )); then
                min_use=$u
            fi
        done
        cpu_imbalance=$(awk "BEGIN {printf \"%.2f\", $max_use - $min_use}")
    fi

    # ---- CS_RATE ----
    # vmstat cs 列平均值
    local vmstat_section
    # 优先匹配明确的 vmstat 节标题
    vmstat_section=$(sed -n '/=== vmstat ===/,/^=== /p' "$cpu_source" 2>/dev/null || true)
    if [[ -z "$vmstat_section" ]]; then
        vmstat_section=$(sed -n '/^--- vmstat ---/,/^--- /p' "$cpu_source" 2>/dev/null || true)
    fi
    if [[ -z "$vmstat_section" ]]; then
        # 最后回退：匹配所有看起来像 vmstat 数据行的行（r b swpd free buff cache ... cs ...）
        vmstat_section=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$cpu_source" 2>/dev/null || true)
    fi
    if [[ -n "$vmstat_section" ]]; then
        local cs_sum=0 cs_cnt=0
        while IFS= read -r line; do
            # 跳过标题/注释行（非数据行）
            [[ "$line" =~ ^[[:space:]]*[0-9] ]] || continue
            local fields=($line)
            # vmstat 列顺序: r b swpd free buff cache si so bi bo in cs us sy id wa st
            # cs 是第 12 列（0-indexed: 11）
            local cs_val=0
            if ((${#fields[@]} >= 12)); then
                cs_val=${fields[11]}
            fi
            if [[ "$cs_val" =~ ^[0-9]+$ ]] && (( cs_val > 0 )); then
                cs_sum=$((cs_sum + cs_val))
                ((cs_cnt++))
            fi
        done <<< "$vmstat_section"
        if ((cs_cnt > 0)); then
            cs_rate=$((cs_sum / cs_cnt))
        fi
    fi

    echo "$cpu_usage $cpu_imbalance $cs_rate"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-stealtask-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    local KFILE="${DATA_DIR}/kernel_config_info.txt"

    # ---- STEAL 信息 ----
    local config_sched_steal steal_support steal_enabled cmdline_steal_node_limit steal_version
    read -r config_sched_steal steal_support steal_enabled cmdline_steal_node_limit steal_version <<< "$(extract_steal_info "$KFILE")"

    # ---- CPU 指标 ----
    local cpu_usage cpu_imbalance cs_rate
    read -r cpu_usage cpu_imbalance cs_rate <<< "$(extract_cpu_metrics "$DATA_DIR")"

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "config_sched_steal": "$(json_escape "$config_sched_steal")",
  "steal_support": "$(json_escape "$steal_support")",
  "steal_enabled": "$(json_escape "$steal_enabled")",
  "cmdline_steal_node_limit": "$(json_escape "$cmdline_steal_node_limit")",
  "steal_version": "$(json_escape "$steal_version")",
  "cpu_usage": ${cpu_usage:-0},
  "cpu_imbalance": ${cpu_imbalance:-0},
  "cs_rate": ${cs_rate:-0}
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"
