---
name: java-arm-migration
description: 将本地有源码 Java 项目迁移到 ARM64，完成源码兼容扫描、按明确路由执行 SQL 迁移、构建、制品扫描和架构验证。
metadata:
  version: "2.3.0"
---

# Java ARM64 迁移

输入一个本地 Java 项目目录。所有修改仅发生在隔离工作副本中，不修改原项目。

## 执行

```bash
python3 scripts/run_migration.py --source <project>
```

主流程固定为：

```text
prepare → inspect → baseline → compatibility → sql → build → package_scan → verify
```

这些阶段是流程不变量，精简 Skill 时不得删除或用“默认成功/默认跳过”替代。其中 `sql` 必须做出明确的 `MIGRATE` 或 `SKIP` 决策；经过 `sql` 阶段不等于已经执行 SQL 迁移。

默认 `--stage auto` 自动开始或续跑。显式 `--stage` 是有前置校验的恢复入口，并会继续执行后续阶段，不是无条件跳转：

```text
--stage auto|prepare|inspect|baseline|compatibility|sql|build|package_scan|verify
```

## SQL 路由

SQL 是必要决策阶段，不得根据项目框架、SQL 文件、历史 config 或未填写参数自行推断为“不需要”。

- 需要数据库迁移：用户必须明确提供 `--source-db <db> --target-db <db>`。
- 明确不需要 SQL 方言迁移：使用 `--skip-sql`。
- 源库与目标库相同：记录为明确 `SKIP`。
- 用户未说明：在 `sql` 阶段返回 `WAITING_FOR_USER / DATABASE_ROUTE_REQUIRED`，取得明确决策后再继续。
- 持久 SQL 路由只认 `<work_dir>/database-route.json`；旧 `migration-config.json` 中的 `skip_sql/source_db/target_db` 均不得决定后续执行。
- `--enable-sql` 仅用于撤销已记录的 `SKIP` 决策，使流程重新要求 SQL 路由。

### SQL Skill handoff 是必须步骤

当路由为 `MIGRATE` 时，Java Skill 会创建 task-scoped SQL 工作目录与 `sql-handoff.json`，随后返回：

```text
WAITING_FOR_SQL / SQL_MIGRATION_REQUIRED
```

此时调用方/Agent **必须真正调用独立 `sql-migration` Skill**，使用 `action_required.inputs`（与 `sql_skill` 相同）的四个参数：

```text
PROJECT_PATH=<work_source>
WORK_DIR=<work_dir>/sql-migration/<task_id>
SOURCE_DB=<source_db>
TARGET_DB=<target_db>
```

`sql_resume_controller.py` 只负责等待 SQL finalize 结果并恢复 Java `--stage build`，**不会替代调用方执行 SQL Skill**。因此：

```text
WAITING_FOR_SQL
→ 调用 sql-migration Skill
→ SQL finalize 生成 sql-migration-result.json/source_code.patch
→ controller --stage build
→ SQL handoff gate 应用 Patch
→ build
```

重复运行 Java 命令不会让 `WAITING_FOR_USER` 或 `WAITING_FOR_SQL` 自行消失；必须先完成对应 `action_required`。

SQL finalize 为 `SUCCESS` 或 `COMPLETED_WITH_ACTIONS` 后允许继续。`COMPLETED_WITH_ACTIONS` 使用 `CONTINUE_WITH_PENDING`，未确认项保留到最终 `action_required/completion_actions`。

## 构建与 DevKit

- 自动识别 Maven、Gradle 或 Ant；baseline 必须成功后才能进入 compatibility。
- final build 使用 baseline 记录的同一构建方式。
- DevKit 只从 `assets/migration-tools.json` 获取；`download_url` 优先，否则使用绝对 `local_path`。两者都为空时 `BLOCKED / AI_MIGRATION_TOOL_SOURCE_EMPTY`。
- 源码和制品扫描统一使用 CSV：

```text
ai-migration porting src-mig ... -r csv
ai-migration porting pkg-mig ... -r csv
```

源码扫描只按 `*_zh.csv` 的“修改级别”处理：

```text
规则项      → 必须修复，进入 action_required
建议项_*    → 不修复，只在最终结果提示
```

`SUCCESS` 与 `SUCCESS_WITH_SUGGESTIONS` 都表示源码 compatibility 已通过。

若 package scan 要求修改源码或依赖，修复后必须重新 `build` 再扫描；不要直接复用旧制品执行 `--stage package_scan`。`action_required.resume_stage` 会指向 `build`。

## 制品与验证

- 最终 JAR/WAR 必须执行 `pkg-mig -r csv`。
- `pkg-mig` 非 0 时只使用 `*_zh.csv` 作为处理依据。
- verify 固定执行 `uname -m`；`aarch64/arm64` 视为当前执行环境架构验证成功。

## 状态与输出

统一状态文件：

```text
<work_dir>/migration-result.json
```

任何等待用户、等待 SQL Skill、需要源码修复或最终有待办的状态，都应以 `action_required` 作为统一外部动作入口。

重要状态：

```text
WAITING_FOR_USER         必须先决定 SQL 路由
WAITING_FOR_SQL          必须调用独立 sql-migration Skill
NEEDS_AGENT_FIX          必须按 action_required 修复并重新进入指定阶段
SUCCESS                  全部必要阶段完成且无待办
COMPLETED_WITH_ACTIONS   自动流程完成，但仍有 SQL/架构待办
```

若 `sql_migration.status == NOT_APPLICABLE`，只能表述为“SQL 路由明确选择 SKIP”，不能表述为“SQL 迁移已执行完成”。

最终 Patch：

```text
<work_dir>/reports/source-compatibility.patch
<work_dir>/sql-migration/<task_id>/reports/source_code.patch
<work_dir>/reports/final-source-changes.patch
```
