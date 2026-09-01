---
name: "sql-migration"
description: "sql-migration Skill 主调度文件。用于将项目源码中嵌入的 SQL（Mapper XML、Java、C# 持久层代码等）从源数据库迁移到目标数据库，覆盖 DevKit 完整支持、DevKit 仅提取、MySQL → Vastbase 三类迁移路线。负责环境自动准备、DevKit 分析转换、残余 SQL AI 处理、目标库验证与规则沉淀、Patch 与报告生成及断点恢复。不适用范围：数据库数据迁移（数据本身的搬迁）、非 SQL 的源码改造。"
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
  version: "2.0.0"
---

# SQL迁移

## 核心原则

- **数据库类型禁止推断（强制约束，优先于一切执行逻辑）**：`SOURCE_DB` / `TARGET_DB` 必须由用户明确提供，任一缺失立即停止执行并向用户询问，不得使用默认值或假设；
- **统一入口**：首次执行与断点恢复只通过 `sql_migration.sh` 进入；重复迁移按 `reset_command` 直接调用 `ai-migration sql-migration migrate --reset`，PREPARE 阶段从 `reports/devkit_path.txt` 复用已就绪的 DevKit/JDK 缓存，跳过环境定位/下载步骤（见「统一入口」与「重复迁移决策」）；
- **AI 与程序职责分离**：AI 只做语义判断与源码修改，不直接写规则库、不生成 Patch、不手工维护分类 JSON；校验、验证与沉淀全部由确定性程序完成（见「AI处理边界」）；
- **不改变源码语义**：只改写 SQL 方言（函数、语法、分页等），严禁修改变量名、控制流和业务逻辑。

## 整体流程

> 环境准备 → SQL 分析与转换 → 残余 SQL AI 适配 → 目标库验证与规则沉淀 → Patch 与报告生成

迁移路线按数据库组合自动选择：`route=A`（DevKit 完整支持，应用 Patch 后再次分析）、`route=B`（DevKit 仅提取，残余 SQL 全部交给 AI）、`route=C`（MySQL → Vastbase，配合专用工具）。

## 输入参数

SQL Skill 对外只接收以下参数：

| 参数 | 说明 | 必填 |
|---|---|---|
| `PROJECT_PATH` | 待迁移源码目录 | 是 |
| `SOURCE_DB` | 源数据库类型（必须由用户提供，禁止推断，见核心原则） | 是 |
| `TARGET_DB` | 目标数据库类型（必须由用户提供，禁止推断，见核心原则） | 是 |
| `WORK_DIR` | SQL迁移工作目录；省略时使用 `$PROJECT_PATH/.devkit-sql-migration/` | 否 |

**动态验证（可选能力）**：`assets/db-connection.json` 的 `source_db_conn.flag`/`target_db_conn.flag` 设 `true` 启用对应库 EXPLAIN 动态验证，未启用则静态分析。**迁移启动前，Agent 先读取当前 flag，再询问用户启用方式（三选项：「已启用，直接开始」期望 flag=true、「启用，需配置」引导用户编辑设 flag=true 并填连接信息、「静态分析」期望 flag=false；Agent 不代编辑敏感信息）。对「已启用」「静态分析」两项，若期望 flag 与当前配置不一致，Agent 必须再次提问确认：「按配置文件执行」（沿用当前 flag 开始）或「修改配置文件」（引导用户编辑 `assets/db-connection.json` 改 flag 至期望值后开始）；一致则直接开始。**（配置方式见该文件内 `_comment`）。迁移结果含 `source_validation_enabled`/`target_validation_enabled` 字段，Agent 展示结果时必须告知实际验证模式，若与用户选择不符需明确提示。SQL Analysis、Java 和内部工具不作为调用参数。

## 统一入口

所有迁移执行（首次执行、断点恢复）都通过统一入口 `sql_migration.sh` 进入：

```bash
bash scripts/sql_migration.sh \
  --project-path "$PROJECT_PATH" \
  --source-db "$SOURCE_DB" \
  --target-db "$TARGET_DB" \
  [--work-dir "$WORK_DIR"]
```

