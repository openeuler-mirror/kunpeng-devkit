#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 numa-sched-analysis 所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 pmu_info.txt 等文件）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-numa-sched-analysis_collect
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

# 从 pmu_info.txt 提取 HHA 数据
extract_pmu_info() {
    local pfile="$1"
    local hha_available=false
    local ops_per_sec=0
    local remote_ratio=0
    local pmu_path_applicable=false

    [[ ! -f "$pfile" ]] && { echo "$hha_available $ops_per_sec $remote_ratio $pmu_path_applicable"; return; }

    # 提取 ops_per_sec（不依赖 /sys/devices/hha* 路径，各平台路径不同）
    local ops_line
    ops_line=$(grep -oP 'ops_per_sec=\K[0-9]+' "$pfile" 2>/dev/null | head -1 || true)
    if [[ -n "$ops_line" ]]; then
        ops_per_sec=$ops_line
    fi

    # 提取 remote_ratio
    local ratio_line
    ratio_line=$(grep -oP 'remote_ratio=\K[0-9.]+' "$pfile" 2>/dev/null | head -1 || true)
    if [[ -n "$ratio_line" ]]; then
        remote_ratio=$ratio_line
    fi

    # HHA 可用判定：以 ops_per_sec > 0 为准（不依赖设备路径字符串）
    if (( ops_per_sec > 0 )); then
        hha_available=true
        pmu_path_applicable=true
    fi

    echo "$hha_available $ops_per_sec $remote_ratio $pmu_path_applicable"
}

# 从 memory_metrics_analysis.txt 提取 vmstat/numastat 数据
extract_vmstat_info() {
    local mfile="$1"
    local numa_hit=0
    local numa_miss=0
    local numa_foreign=0
    local remote_access_ratio=0

    [[ ! -f "$mfile" ]] && { echo "$numa_hit $numa_miss $numa_foreign $remote_access_ratio"; return; }

    # 搜索 NUMA Statistics 节
    local numa_section
    numa_section=$(sed -n '/=== NUMA Statistics ===/,/^=== /p' "$mfile" 2>/dev/null || true)
    # 也尝试 --- NUMA Statistics --- 定界符
    if [[ -z "$numa_section" ]]; then
        numa_section=$(sed -n '/--- NUMA Statistics ---/,/^--- /p' "$mfile" 2>/dev/null || true)
    fi
    # 回退：搜索整个文件中 numastat 相关行
    if [[ -z "$numa_section" ]]; then
        numa_section=$(grep -E 'numa_hit|numa_miss|numa_foreign' "$mfile" 2>/dev/null || true)
    fi

    if [[ -n "$numa_section" ]]; then
        numa_hit=$(echo "$numa_section" | grep -oP 'numa_hit\s+\K[0-9]+' | head -1 || echo "0")
        numa_miss=$(echo "$numa_section" | grep -oP 'numa_miss\s+\K[0-9]+' | head -1 || echo "0")
        numa_foreign=$(echo "$numa_section" | grep -oP 'numa_foreign\s+\K[0-9]+' | head -1 || echo "0")
    fi

    # 计算 REMOTE_ACCESS_RATIO = NUMA_MISS / (NUMA_HIT + NUMA_MISS) × 100
    local total=$((numa_hit + numa_miss))
    if ((total > 0)); then
        remote_access_ratio=$(awk "BEGIN {printf \"%.2f\", ${numa_miss}/${total}*100}")
    fi

    echo "$numa_hit $numa_miss $numa_foreign $remote_access_ratio"
}

# 从 static_info.txt 提取 NUMA 节点数
extract_numa_nodes() {
    local sfile="$1"
    local nodes=1

    [[ ! -f "$sfile" ]] && { echo "$nodes"; return; }

    # 仅匹配 "node X cpus:" 行，排除 "node X size:" / "node X free:"
    nodes=$(sed -n '/^--- NUMA Topology ---$/,/^--- /p' "$sfile" | grep -cE '^node [0-9]+ cpus?:' 2>/dev/null || true)
    if ((nodes == 0)); then
        nodes=$(grep -oP 'available:\s+\K\d+' "$sfile" 2>/dev/null || true)
        nodes=${nodes:-1}
    fi
    echo "$nodes"
}

