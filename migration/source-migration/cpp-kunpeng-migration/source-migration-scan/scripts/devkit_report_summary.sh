#!/usr/bin/env bash
# SourceCode build script
# Copyright Huawei Technologies Co., Ltd. 2023. All rights reserved.
# DevKit 扫描报告读取与汇总脚本
#
# 用途：流式读取并汇总 DevKit 扫描报告（CSV/HTML），生成压缩型摘要文件，
#       防止大型报告加载到 agent 上下文触发上下文压缩。
#       本脚本采用 awk 逐行流式处理，内存占用与报告大小无关（O(1) 内存）。
#
# 用法：
#   DEVKIT_REPORT_DIR=<报告目录>  bash $SKILL_DIR/source-migration-scan/scripts/devkit_report_summary.sh
#   或
#   DEVKIT_REPORT_DIR=<报告目录> WORK_DIR=<工作目录> bash $SKILL_DIR/source-migration-scan/scripts/devkit_report_summary.sh
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
#   4  JSON 输出失败（磁盘错误；无 jq 时自动使用 awk 生成）

set -euo pipefail

log() { echo "[report-summary] $*" >&2; }
warn() { echo "[report-summary] WARN: $*" >&2; }
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
# DevKit CSV 报告前部包含元数据（Scanned time、Configuration、统计信息等），
# 真正的数据表头行包含 "filename" 和 "category" 字段，需动态查找其所在行号
HEADER_LINE_NUM=$(grep -n '"filename"' "${CSV_FILES[0]}" | head -1 | cut -d: -f1 || true)
if [[ -z "$HEADER_LINE_NUM" ]]; then
  # 兼容旧格式：表头可能在第 1 行（无元数据前导）
  HEADER_LINE_NUM=1
  HEADER=$(head -1 "${CSV_FILES[0]}")
  if ! echo "$HEADER" | grep -qi 'category'; then
    fail 3 "CSV 中未找到包含 filename/category 的数据表头行（非标准 DevKit 报告格式）"
  fi
fi
HEADER=$(sed -n "${HEADER_LINE_NUM}p" "${CSV_FILES[0]}")
log "数据表头（第 ${HEADER_LINE_NUM} 行）：$HEADER"

