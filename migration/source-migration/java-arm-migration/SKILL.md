---
name: java-arm-migration
description: 将本地有源码 Java 项目迁移到 ARM64，完成源码兼容改造、按需 SQL 迁移、重新构建、制品扫描和 ARM64 架构验证。
metadata:
  version: "2.3.0"
---

# Java 有源码 ARM64 迁移

输入为本地 Java 项目目录。迁移在隔离工作副本中执行，不修改原项目。

## 执行

```bash
python3 scripts/run_migration.py \
  --source <本地Java项目目录>
```

主流程：

```text
java-source-migration
  prepare → inspect → baseline → compatibility → sql
                                      ↓
java-build-verification
  build → package_scan → verify
```

所有阶段共用 `<work_dir>/migration-result.json`。默认 `--stage auto` 根据 `workflow.next_stage` 自动开始或续跑；也可通过 `--stage <阶段>` 从指定受控阶段恢复，并在该阶段成功后继续自动执行后续阶段。

## 输入参数

必填：

```text
--source                本地 Java 项目源码目录
```

可选参数保留 SQL 改造参数，并提供流程级 `--stage` 恢复参数：

```text
--stage                 auto | prepare | inspect | baseline | compatibility | sql | build | package_scan | verify
--source-db             SQL 源数据库类型
--target-db             SQL 目标数据库类型
--skip-sql              不执行 SQL 方言迁移
--enable-sql            清除之前记录的 skip-sql，重新启用 SQL 路由判断
```

`--stage` 默认值为 `auto`。显式阶段表示“从该受控阶段开始/恢复，并继续自动执行后续阶段”，不是无条件跳转；后置阶段会校验必要的前置状态。`--stage build` 是 SQL Skill 完成后的常用恢复场景，会先重新进入 SQL handoff gate，校验 SQL 结果/决策并幂等应用 Patch，再进入 build。除 `--stage` 和 SQL 相关参数外，不再提供构建命令、工作目录、ai-migration 命令、验证命令或架构命令等外部覆盖参数。

阶段门禁：`baseline` 依赖 inspect，`compatibility` 依赖成功 baseline，`sql/build` 依赖成功 compatibility，`package_scan` 依赖成功 final build，`verify` 依赖成功 package scan 和最终制品。`--stage sql` 适合 SQL Skill 完成后重新进入 SQL 收口；`--stage build` 会先做同样的 SQL handoff gate，再开始最终构建。

## ai-migration 工具获取

只通过 `assets/migration-tools.json` 获取 DevKit `ai-migration`：

```json
{
  "migration_tools": [
    {
      "name": "devKit-ai-migration-tool",
      "download_url": "",
      "local_path": ""
    }
  ]
}
```

`download_url` 非空时下载压缩包，仅支持 `.zip`、`.tar`、`.tar.gz`；否则使用 `local_path`。`local_path` 必须为完整绝对路径，可指向包含 `ai-migration` 的本地目录，或 `.zip`、`.tar`、`.tar.gz` 压缩包；不接受相对路径、裸可执行文件或其他格式。两者都为空时直接 `BLOCKED / AI_MIGRATION_TOOL_SOURCE_EMPTY`。

本地目录每次获取时先删除旧工具副本，再完整复制到 `<work_dir>/tools/devKit-ai-migration-tool/payload/`。`.tar/.tar.gz` 解压允许目标仍位于解压根目录内的相对符号链接（包括安全的 `../` sibling 链接），仅拒绝最终目标逃出解压根目录的链接。源码扫描统一执行 `ai-migration porting src-mig ... -r csv`，制品扫描统一执行 `ai-migration porting pkg-mig ... -r csv`，两类兼容扫描都显式只生成 CSV 报告。

源码和制品兼容扫描都显式指定 `-r csv`，只生成 CSV 报告。源码扫码对 `*_zh.csv` 的“修改级别”做确定性分类：`规则项`是必须修复项，进入 `action_required`；`建议项_优化类`、`建议项_规范类`、`建议项_通用类`只保留在最终结果提示中，不触发源码修改。源码扫码 `returncode == 0` 仍直接视为通过，但会在存在中文 CSV 时提取建议项用于最终提示；`returncode != 0` 时只读取 `*_zh.csv`，忽略 `*_en.csv`，只有明确的规则项才返回 `NEEDS_AGENT_FIX`，若只有建议项则继续后续流程。无法完整识别“修改级别”时不会猜测，会返回分类不完整错误。制品扫码继续保持原有的 returncode 处理语义。

## SQL 迁移

需要 SQL 适配时只向独立 `sql-migration` Skill 提供：

```text
PROJECT_PATH
WORK_DIR
SOURCE_DB
TARGET_DB
```

进入 SQL 迁移时会生成 `<work_dir>/sql-handoff.json` 和唯一 `task_id`，并为该任务使用独立 `<work_dir>/sql-migration/<task_id>/` 作为 SQL `WORK_DIR`，避免旧 SQL 结果串入新任务。Java Skill 同时启动 `scripts/sql_resume_controller.py` 持续观察该 task 的 SQL 结果；SQL finalize 为 `SUCCESS` 或 `COMPLETED_WITH_ACTIONS` 后，Controller 自动调用同一 Java 入口 `--stage build`。若 Controller 丢失，后续任意一次 Java 执行都会通过 reconciliation 检测已完成 SQL 并恢复。`COMPLETED_WITH_ACTIONS` 固定采用 `CONTINUE_WITH_PENDING` 自动策略，并把结果/Patch SHA 写入 `sql-migration-decision.json`，待确认项继续保留到最终 `completion_actions`。`--stage build` 仍会先执行 SQL handoff gate 幂等应用 `source_code.patch`。

## 执行要求

- 构建命令只允许根据 Maven、Gradle 或 Ant 标准入口自动识别；无法识别时阻塞。
- 基线构建必须成功后才进入兼容改造。
- 源码扫码只修复 `*_zh.csv` 中“修改级别=规则项”的条目；建议项只在最终结果中提示，不进入修复动作。
- 最终构建使用 baseline 阶段自动确认的同一构建方式。
- 最终 JAR/WAR 必须再次执行 `ai-migration porting pkg-mig`。
- verify 阶段固定执行 `uname -m`；SQL 无待办且 ARM64 架构验证通过时才能 `SUCCESS`。

需要外部动作时统一读取 `migration-result.json.action_required`。最终 `COMPLETED_WITH_ACTIONS` 时该字段必定与 `completion_actions` 一致，不再出现存在 SQL 待办但 `action_required=null` 的状态。


## 最终 Patch 汇总

最终 `migration-result.json.patches` / `result_summary` 固定给出：

```text
reports/source-compatibility.patch   # 仅 compatibility checkpoint 之后、SQL 之前的源码兼容修复
sql-migration/<task_id>/reports/source_code.patch  # 独立 SQL Skill 的源码改造 Patch
reports/final-source-changes.patch   # 从 Java 迁移 Git 基线到最终工作区的全部源码变化
```

`run_migration.py` 完成时的 JSON 汇总也直接输出上述 Patch 地址。
