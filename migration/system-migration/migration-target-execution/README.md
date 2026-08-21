# migration-target-execution

## 简介

`migration-target-execution` 用于读取源端采集生成的正式 `migration-plan.json`，在鲲鹏 ARM64 目标环境中按固定顺序完成目标预检、目标变更确认、数据库迁移、中间件迁移、Java应用迁移和最终验收汇总。

该顶层 Skill 采用迁移指导模式：负责模块顺序、进入条件和变更确认，不建立额外的跨模块业务状态机。数据库、中间件和 Java 应用由各自子 Skill 保持原有执行流程和原生结果。

## 功能特性

- 唯一业务输入为同一份 `migration-plan.json`。
- 根据 `migration_id` 和 `target_environment.migration_work_dir` 建立统一目标迁移工作目录。
- 目标预检检查 ARM64 环境并准备数据库、中间件安装包、迁移工具和 License。
- 目标预检只在允许字段范围内更新原 `migration-plan.json`。
- 根据计划生成轻量 `operation-plan.json`，在实际修改目标环境前要求用户明确确认。
- 用户批准后生成 `migration-approval.json`，并在各目标修改模块执行前校验计划一致性。
- 固定执行顺序：数据库 → 中间件 → Java应用。
- `route.database`、`route.middleware`、`route.application` 为空时自动跳过对应模块。
- Java无源码应用基于采集的 JAR/WAR 组件执行；需要 SQL 适配时调用独立 `sql-migration` Skill。
- 最终直接读取各子 Skill 原生结果进行验收汇总，不强制转换为统一 result schema。

## 适用场景

- 已完成 x86 源系统采集，并取得正式 `migration-plan.json`。
- 需要在鲲鹏 ARM64 目标环境执行数据库、中间件和 Java 应用迁移。
- 需要统一准备安装包、迁移工具和 License，再执行目标环境修改。
- 需要在目标修改前向用户展示迁移对象和路线并取得批准。
- 需要对多个迁移模块按依赖顺序执行并汇总原生验收结果。

## 前置条件

- 已取得 `migration-source-collector` 生成并校验通过的 `migration-plan.json` 及其引用制品。
- 当前主机为 ARM64/aarch64 目标环境，或可在该目标环境执行 Skill。
- 具备目标迁移所需的 root 权限或可用的免密 sudo 权限。
- `migration-plan.json` 中 `target_environment.migration_work_dir` 已配置可用基础路径。
- 计划引用的本地组件包、工具包和采集 JAR/WAR 可访问；需要下载的包具有可用来源。
- 数据库或中间件需要 License 时，用户能够按预检提示上传对应 License 文件。
- `migration-plan.json` 与目标迁移工作目录需要满足原子更新的文件系统要求。

## Skill 目录结构

```text
migration-target-execution/
├── SKILL.md
├── README.md
├── prompt.md
├── references/
│   └── migration-plan-guide.md
├── assets/
│   └── schemas/
│       ├── operation-plan.schema.json
│       └── migration-approval.schema.json
├── scripts/
│   ├── system-migration.sh           # 顶层控制命令
│   ├── migration_control.py
│   └── migration_plan.py
├── migration-precheck/               # 目标环境预检
│   ├── migration-precheck.md
│   └── scripts/run-precheck.sh
├── database-migration/               # 数据库迁移子Skill
│   ├── information-collection/
│   ├── database-deploy/
│   └── data-migration/
├── middleware-migration/             # 中间件迁移子Skill
└── java-application-migration/        # JAR/WAR无源码应用迁移
    └── java-application-migration.md
```

## 使用方式

顶层执行先固定迁移计划路径并检查计划：

```bash
export MIGRATION_PLAN_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' /path/to/migration-plan.json)"
sh scripts/system-migration.sh inspect \
  --migration-plan "$MIGRATION_PLAN_PATH"
sh migration-precheck/scripts/run-precheck.sh \
  --plan "$MIGRATION_PLAN_PATH"
```

之后按 Skill 流程执行：

```text
目标预检
→ prepare生成operation-plan.json
→ 用户确认
→ approve
→ 数据库/中间件/Java应用按需执行
→ 验收汇总
```

用户确认目标变更后，每个会修改目标环境的模块执行前需要通过：

```bash
sh scripts/system-migration.sh verify \
  --migration-plan "$MIGRATION_PLAN_PATH"
```

如果批准后 `migration-plan.json` 或 `operation-plan.json` 被修改，需要重新生成变更清单并再次确认。

## 工作流程

