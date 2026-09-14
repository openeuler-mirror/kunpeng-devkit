#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 dynamic-smt-analysis 所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 cpu_detail_info.txt、kernel_config_info.txt）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-dynamic-smt-analysis_collect
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

# 从 cpu_detail_info.txt 提取 CPU_USAGE 和 SMT_ACTIVE
extract_cpu_info() {
    local cfile="$1"
    local cpu_usage=0
    local smt_active="未知"

    [[ ! -f "$cfile" ]] && { echo "$cpu_usage $smt_active"; return; }

    # ---- CPU_USAGE: 从 /proc/stat 多采样节计算 ----
    # 用 awk 状态跟踪跳过 === SAMPLE 块（sed 的 /^=== / 终止模式会误匹配 SAMPLE 标题行）
    local proc_stat_section
    proc_stat_section=$(awk '
        /\/proc\/stat.*多采样/             { in_section=1; next }
        in_section && /^=== / && !/^=== SAMPLE/ { exit }
        in_section                         { print }
    ' "$cfile" 2>/dev/null || true)
    if [[ -z "$proc_stat_section" ]]; then
        proc_stat_section=$(awk '
            /^===.*\/proc\/stat/           { in_section=1; next }
            in_section && /^=== / && !/^=== SAMPLE/ { exit }
            in_section                     { print }
        ' "$cfile" 2>/dev/null || true)
    fi
    if [[ -z "$proc_stat_section" ]]; then
        proc_stat_section=$(awk '
            /^---.*\/proc\/stat/           { in_section=1; next }
            in_section && /^--- / && !/^--- SAMPLE/ { exit }
            in_section                     { print }
        ' "$cfile" 2>/dev/null || true)
    fi
    if [[ -z "$proc_stat_section" ]]; then
        proc_stat_section=$(sed -n '/\/proc\/stat/,/^$/p' "$cfile" 2>/dev/null || true)
    fi

    if [[ -n "$proc_stat_section" ]]; then
        local -a cpu_utilizations=()
        local -a cpu_lines=()
        while IFS= read -r line; do
            if [[ "$line" =~ ^cpu\  ]]; then
                cpu_lines+=("$line")
            fi
        done <<< "$proc_stat_section"

        # 相邻两两采样计算利用率
        local i
        for ((i=1; i<${#cpu_lines[@]}; i++)); do
            local prev=(${cpu_lines[$((i-1))]})
            local curr=(${cpu_lines[$i]})
            local delta_total=0 delta_idle=0
            local j
            for ((j=1; j<8; j++)); do
                local d=$(( ${curr[$j]:-0} - ${prev[$j]:-0} ))
                ((delta_total += d))
                # idle=第4列(索引4), iowait=第5列(索引5)
                ((j == 4 || j == 5)) && ((delta_idle += d))
            done
            if ((delta_total > 0)); then
                local util
                util=$(awk "BEGIN {printf \"%.2f\", ($delta_total - $delta_idle) / $delta_total * 100}")
                cpu_utilizations+=("$util")
            fi
        done

        if ((${#cpu_utilizations[@]} > 0)); then
            local sum=0
            for u in "${cpu_utilizations[@]}"; do
                sum=$(awk "BEGIN {print $sum + $u}")
            done
            cpu_usage=$(awk "BEGIN {printf \"%.2f\", $sum / ${#cpu_utilizations[@]}}")
        fi
    fi

    # 回退：从 mpstat Average: all 行
    if [[ "$cpu_usage" == "0" || -z $(echo "$cpu_usage" | tr -d '0.') ]]; then
        local avg_line
        avg_line=$(grep -E '^Average:\s+all' "$cfile" 2>/dev/null | head -1 || true)
        if [[ -n "$avg_line" ]]; then
            local idle
            idle=$(echo "$avg_line" | awk '{print $NF}')
            if [[ -n "$idle" ]]; then
                cpu_usage=$(awk "BEGIN {printf \"%.2f\", 100 - $idle}")
            fi
        fi
    fi

    # ---- SMT_ACTIVE ----
    local smt_line
    smt_line=$(grep -E 'SMT active:' "$cfile" 2>/dev/null | head -1 || true)
    if [[ -n "$smt_line" ]]; then
        if echo "$smt_line" | grep -qE ':\s*1'; then
            smt_active="已启用"
        elif echo "$smt_line" | grep -qE ':\s*0'; then
            smt_active="未启用"
        fi
    fi

    echo "$cpu_usage $smt_active"
}

# 从 kernel_config_info.txt 提取 SCHED_SUPPORT (KEEP_ON_CORE)
extract_sched_info() {
    local kfile="$1"
    local sched_support="未知"

    [[ ! -f "$kfile" ]] && { echo "$sched_support"; return; }

    local sched_section
    sched_section=$(sed -n '/=== 调度特性 ===/,/^=== /p' "$kfile" 2>/dev/null || true)

    # 先检查 NOT present（否则 KEEP_ON_CORE.*present 会误匹配 "NOT present"）
    if echo "$sched_section" | grep -qE 'KEEP_ON_CORE.*NOT present' 2>/dev/null; then
        sched_support="不支持"
    elif echo "$sched_section" | grep -qE 'KEEP_ON_CORE.*present' 2>/dev/null; then
        sched_support="支持"
    elif echo "$sched_section" | grep -q 'NO_KEEP_ON_CORE' 2>/dev/null; then
        sched_support="支持"
    elif echo "$sched_section" | grep -q 'KEEP_ON_CORE' 2>/dev/null; then
        sched_support="支持"
    fi

    echo "$sched_support"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-dynamic-smt-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    local CFILE="${DATA_DIR}/cpu_detail_info.txt"
    local KFILE="${DATA_DIR}/kernel_config_info.txt"

    # ---- CPU 信息 ----
    local cpu_usage smt_active
    read -r cpu_usage smt_active <<< "$(extract_cpu_info "$CFILE")"

    # ---- 调度特性 ----
    local sched_support
    sched_support=$(extract_sched_info "$KFILE")

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "cpu_usage": ${cpu_usage:-0},
  "smt_active": "$(json_escape "$smt_active")",
  "sched_support": "$(json_escape "$sched_support")"
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"
