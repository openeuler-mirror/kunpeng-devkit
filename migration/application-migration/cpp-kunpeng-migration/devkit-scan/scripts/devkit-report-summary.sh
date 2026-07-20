#!/usr/bin/env bash
# DevKit 扫描报告读取与汇总脚本
#
# 用途：流式读取并汇总 DevKit 扫描报告（CSV/HTML），生成压缩型摘要文件，
#       防止大型报告加载到 agent 上下文触发上下文压缩。
#       本脚本采用 awk 逐行流式处理，内存占用与报告大小无关（O(1) 内存）。
#
# 用法：
#   DEVKIT_REPORT_DIR=<报告目录>  bash devkit-report-summary.sh
#   或
#   DEVKIT_REPORT_DIR=<报告目录> WORK_DIR=<工作目录> bash devkit-report-summary.sh
#
# 输出：
#   $DEVKIT_REPORT_DIR/summary.txt          — 人类可读摘要（统计 + 表格 + 前 N 条明细）
#   $WORK_DIR/reports/devkit_summary.json   — 机器可读摘要（供后续阶段程序化读取）
#   stdout                                 — 打印摘要前 30 行供 agent 快速预览
#
# 退出码：
#   0  成功（报告目录为空时也返回 0，仅输出"无问题"摘要）
#   1  环境校验失败（DEVKIT_REPORT_DIR 未设置或不存在）
#   2  未找到任何 CSV/HTML 报告文件
#   3  CSV 表头格式不符合预期（无 PortingCategory 列）
#   4  JSON 输出失败（缺少 jq 或磁盘错误）

set -euo pipefail

