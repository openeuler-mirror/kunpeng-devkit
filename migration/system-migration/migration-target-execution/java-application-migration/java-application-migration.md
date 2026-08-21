# Java 无源码应用迁移

## 核心原则

- 每个 JAR/WAR 组件统一通过 `migrate_application.py --stage auto` 执行和恢复。
- 输入制品只根据 `packages[].local_path` 确定性解析，`install_location` 仅作为部署参考，不使用 `find` / `glob` 重新选择同名制品。
- 迁移按 **prepare → compatibility → decompile → sql → compile → repackage** 串行推进；DevKit 只对迁移前输入组件执行一次。
- 等待 SQL Skill、用户确认或 Agent 处理时，以组件返回的 `workflow.resume` 恢复。
- SQL `COMPLETED_WITH_ACTIONS` 必须取得用户真实决定后才能继续；候选制品生成不等于目标环境启动验证成功。

## 整体流程

> **准备组件 → 兼容性分析 → 按需反编译 → SQL 适配与确认 → 重新编译 → 重新打包 → 目标环境启动验证**

不需要 SQL 适配时，按程序当前路线跳过反编译、SQL 和重新编译处理。

## 输入与入口

输入来自 `migration-plan.json` 的 `route.application[].packages[]`。主要参数：

- `application-id`：应用 ID；
- `package-id`：JAR/WAR 组件 ID；
- `packages[].local_path`：实际输入制品。

统一入口：

```bash
python3 java-application-migration/scripts/migrate_application.py \
  --plan "${MIGRATION_PLAN_PATH:?请先完成目标预检并导出 MIGRATION_PLAN_PATH}" \
  --application-id <application-id> \
  --package-id <package-id> \
  --stage auto
```

输入无效时返回 `INPUT_INCOMPLETE`；迁移开始后输入包发生变化时阻塞当前组件，并使用新的迁移工作目录重新执行。

## 迁移阶段

| 阶段 | 行为 |
|---|---|
| `prepare` | 解析应用和组件，确定输入 JAR/WAR，创建组件工作目录。 |
| `compatibility` | 对输入组件执行一次 DevKit `porting pkg-mig`；需要人工修复时返回 `NEEDS_AGENT_FIX / FIX_PACKAGE_COMPATIBILITY`。 |
| `decompile` | 仅在需要 SQL 适配时解包、反编译并准备 SQL 工作区。 |
| `sql` | 调用独立 SQL Skill，消费其结果并按需进入用户确认。 |
| `compile` | 重新编译发生修改的 Java 源码；无法自动处理时返回 `NEEDS_AGENT_FIX / FIX_DECOMPILED_SOURCE_COMPILE`。 |
| `repackage` | 重建 JAR/WAR，生成候选制品、源码变化统计和制品变化报告。 |

候选制品不再执行第二次 DevKit 分析。脚本阶段返回 `NEEDS_AGENT_FIX` 时，Agent 只处理 `action_required` 指定的问题，完成后执行 `workflow.resume`。

## SQL 适配与用户确认

需要 SQL 适配时，从 `migration-result.json.sql_skill` 读取：

```text
PROJECT_PATH
WORK_DIR
SOURCE_DB
TARGET_DB
```

调用独立 SQL Skill：

```bash
bash <sql-migration>/scripts/sql_migration.sh \
  --project-path "$PROJECT_PATH" \
  --work-dir "$WORK_DIR" \
  --source-db "$SOURCE_DB" \
  --target-db "$TARGET_DB"
```

固定结果：

```text
<WORK_DIR>/reports/sql-migration-result.json
<WORK_DIR>/reports/source_code.patch
```

SQL Skill 返回终态后，**先执行当前组件 `workflow.resume`**，由 Java 迁移程序消费结果：

- `SUCCESS`：应用 Patch 后继续；
- `COMPLETED_WITH_ACTIONS`：进入 `WAITING_FOR_USER / SQL_MIGRATION_CONFIRMATION`；
- 其他未完成状态：保持 SQL 阶段。

SQL Patch 由应用迁移内部处理，Agent 不手工复制。

`WAITING_FOR_USER` 时当前执行轮结束，必须等待用户真实回复；选项保持中性、不设置默认推荐。继续时执行：

