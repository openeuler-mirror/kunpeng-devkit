#!/usr/bin/env bash
# DevKit 扫描摘要 JSON 读取脚本（三级工具兜底）
#
# 用途：从 $WORK_DIR/reports/devkit_summary.json 中按字段读取内容，
#       供 4.2.0-prelude / 4.2.0 / 4.2.5 等章节判定 Rule 类别是否触发。
#       本脚本封装 jq → python3 → python2 → awk 降级路径，
#       任何环境下均可读取生成的 JSON 摘要，避免上下文加载整份 DevKit 报告。
#
# 用法：
#   WORK_DIR=<工作目录> bash devkit-summary-read.sh <field>
#
# 字段：
#   rule_categories    — 输出 Rule 级问题类别，每行一个（供触发条件判定）
#   categories         — 输出按 Category 统计：category<TAB>total<TAB>rule
#   rule_detail_sample — 输出 Rule 明细示例：每行 [CATEGORY] LOCATION: SUGGESTION
#   all                — 依次输出以上三段（用空行分隔）
#   has_rule           — 仅当 rule_categories 非空时输出 "yes" 并以 0 退出，否则输出 "no" 并以 11 退出
#   has <CATEGORY>     — 检查指定类别是否在 rule_categories 中，存在则 0/yes，不存在则 12/no
#
# 环境变量：
#   WORK_DIR — 工作目录（必填，JSON 文件位于 $WORK_DIR/reports/devkit_summary.json）
#
# 退出码：
#   0   成功（has_rule/has 检查且条件满足）
#   1   参数/环境错误（参数缺失、WORK_DIR 未设置、JSON 文件不存在、JSON 文件为空）
#   2   字段名无效
#   11  has_rule 检查：rule_categories 为空
#   12  has <CATEGORY> 检查：未在 rule_categories 中找到
#   13  降级 awk 路径下 JSON 文件不含预期字段（格式损坏）

set -euo pipefail

log()  { echo "[summary-read] $*" >&2; }
fail() { log "ERROR: $2"; exit "$1"; }

# --- 0. 前置校验 ---
[[ $# -ge 1 ]] || fail 2 "用法：$0 <field> [CATEGORY]"
[[ -n "${WORK_DIR:-}" ]] || fail 1 "环境变量 WORK_DIR 未设置"
JSON_FILE="$WORK_DIR/reports/devkit_summary.json"
[[ -s "$JSON_FILE" ]] || fail 1 "JSON 摘要文件不存在或为空：$JSON_FILE"

FIELD="$1"
case "$FIELD" in
  rule_categories|categories|rule_detail_sample|all|has_rule|has) ;;
  *) fail 2 "无效字段：$FIELD（合法：rule_categories / categories / rule_detail_sample / all / has_rule / has）" ;;
esac