log() { echo "[report-summary] $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

# --- 0. 前置校验 ---
[[ -n "${DEVKIT_REPORT_DIR:-}" ]] || fail 1 "环境变量 DEVKIT_REPORT_DIR 未设置"
[[ -d  "$DEVKIT_REPORT_DIR"       ]] || fail 1 "DEVKIT_REPORT_DIR 不是目录：$DEVKIT_REPORT_DIR"

WORK_DIR="${WORK_DIR:-$(dirname "$DEVKIT_REPORT_DIR")}"
mkdir -p "$WORK_DIR/reports"

# 收集所有 CSV 报告（DevKit 主输出）
CSV_FILES=()
while IFS= read -r f; do CSV_FILES+=("$f"); done < <(find "$DEVKIT_REPORT_DIR" -maxdepth 3 -type f -name "*.csv" 2>/dev/null | sort)
if [[ ${#CSV_FILES[@]} -eq 0 ]]; then
  # 也尝试 HTML 报告（部分 DevKit 版本输出 HTML 而非 CSV）
  HTML_FILES=()
  while IFS= read -r f; do HTML_FILES+=("$f"); done < <(find "$DEVKIT_REPORT_DIR" -maxdepth 3 -type f -name "*.html" -o -name "*.htm" 2>/dev/null | sort)
  if [[ ${#HTML_FILES[@]} -eq 0 ]]; then
    fail 2 "未在 $DEVKIT_REPORT_DIR 找到任何 CSV/HTML 报告文件"
  fi
  log "检测到 HTML 报告（${#HTML_FILES[@]} 个），本脚本暂仅汇总 CSV 格式，请确认 DevKit 输出格式"
  log "（如 DevKit 已输出 CSV，请使用 CSV 报告目录作为 DEVKIT_REPORT_DIR）"
  exit 2
fi

log "发现 ${#CSV_FILES[@]} 个 CSV 报告："
for f in "${CSV_FILES[@]}"; do log "  - $f"; done

SUMMARY_FILE="$DEVKIT_REPORT_DIR/summary.txt"
JSON_FILE="$WORK_DIR/reports/devkit_summary.json"

# --- 1. 探测表头（确定列索引） ---
# DevKit CSV 表头典型字段：File, Line, Category, Level, Suggestion
# 不同版本列顺序可能不同，扫描表头动态定位 Category 与 Level 列
HEADER=$(head -1 "${CSV_FILES[0]}")
log "表头：$HEADER"

# 去除可能的 BOM
HEADER=${HEADER#$'\xef\xbb\xbf'}
IFS=',' read -r -a COLS <<< "$HEADER"

CAT_IDX=-1
LVL_IDX=-1
FILE_IDX=-1
LINE_IDX=-1
SUG_IDX=-1
for i in "${!COLS[@]}"; do
  col=$(echo "${COLS[$i]}" | tr -d ' "')
  case "$col" in
    *ategory*|*CATEGORY*) CAT_IDX=$i ;;
    *evel*|*LEVEL*)       LVL_IDX=$i ;;
    *ile*|*FILE*)         FILE_IDX=$i ;;
    *ine*|*LINE*)         LINE_IDX=$i ;;
    *uggestion*|*SUG*)    SUG_IDX=$i ;;
  esac
done

if [[ $CAT_IDX -lt 0 || $LVL_IDX -lt 0 ]]; then
  fail 3 "CSV 表头缺少 PortingCategory 或 Level 列（无法定位问题类型/级别）。表头：$HEADER"
fi
log "列索引：Category=$CAT_IDX Level=$LVL_IDX File=$FILE_IDX Line=$LINE_IDX Suggestion=$SUG_IDX"

# --- 2. 流式统计（awk，O(1) 内存） ---
TMP_STATS=$(mktemp)
TMP_DETAIL=$(mktemp)
TMP_RULE=$(mktemp)
TMP_SUGG=$(mktemp)
trap 'rm -f "$TMP_STATS" "$TMP_DETAIL" "$TMP_RULE" "$TMP_SUGG"' EXIT

# 逐文件流式处理：跳过表头行，按 Level 分类收集明细
for f in "${CSV_FILES[@]}"; do
  awk -F',' -v cat="$CAT_IDX" -v lvl="$LVL_IDX" -v file_idx="$FILE_IDX" \
         -v line_idx="$LINE_IDX" -v sug_idx="$SUG_IDX" '
    function get(i) { return $i }
    NR==1 { next }
    # CSV 字段可能含逗号（被双引号包裹），此处采用简化解析；如遇复杂 CSV 改用 python -c
    {
      cat = $cat
      lvl = $lvl
      gsub(/^[ \t"]+|[ \t"]+$/, "", cat)
      gsub(/^[ \t"]+|[ \t"]+$/, "", lvl)
      print cat "|" lvl
    }
  ' "$f" >> "$TMP_STATS"
done

# 按 Category 统计（总数 + Rule/Suggestion 拆分）
awk -F'|' '
  {
    cat = $1; lvl = $2
    total[cat]++
    if (lvl ~ /Rule/) rule[cat]++; else sugg[cat]++
  }
  END {
    printf "%s|%s|%s\n", "Category", "Total", "Rule"
    for (c in total) printf "%s|%d|%d\n", c, total[c], rule[c]+0
  }
' "$TMP_STATS" | sort -t'|' -k2 -nr > "$TMP_DETAIL"

# 提取 Rule 级别类别（用于后续 4.2.x 触发条件判定）
awk -F'|' '$3 > 0 {print $1}' "$TMP_DETAIL" | sort -u > "$TMP_RULE"

# 统计各 Level 总量
LEVEL_TOTAL=$(awk -F'|' '{print $2}' "$TMP_STATS" | sort | uniq -c | sort -rn || true)
TOTAL_ROWS=$(wc -l < "$TMP_STATS" | tr -d ' ')

# --- 3. 提取 Rule 级问题明细（按 Category 截取前 N 条，防止输出过大） ---
DETAIL_HEAD_LIMIT=10
awk -F',' -v cat="$CAT_IDX" -v lvl="$LVL_IDX" -v file_idx="$FILE_IDX" \
       -v line_idx="$LINE_IDX" -v sug_idx="$SUG_IDX" -v limit="$DETAIL_HEAD_LIMIT" '
  NR==1 { next }
  {
    # 简化解析
    cat_v = $cat
    lvl_v = $lvl
    file_v = (file_idx >= 0 ? $file_idx : "")
    line_v = (line_idx >= 0 ? $line_idx : "")
    sug_v  = (sug_idx  >= 0 ? $sug_idx  : "")
    gsub(/^[ \t"]+|[ \t"]+$/, "", cat_v)
    gsub(/^[ \t"]+|[ \t"]+$/, "", lvl_v)
    gsub(/^[ \t"]+|[ \t"]+$/, "", file_v)
    gsub(/^[ \t"]+|[ \t"]+$/, "", line_v)
    gsub(/^[ \t"]+|[ \t"]+$/, "", sug_v)
    if (lvl_v ~ /Rule/) {
      print cat_v "|" file_v ":" line_v "|" sug_v
    }
  }
' "${CSV_FILES[@]}" | head -"$DETAIL_HEAD_LIMIT" > "$TMP_SUGG" || true

# --- 4. 写入人类可读摘要 ---
{
  echo "=================================================="
  echo " DevKit 扫描报告汇总"
  echo "=================================================="
  echo "报告目录：$DEVKIT_REPORT_DIR"
  echo "报告文件：${#CSV_FILES[@]} 个 CSV"
  echo "问题总数：$TOTAL_ROWS"
  echo
  echo "--- 按 Level 统计 ---"
  echo "$LEVEL_TOTAL" | awk '{$1=""; printf "  %-20s %s\n", $1, $0}' | sed 's/^  $/  (无)/'
  echo
  echo "--- 按 Category 统计（按总数降序）---"
  printf "  %-30s %-8s %-8s\n" "Category" "Total" "Rule"
  printf "  %-30s %-8s %-8s\n" "------------------------------" "--------" "--------"
  awk -F'|' 'NR>1 {printf "  %-30s %-8s %-8s\n", $1, $2, $3}' "$TMP_DETAIL"
  echo
  echo "--- Rule 级问题类别（触发 4.2.x 处理）---"
  if [[ -s "$TMP_RULE" ]]; then
    sed 's/^/  - /' "$TMP_RULE"
  else
    echo "  (无)"
  fi
  echo
  echo "--- Rule 级问题明细（前 $DETAIL_HEAD_LIMIT 条示例）---"
  if [[ -s "$TMP_SUGG" ]]; then
    awk -F'|' '{printf "  [%s] %s\n      建议：%s\n", $1, $2, $3}' "$TMP_SUGG"
  else
    echo "  (无)"
  fi
  echo
  echo "=================================================="
  echo " 完整明细请直接查阅报告目录：$DEVKIT_REPORT_DIR"
  echo " 本摘要不加载到 agent 上下文，请勿将整份报告回填"
  echo "=================================================="
} > "$SUMMARY_FILE"

log "摘要已写入：$SUMMARY_FILE"

# --- 5. 写入机器可读 JSON 摘要 ---
# 优先级：jq → python3 → python2 → awk 手工拼接
# 服务器通常具备 python3；若均无，则仅生成 summary.txt，提示用户使用 awk 读取

write_json_with_jq() {
  local categories_json rule_cats_json detail_json
  categories_json=$(awk -F'|' 'NR>1 {
    gsub(/"/, "\\\"", $1)
    printf "{\"category\":\"%s\",\"total\":%s,\"rule\":%s},\n", $1, $2, $3
  }' "$TMP_DETAIL" | sed '$ s/,$//')

  rule_cats_json=$(awk '{gsub(/"/, "\\\"", $0); printf "\"%s\",", $0}' "$TMP_RULE" | sed '$ s/,$//')
  [[ -z "$rule_cats_json" ]] && rule_cats_json=""

  detail_json=$(awk -F'|' '{
    gsub(/"/, "\\\"", $1)
    gsub(/"/, "\\\"", $2)
    gsub(/"/, "\\\"", $3)
    printf "{\"category\":\"%s\",\"location\":\"%s\",\"suggestion\":\"%s\"},\n", $1, $2, $3
  }' "$TMP_SUGG" | sed '$ s/,$//')
  [[ -z "$detail_json" ]] && detail_json=""

  cat > "$JSON_FILE" <<EOF
{
  "report_dir": "$DEVKIT_REPORT_DIR",
  "csv_count": ${#CSV_FILES[@]},
  "total_issues": $TOTAL_ROWS,
  "rule_categories": [${rule_cats_json}],
  "categories": [${categories_json}],
  "rule_detail_sample": [${detail_json}]
}
EOF
  jq . "$JSON_FILE" >/dev/null 2>&1
}

write_json_with_python() {
  local py_cmd="$1"
  "$py_cmd" - "$JSON_FILE" "$DEVKIT_REPORT_DIR" "${#CSV_FILES[@]}" "$TOTAL_ROWS" \
            "$TMP_DETAIL" "$TMP_RULE" "$TMP_SUGG" <<'PYEOF'
import json, sys
out_path, report_dir, csv_count, total = sys.argv[1:5]
tmp_detail, tmp_rule, tmp_sugg = sys.argv[5:8]

def load_lines(p):
    try:
        with open(p, 'r', encoding='utf-8') as f:
            return [l.rstrip('\n') for l in f if l.strip()]
    except FileNotFoundError:
        return []

categories = []
for line in load_lines(tmp_detail)[1:]:  # skip header
    parts = line.split('|')
    if len(parts) >= 3:
        categories.append({"category": parts[0], "total": int(parts[1]), "rule": int(parts[2])})

rule_cats = load_lines(tmp_rule)
detail = []
for line in load_lines(tmp_sugg):
    parts = line.split('|', 2)
    if len(parts) >= 3:
        detail.append({"category": parts[0], "location": parts[1], "suggestion": parts[2]})

obj = {
    "report_dir": report_dir,
    "csv_count": int(csv_count),
    "total_issues": int(total),
    "rule_categories": rule_cats,
    "categories": categories,
    "rule_detail_sample": detail,
}
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
PYEOF
}

write_json_with_awk_fallback() {
  # 手工拼接 JSON（不验证语法，仅供 agent 后续 grep/awk 读取）
  # 标记为降级输出
  local rule_total detail_total category_total
  rule_total=$(wc -l < "$TMP_RULE" | tr -d ' ')
  detail_total=$(wc -l < "$TMP_SUGG" | tr -d ' ')
  category_total=$(awk 'END{print NR-1}' "$TMP_DETAIL")  # 减去表头

  {
    echo "{"
    echo "  \"_fallback\": \"awk_manual_no_jq_no_python\","
    echo "  \"report_dir\": \"$DEVKIT_REPORT_DIR\","
    echo "  \"csv_count\": ${#CSV_FILES[@]},"
    echo "  \"total_issues\": $TOTAL_ROWS,"
    echo "  \"rule_categories\": ["
    awk -v total="$rule_total" '{
      printf "    \"%s\"", $0
      if (NR != total) printf ","
      print ""
    }' "$TMP_RULE"
    echo "  ],"
    echo "  \"categories\": ["
    awk -F'|' -v total="$category_total" 'NR>1 {
      gsub(/"/, "\\\"", $1)
      printf "    {\"category\":\"%s\",\"total\":%s,\"rule\":%s}", $1, $2, $3
      if (NR-1 != total) printf ",\n"; else printf "\n"
    }' "$TMP_DETAIL"
    echo "  ],"
    echo "  \"rule_detail_sample\": ["
    awk -F'|' -v total="$detail_total" '{
      gsub(/"/, "\\\"", $1); gsub(/"/, "\\\"", $2); gsub(/"/, "\\\"", $3)
      printf "    {\"category\":\"%s\",\"location\":\"%s\",\"suggestion\":\"%s\"}", $1, $2, $3
      if (NR != total) printf ",\n"; else printf "\n"
    }' "$TMP_SUGG"
    echo "  ]"
    echo "}"
  } > "$JSON_FILE"
  warn "已使用 awk 降级生成 JSON，语法未经严格校验，建议优先安装 jq 或 python3"
}

JSON_GENERATED=0
if command -v jq >/dev/null 2>&1; then
  log "使用 jq 生成 JSON 摘要"
  if write_json_with_jq; then
    JSON_GENERATED=1
  else
    warn "jq 生成失败，尝试降级方案"
  fi
fi

if [[ $JSON_GENERATED -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
  log "使用 python3 生成 JSON 摘要（jq 不可用时的首选降级）"
  if write_json_with_python python3; then
    JSON_GENERATED=1
  else
    warn "python3 生成失败，尝试 python2"
  fi
fi

if [[ $JSON_GENERATED -eq 0 ]] && command -v python2 >/dev/null 2>&1; then
  log "使用 python2 生成 JSON 摘要"
  if write_json_with_python python2; then
    JSON_GENERATED=1
  fi
fi

if [[ $JSON_GENERATED -eq 0 ]]; then
  warn "jq / python3 / python2 均不可用，使用 awk 降级生成 JSON 摘要"
  write_json_with_awk_fallback
  JSON_GENERATED=1
  log "JSON 摘要已写入（awk 降级）：$JSON_FILE"
  log "后续读取建议：用 awk/grep 解析，避免依赖 jq 语法校验"
else
  log "JSON 摘要已写入：$JSON_FILE"
fi

# --- 6. stdout 输出预览（前 30 行） ---
log "摘要预览（前 30 行）："
head -30 "$SUMMARY_FILE" || true

log "完成：共 $TOTAL_ROWS 条问题，Rule 类别 $(wc -l < "$TMP_RULE" | tr -d ' ') 个"
log "后续阶段请通过 jq 读取 $JSON_FILE 获取 Rule 类别列表（用于触发 4.2.x 各节）"