入口脚本负责**环境准备**（`WORK_DIR` 子目录初始化、DevKit 定位或下载、按需 JDK 定位或下载），完成后调用 `ai-migration` 二进制的 `sql-migration migrate` 子命令进入迁移主流程。`ai-migration` 二进制随 DevKit 压缩包分发，路径由 `scripts/download_devkit.sh` 解压后写入 `reports/devkit_path.txt` 的 `AI_MIGRATION` 字段，入口脚本读取后调用；调用时仅显式传入 `--db-config` 一个 SKILL 资源绝对路径（指向 `assets/db-connection.json`），二进制本身不依赖 SKILL 目录结构。`references/ai-sql-transformation.md` 由 Agent 通过 SKILL.md 的 references 指引自行定位读取，`scripts/sql_migration.sh` 由 Agent 通过 SKILL 目录结构自行定位调用，二者均不通过参数注入二进制。迁移主流程只读取入口预置的 `reports/devkit_path.txt` 与 `reports/jdk_path.txt`，不再包含 DevKit/JDK 的定位或下载逻辑。首次执行、断点恢复使用同一入口。重复迁移（`--reset`）由 `reset_command` 直接调用 `ai-migration sql-migration migrate --reset`，PREPARE 阶段复用 `reports/devkit_path.txt` 已就绪的缓存，跳过环境定位/下载步骤；缓存丢失时 PREPARE 失败，由 Agent 引导用户重新调 `sql_migration.sh` 走完整环境准备（见「重复迁移决策」）。

`ai-migration` 二进制只暴露 `sql-migration` 一个子命令，下分 `migrate` / `finalize` 两个子命令区分两种模式（迁移主流程 / AI 阶段收敛），共享 `--db-config` 一个 SKILL 资源参数：

```bash
# 迁移主流程（首次执行 / 断点恢复 / --reset 重跑）
ai-migration sql-migration migrate --project-path ... --source-db ... --target-db ... \
  [--work-dir ...] [--reset] [--internal-resume] \
  --db-config ...

# AI 阶段收敛（WAITING_FOR_AI 后 Agent 调用）
ai-migration sql-migration finalize \
  --work-dir ... --compatible ... --converted ... --manual-review ... \
  --db-config ...
```

Agent 只直接调用入口脚本与 `ai-migration sql-migration finalize`（AI 阶段收敛，见 AI处理边界），不直接调用 `common/`、`stages/`、`tools/` 内部 Python 模块，也不直接调用 `scripts/download_devkit.sh`、`scripts/download_jdk.sh` 等环境准备脚本。这些内部 Python 模块（`sql_migration.py`、`stages/*`、`tools/build_ai_workset.py`、`tools/finalize_ai_stage.py`、`tools/parse_report.py`、`tools/target_sql_validator.py`、`common/*` 等）已封装进 `ai-migration` 二进制，SKILL 目录只保留 `sql_migration.sh` / `download_devkit.sh` / `download_jdk.sh` 三个 shell 入口。

## 执行流程

```text
PREPARE
→ ANALYZE
→ AI_TRANSFORMATION（按需）
→ FINALIZE
→ COMPLETE
```

- `PREPARE`：准备工作目录和源码 `a/b` 副本，读取入口预置环境，确定数据库迁移路线。
- `ANALYZE`：执行 DevKit SQL 分析/转换，生成标准分类结果；DevKit 支持路线（`route=A`）按既有规则应用 DevKit Patch 后再次分析。
- `AI_TRANSFORMATION`：仅当存在残余 SQL 时进入，生成 `reports/ai-workset.json` 并返回 `WAITING_FOR_AI`。
- `FINALIZE`：生成 `source_code.patch`、转换报告路径并生成最终汇总报告。

Agent 不直接调用内部 DevKit、源码复制、Patch 或路径转换实现。

## AI处理边界

`WAITING_FOR_AI` 时，唯一主输入为：

```text
$WORK_DIR/reports/ai-workset.json
```

AI 进入本阶段**必须先完整阅读** [references/ai-sql-transformation.md](references/ai-sql-transformation.md)，按其中「输入边界」、「AI 行为约束」、「AI处理原则」、「目标库动态验证」、「AI 阶段收敛」等章节执行。