```bash
python3 java-application-migration/scripts/sql_decision.py \
  --plan "$MIGRATION_PLAN_PATH" \
  --application-id <application-id> \
  --package-id <package-id> \
  --decision continue \
  --decision-source USER
```

拒绝使用 `--decision reject --decision-source USER`。缺少 `decision_source=USER` 的自动或历史决策不得消费。

## 重新打包输出

生成：

```text
<组件工作目录>/output/<name>-kunpeng-arm64.jar|war
<组件工作目录>/reports/artifact-change-report.json
<组件工作目录>/reports/artifact-change-report.md
```

结果中：

- `source_change_summary` 表示 Patch 工作区实际变化的源码文件；
- `artifact_change_report.summary` 表示最终 JAR/WAR 制品层变化条目。

二者不得混用。完成后进入：

```text
status = WAITING_FOR_AGENT
stage = APPLICATION_VERIFICATION
reason_code = VERIFY_APPLICATION_STARTUP
```

此时 `migration_completion.static_migration.status = SUCCESS`，只表示候选制品已生成，不表示应用启动成功。

## 目标环境启动验证

启动验证由 Agent 使用目标环境真实运行时和部署方式执行，不存在脚本 `verify` stage。

### 上下文与停止条件

优先使用：

1. `migration-plan.json`、当前组件 `migration-result.json` 和 `action_required`；
2. 已完成的数据库、中间件等前序迁移结果；
3. 与已知产品、服务、路径相关的一次定向检查；
4. 必要时用 `systemctl`、`ps`、`ss` 和有限目录做一次有界补充探测。

出现以下任一情况停止扩大探测：必要运行依赖确认缺失、已定位明确启动失败原因、仍无法确定真实部署方式，或已有足够证据判定 `SUCCESS` / `NEEDS_AGENT_FIX` / `BLOCKED`。有界探测后仍无法确定真实部署方式时询问用户，不继续扩大搜索。

不得从全盘 `find /` 开始，不猜测启动命令或替代运行时；不得使用迁移工具目录中的 JDK 代替目标应用运行时；`which` / PATH 不能单独证明软件未安装。

### 启动与验证

- WAR 使用目标 Servlet 容器/应用服务器的真实部署方式，不使用 `java -jar`；
- 可执行 JAR 结合 MANIFEST、实际 service/script 和部署配置启动；
- 非独立 JAR 按真实宿主或加载方式验证。

至少检查目标架构、部署方式、应用启动、进程/服务/容器、端口或 health、启动日志。涉及数据库或 SQL 迁移时，条件允许则增加数据库连接或 SQL smoke。

### 验证结果

Agent 只写：

```text
<组件工作目录>/reports/application-verification-result.json
```

最小结构：

```json
{
  "status": "SUCCESS | NEEDS_AGENT_FIX | BLOCKED",
  "summary": "验证结论",
  "evidence": [],
  "missing_dependencies": [],
  "failed_checks": [],
  "unverified_checks": []
}
```

写完后执行组件 `workflow.resume`。程序生成 `reports/application-verification.md` 并更新 `migration-result.json` 和 `migration_completion.target_environment_verification`；Agent 不直接修改核心状态 JSON。

结果映射：

- `SUCCESS`：无待办时最终 `SUCCESS`，仍有待办时 `COMPLETED_WITH_ACTIONS`；
- `NEEDS_AGENT_FIX`：进入 `FIX_APPLICATION_STARTUP`，修复后重新验证；
- `BLOCKED`：记录缺失条件，条件补齐后重新验证。

## 状态与恢复

| 状态 | 含义 |
|---|---|
| `WAITING_FOR_SKILL` | 等待 SQL Skill |
| `WAITING_FOR_USER` | 等待用户确认 SQL 结果 |
| `NEEDS_AGENT_FIX` | 当前阶段需要 Agent 修复 |
| `WAITING_FOR_AGENT` | 等待目标环境启动验证 |
| `BLOCKED` / `FAILED` | 当前组件无法继续 |
| `SUCCESS` | 静态迁移和启动验证均成功，且无待办 |
| `COMPLETED_WITH_ACTIONS` | 启动验证成功，但仍有明确待办 |

外部动作完成后直接执行当前组件 `workflow.resume` 中给出的入口和参数，不重新搜索 Skill、输入制品或迁移路线。一个组件的状态和输出不覆盖同应用的其他组件。
