---
name: migration-target-execution
description: 读取采集 Skill 生成的 migration-plan.json，在鲲鹏目标环境完成预检、目标变更确认、数据库、中间件、Java 应用迁移和验收汇总。
metadata:
  version: "5.4.0"
---

# 鲲鹏目标环境迁移主控 Skill

## 核心原则

- 全流程使用采集阶段交付的同一份 `migration-plan.json`，后续通过固定的 `MIGRATION_PLAN_PATH` 传递。
- 目标预检和用户批准完成后，按 **数据库 → 中间件 → Java 应用** 顺序执行；空路由跳过。
- 任何目标环境修改前必须通过 `verify`；未取得用户批准不得执行目标变更。
- 子模块按自身状态和 `workflow.resume` 执行与恢复，主控不重建其内部状态或迁移路线。

## 整体流程

> **迁移计划检查与预检 → 目标变更确认 → 数据库迁移（按需） → 中间件迁移（按需） → Java 应用迁移（按需） → 验收汇总**

子模块返回等待状态时立即停止当前执行轮，按其状态契约完成外部 Skill、用户确认或 Agent 操作后，再从 `workflow.resume` 恢复。

## 输入与工作目录

唯一业务输入为采集包中的 `migration-plan.json`。进入流程时固定绝对路径：

```bash
export MIGRATION_PLAN_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' /path/to/migration-plan.json)"
```

迁移工作目录为：

```text
<target_environment.migration_work_dir>/<migration_id>
```

执行前遵循 [references/migration-plan-guide.md](references/migration-plan-guide.md)：目标预检只按允许范围更新原计划；目标变更批准后计划保持只读，若计划发生变化必须重新 `prepare` 并取得用户确认。

## 阶段 1：迁移计划检查与目标预检

检查计划并确定需要执行的模块：

```bash
sh scripts/system-migration.sh inspect \
  --migration-plan "$MIGRATION_PLAN_PATH"
```

执行 [migration-precheck/migration-precheck.md](migration-precheck/migration-precheck.md)：

```bash
sh migration-precheck/scripts/run-precheck.sh \
  --plan "$MIGRATION_PLAN_PATH"
```

预检负责目标环境检查、组件包和迁移工具准备、License 检查及允许范围内的计划更新。有阻塞项时停止在本阶段。

## 阶段 2：目标变更确认

生成目标变更清单：

```bash
sh scripts/system-migration.sh prepare \
  --migration-plan "$MIGRATION_PLAN_PATH"
```

向用户展示 `$MIGRATION_WORK_DIR/control/operation-plan.json` 并等待明确决定。批准后执行：

```bash
sh scripts/system-migration.sh approve \
  --migration-plan "$MIGRATION_PLAN_PATH" \
  --decision approve
```

用户拒绝则记录 `reject` 并停止目标环境修改。

## 阶段 3～5：执行迁移模块

每个非空路由执行前先校验批准状态：

```bash
sh scripts/system-migration.sh verify \
  --migration-plan "$MIGRATION_PLAN_PATH"
```

按顺序调用：

| 路由 | 子模块 |
|---|---|
| `route.database` | [database-migration/database-migration.md](database-migration/database-migration.md) |
| `route.middleware` | [middleware-migration/middleware-migration.md](middleware-migration/middleware-migration.md) |
| `route.application` | [java-application-migration/java-application-migration.md](java-application-migration/java-application-migration.md) |

对应路由为空时直接跳过。子模块的具体命令、暂停状态、用户确认和恢复方式以其文档及运行结果为准。

Java 组件的输入制品由其入口根据 `packages[].local_path` 确定性解析；调用方不使用 `find` / `glob` 重新选择同名制品。Java 组件请求独立 SQL Skill 或 Agent 验证时，完成外部动作后必须先按该组件 `workflow.resume` 恢复，由 Java 迁移程序消费结果并决定下一状态。

## 阶段 6：验收汇总

读取各子模块原生结果形成最终结论：

| 模块 | 主要结果 |
|---|---|
| 目标预检 | `precheck/migration-plan-report.md` |
| 数据库 | 数据库子 Skill 的部署、迁移和验证结果 |
| 中间件 | `middleware/reports/batch_migration_summary.json`、`batch_migration_summary.md` |
| Java 应用 | 各组件 `migration-result.json`、`reports/application-verification.md` |

Java 应用只有静态迁移和目标环境验证都满足成功条件时才能归并为完全成功。统计时区分：

- `source_change_summary`：源码改造文件；
- `artifact_change_report.summary`：候选 JAR/WAR 制品层变化条目。

不得用制品变化数量替代源码文件统计。根 Skill 保留子模块原生结果，不要求转换为统一结果 schema。

## 调起与恢复

- 根 Skill 负责阶段顺序、目标变更确认和最终汇总；子模块负责自身迁移逻辑和状态。
- `WAITING_FOR_SKILL`、`WAITING_FOR_USER`、`WAITING_FOR_AGENT` 等等待状态均按子模块返回的契约处理。
- 外部动作完成后优先执行已有 `workflow.resume`，不重新发现 Skill、输入制品、工作目录或迁移路线。
- 根 Skill 只维护 `operation-plan.json` 和 `migration-approval.json` 两个目标变更确认文件，不直接修改子模块核心状态。