## 输出产物

迁移完成后，`$WORK_DIR/reports/` 下生成以下关键产物：

```text
$WORK_DIR/reports/pending_confirm_sql.json
$WORK_DIR/reports/manual_review_report.json
$WORK_DIR/reports/source_code.patch
$WORK_DIR/reports/migration_summary.csv
$WORK_DIR/reports/sql-migration-result.json
```

## 迁移状态

迁移状态记录在 `$WORK_DIR/sql-migration-result.json`，反映当前迁移主流程所处阶段与结果：

- `SUCCESS`：迁移完成且无待确认/人工处理项；
- `COMPLETED_WITH_ACTIONS`：Patch和报告已生成，但仍存在待确认或人工处理项；
- `WAITING_FOR_AI`：等待 AI 处理残余 SQL；
- `WAITING_FOR_USER_DECISION`：迁移已完成，等待用户决定是否重复迁移（见「重复迁移决策」）；
- `BLOCKED`：输入、工具或必要执行条件不满足；
- `FAILED`：非预期执行失败。

## 重复迁移决策（`WAITING_FOR_USER_DECISION`）

`WAITING_FOR_USER_DECISION` 是状态机中的**持久化门禁**：迁移到 COMPLETE 后建立门禁，防止用户/Agent 在未明确选择重复迁移时误触发重跑丢失结果。

到达 COMPLETE 时**始终建立门禁**（state 转为 `WAITING_FOR_USER_DECISION`），但**返回内容分场景**：

- **用户主动发起的首次入口调用**（无 `--reset`、无 `--internal-resume`）：返回询问 payload：
  - `previous_result`：上次迁移的完整结果；
  - `prompt`：询问用户是否重复迁移的提示文案；
  - `reset_command`：带 `--reset` 参数的完整命令，用户选择重复迁移时由 Agent 执行。
- **`ai-migration sql-migration finalize` 接力调用**（带 `--internal-resume`）：直接返回最终迁移结果，**不返回询问 payload**——询问交互留给后续用户主动发起的入口调用。`finalize` 子命令收敛完成后 in-process 调用 `sql_migration.main`（以 `--internal-resume` 形式接力续跑 migrate 模式，不通过命令行转发），Agent 无需关心。
- **`--reset` 重跑**（带 `--reset`，state 中 `reset_run=True`）：用户刚明确选择重复迁移，跑完直接返回最终结果，不询问。

Agent 收到 `WAITING_FOR_USER_DECISION`（仅用户主动发起的首次入口调用会返回此 payload）后**必须立即向用户提问**，提供两个选项，**不预展示 `previous_result`，不主动读取工作目录下的历史产物文件**（reports 等）：

- **查看已有结果**：用户选择后，Agent 从 payload 的 `previous_result` 展示（不读产物文件），并明确告知实际验证模式（`source_validation_enabled`/`target_validation_enabled`），不执行 `reset_command`；
- **重复迁移**：Agent 执行 `reset_command`（`ai-migration sql-migration migrate ... --reset`，复用 `reports/devkit_path.txt` 中已就绪的 `ai-migration` 二进制与 DevKit 缓存），清理工作目录（保留 `downloads/`、`sql-analysis/`、`devkit-sql-migration-cache/` 及 `reports/devkit_path.txt`、`reports/jdk_path.txt` 环境缓存）并从阶段 1 重跑。环境缓存保留使得重跑无需重新定位/下载 DevKit/JDK；若缓存已丢失，PREPARE 失败，由 Agent 引导用户重新调 `sql_migration.sh` 走完整环境准备。

**约束**：

- Agent 不得在首次迁移、断点恢复或其它阶段主动附加 `--reset`；
- Agent 不得自行决定是否重复迁移，必须由用户选择；
- Agent 不得主动附加 `--internal-resume`，该参数仅供 `ai-migration sql-migration finalize` 内部接力调用使用；
- 用户未决策前再次调用主入口（不带 `--reset`）会继续返回 `WAITING_FOR_USER_DECISION`。