# 从 kernel_config_info.txt 提取 PARAL 信息
extract_paral_info() {
    local kfile="$1"
    local paral_support="不支持"
    local paral_enabled="未启用"
    local sched_util_low_pct="null"

    [[ ! -f "$kfile" ]] && { echo "$paral_support $paral_enabled $sched_util_low_pct"; return; }

    # 提取调度特性节
    local sched_section
    sched_section=$(sed -n '/=== 调度特性 ===/,/^=== /p' "$kfile" 2>/dev/null || true)

    # PARAL 支持检测
    if echo "$sched_section" | grep -q "PARAL: present" 2>/dev/null; then
        paral_support="支持"
        paral_enabled="已启用"
    elif echo "$sched_section" | grep -q "PARAL" 2>/dev/null; then
        paral_support="支持"
        # 检查是否含 NO_PARAL
        if echo "$sched_section" | grep -q "NO_PARAL" 2>/dev/null; then
            paral_enabled="未启用"
        elif echo "$sched_section" | grep -q "PARAL" 2>/dev/null; then
            # 含 PARAL 但不含 NO_PARAL → 已启用
            paral_enabled="已启用"
        fi
    fi

    # SCHED_UTIL_LOW_PCT 提取
    # 格式：在"特殊调度参数"节中，sched_util_ratio 行后紧跟一行
    local special_section
    special_section=$(sed -n '/=== 特殊调度参数 ===/,/^=== /p' "$kfile" 2>/dev/null || true)
    if [[ -n "$special_section" ]]; then
        if echo "$special_section" | grep -q "not exist\|not set\|无法获取" 2>/dev/null; then
            sched_util_low_pct="null"
        else
            # 尝试提取数字
            local pct_val
            pct_val=$(echo "$special_section" | grep -oP 'sched_util_low_pct[=:]\s*\K[0-9]+' 2>/dev/null | head -1 || true)
            if [[ -z "$pct_val" ]]; then
                # 尝试 sched_util_ratio 相邻行
                pct_val=$(echo "$special_section" | grep -A1 'sched_util_ratio' | tail -1 | grep -oP '^\s*\K[0-9]+' | head -1 || true)
            fi
            if [[ -n "$pct_val" ]]; then
                sched_util_low_pct="$pct_val"
            fi
        fi
    fi

    echo "$paral_support $paral_enabled $sched_util_low_pct"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-numa-sched-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    local PFILE="${DATA_DIR}/pmu_info.txt"
    local MFILE="${DATA_DIR}/memory_metrics_analysis.txt"
    local SFILE="${DATA_DIR}/static_info.txt"
    local KFILE="${DATA_DIR}/kernel_config_info.txt"

    # ---- PMU HHA 数据 ----
    local hha_available ops_per_sec remote_ratio pmu_path_applicable
    read -r hha_available ops_per_sec remote_ratio pmu_path_applicable <<< "$(extract_pmu_info "$PFILE")"

    # ---- vmstat/numastat 数据 ----
    local numa_hit numa_miss numa_foreign remote_access_ratio
    read -r numa_hit numa_miss numa_foreign remote_access_ratio <<< "$(extract_vmstat_info "$MFILE")"

    # ---- NUMA 节点数 ----
    local numa_nodes
    numa_nodes=$(extract_numa_nodes "$SFILE")

    # ---- PARAL 信息 ----
    local paral_support paral_enabled sched_util_low_pct
    read -r paral_support paral_enabled sched_util_low_pct <<< "$(extract_paral_info "$KFILE")"

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "hha_available": $hha_available,
  "ops_per_sec": ${ops_per_sec},
  "remote_ratio": ${remote_ratio},
  "pmu_path_applicable": $pmu_path_applicable,
  "numa_hit": ${numa_hit},
  "numa_miss": ${numa_miss},
  "numa_foreign": ${numa_foreign},
  "remote_access_ratio": ${remote_access_ratio},
  "numa_nodes": ${numa_nodes},
  "paral_support": "$(json_escape "$paral_support")",
  "paral_enabled": "$(json_escape "$paral_enabled")",
  "sched_util_low_pct": $sched_util_low_pct
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"