```text
migration-plan.json
        ↓
inspect
校验计划并初始化MIGRATION_WORK_DIR
        ↓
目标预检 migration-precheck
环境事实 / 安装包 / 工具 / License
        ↓
prepare
生成 operation-plan.json
        ↓
用户明确确认目标变更
        ↓
approve
生成 migration-approval.json
        ↓
route.database 非空？
 ├─ 是 → verify → 数据库迁移
 └─ 否 → 跳过
        ↓
route.middleware 非空？
 ├─ 是 → verify → 中间件迁移
 └─ 否 → 跳过
        ↓
route.application 非空？
 ├─ 是 → verify → Java应用迁移 → Agent应用启动验证
 └─ 否 → 跳过
        ↓
读取各子Skill原生结果
        ↓
验收汇总
```

数据库、中间件、Java应用的固定顺序用于保证应用迁移执行前目标依赖已处理。

## 输出产物

统一运行目录：

```text
<target_environment.migration_work_dir>/<migration_id>/
```

主要目录和产物：

```text
<MIGRATION_WORK_DIR>/
├── control/
│   ├── operation-plan.json
│   └── migration-approval.json
├── precheck/
│   └── migration-plan-report.md 等预检产物
├── packages/
├── licenses/
├── tools/
├── database/
│   └── 数据库部署/数据迁移原生报告
├── middleware/
│   └── batch_migration_summary.json
└── applications/
    └── <application-id>/packages/<package-id>/
        ├── migration-result.json
        └── reports/
            ├── artifact-change-report.json
            └── artifact-change-report.md
```

根 Skill 不额外生成统一 `result.json`。最终验收直接基于：

- 预检 `migration-plan-report.md`；
- 数据库 `deploy_summary_*.json`、`deploy_report_*.md` 及数据迁移报告；
- 中间件 `batch_migration_summary.json`；
- Java应用各组件 `migration-result.json` 及最终制品变更报告 `artifact-change-report.json/.md`。Java组件结果中的 `migration_completion` 分别记录静态迁移和目标环境验证状态。

## 常见问题

### 1. 可以直接拿一个手工编写的 migration-plan.json 执行吗？

应使用源端采集 Skill 按正式模板生成并校验通过的计划。目标执行会依赖其中的 `migration_id`、迁移路线、组件包、工具包和应用制品信息。

### 2. 为什么预检后还要进行目标变更确认？

预检主要验证目标环境和准备执行条件；真正安装数据库、中间件或处理应用前，需要把实际迁移对象和路线展示给用户确认。

### 3. 用户批准以后还能修改 migration-plan.json 吗？

批准后目标执行计划进入保护状态。若计划或变更清单发生变化，`verify` 会阻止继续修改目标环境，需要重新 `prepare` 和确认。

### 4. 某类组件不存在时是否还会执行对应子 Skill？

不会。`route.database`、`route.middleware` 或 `route.application` 为空时直接跳过对应模块。

### 5. Java应用为什么会返回 `WAITING_FOR_AGENT`？

`migrate_application.py` 完成 `repackage` 和制品变更报告后进入 `WAITING_FOR_AGENT / VERIFY_APPLICATION_STARTUP`。应用启动验证由当前主 Agent 按 `java-application-migration/java-application-migration.md` 在目标 ARM64 环境实际部署和启动候选制品；Agent 只写 `reports/application-verification-result.json`，随后按 `workflow.resume` 回到当前组件，由程序生成 `application-verification.md` 并更新 `migration-result.json`。该阶段不增加 `verify` 脚本 stage，也不再执行第二次 DevKit 分析。

### 6. Java应用为什么可能返回 `COMPLETED_WITH_ACTIONS`？

Agent 已完成目标环境启动验证，但 SQL 仍有 `pending_confirm/todo/manual_review` 或其他明确待办时返回该状态。Java组件通过 `migration_completion.static_migration` 和 `migration_completion.target_environment_verification` 分别记录候选制品和目标环境启动验证两个维度。

### 7. Java应用调用 SQL Skill 后如何恢复？

恢复目标由组件 `migration-result.json.workflow.resume` 持久化。SQL完成后继续原 `java-application-migration` 组件的 `--stage auto`，不重新判断或切换到 `java-arm-migration`。
SQL Skill 返回 `SUCCESS/COMPLETED_WITH_ACTIONS` 后先恢复当前 Java 组件一次，使调用方状态与用户交互一致；只有组件正式返回 `WAITING_FOR_USER` 后才展示确认。输入 JAR/WAR 由组件入口按 `packages[].local_path` 解析，不额外搜索同名文件。

### 8. 根 Skill 是否维护数据库、中间件和应用的统一状态文件？

不维护。根 Skill只保留目标变更确认相关的 `operation-plan.json` 和 `migration-approval.json`，各子 Skill 保留自身原生状态和报告。
