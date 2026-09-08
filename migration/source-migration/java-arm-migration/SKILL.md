---
name: java-arm-migration
description: 将本地有源码 Java 项目迁移到 ARM64，完成源码兼容改造、按需 SQL 迁移、构建、制品扫描和架构验证。
metadata:
  version: "2.3.0"
---

# Java ARM64 迁移

输入一个本地 Java 项目目录。所有修改发生在隔离工作副本中，不修改原项目。

## 执行

```bash
python3 scripts/run_migration.py --source <project>
```

主流程：

```text
prepare → inspect → baseline → compatibility → sql → build → package_scan → verify
```

默认 `--stage auto` 自动开始或续跑。需要显式恢复时可使用：

```text
--stage auto|prepare|inspect|baseline|compatibility|sql|build|package_scan|verify
```

SQL 参数：

```text
--source-db <db>
--target-db <db>
--skip-sql
--enable-sql
```

## 关键规则

### 构建

- 自动识别 Maven、Gradle 或 Ant，不接受外部构建命令覆盖。
- baseline 必须成功后才进入 compatibility。
- final build 使用 baseline 确认的同一构建方式。

### DevKit

工具只从 `assets/migration-tools.json` 获取：

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

`download_url` 优先；否则使用绝对 `local_path`。支持目录、`.zip`、`.tar`、`.tar.gz`。两者都为空时返回 `BLOCKED / AI_MIGRATION_TOOL_SOURCE_EMPTY`。

源码和制品扫描统一生成 CSV：

```text
ai-migration porting src-mig ... -r csv
ai-migration porting pkg-mig ... -r csv
```

源码扫码只读取 `*_zh.csv` 的“修改级别”：

```text
规则项        → 必须修复，进入 action_required
建议项_*      → 不修复，只在最终结果提示
```

`SUCCESS` 和 `SUCCESS_WITH_SUGGESTIONS` 都表示 compatibility 已通过，可继续 SQL/build。

### SQL

需要 SQL 迁移时向独立 `sql-migration` Skill 提供四个参数：

```text
PROJECT_PATH=<work_source>
WORK_DIR=<work_dir>/sql-migration/<task_id>
SOURCE_DB=<source_db>
TARGET_DB=<target_db>
```

Java Skill 写入 `<work_dir>/sql-handoff.json`，并启动 `scripts/sql_resume_controller.py`。SQL finalize 为 `SUCCESS` 或 `COMPLETED_WITH_ACTIONS` 后，controller 自动执行 Java `--stage build`；build 入口先经过 SQL handoff gate，再应用 `source_code.patch`。

`COMPLETED_WITH_ACTIONS` 使用 `CONTINUE_WITH_PENDING`，SQL 待确认项保留到最终 `action_required/completion_actions`。

### 制品与验证

- 最终 JAR/WAR 执行 `pkg-mig -r csv`。
- `pkg-mig` 返回非 0 时仅使用 `*_zh.csv` 作为修复依据。
- verify 固定执行 `uname -m`；`aarch64/arm64` 视为架构验证成功。

## 状态与输出

统一状态文件：

```text
<work_dir>/migration-result.json
```

需要外部处理时读取：

```text
action_required
```

最终 Patch：

```text
<work_dir>/reports/source-compatibility.patch
<work_dir>/sql-migration/<task_id>/reports/source_code.patch
<work_dir>/reports/final-source-changes.patch
```

最终结果为：

```text
SUCCESS                 无剩余待办
COMPLETED_WITH_ACTIONS  已完成自动流程，但仍有 SQL/架构待办
```
