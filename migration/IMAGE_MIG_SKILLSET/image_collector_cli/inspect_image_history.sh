#!/usr/bin/env bash
# =============================================================================
# inspect_image_history.sh
# 批量导出 `docker history --no-trunc` 的完整层信息
#
# 三种运行模式：
#   1. 无参数         → 自动扫描所有本地镜像
#   2. 参数是文本文件  → 从文件逐行读取镜像名（# 开头为注释）
#   3. 参数是镜像名   → 单镜像
#
# 用法：
#   bash inspect_image_history.sh
#   bash inspect_image_history.sh images.txt
#   bash inspect_image_history.sh python:3.11-slim
#
# 可选环境变量：
#   OUTPUT_DIR   输出目录，默认 image_history_out
#   PARALLEL     并发数，默认 8
#   FILTER       镜像名过滤关键词（grep 正则），仅自动扫描模式生效
#
# 输出结构：
#   <OUTPUT_DIR>/
#     ├── summary.json        # 所有镜像汇总（JSON Array）
#     └── images/
#         ├── repo_image_tag.json   # 每个镜像单独 JSON
#         └── ...
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 参数 & 环境变量
# --------------------------------------------------------------------------
ARG="${1:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
MAX_PARALLEL="${PARALLEL:-8}"
FILTER="${FILTER:-}"

# --------------------------------------------------------------------------
# 日志
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RESET='\033[0m'
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_err()  { echo -e "${RED}[ERR]${RESET}   $*" >&2; }

# --------------------------------------------------------------------------
# 检查 docker
# --------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    log_err "未找到 docker，请先安装"
    exit 1
fi

# --------------------------------------------------------------------------
# 镜像名 → 安全文件名
# --------------------------------------------------------------------------
safe_filename() {
    printf '%s' "$1" | sed 's|[:/\\ ]|_|g'
}

# --------------------------------------------------------------------------
# 核心：对单个镜像执行 docker history --no-trunc，输出一个 JSON 对象
# --------------------------------------------------------------------------
inspect_one() {
    local image="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)

    # 用 {{json .}} 逐行输出每层的 JSON 对象（所有 Docker 版本均支持）
    local raw="" ec=0
    raw=$(docker history --no-trunc --format '{{json .}}' "$image" 2>/dev/null) || ec=$?

    if [[ $ec -ne 0 ]] || [[ -z "$raw" ]]; then
        printf '{"meta":{"source_image":"%s","collected_at":"%s","status":"error","error":"docker history failed"}}\n' \
            "$image" "$ts"
        return
    fi

    python3 -c "
import sys, json
image = sys.argv[1]; ts = sys.argv[2]
raw = sys.stdin.read().strip()
layers = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        layers.append(json.loads(line))
    except Exception as e:
        layers.append({'parse_error': str(e), 'raw': line})
result = {
    'meta': {
        'source_image': image,
        'collected_at': ts,
        'status': 'ok',
        'collector': 'inspect_image_history.sh',
        'layer_count': len(layers),
    },
    'history': layers,
}
print(json.dumps(result, ensure_ascii=False))
" "$image" "$ts" <<< "$raw"
}

export -f inspect_one

# --------------------------------------------------------------------------
# 确定镜像列表
# --------------------------------------------------------------------------
declare -a IMAGES=()

