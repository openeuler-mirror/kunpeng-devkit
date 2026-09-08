# java-arm-migration

用于将本地有源码 Java 项目迁移到 ARM64。Skill 在隔离工作副本中执行，不修改原始项目。

## 使用

```bash
python3 scripts/run_migration.py --source /path/to/project
```

需要 SQL 迁移：

```bash
python3 scripts/run_migration.py \
  --source /path/to/project \
  --source-db MySQL \
  --target-db DM
```

无需 SQL：

```bash
python3 scripts/run_migration.py --source /path/to/project --skip-sql
```

中断后重复执行原命令即可自动续跑；也可用 `--stage <stage>` 显式恢复。

## 流程

```text
prepare
→ inspect
→ baseline
→ compatibility
→ sql
→ build
→ package_scan
→ verify
```

关键行为：

- 自动识别 Maven/Gradle/Ant。
- DevKit 源码和制品扫描固定使用 `-r csv`。
- 源码 CSV 中只有“规则项”需要修复；“建议项_*”只提示。
- `SUCCESS_WITH_SUGGESTIONS` 属于 compatibility 通过状态。
- SQL 使用 task-scoped `WORK_DIR` 和 `sql-handoff.json` 隔离任务。
- SQL 完成后 controller 自动以 `--stage build` 恢复 Java 流程。
- 最终执行制品扫描和 `uname -m` 架构验证。

## 参数

```text
--source       必填，本地 Java 项目目录
--stage        auto|prepare|inspect|baseline|compatibility|sql|build|package_scan|verify
--source-db    SQL 源数据库
--target-db    SQL 目标数据库
--skip-sql     跳过 SQL 迁移
--enable-sql   清除已记录的 skip-sql
```

## DevKit 配置

编辑 `assets/migration-tools.json`：

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

`download_url` 与 `local_path` 至少配置一个。

## 输出

默认工作目录：

```text
~/.java-arm-migration/work/<project-id>/
```

主要文件：

```text
migration-result.json
sql-handoff.json
reports/source-compatibility.patch
sql-migration/<task_id>/reports/source_code.patch
reports/final-source-changes.patch
output/
```

`migration-result.json.action_required` 是统一的后续动作入口。
