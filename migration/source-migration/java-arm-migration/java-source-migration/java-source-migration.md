# Java 源码迁移

阶段：

```text
prepare → inspect → baseline → compatibility → sql
```

状态统一写入顶层 `<work_dir>/migration-result.json`。

## prepare / inspect

`prepare` 将项目复制到 `<work_dir>/workspace/source/`，排除已有构建产物和常见缓存，并建立 Git 基线。项目外符号链接会被拒绝。

`inspect` 识别 Maven、Gradle 或 Ant 构建入口；无法确定时通过 `action_required.type=PROVIDE_BUILD_COMMAND` 要求提供 `--build-command`。

## baseline

执行迁移前完整构建。失败时返回：

```text
NEEDS_AGENT_FIX / FIX_BASELINE_BUILD
```

修复后重新 `--stage auto`，基线成功后才进入兼容性检查。

## compatibility

执行 DevKit `porting src-mig`，并检查架构敏感源码及项目内原生库。DevKit findings 必须修复后重扫。

仅存在需要人工判断的架构热点时，可写：

```json
{
  "decision": "PASS_REVIEW",
  "review_sha256": "<migration-result.json中的review_sha256>"
}
```

到 `<work_dir>/compatibility-review.json`。源码或扫描结果变化后旧确认失效。

## sql

不需要 SQL 迁移时记录 `NOT_APPLICABLE`。需要迁移时，数据库路线来自参数或 `<work_dir>/database-route.json`，并向 `sql-migration` 提供四个参数：

```text
PROJECT_PATH=<work_source>
WORK_DIR=<work_dir>/sql-migration
SOURCE_DB=<source_db>
TARGET_DB=<target_db>
```

SQL结果固定读取：

```text
<WORK_DIR>/reports/sql-migration-result.json
<WORK_DIR>/reports/source_code.patch
```

`SUCCESS` 自动应用 Patch；`COMPLETED_WITH_ACTIONS` 等待 `sql-migration-decision.json` 的 `CONTINUE_WITH_PENDING`，校验结果和 Patch SHA 后继续。
