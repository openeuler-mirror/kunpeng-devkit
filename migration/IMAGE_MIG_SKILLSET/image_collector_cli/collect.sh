#!/usr/bin/env bash
# =============================================================================
# collect.sh  —  镜像信息采集入口（不需要 pull 镜像）
#
# 用法：
#   bash collect.sh -h
#
# 采集基础镜像：
#   bash collect.sh --mode base --image  registry/foo:v1  --output ./out
#   bash collect.sh --mode base --list   base_images.txt  --output ./out
#
# 采集业务镜像并与基础镜像 diff：
#   bash collect.sh --mode biz  --list   biz_images.txt   --output ./out_biz \
#                   --base-output ./out_base
#
# 参数：
#   --mode   base|biz      必填。base=基础镜像, biz=业务镜像
#   --image  <image:tag>   与 --list 二选一
#   --list   <txt文件>     每行一个镜像，# 开头为注释
#   --output <目录>        输出根目录，默认 ./collector_out
#   --base-output <目录>   biz 模式：指定已有基础镜像结果目录（用于 diff）
#   --workers <N>          并发数，默认 4
#
# 输出（每个镜像一个子目录）：
#   <output>/<image_name>/
#     manifest.json        镜像 manifest（架构/OS/ENV/CMD/layers）
#     history.json         构建历史（每层 RUN/COPY 命令）
#     layer.json           容器内环境成分（x86 only，ARM 自动跳过）
#     diff.json            与基础镜像的 diff（仅 biz 模式）
#   <output>/_collect_summary.json
#   <output>.tar.gz
# =============================================================================

set -euo pipefail

# ── 颜色日志 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }
step()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}" >&2; }

# ── 默认值 ────────────────────────────────────────────────────────────────────
MODE=""
IMAGE_ARG=""
LIST_ARG=""
OUTPUT_DIR="./collector_out"
BASE_OUTPUT=""
WORKERS=4
TIMEOUT=300
NO_LAYER=0

# ── 解析参数 ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)         MODE="$2";         shift 2 ;;
        --image)        IMAGE_ARG="$2";    shift 2 ;;
        --list)         LIST_ARG="$2";     shift 2 ;;
        --output)       OUTPUT_DIR="$2";   shift 2 ;;
        --base-output)  BASE_OUTPUT="$2";  shift 2 ;;
        --workers)      WORKERS="$2";      shift 2 ;;
        --timeout)      TIMEOUT="$2";      shift 2 ;;
        -h|--help)
            awk '/^# =/{found++; next} found==1 && /^#/{sub(/^# ?/,""); print} found==2{exit}' "$0"
            exit 0 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# ── 校验 ─────────────────────────────────────────────────────────────────────
[[ -z "$MODE" ]] && { err "--mode 必填 (base | biz)"; exit 1; }
[[ "$MODE" != "base" && "$MODE" != "biz" ]] && { err "--mode 只能是 base 或 biz"; exit 1; }
[[ -z "$IMAGE_ARG" && -z "$LIST_ARG" ]] && { err "必须指定 --image 或 --list"; exit 1; }
[[ -n "$IMAGE_ARG" && -n "$LIST_ARG" ]] && { err "--image 与 --list 不能同时使用"; exit 1; }
[[ -n "$LIST_ARG" && ! -f "$LIST_ARG" ]] && { err "文件不存在: $LIST_ARG"; exit 1; }

# ── 定位辅助脚本 ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_find_script() {
    local name="$1"
    # 只在同目录查找（所有脚本均随 image_collector 打包在同一目录）
    [[ -f "$SCRIPT_DIR/$name" ]] && { echo "$SCRIPT_DIR/$name"; return; }
    echo ""
}

ENV_SCRIPT="$(_find_script inspect_image_env.sh)"
HIST_SCRIPT="$(_find_script inspect_image_history.sh)"
ANALYZE_SCRIPT="$SCRIPT_DIR/analyze.py"

[[ -f "$ANALYZE_SCRIPT" ]] || { err "找不到 analyze.py: $ANALYZE_SCRIPT"; exit 1; }

