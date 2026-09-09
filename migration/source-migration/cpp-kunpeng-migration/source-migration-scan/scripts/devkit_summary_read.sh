#!/usr/bin/env bash
# SourceCode build script
# Copyright Huawei Technologies Co., Ltd. 2023. All rights reserved.
# DevKit 扫描摘要 JSON 读取脚本（三级工具兜底）
#
# 用途：从 $WORK_DIR/reports/devkit_summary.json 中按字段读取内容，
#       供 4.2.0-prelude / 4.2.0 / 4.2.5 等章节判定 Rule 类别是否触发。
#       本脚本封装 jq → awk 降级路径（纯 shell/awk 实现，不依赖 python），
#       任何环境下均可读取生成的 JSON 摘要，避免上下文加载整份 DevKit 报告。
#
# 用法：
#   WORK_DIR=<工作目录> bash $SKILL_DIR/source-migration-scan/scripts/devkit_summary_read.sh <field>
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
command -v jq >/dev/null 2>&1 && HAS_JQ=1

if [[ $HAS_JQ -eq 0 ]]; then
  log "jq 不可用，使用 awk 降级路径"
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

# 2.2 awk 降级路径（无 jq 时，纯 shell/awk 实现）
# 适用于 devkit_report_summary.sh 通过 awk_fallback 生成的 JSON，
# 也兼容 jq 生成的合法 JSON。
awk_extract_section() {
  # 提取以 "$1: [" 开头、以 "  ]," 或 "  ]" 结束（含嵌套花括号深度计数）
  # 匹配到表头行时仅进入提取状态，不打印该行本身
  local header="$1"
  awk -v header="$header" '
    $0 ~ "^[[:space:]]*\"" header "\":[[:space:]]*\\[" {
      flag = 1; depth = 0; next
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
  # 兼容两种 JSON 格式：jq 多行对象 / awk_fallback 单行对象
  # 先折叠换行、归一化冒号后空白，再逐对象提取 category/total/rule
  awk_extract_section categories \
    | tr -d '\n' \
    | sed -E 's/:[[:space:]]+/:/g' \
    | grep -o '{[^}]*}' \
    | sed -nE 's/.*"category":"([^"]*)".*"total":([0-9]+).*"rule":([0-9]+).*/\1\t\2\t\3/p'
}

read_detail_awk() {
  awk_extract_section rule_detail_sample \
    | tr -d '\n' \
    | sed -E 's/:[[:space:]]+/:/g' \
    | grep -o '{[^}]*}' \
    | sed -nE 's/.*"category":"([^"]*)".*"location":"([^"]*)".*"suggestion":"([^"]*)".*/[\1] \2: \3/p'
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
  # 优先级：jq > awk
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

  # awk 降级（纯 shell 实现）
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
