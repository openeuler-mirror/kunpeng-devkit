# Java 源码迁移

阶段：

```text
prepare → inspect → baseline → compatibility → sql
```

状态统一写入顶层 `<work_dir>/migration-result.json`。

## prepare / inspect

`prepare` 将项目复制到默认工作目录 `~/.java-arm-migration/work/<project-id>/workspace/source/`，排除已有构建产物和常见缓存，并建立 Git 基线。项目外符号链接会被拒绝。

`inspect` 只根据 Maven、Gradle 或 Ant 标准入口自动识别构建命令，不接受外部 `build-command` 输入。无法识别时返回 `BLOCKED / BUILD_COMMAND_NOT_DETECTED`，需要先修正或标准化项目构建入口。

## baseline

执行迁移前完整构建。失败时返回：

```text
NEEDS_AGENT_FIX / FIX_BASELINE_BUILD
```

修复后重新执行顶层命令，入口根据 `workflow.next_stage` 自动续跑；基线成功后才进入兼容性检查。

## compatibility

执行 DevKit `ai-migration porting src-mig`，并固定指定 `-r csv` 只生成 CSV 报告。ai-migration 只通过顶层 `assets/migration-tools.json` 获取，不接受命令行覆盖。

源码类型根据工作区实际存在的 `.java` / `.py` / `.scala` 文件动态生成 `-s` 参数；构建验证由 baseline/build 阶段独立完成。

DevKit 源码 CSV 按官方“修改级别”字段分类：

```text
规则项
→ 必须修复
→ 进入 findings / action_required
→ 返回 NEEDS_AGENT_FIX

建议项_优化类 / 建议项_规范类 / 建议项_通用类
→ 不需要修复
→ 不进入 action_required
→ 保留到最终 result_summary.source_scan_advisories
```

`returncode == 0` 仍表示扫码通过；若存在 `*_zh.csv`，仅解析其中建议项用于最终提示，解析失败不改变扫码成功结论。`returncode != 0` 时只读取 `*_zh.csv`、忽略 `*_en.csv`：若存在规则项则要求修复；若只有建议项则 compatibility 记为 `SUCCESS_WITH_SUGGESTIONS` 并继续后续阶段。若 CSV 的规则/建议统计与扫描详情无法按“修改级别”完整对应，返回 `AI_MIGRATION_SOURCE_CSV_CLASSIFICATION_INCOMPLETE`，不会猜测或误把建议项当规则项。

## sql

顶层可选参数包括流程恢复参数 `--stage`，以及 SQL 改造参数 `--source-db`、`--target-db`、`--skip-sql`、`--enable-sql`；SQL Skill 完成后可使用 `--stage sql` 或 `--stage build` 受控恢复。需要迁移时，数据库路线来自这些参数或 `<work_dir>/database-route.json`，并向 `sql-migration` 提供四个参数：

```text
PROJECT_PATH=<work_source>
WORK_DIR=<work_dir>/sql-migration/<task_id>
SOURCE_DB=<source_db>
TARGET_DB=<target_db>
```

SQL 结果固定读取：

```text
<WORK_DIR>/reports/sql-migration-result.json
<WORK_DIR>/reports/source_code.patch

其中 `<WORK_DIR>` 为 task-scoped `<java_work_dir>/sql-migration/<task_id>/`。
```

`SUCCESS` 自动应用 Patch；`COMPLETED_WITH_ACTIONS` 采用固定 `CONTINUE_WITH_PENDING` 策略，自动写入绑定 SQL result/Patch SHA 的 `sql-migration-decision.json` 后继续，并把 pending/manual-review 留到最终 completion_actions。Java 侧使用 `sql-handoff.json + task_id` 隔离任务并启动 resume controller，SQL finalize 后自动触发 `--stage build`。


### SQL Skill 完成后的自动/显式恢复

正常路径由内置 `sql_resume_controller.py` 在 SQL finalize 后自动调用 `--stage build`。如果 watcher 被运行环境中断，默认 `--stage auto` 的 reconciliation 会在下一次 Java 入口执行时恢复。以下命令保留为人工/外部编排的显式恢复入口：

```bash
python3 scripts/run_migration.py --source <project> --source-db <source_db> --target-db <target_db> --stage sql
# 或：--stage build（会先执行 SQL handoff gate）
```

该参数不会绕过 SQL 收口。顶层入口会先调用 SQL stage 验证 task-scoped `sql-migration-result.json`：`SUCCESS` 自动幂等应用 Patch；`COMPLETED_WITH_ACTIONS` 自动生成匹配 SHA 的 `CONTINUE_WITH_PENDING` 决策并应用 Patch。SQL 未完成或 Patch 冲突时停止，不进入 build。Patch 应用对 CRLF/LF 行尾差异使用 `git apply --ignore-space-change --ignore-whitespace` 兼容处理，并保持 `--check` 与实际 apply 参数一致。


源码 compatibility 第一次进入时记录 Git tree checkpoint；扫描修复后首次 `returncode == 0` 时生成 `<work_dir>/reports/source-compatibility.patch`，因此该 Patch 不混入此前 baseline 构建修复，也不混入后续 SQL 改造。
