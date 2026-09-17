# AI 辅助改造参考

## 输入边界

AI_TRANSFORMATION 阶段（`WAITING_FOR_AI`）的唯一工作集：

```text
$WORK_DIR/reports/ai-workset.json
```

工作集（`schema_version=1.2`）顶层直接提供 `database_context`，包含源/目标数据库、源库/目标库动态验证是否启用，以及目标库验证关闭时 converted 项进入 `pending_confirm` 的规则。AI 不再额外读取 `assets/db-connection.json` 判断这些状态。顶层同时固化以下路径字段供 Agent 调用 `finalize` 子命令时复用，无需自行推断：

- `ai_migration_path`：`ai-migration` 二进制绝对路径（来自 `reports/devkit_path.txt` 的 `AI_MIGRATION` 字段）；
- `finalize.entry`：完整的 `sql-migration finalize` 命令前缀（含二进制路径、`sql-migration finalize` 子命令与 `--db-config` 参数），`finalize.entry_mode=SUBCOMMAND` 表示该前缀可直接拼接；`finalize.db_config` 为前缀中固化的 SKILL 资源路径副本，Agent 不应修改。`references/ai-sql-transformation.md` 与 `scripts/sql_migration.sh` 不再固化到 ai-workset.json，由 Agent 通过 SKILL 目录结构自行定位。

每条工作项直接包含：

- `workset_id`：结果分类的唯一标识；
- `source_sql` / `target_sql`：原始 SQL 与 DevKit 建议；
- `path` / `relative_path` / `start_line` / `end_line`：唯一源码位置与允许修改范围；
- `source_fragment`：需要判断/修改的精确源码片段；
- `context_before` / `context_after`：精确片段前后的有限上下文，避免再次读取整个 XML/Java/cs 文件；
- `context_truncated`：有限上下文是否因长度上限被截断；
- `fallback_read`：仅当嵌入上下文确实不足时允许读取的同一文件、限定行范围；
- `suggestions_cn` / `explain_exec_result_before`：DevKit分析信息；
- `rule_candidates`：最多少量相关历史规则；
- `identified_issues`：确定性程序已识别、在 `converted` 完成前必须消除的源数据库方言问题。

### 上下文使用顺序

AI_TRANSFORMATION 阶段必须按以下顺序处理信息：

1. 先读取 `ai-workset.json` 顶层 `database_context` 和当前 item；
2. 使用 `source_sql`、`target_sql`、`source_fragment`、`context_before/context_after`、`suggestions_cn`、`rule_candidates` 完成语义判断；
3. 只有嵌入信息不足时，才允许按该 item 的 `fallback_read.path/start_line/end_line` 读取一次局部源码；
4. 不允许为了定位同一 SQL 再扫描源码树、Glob/Find 文件、读取完整 Mapper/XML/Java 文件；
5. 不额外读取 `db-connection.json`，不通过外部 Web 搜索补充数据库方言规则；本地信息不足以可靠判断时直接归类 `manual-review`。

## AI 行为约束

AI 严禁：

- 扫描整个源码树或 Glob/Find 查找文件；
- 读取完整 Mapper/XML/Java/cs 文件；
- 重复读取 `assets/db-connection.json`；
- 通过外部 Web 补充数据库方言规则；
- 手工修改分类 JSON、创建 `.ai-completed`、生成 Patch；
- 在 `ai-workset.json` 写 `validated` 字段或直接编辑规则库 `rulers_<SOURCE>_to_<TARGET>.md`。

## AI处理原则

对每个 `workset_id` 做语义判断：

### 1. compatible

SQL 在目标数据库无需改造即可使用。源码不修改。

典型情况包括：

- EXPLAIN仅反映表、列、视图等目标对象尚未创建，SQL语法本身兼容；
- AI根据数据库语义判断 DevKit 残余提示不需要实际源码修改。

### 2. converted

SQL 存在真实方言差异。AI仅修改工作集指定的 `source-code/b` 文件与对应SQL范围，修改只限 SQL 方言改写（函数、语法、分页等），严禁修改变量名、控制流和业务逻辑。只有当该范围实际发生修改，并且 `identified_issues` 所代表的源方言问题已全部从当前 SQL 中消除时，才能提交 `converted`。仅处理部分问题不得标记为 `converted`。

常见类型：

- 数据库函数差异；
- 系统表/数据字典差异；
- DML语法差异；
- 运算符或分页等方言差异。

AI 修改源码后，**必须**在 `ai-workset.json` 对应 item 中写入以下字段：

**`ai_target_sql`（纯 SQL 语句）**：

转换后的**纯 SQL 语句**（不含 Java/Python 代码、缩进、引号包裹、注释等宿主语言上下文）。

用途：

- **报告 `target_sql`**：`finalize_ai_stage.py` 用它写入 `migrated_sql.json` / `pending_confirm_sql.json` / `manual_review_report.json` 的 `target_sql` 字段，最终进入 `migration_summary.csv`；
- **EXPLAIN 验证输入**：`target_sql_validator.py` 优先使用它执行目标库 EXPLAIN；
- **规则沉淀**：`finalize_ai_stage.py` 用验证通过的 `ai_target_sql` 作为规则库中"转换后 SQL"示例。

未提供时回退到 DevKit 原始建议（可能为空），**不会**用源码块兜底。

**`rule_pattern_key`（转换模式键，用于规则去重）**：

格式为大写下划线，命名规则 `<源数据库>_<源特性>_TO_<目标数据库>_<目标特性>`：

```
ORACLE_DECODE_TO_MYSQL_CASE_WHEN
ORACLE_ROWNUM_TO_MYSQL_LIMIT
MYSQL_BACKTICK_TO_DM_DOUBLE_QUOTE
```