# ── 检测架构，决定是否跳过 layer 采集 ────────────────────────────────────────
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    warn "检测到 ARM 架构 ($ARCH)，自动跳过 layer 采集"
    NO_LAYER=1
fi

if [[ $NO_LAYER -eq 0 && -z "$ENV_SCRIPT" ]]; then
    warn "找不到 inspect_image_env.sh，将跳过 layer 采集"
    NO_LAYER=1
fi
if [[ -z "$HIST_SCRIPT" ]]; then
    warn "找不到 inspect_image_history.sh，将跳过 history 采集"
    HIST_SCRIPT=""
fi

# ── 构建镜像列表 ──────────────────────────────────────────────────────────────
declare -a IMAGES=()
declare -A _SEEN_IMAGES=()   # 用于去重

_add_image() {
    local img="$1"
    if [[ -n "${_SEEN_IMAGES[$img]+_}" ]]; then
        warn "重复镜像已跳过: $img"
        return
    fi
    _SEEN_IMAGES[$img]=1
    IMAGES+=("$img")
}

if [[ -n "$IMAGE_ARG" ]]; then
    _add_image "$IMAGE_ARG"
else
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        _add_image "$line"
    done < "$LIST_ARG"
    [[ ${#IMAGES[@]} -eq 0 ]] && { err "列表文件中没有有效镜像: $LIST_ARG"; exit 1; }
fi

TOTAL=${#IMAGES[@]}
info "mode=$MODE  镜像数=$TOTAL  workers=$WORKERS  timeout=${TIMEOUT}s"
info "layer采集=$([ $NO_LAYER -eq 1 ] && echo 跳过 || echo 开启)"
[[ -n "$BASE_OUTPUT" ]] && info "基础镜像结果目录: $BASE_OUTPUT"

# ── 创建输出目录 ──────────────────────────────────────────────────────────────
OUT_ROOT="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
START_TS=$(date +%s)

# ── safe_name ─────────────────────────────────────────────────────────────────
safe_name() { printf '%s' "$1" | sed 's|[:/\\ ]|_|g'; }

# ── 采集单个镜像 ──────────────────────────────────────────────────────────────
collect_one() {
    local image="$1"
    local sname
    sname=$(safe_name "$image")
    local img_dir="$OUT_ROOT/$sname"
    mkdir -p "$img_dir"

    local got_layer=0 got_hist=0 got_manifest=0

    # ── 0. 若镜像不在本地且需要 layer 采集，则先 pull ────────────────────────
    local pulled_here=0
    if [[ $NO_LAYER -eq 0 ]]; then
        if ! docker image inspect "$image" &>/dev/null 2>&1; then
            info "[$image] 本地不存在，开始 pull..."
            if docker pull "$image" >/dev/null 2>&1; then
                pulled_here=1
                info "[$image] pull 完成"
            else
                warn "[$image] pull 失败，将跳过 layer 采集"
            fi
        fi
    fi

    # ── 1. layer（环境成分）──────────────────────────────────────────────────
    if [[ $NO_LAYER -eq 0 ]]; then
        local layer_tmp
        layer_tmp=$(mktemp /tmp/layer_XXXXXX)
        if OUTPUT_DIR="$img_dir/_layer_tmp" TIMEOUT="$TIMEOUT" \
              bash "$ENV_SCRIPT" "$image" >/dev/null 2>&1; then
            local found
            found=$(find "$img_dir/_layer_tmp/images" -name "*.json" 2>/dev/null | head -1)
            if [[ -n "$found" ]]; then
                cp "$found" "$img_dir/layer.json"
                got_layer=1
            fi
        fi
        rm -rf "$img_dir/_layer_tmp"
        rm -f "$layer_tmp"
        [[ $got_layer -eq 0 ]] && warn "[$image] layer 采集失败或无输出，已跳过"
    else
        info "[$image] 跳过 layer 采集"
    fi

    # ── 2 & 3. manifest + history（不需要 pull，直接从 registry 获取）─────────
    #
    # 策略（按优先级，均不需要 pull）：
    #   A. docker buildx imagetools inspect --format '{{json .}}'
    #      → 包含完整 manifest + history + config，复用 Docker 认证，推荐首选
    #   B. skopeo inspect docker://<image>
    #      → 备选，含 history（LayersData）
    #   C. docker manifest inspect <image>
    #      → 只有 manifest，无 history
    #   D. docker image inspect <image>（本地兜底，需已 pull）
    #
    local bx_raw=""
    bx_raw=$(docker buildx imagetools inspect --format '{{json .}}' "$image" 2>/dev/null) || bx_raw=""

    if [[ -n "$bx_raw" ]]; then
        # ── A. buildx imagetools 成功：同时产出 manifest.json 和 history.json ──
        # 先写临时文件避免 pipe+heredoc stdin 冲突
        local bx_tmp
        bx_tmp=$(mktemp /tmp/bx_XXXXXX)
        echo "$bx_raw" > "$bx_tmp"
        python3 - "$image" "$img_dir/manifest.json" "$img_dir/history.json" "$bx_tmp" << 'PYEOF'
import sys, json, datetime
image, manifest_path, history_path, data_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
with open(data_file) as f:
    d = json.load(f)

mf      = d.get('manifest', {})    # 仅含 mediaType/digest/size（manifest list 条目）
img     = d.get('image', {})
cfg     = img.get('config', {})
rootfs  = img.get('rootfs', {})

manifest = {
    'meta': {'source_image': image, 'collected_at': ts, 'collector': 'docker_buildx_imagetools'},
    'name':           d.get('name', ''),
    'manifest_digest': mf.get('digest', ''),
    'media_type':     mf.get('mediaType', ''),
    'layers':         rootfs.get('diff_ids', []),   # layer diff_ids（uncompressed sha256）
    'created':        img.get('created', ''),
    'architecture':   img.get('architecture', ''),
    'os':             img.get('os', ''),
    'env':            cfg.get('Env', []),
    'cmd':            cfg.get('Cmd', []),
    'entrypoint':     cfg.get('Entrypoint', []),
    'workdir':        cfg.get('WorkingDir', ''),
    'labels':         cfg.get('Labels', {}),
    'rootfs':         rootfs,
}
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)

raw_hist = img.get('history', [])
history = {
    'meta': {'source_image': image, 'collected_at': ts, 'collector': 'docker_buildx_imagetools', 'layer_count': len(raw_hist)},
    'history': raw_hist,
    'layers':  rootfs.get('diff_ids', []),
}
with open(history_path, 'w') as f:
    json.dump(history, f, ensure_ascii=False, indent=2)
PYEOF
        local py_ec=$?
        rm -f "$bx_tmp"
        if [[ $py_ec -eq 0 ]]; then
            got_manifest=1
            got_hist=1
        else
            warn "[$image] buildx imagetools 数据解析失败"
        fi
    else
        # ── B. skopeo 备选 ────────────────────────────────────────────────────
        local skopeo_raw=""
        if command -v skopeo &>/dev/null; then
            skopeo_raw=$(skopeo inspect "docker://$image" 2>/dev/null) || skopeo_raw=""
        fi

        if [[ -n "$skopeo_raw" ]]; then
            local sk_tmp
            sk_tmp=$(mktemp /tmp/sk_XXXXXX)
            echo "$skopeo_raw" > "$sk_tmp"
            python3 - "$image" "$img_dir/manifest.json" "$img_dir/history.json" "$sk_tmp" << 'PYEOF'
import sys, json, datetime
image, manifest_path, history_path, data_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
with open(data_file) as f:
    d = json.load(f)
manifest = {
    'meta': {'source_image': image, 'collected_at': ts, 'collector': 'skopeo_inspect'},
    'name': d.get('Name',''), 'digest': d.get('Digest',''), 'repo_tags': d.get('RepoTags',[]),
    'created': d.get('Created',''), 'architecture': d.get('Architecture',''), 'os': d.get('Os',''),
    'layers': d.get('Layers',[]), 'env': d.get('Env',[]), 'cmd': d.get('Cmd',[]),
    'entrypoint': d.get('Entrypoint',[]), 'workdir': d.get('WorkDir',''), 'labels': d.get('Labels',{}),
}
with open(manifest_path, 'w') as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
layers_data = d.get('LayersData', [])
history = {
    'meta': {'source_image': image, 'collected_at': ts, 'collector': 'skopeo_inspect', 'layer_count': len(layers_data)},
    'history': layers_data, 'layers': d.get('Layers', []),
}
with open(history_path, 'w') as f:
    json.dump(history, f, ensure_ascii=False, indent=2)
PYEOF
            local sk_ec=$?
            rm -f "$sk_tmp"
            [[ $sk_ec -eq 0 ]] && got_manifest=1 && got_hist=1
        else
            # ── C. docker manifest inspect（无 history）───────────────────────
            local dm_raw=""
            dm_raw=$(docker manifest inspect "$image" 2>/dev/null) || dm_raw=""
            if [[ -n "$dm_raw" ]]; then
                echo "$dm_raw" | python3 -c "
import sys, json, datetime
image = sys.argv[1]
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
d = json.load(sys.stdin)
manifest = {
    'meta': {'source_image': image, 'collected_at': ts, 'collector': 'docker_manifest_inspect'},
    'schema_version': d.get('schemaVersion', ''),
    'media_type':     d.get('mediaType', ''),
    'config':         d.get('config', {}),
    'layers':         d.get('layers', []),
}
print(json.dumps(manifest, ensure_ascii=False, indent=2))
" "$image" > "$img_dir/manifest.json" 2>/dev/null && got_manifest=1
                warn "[$image] 已获取 manifest，但无 history（需安装 docker buildx 或 skopeo）"
            else
                # ── D. 本地 docker image inspect 兜底（需已 pull）────────────
                local mraw=""
                mraw=$(docker image inspect "$image" 2>/dev/null) || mraw=""
                if [[ -n "$mraw" ]]; then
                    echo "$mraw" | python3 -c "
import sys, json, datetime
data = json.load(sys.stdin)
item = data[0] if isinstance(data, list) else data
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
out = {
    'meta': {'source_image': sys.argv[1], 'collected_at': ts, 'collector': 'docker_image_inspect_local'},
    'id': item.get('Id',''), 'repo_tags': item.get('RepoTags',[]),
    'repo_digests': item.get('RepoDigests',[]), 'created': item.get('Created',''),
    'architecture': item.get('Architecture',''), 'os': item.get('Os',''), 'size': item.get('Size',0),
    'rootfs': {'type': item.get('RootFS',{}).get('Type',''), 'layers': item.get('RootFS',{}).get('Layers',[])},
    'config': {
        'env': item.get('Config',{}).get('Env',[]), 'cmd': item.get('Config',{}).get('Cmd',[]),
        'entrypoint': item.get('Config',{}).get('Entrypoint',[]),
        'workdir': item.get('Config',{}).get('WorkingDir',''), 'labels': item.get('Config',{}).get('Labels',{}),
    },
}
print(json.dumps(out, ensure_ascii=False, indent=2))
" "$image" > "$img_dir/manifest.json" 2>/dev/null && got_manifest=1
                    if [[ -n "$HIST_SCRIPT" ]]; then
                        if OUTPUT_DIR="$img_dir/_hist_tmp" bash "$HIST_SCRIPT" "$image" >/dev/null 2>&1; then
                            local found
                            found=$(find "$img_dir/_hist_tmp/images" -name "*.json" 2>/dev/null | head -1)
                            [[ -n "$found" ]] && cp "$found" "$img_dir/history.json" && got_hist=1
                        fi
                        rm -rf "$img_dir/_hist_tmp"
                    fi
                    [[ $got_manifest -eq 0 ]] && warn "[$image] 所有方式均失败，镜像未在本地且无法访问 registry"
                else
                    warn "[$image] manifest/history 均采集失败（需 docker buildx / skopeo，且镜像未在本地）"
                fi
            fi
        fi
    fi

    # 三项全无则报警
    if [[ $got_layer -eq 0 && $got_hist -eq 0 && $got_manifest -eq 0 ]]; then
        warn "[$image] 三项信息均采集失败！"
    else
        ok "[$image] 完成 (layer=$got_layer history=$got_hist manifest=$got_manifest)"
    fi

    # 写 per-image 状态
    python3 -c "
import json, sys
print(json.dumps({
    'image': sys.argv[1],
    'got_layer': sys.argv[2]=='1',
    'got_history': sys.argv[3]=='1',
    'got_manifest': sys.argv[4]=='1',
}, ensure_ascii=False))
" "$image" "$got_layer" "$got_hist" "$got_manifest" > "$img_dir/_status.json"

    # ── 清理：若本次 pull 的镜像，采集完成后删除 ─────────────────────────────
    if [[ $pulled_here -eq 1 ]]; then
        docker rmi "$image" >/dev/null 2>&1 && info "[$image] 已清理本地镜像" \
            || warn "[$image] 镜像清理失败（可能已被其他进程使用）"
    fi
}

export -f collect_one safe_name ok warn info err
export OUT_ROOT NO_LAYER ENV_SCRIPT HIST_SCRIPT TIMEOUT

# ── 并发执行采集 ──────────────────────────────────────────────────────────────
step "采集阶段 (${TOTAL} 个镜像)"

declare -a PIDS=()
for img in "${IMAGES[@]}"; do
    (collect_one "$img") &
    PIDS+=($!)
    if (( ${#PIDS[@]} >= WORKERS )); then
        wait "${PIDS[0]}" 2>/dev/null || true
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done

# ── biz 模式：调用 analyze.py 做 diff ─────────────────────────────────────────
if [[ "$MODE" == "biz" ]]; then
    step "分析阶段 (diff + 基础镜像解析)"
    python3 "$ANALYZE_SCRIPT" \
        --mode biz \
        --collect-dir "$OUT_ROOT" \
        ${BASE_OUTPUT:+--base-dir "$BASE_OUTPUT"} \
        2>&1
elif [[ "$MODE" == "base" ]]; then
    step "分析阶段 (基础镜像索引)"
    python3 "$ANALYZE_SCRIPT" \
        --mode base \
        --collect-dir "$OUT_ROOT" \
        2>&1
fi

# ── 生成汇总 ─────────────────────────────────────────────────────────────────
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

python3 - "$OUT_ROOT" "$MODE" "$ELAPSED" "${IMAGES[@]}" << 'PYEOF'
import sys, json, os
from pathlib import Path
out_root, mode, elapsed = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
images = sys.argv[4:]
records = []
for img in images:
    safe = img.replace('/','_').replace(':','_').replace(' ','_')
    st_file = out_root / safe / '_status.json'
    if st_file.exists():
        try:
            records.append(json.loads(st_file.read_text()))
        except Exception:
            records.append({'image': img, 'error': 'status parse error'})
    else:
        records.append({'image': img, 'error': 'not collected'})

summary = {
    'mode': mode,
    'collected_at': __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'elapsed_sec': elapsed,
    'total': len(images),
    'results': records,
}
(out_root / '_collect_summary.json').write_text(
    json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
print(f"[collect.sh] 汇总写入: {out_root}/_collect_summary.json", file=sys.stderr)
PYEOF

# ── 打包 ─────────────────────────────────────────────────────────────────────
step "打包"
PACK_NAME="${OUTPUT_DIR%/}.tar.gz"
tar czf "$PACK_NAME" -C "$(dirname "$OUT_ROOT")" "$(basename "$OUT_ROOT")" 2>/dev/null
ok "压缩包: $PACK_NAME  ($(du -sh "$PACK_NAME" 2>/dev/null | cut -f1))"

echo "" >&2
echo -e "${BOLD}${GREEN}═══ 完成 ═══${NC}" >&2
info "耗时: ${ELAPSED}s  输出: $OUT_ROOT"