if [[ -z "$ARG" ]]; then
    log_info "未指定输入，扫描所有本地镜像..."
    mapfile -t IMAGES < <(
        docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep -v '<none>' | sort -u
    )
    if [[ -n "$FILTER" ]]; then
        mapfile -t IMAGES < <(printf '%s\n' "${IMAGES[@]}" | grep -E "$FILTER" || true)
        log_info "过滤关键词 '$FILTER' 命中 ${#IMAGES[@]} 个"
    fi
    [[ ${#IMAGES[@]} -eq 0 ]] && { log_err "本地没有任何镜像"; exit 1; }
    : "${OUTPUT_DIR:=image_history_out}"

elif [[ -f "$ARG" ]]; then
    log_info "从文件读取镜像列表: $ARG"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line// /}"
        [[ -z "$line" ]] && continue
        IMAGES+=("$line")
    done < "$ARG"
    [[ ${#IMAGES[@]} -eq 0 ]] && { log_err "文件中没有有效镜像名: $ARG"; exit 1; }
    : "${OUTPUT_DIR:=image_history_out}"

else
    if ! docker image inspect "$ARG" &>/dev/null 2>&1; then
        log_err "镜像不存在: $ARG"
        exit 1
    fi
    IMAGES=("$ARG")
    : "${OUTPUT_DIR:=image_history_out}"
fi

TOTAL=${#IMAGES[@]}
log_info "共 $TOTAL 个镜像，并发度: $MAX_PARALLEL"

# --------------------------------------------------------------------------
# 创建输出目录结构
# --------------------------------------------------------------------------
IMAGES_SUBDIR="${OUTPUT_DIR}/images"
mkdir -p "$IMAGES_SUBDIR"
log_info "输出目录: $OUTPUT_DIR"
log_info "  汇总文件:   ${OUTPUT_DIR}/summary.json"
log_info "  单镜像目录: ${IMAGES_SUBDIR}/"

# --------------------------------------------------------------------------
# 并发执行
# --------------------------------------------------------------------------
declare -a PIDS=() TMPFILES=()
ALL_RESULTS_FILE=$(mktemp)

cleanup() {
    log_warn "中断，清理中..."
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    for f in "${TMPFILES[@]:-}"; do rm -f "$f"; done
    rm -f "$ALL_RESULTS_FILE"
    exit 130
}
trap cleanup INT TERM
trap 'rm -f "$ALL_RESULTS_FILE"' EXIT

flush_head() {
    local head_tf="${TMPFILES[0]}"
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
    TMPFILES=("${TMPFILES[@]:1}")
    if [[ -s "$head_tf" ]]; then
        local json_line
        json_line=$(cat "$head_tf")
        echo "$json_line" >> "$ALL_RESULTS_FILE"
        local img_name safe_name
        img_name=$(python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('meta',{}).get('source_image','unknown'))" <<< "$json_line" 2>/dev/null || echo "unknown")
        safe_name=$(safe_filename "$img_name")
        python3 -m json.tool <<< "$json_line" > "${IMAGES_SUBDIR}/${safe_name}.json" 2>/dev/null \
            || echo "$json_line" > "${IMAGES_SUBDIR}/${safe_name}.json"
    fi
    rm -f "$head_tf"
}

for i in "${!IMAGES[@]}"; do
    img="${IMAGES[$i]}"
    tf=$(mktemp)
    TMPFILES+=("$tf")
    (
        log_info "[$(( i+1 ))/$TOTAL] $img"
        inspect_one "$img" > "$tf"
        log_ok  "[$(( i+1 ))/$TOTAL] done: $img"
    ) &
    PIDS+=($!)
    if (( ${#PIDS[@]} >= MAX_PARALLEL )); then
        flush_head
    fi
done

while (( ${#PIDS[@]} > 0 )); do
    flush_head
done

# --------------------------------------------------------------------------
# 生成汇总 summary.json
# --------------------------------------------------------------------------
SUMMARY_FILE="${OUTPUT_DIR}/summary.json"
python3 - "$ALL_RESULTS_FILE" "$SUMMARY_FILE" << 'PYEOF'
import sys, json
src, dst = sys.argv[1], sys.argv[2]
records = []
with open(src) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception as e:
            records.append({"parse_error": str(e), "raw": line[:500]})
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(records, f, ensure_ascii=False, indent=2)
PYEOF

rm -f "$ALL_RESULTS_FILE"

# --------------------------------------------------------------------------
# 摘要
# --------------------------------------------------------------------------
total_singles=$(ls "${IMAGES_SUBDIR}"/*.json 2>/dev/null | wc -l | tr -d ' ')
log_ok "===== 完成 ====="
log_ok "  共处理: $TOTAL 个镜像"
log_ok "  单镜像: $total_singles 个 -> ${IMAGES_SUBDIR}/"
log_ok "  汇总:   $SUMMARY_FILE"