同一转换模式（不区分表名/列名）只沉淀一条规则。所有 AI converted 且通过完整性检查的项均沉淀为规则，按 target 库验证状态标注【已验证】（EXPLAIN 通过）或【待人工确认】（验证失败或未启用目标库验证）；未提供 `rule_pattern_key` 则跳过该条沉淀。

**`rule_summary`（一句话转换说明，作为规则标题）**：

如"Oracle DECODE 函数转 MySQL CASE WHEN 表达式"、"Oracle ROWNUM 转 MySQL LIMIT 子句"。未提供时使用 `rule_pattern_key` 生成默认标题。

### 字段写入示例

Java 源码中 AI 修改后：

```java
    String sql = "SELECT CASE WHEN status = 1 THEN 'ACTIVE' ELSE 'INACTIVE' END FROM users";
```

对应的 workset item 字段：

```json
{
  "ai_target_sql": "SELECT CASE WHEN status = 1 THEN 'ACTIVE' ELSE 'INACTIVE' END FROM users",
  "rule_pattern_key": "ORACLE_DECODE_TO_MYSQL_CASE_WHEN",
  "rule_summary": "Oracle DECODE 函数转 MySQL CASE WHEN 表达式"
}
```

### 3. manual-review

无法可靠完成或验证时，不继续猜测，标记人工介入。

## 目标库动态验证

`assets/db-connection.json` 中：

- `target_db_conn.flag=false`：转换完成后不做目标库 EXPLAIN，`converted` 项由收敛脚本进入 `pending_confirm_sql.json`；
- `target_db_conn.flag=true`：AI只提交 `converted` 分类；后续由 `target_sql_validator.py` 确定性执行目标库 EXPLAIN。通过项进入 `migrated`，明确失败项进入 `manual-review`，无法确定性验证的项进入 `pending_confirm`。

EXPLAIN 只做解析/执行计划验证，不实际执行 DML。

## AI 阶段收敛

AI完成源码修改和结果判断后，不再自己修改以下文件：

```text
compatible_sql.json
migrated_sql.json
to_do-migrated_sql.json
pending_confirm_sql.json
manual_review_report.json
rulers_<SOURCE>_to_<TARGET>.md（规则库，位于 devkit-sql-migration-cache/）
.ai-completed
```

统一调用 `ai-migration` 二进制的 `sql-migration finalize` 子命令（命令前缀由 `ai-workset.json.finalize.entry` 提供，无需手动拼接）：

```bash
"<ai-migration>" sql-migration finalize \
  --db-config "<SKILL>/assets/db-connection.json" \
  --work-dir "$WORK_DIR" \
  --compatible "<workset-id,...>" \
  --converted "<workset-id,...>" \
  --manual-review "<workset-id,...>"
```

`<ai-migration>` 路径来自 `ai-workset.json` 顶层的 `ai_migration_path` 字段（与 `finalize.entry` 前缀一致）。`--db-config` 已固化在前缀中，Agent 直接复制 `finalize.entry` 字段并在末尾追加 `--work-dir / --compatible / --converted / --manual-review` 即可，不要重新拼接路径。`references/ai-sql-transformation.md` 与 `scripts/sql_migration.sh` 不再通过参数注入，由 Agent 通过 SKILL 目录结构自行定位。

所有 `workset_id` 必须且只能进入一个结果分类。脚本会自动：

1. 校验所有工作项均已分类；
2. 对 `converted` 执行完整性检查；未实际修改或仍残留可确定源方言问题的项自动降级为 `manual-review`，且不进入目标库 EXPLAIN；
3. 根据当前 `to_do-migrated_sql.json` 生成标准结果条目；
4. 同步 compatible/migrated/pending_confirm/manual_review/to_do；
5. 把 `ai_outcome`、处理时间、`converted_integrity` 和最终源码片段记录回 `ai-workset.json`；
6. 创建 `.ai-completed`；
7. 自动 in-process 调用 `sql_migration.main` 并附加 `--internal-resume` 接力续跑进入 FINALIZE（不通过 `ai-migration sql-migration` 命令行转发）；
8. 生成 `source_code.patch`、路径转换和最终汇总报告。

不创建固定 `ai-migration-result.json`，也不需要临时 Python 脚本整理报告。

## 转换来源

- AI判断无需转换：`conversion_source=AI确认兼容`；
- AI转换且目标库验证成功：`conversion_source=AI`；
- DevKit已有目标SQL、AI继续改造且验证成功：`conversion_source=DevKit+AI`；
- 未启用目标库验证的转换项：`conversion_source=AI待确认`，并保留 `conversion_origin` 说明来源。

### AI 转换风险与收敛

`ai-workset.json` 中 `semantic_review.manual_review_required=true` 的工作项必须归入 `manual-review`，不得提交为 `converted`。典型包括 `REPLACE INTO` 的 upsert 语义改写和疑似源 SQL 异常（如 `TIMESTAP(...)`）。系统目录改写等高风险项会保留风险标记，由后续确认/验证处理。AI 完成分类后使用 `ai-workset.json.finalize.entry` 提供的 `sql-migration finalize` 命令前缀（`entry_mode=SUBCOMMAND`，仅含 `--db-config` 共享参数）及 `finalize.work_dir` 调用 Finalize：直接复制 `finalize.entry` 字段，并在末尾追加 `--work-dir` / `--compatible` / `--converted` / `--manual-review` 参数，不根据当前目录重新拼接路径，也不直接调用 `scripts/tools/finalize_ai_stage.py`。
