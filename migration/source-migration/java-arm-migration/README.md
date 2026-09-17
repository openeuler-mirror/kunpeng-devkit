# java-arm-migration

将本地有源码 Java 项目迁移到 ARM64。Skill 在隔离工作副本中执行，不修改原项目。

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

明确无需 SQL 方言迁移：

```bash
python3 scripts/run_migration.py --source /path/to/project --skip-sql
```

## 固定流程

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

任何精简都不能删除这些必要阶段。`sql` 是必要决策点：必须明确 `MIGRATE` 或 `SKIP`，不能因为没有数据库参数而默认跳过。

### 两个等待状态必须人工/Agent完成动作

`WAITING_FOR_USER / DATABASE_ROUTE_REQUIRED`：明确选择 SQL 路由。

`WAITING_FOR_SQL / SQL_MIGRATION_REQUIRED`：Java Skill 已创建 handoff，但 **SQL 迁移尚未执行**。调用方必须使用输出的 `action_required.inputs` 调用独立 `sql-migration` Skill。Java 的 resume controller 只等待 SQL finalize 并恢复 `--stage build`，不会自己执行 SQL Skill。

因此，重复运行原 Java 命令只能恢复已经满足前置条件的流程，不能自动解决上述等待状态。

## 关键规则

- SQL 路由唯一持久化来源是 `database-route.json`；不继承旧 `migration-config.json` 的 `skip_sql/source_db/target_db`。
- `--enable-sql` 撤销已记录的 SKIP 决策，使流程重新要求 SQL 路由。
- DevKit 源码和制品扫描固定 `-r csv`。
- 源码 CSV：`规则项`必须修复，`建议项_*`仅提示。
- `SUCCESS_WITH_SUGGESTIONS` 属于 compatibility 通过状态。
- package scan 若要求改源码/依赖，修复后必须重新 build 再扫描。
- SQL finalize 完成后 controller 通过 `--stage build` 接力，并先经过 SQL Patch gate。
- 最终必须完成 build、package_scan 和 `uname -m` verify。
- `sql_migration.status=NOT_APPLICABLE` 表示明确 SKIP，不代表执行过 SQL 迁移。

## 参数

```text
--source       必填，本地 Java 项目目录
--stage        auto|prepare|inspect|baseline|compatibility|sql|build|package_scan|verify
--source-db    SQL 源数据库，需与 --target-db 成对提供
--target-db    SQL 目标数据库
--skip-sql     明确记录 SQL 方言迁移不适用
--enable-sql   撤销已记录的 SKIP 决策
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
database-route.json
sql-handoff.json
reports/source-compatibility.patch
sql-migration/<task_id>/reports/source_code.patch
reports/final-source-changes.patch
output/
```

外部动作统一读取 `migration-result.json.action_required`；最终输出同时包含 `sql_migration`，用于明确区分 SQL 实际执行、等待和 SKIP。
