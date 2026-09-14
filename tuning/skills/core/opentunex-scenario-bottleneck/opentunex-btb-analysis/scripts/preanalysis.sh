#!/usr/bin/env bash
# preanalysis.sh - 从已有采集数据文件提取 BTB/TidCMP 分析所需关键字段，生成 preanalysis.json
# 用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]
#   DATA_DIR:   采集批次目录（含 static_info.txt、top_processes.txt 等文件）
#   OUTPUT_DIR: JSON 输出目录，默认 ${DATA_DIR}/opentunex-btb-analysis_collect
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

# 从 static_info.txt 提取: IS_KUNPENG, PART_ID, IS_920_NEW_MODEL
# IS_KUNPENG: lscpu 输出含 "Kunpeng" 关键字（鲲鹏必为 ARM，无需单独判断 ARCH）
# IS_920_NEW_MODEL: dmidecode -t processor 输出的 ID 字段，若以 "20 D0" 开头则为 920 新型号
extract_cpu_info() {
    local data_dir="$1"
    local is_kunpeng=false
    local part_id=""
    local is_920_new_model=false

    local sfile=""
    if [[ -f "${data_dir}/static_info.txt" ]]; then
        sfile="${data_dir}/static_info.txt"
    elif [[ -f "${data_dir}/cpu_info.txt" ]]; then
        sfile="${data_dir}/cpu_info.txt"
    fi

    if [[ -z "$sfile" ]]; then
        echo "$is_kunpeng $(json_escape "$part_id") $is_920_new_model"
        return
    fi

    # IS_KUNPENG: 从 lscpu 输出中检测 "Kunpeng" 关键字（位于 "Model name:" 行）
    if grep -qiE 'Kunpeng' "$sfile" 2>/dev/null; then
        is_kunpeng=true
    fi

    # PART_ID: 从 dmidecode -t processor 输出中提取 ID 字段
    # dmidecode 输出格式: "ID: 20 D0 1F 49 00 00 00 00"
    part_id=$(grep -iE '^\s*ID:' "$sfile" | head -1 | sed 's/^[[:space:]]*ID:[[:space:]]*//I' | sed 's/[[:space:]]*$//' || true)

    # IS_920_NEW_MODEL: dmidecode processor ID 以 "20 D0" 开头即为 920 新型号
    if [[ -n "$part_id" ]] && echo "$part_id" | grep -qiE '^20[[:space:]]+D0'; then
        is_920_new_model=true
    fi

    echo "$is_kunpeng $(json_escape "$part_id") $is_920_new_model"
}

# 从 top_processes.txt 或 process_info.txt 提取: REDIS_RUNNING, MYSQL_RUNNING
extract_process_info() {
    local data_dir="$1"
    local redis_running=false
    local mysql_running=false

    local pfile=""
    if [[ -f "${data_dir}/top_processes.txt" ]]; then
        pfile="${data_dir}/top_processes.txt"
    elif [[ -f "${data_dir}/process_info.txt" ]]; then
        pfile="${data_dir}/process_info.txt"
    fi

    if [[ -z "$pfile" ]]; then
        echo "$redis_running $mysql_running"
        return
    fi

    # 搜索 redis-server 进程
    if grep -qi 'redis-server' "$pfile" 2>/dev/null; then
        redis_running=true
    fi

    # 搜索 mysqld 进程（排除 mysqld_safe 等辅助进程）
    if grep -qiE 'mysqld\b|mariadbd' "$pfile" 2>/dev/null; then
        mysql_running=true
    fi

    echo "$redis_running $mysql_running"
}

# ============================================================
# 主流程
# ============================================================

main() {
    local DATA_DIR="${1:-}"
    local OUTPUT_DIR="${2:-${DATA_DIR}/opentunex-btb-analysis_collect}"

    [[ -z "$DATA_DIR" ]] && die "用法: bash preanalysis.sh <DATA_DIR> [OUTPUT_DIR]"
    [[ -d "$DATA_DIR" ]] || die "DATA_DIR 不存在: $DATA_DIR"

    mkdir -p "$OUTPUT_DIR"
    local JSON_FILE="${OUTPUT_DIR}/preanalysis.json"

    # ---- 从 static_info.txt / cpu_info.txt 提取 CPU 信息 ----
    local is_kunpeng part_id is_920_new_model
    read -r is_kunpeng part_id is_920_new_model <<< "$(extract_cpu_info "$DATA_DIR")"

    # ---- 从 top_processes.txt / process_info.txt 提取关键进程 ----
    local redis_running mysql_running
    read -r redis_running mysql_running <<< "$(extract_process_info "$DATA_DIR")"

    # ---- 构建 JSON ----
    cat > "$JSON_FILE" <<EOF
{
  "is_kunpeng": ${is_kunpeng},
  "part_id": "$part_id",
  "is_920_new_model": ${is_920_new_model},
  "redis_running": ${redis_running},
  "mysql_running": ${mysql_running}
}
EOF

    echo "preanalysis.json 已生成: $JSON_FILE ($(wc -c < "$JSON_FILE") bytes)"
}

main "$@"