# 去除可能的 BOM
HEADER=${HEADER#$'\xef\xbb\xbf'}

# 使用 awk CSV 解析检测列索引（表头字段 "line number(start line, end line)" 含逗号，
# 不能用 bash IFS=',' 简单拆分，否则后续列索引全部错位）
INDICES=$(awk -v hdr="$HEADER" '
  function csv_parse(line,    i, c, fld, q, n) {
    n = 0; fld = ""; q = 0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (c == "\"") {
        if (q && substr(line, i+1, 1) == "\"") { fld = fld "\""; i++ }
        else { q = !q }
      } else if (c == "," && !q) {
        CSV[n++] = fld; fld = ""
      } else {
        fld = fld c
      }
    }
    CSV[n++] = fld
    return n
  }
  BEGIN {
    nf = csv_parse(hdr)
    cat = -1; lvl = -1; file = -1; line = -1; sug = -1
    for (i = 0; i < nf; i++) {
      col = CSV[i]
      gsub(/^[ \t"]+|[ \t"]+$/, "", col)
      if (col ~ /ategory/ || col ~ /CATEGORY/)         cat = i
      else if (col ~ /evel/ || col ~ /LEVEL/)          lvl = i
      else if (col ~ /ilename/ || col ~ /FILENAME/)    file = i
      else if (col ~ /ine.*number/ || col ~ /ine.*num/ || col ~ /LINE/) line = i
      else if (col ~ /uggestion/ || col ~ /SUG/)       sug = i
    }
    printf "%d %d %d %d %d", cat, lvl, file, line, sug
  }
')
read -r CAT_IDX LVL_IDX FILE_IDX LINE_IDX SUG_IDX <<< "$INDICES"

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

# 逐文件流式处理：跳过元数据前导与表头行，按 Level 分类收集明细
# DevKit CSV 字段含双引号包裹的逗号（如 "(1, 1)"）及跨行换行（如汇编寄存器建议列表），
# 需 RFC4180 风格解析：先合并跨行记录，再逐字段解析
for f in "${CSV_FILES[@]}"; do
  awk -v cat_idx="$CAT_IDX" -v lvl_idx="$LVL_IDX" '
    function csv_parse(line,    i, c, fld, q, n) {
      n = 0; fld = ""; q = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") {
          if (q && substr(line, i+1, 1) == "\"") { fld = fld "\""; i++ }
          else { q = !q }
        } else if (c == "," && !q) {
          CSV[n++] = fld; fld = ""
        } else {
          fld = fld c
        }
      }
      CSV[n++] = fld
      return n
    }
    # 合并跨行 CSV 记录：双引号字段内含换行符时，引号计数为奇数表示记录未结束
    {
      if (pending) {
        buf = buf "\n" $0
      } else {
        buf = $0
      }
      tmp = buf
      if (gsub(/"/, "", tmp) % 2 == 1) {
        pending = 1
        next
      }
      pending = 0
      line = buf
    }
    # 跳过元数据前导行，直到找到数据表头（含 filename 和 category）
    !found_hdr {
      if (line ~ /filename/ && line ~ /category/) found_hdr = 1
      next
    }
    line ~ /^[[:space:]]*$/ { next }
    {
      csv_parse(line)
      cat_v = CSV[cat_idx]
      lvl_v = CSV[lvl_idx]
      gsub(/^[ \t"]+|[ \t"]+$/, "", cat_v)
      gsub(/^[ \t"]+|[ \t"]+$/, "", lvl_v)
      if (cat_v == "" && lvl_v == "") next
      print cat_v "|" lvl_v
    }
  ' "$f" >> "$TMP_STATS"
done

# 按 Category 统计（总数 + Rule/Suggestion 拆分）
# 表头单独写入，避免 sort 将表头排到末尾导致 NR>1 跳过最大行
{
  echo "Category|Total|Rule"
  awk -F'|' '
    {
      cat = $1; lvl = $2
      total[cat]++
      if (lvl ~ /Rule/) rule[cat]++; else sugg[cat]++
    }
    END {
      for (c in total) printf "%s|%d|%d\n", c, total[c], rule[c]+0
    }
  ' "$TMP_STATS" | sort -t'|' -k2 -nr
} > "$TMP_DETAIL"

# 提取 Rule 级别类别（用于后续 4.2.x 触发条件判定）
# NR>1 跳过表头，($3+0) 强制数值比较避免 "Rule" 被误判为 > 0
awk -F'|' 'NR>1 && ($3+0) > 0 {print $1}' "$TMP_DETAIL" | sort -u > "$TMP_RULE"

# 统计各 Level 总量
LEVEL_TOTAL=$(awk -F'|' '{print $2}' "$TMP_STATS" | sort | uniq -c | sort -rn || true)
TOTAL_ROWS=$(wc -l < "$TMP_STATS" | tr -d ' ')

# --- 3. 提取 Rule 级问题明细（按 Category 截取前 N 条，防止输出过大） ---
DETAIL_HEAD_LIMIT=10
awk -v cat_idx="$CAT_IDX" -v lvl_idx="$LVL_IDX" -v file_idx="$FILE_IDX" \
       -v line_idx="$LINE_IDX" -v sug_idx="$SUG_IDX" -v limit="$DETAIL_HEAD_LIMIT" '
    function csv_parse(line,    i, c, fld, q, n) {
      n = 0; fld = ""; q = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") {
          if (q && substr(line, i+1, 1) == "\"") { fld = fld "\""; i++ }
          else { q = !q }
        } else if (c == "," && !q) {
          CSV[n++] = fld; fld = ""
        } else {
          fld = fld c
        }
      }
      CSV[n++] = fld
      return n
    }
    # 多文件处理：每个文件重置表头探测与跨行合并状态
    FNR == 1 { found_hdr = 0; pending = 0 }
    # 合并跨行 CSV 记录
    {
      if (pending) {
        buf = buf "\n" $0
      } else {
        buf = $0
      }
      tmp = buf
      if (gsub(/"/, "", tmp) % 2 == 1) {
        pending = 1
        next
      }
      pending = 0
      line = buf
    }
    !found_hdr {
      if (line ~ /filename/ && line ~ /category/) found_hdr = 1
      next
    }
    line ~ /^[[:space:]]*$/ { next }
    {
      csv_parse(line)
      cat_v = CSV[cat_idx]
      lvl_v = CSV[lvl_idx]
      file_v = (file_idx >= 0 ? CSV[file_idx] : "")
      line_v = (line_idx >= 0 ? CSV[line_idx] : "")
      sug_v  = (sug_idx  >= 0 ? CSV[sug_idx]  : "")
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
  if [[ -n "$LEVEL_TOTAL" ]]; then
    printf "%s\n" "$LEVEL_TOTAL" | awk '{printf "  %-30s %5s\n", $2, $1}'
  else
    echo "  (无)"
  fi
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
# 优先级：jq → awk 手工拼接（纯 shell 实现，不依赖 python）
# 服务器通常具备 jq；若不可用，自动用 awk 手工拼接生成 JSON

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

write_json_with_awk_fallback() {
  # 手工拼接 JSON（不验证语法，仅供 agent 后续 grep/awk 读取）
  # 标记为降级输出
  local rule_total detail_total category_total
  rule_total=$(wc -l < "$TMP_RULE" | tr -d ' ')
  detail_total=$(wc -l < "$TMP_SUGG" | tr -d ' ')
  category_total=$(awk 'END{print NR-1}' "$TMP_DETAIL")  # 减去表头

  {
    echo "{"
    echo "  \"_fallback\": \"awk_manual_no_jq\","
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
  warn "已使用 awk 降级生成 JSON，语法未经严格校验，建议优先安装 jq"
}

JSON_GENERATED=0
if command -v jq >/dev/null 2>&1; then
  log "使用 jq 生成 JSON 摘要"
  if write_json_with_jq; then
    JSON_GENERATED=1
  else
    warn "jq 生成失败，使用 awk 降级"
  fi
fi

if [[ $JSON_GENERATED -eq 0 ]]; then
  warn "jq 不可用或生成失败，使用 awk 手工拼接生成 JSON 摘要"
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
