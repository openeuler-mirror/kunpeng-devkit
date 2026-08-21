#!/bin/bash
# run_handoff.sh — Agent 接管清单串行调度器：读取 middleware-agent-handoff.json，
# 逐项调用 <per_item_script>（exit 0 视为成功），最后生成 middleware-agent-handoff-result.json。
# 用法: run_handoff.sh <handoff.json> <per_item_script> [--dry-run]
#   --dry-run 只输出各接管项摘要，不真正执行
# 退出码：0 全部成功；1 存在失败项或参数/清单错误

set -u

# ==================== 主流程 ====================
HANDOFF_JSON=""
PER_ITEM_SCRIPT=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -*)
            echo "未知参数: $1" >&2; exit 2 ;;
        *)
            if [ -z "$HANDOFF_JSON" ]; then
                HANDOFF_JSON="$1"
            elif [ -z "$PER_ITEM_SCRIPT" ]; then
                PER_ITEM_SCRIPT="$1"
            else
                echo "未知参数: $1" >&2; exit 2
            fi
            shift ;;
    esac
done

if [ -z "$HANDOFF_JSON" ]; then
    echo "用法: $0 <handoff.json> <per_item_script> [--dry-run]" >&2
    exit 2
fi
if [ ! -f "$HANDOFF_JSON" ]; then
    echo "接管清单不存在: $HANDOFF_JSON" >&2
    exit 2
fi
if [ "$DRY_RUN" -eq 0 ] && [ -z "$PER_ITEM_SCRIPT" ]; then
    echo "缺少 per_item_script（--dry-run 可不传）" >&2
    exit 2
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
ITEMS_DIR="$TMP_DIR/items"
RESULT_FILE="$TMP_DIR/results.txt"
mkdir -p "$ITEMS_DIR"
: > "$RESULT_FILE"

TOTAL=$(python3 - "$HANDOFF_JSON" "$ITEMS_DIR" <<'PY'
import json, sys, os
with open(sys.argv[1], encoding='utf-8') as f:
    items = json.load(f).get('items', [])
out_dir = sys.argv[2]
for i, it in enumerate(items):
    with open(os.path.join(out_dir, 'item-%04d.json' % i), 'w', encoding='utf-8') as w:
        json.dump(it, w, ensure_ascii=False)
print(len(items))
PY
)

if ! printf '%s' "$TOTAL" | grep -qE '^[0-9]+$'; then
    echo "接管清单解析失败（非法条目数: ${TOTAL:-空}）: $HANDOFF_JSON" >&2
    exit 2
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "接管清单为空，无需处理"
    exit 0
fi

echo "[handoff] 接管项 $TOTAL 个，串行处理"

if [ "$DRY_RUN" -eq 1 ]; then
    python3 - "$ITEMS_DIR" <<'PY'
import json, sys, glob, os
for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.json'))):
    d = json.load(open(p, encoding='utf-8'))
    print('  type=%-18s deploy_dir=%s  reason=%s' % (d.get('type'), d.get('deploy_dir'), d.get('reason')))
PY
    exit 0
fi

for item_file in $(find "$ITEMS_DIR" -name '*.json' -print | sort); do
    "$PER_ITEM_SCRIPT" "$item_file"
    rc=$?
    printf '%s %s\n' "$(basename "$item_file" .json)" "$rc" >> "$RESULT_FILE"
done

OUT_JSON="$(dirname "$HANDOFF_JSON")/middleware-agent-handoff-result.json"
FAILED=$(python3 - "$RESULT_FILE" "$ITEMS_DIR" "$OUT_JSON" <<'PY'
import json, sys, os, glob
res_file, items_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
rc_map = {}
with open(res_file, encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if line:
            idx, rc = line.split(None, 1)
            rc_map[idx] = int(rc)
rows = []
for p in sorted(glob.glob(os.path.join(items_dir, '*.json'))):
    idx = os.path.splitext(os.path.basename(p))[0]
    d = json.load(open(p, encoding='utf-8'))
    rows.append({'item': idx, 'id': d.get('id'), 'type': d.get('type'),
                 'deploy_dir': d.get('deploy_dir'), 'exit_code': rc_map.get(idx, -1)})
out = {
    'status': 'HANDOFF_DONE',
    'total': len(rows),
    'success': sum(1 for r in rows if r['exit_code'] == 0),
    'failed': sum(1 for r in rows if r['exit_code'] != 0),
    'items': rows,
}
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(out['failed'])
PY
)

echo "[handoff] 完成，结果见 $OUT_JSON"
[ "$FAILED" -eq 0 ] && exit 0
exit 1
