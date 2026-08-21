---
name: java-arm-migration
description: 将本地有源码 Java 项目迁移到 ARM64，完成源码兼容改造、按需 SQL 迁移、重新构建、制品扫描和验证。
metadata:
  version: "2.3.0"
---

# Java 有源码 ARM64 迁移

输入为本地 Java 项目目录。迁移在隔离工作副本中执行，不修改原项目。

## 执行

```bash
python3 scripts/run_migration.py \
  --source <本地Java项目目录> \
  --stage auto
```

主流程分为两个子 Skill：

```text
java-source-migration
  prepare → inspect → baseline → compatibility → sql
                                      ↓
java-build-verification
  build → package_scan → verify
```

所有阶段共用 `<work_dir>/migration-result.json`。`workflow.next_stage` 记录恢复位置，再次执行 `--stage auto` 即可续跑。

## 输入参数

常用可选参数：

```text
--build-command         项目构建命令
--devkit-command        DevKit CLI
--source-db             SQL源数据库类型
--target-db             SQL目标数据库类型
--skip-sql              不执行SQL方言迁移
--verify-command        ARM64运行/验收命令
--architecture-command  架构检查命令，默认 uname -m
```

构建命令未提供时由源码子 Skill根据 Maven、Gradle 或 Ant 项目入口识别。

## SQL 迁移

需要 SQL 适配时只向独立 `sql-migration` Skill提供：

```text
PROJECT_PATH
WORK_DIR
SOURCE_DB
TARGET_DB
```

当前主 Agent直接执行 SQL Skill。结果固定写入 `<WORK_DIR>/reports/`，本 Skill重新执行 `--stage auto` 后自动读取并继续。SQL原结果保持只读；带待办继续时使用 `sql-migration-decision.json` 记录决策和结果/Patch SHA。

## 执行要求

- 基线构建必须成功后才进入兼容改造；
- DevKit源码 findings 必须处理；仅架构热点可通过与当前扫描结果绑定的 `compatibility-review.json` 确认安全；
- 最终构建使用基线阶段确认的同一构建方式；
- 最终 JAR/WAR 必须再次执行 DevKit `pkg-mig`；
- `SUCCESS` 需要 ARM64 架构和运行/验收验证均通过；否则已生成制品时返回 `COMPLETED_WITH_ACTIONS` 并保留待办。

需要外部动作时统一读取 `migration-result.json.action_required`。