if [[ "$FIELD" == "has" && $# -lt 2 ]]; then
  fail 2 "用法：$0 has <CATEGORY>"
fi

# --- 1. 探测可用工具 ---
HAS_JQ=0
HAS_PY3=0
HAS_PY2=0
command -v jq       >/dev/null 2>&1 && HAS_JQ=1
command -v python3  >/dev/null 2>&1 && HAS_PY3=1
command -v python2  >/dev/null 2>&1 && HAS_PY2=1

if [[ $HAS_JQ -eq 0 && $HAS_PY3 -eq 0 && $HAS_PY2 -eq 0 ]]; then
  log "jq / python3 / python2 均不可用，使用 awk 降级路径"
fi

# --- 2. 各字段读取函数（按工具优先级） ---

# 2.1 jq 路径
read_rule_categories_jq() {
  jq -r '.rule_categories[]?' "$JSON_FILE"
}
read_categories_jq() {
  jq -r '.categories[]? | "\(.category)\t\(.total)\t\(.rule)"' "$JSON_FILE"
}
read_detail_jq() {
  jq -r '.rule_detail_sample[]? | "[\(.category)] \(.location): \(.suggestion)"' "$JSON_FILE"
}
has_rule_jq() {
  local n
  n=$(jq -r '.rule_categories | length' "$JSON_FILE" 2>/dev/null || echo 0)
  [[ "${n:-0}" -gt 0 ]]
}
has_category_jq() {
  local cat="$1"
  jq -e --arg c "$cat" '.rule_categories | index($c) != null' "$JSON_FILE" >/dev/null 2>&1
}

# 2.2 python 路径（python3 / python2 共用）
read_with_python() {
  local py_cmd="$1" field="$2" extra="$3"
  "$py_cmd" - "$JSON_FILE" "$field" "$extra" <<'PYEOF'
import json, sys
fp, field, extra = sys.argv[1], sys.argv[2], sys.argv[3]
with open(fp, 'r', encoding='utf-8') as f:
    d = json.load(f)

if field == 'rule_categories':
    for c in d.get('rule_categories') or []:
        print(c)
elif field == 'categories':
    for c in d.get('categories') or []:
        print(f"{c['category']}\t{c['total']}\t{c['rule']}")
elif field == 'rule_detail_sample':
    for s in d.get('rule_detail_sample') or []:
        print(f"[{s['category']}] {s['location']}: {s['suggestion']}")
elif field == 'has_rule':
    rc = d.get('rule_categories') or []
    if len(rc) > 0:
        print('yes'); sys.exit(0)
    else:
        print('no'); sys.exit(11)
elif field == 'has':
    rc = d.get('rule_categories') or []
    if extra in rc:
        print('yes'); sys.exit(0)
    else:
        print('no'); sys.exit(12)
elif field == 'all':
    print('# rule_categories')
    for c in d.get('rule_categories') or []:
        print(c)
    print()
    print('# categories')
    for c in d.get('categories') or []:
        print(f"{c['category']}\t{c['total']}\t{c['rule']}")
    print()
    print('# rule_detail_sample')
    for s in d.get('rule_detail_sample') or []:
        print(f"[{s['category']}] {s['location']}: {s['suggestion']}")
PYEOF
}

# 2.3 awk 降级路径（无 jq / python 时）
# 适用于 devkit-report-summary.sh 通过 awk_fallback 生成的 JSON，
# 也兼容 jq/python 生成的合法 JSON。
awk_extract_section() {
  # 提取以 "$1: [" 开头、以 "  ]," 或 "  ]" 结束（含嵌套花括号深度计数）
  local header="$1"
  awk -v header="$header" '
    $0 ~ "^[[:space:]]*\"" header "\":[[:space:]]*\\[" {
      flag = 1; depth = 0; print; next
    }
    flag {
      print
      n = gsub(/\{/, "{")
      m = gsub(/\}/, "}")
      depth += n - m
      if (depth <= 0 && $0 ~ /^[[:space:]]*\]/) { flag = 0 }
    }
  ' "$JSON_FILE"
}

awk_extract_field_value() {
  # 从 key: "value" 或 key: number 形式提取顶层 value（仅适用于行内简单值）
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*\"" key "\"[[:space:]]*:" {
      match($0, /:[[:space:]]*(.*),?$/, arr); print arr[1]
    }
  ' "$JSON_FILE" | head -1 | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//; s/,$//' | tr -d '\n'
}

read_rule_categories_awk() {
  awk_extract_section rule_categories \
    | sed -E 's/^[[:space:]]*"(.*)",?$/\1/' \
    | sed '/^$/d; /^[[:space:]]*\]/d'
}

read_categories_awk() {
  awk_extract_section categories \
    | sed -nE 's/.*"category":"([^"]+)","total":([0-9]+),"rule":([0-9]+).*/\1\t\2\t\3/p'
}

read_detail_awk() {
  awk_extract_section rule_detail_sample \
    | sed -nE 's/.*"category":"([^"]+)","location":"([^"]+)","suggestion":"([^"]+)".*/[\1] \2: \3/p'
}

has_rule_awk() {
  # 提取 rule_categories 数组内容行（非空且非括号行）
  local n
  n=$(read_rule_categories_awk | sed '/^$/d' | wc -l | tr -d ' ')
  [[ "${n:-0}" -gt 0 ]]
}

has_category_awk() {
  local target="$1"
  read_rule_categories_awk | grep -Fxq "$target"
}

# --- 3. 分发到具体实现 ---

run_field() {
  local field="$1" extra="${2:-}"
  # 优先级：jq > python3 > python2 > awk
  if [[ $HAS_JQ -eq 1 ]]; then
    case "$field" in
      rule_categories)    read_rule_categories_jq ;;
      categories)         read_categories_jq ;;
      rule_detail_sample) read_detail_jq ;;
      all)
        echo '# rule_categories';    read_rule_categories_jq
        echo; echo '# categories';   read_categories_jq
        echo; echo '# rule_detail_sample'; read_detail_jq
        ;;
      has_rule) has_rule_jq && { echo yes; return 0; } || { echo no; return 11; } ;;
      has)      has_category_jq "$extra" && { echo yes; return 0; } || { echo no; return 12; } ;;
    esac
    return 0
  fi

  if [[ $HAS_PY3 -eq 1 ]]; then
    read_with_python python3 "$field" "$extra"
    return $?
  fi

  if [[ $HAS_PY2 -eq 1 ]]; then
    read_with_python python2 "$field" "$extra"
    return $?
  fi

  # awk 降级
  case "$field" in
    rule_categories)    read_rule_categories_awk ;;
    categories)         read_categories_awk ;;
    rule_detail_sample) read_detail_awk ;;
    all)
      echo '# rule_categories';    read_rule_categories_awk
      echo; echo '# categories';   read_categories_awk
      echo; echo '# rule_detail_sample'; read_detail_awk
      ;;
    has_rule) has_rule_awk && { echo yes; return 0; } || { echo no; return 11; } ;;
    has)      has_category_awk "$extra" && { echo yes; return 0; } || { echo no; return 12; } ;;
  esac
}

# --- 4. 执行 ---

EXTRA=""
if [[ "$FIELD" == "has" ]]; then
  EXTRA="$2"
fi

run_field "$FIELD" "$EXTRA"
