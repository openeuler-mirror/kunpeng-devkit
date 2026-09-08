# java-arm-migration

## 简介

`java-arm-migration` 用于将**本地有源码 Java 项目**迁移到 ARM64 环境。Skill 在隔离工作副本中完成项目识别、基线构建、源码兼容性分析、按需 SQL 迁移、最终构建、JAR/WAR 制品扫描以及 ARM64 架构验证，不直接修改原始项目目录。

顶层执行入口为 `scripts/run_migration.py`。所有阶段共用 `<work_dir>/migration-result.json`。默认 `--stage auto` 按 `workflow.next_stage` 自动执行或续跑；也可以通过 `--stage` 从指定受控阶段恢复。

## 功能特性

- 支持 Maven、Gradle、Ant Java 项目构建入口自动识别。
- 自动创建隔离工作副本和 Git 基线，保护原始源码。
- 基线构建通过后再进入兼容性改造，避免把原有构建问题混入迁移问题。
- 使用 DevKit `ai-migration porting src-mig` 进行源码兼容性检查。
- DevKit 源码/制品兼容扫描固定指定 `-r csv`，只生成 CSV 报告；扫码严格按 `returncode` 判断：0 直接通过；非 0 时只读取 `*_zh.csv` 作为修复依据，完全忽略 `*_en.csv`。
- 检查项目中的架构敏感代码和原生库。
- 按需调用独立 `sql-migration` Skill，只传递 `PROJECT_PATH`、`WORK_DIR`、`SOURCE_DB`、`TARGET_DB` 4 个参数。
- 迁移完成后重新构建，并对最终 JAR/WAR 执行 `ai-migration porting pkg-mig` 扫描。
- 固定使用 `uname -m` 完成 ARM64 架构验证。
- 支持中断后自动续跑和 `--stage` 受控恢复；SQL 阶段使用 task-scoped handoff + 本地 resume controller，SQL finalize 后自动触发 `--stage build`，同时保留 reconciliation 兜底。

## 对外输入参数

必填参数只有项目源码目录：

```text
--source                本地 Java 项目源码目录
```

可选参数保留 SQL 改造参数，并增加流程级 stage 参数：

```text
--stage                 auto | prepare | inspect | baseline | compatibility | sql | build | package_scan | verify
--source-db             SQL 源数据库类型
--target-db             SQL 目标数据库类型
--skip-sql              明确不执行 SQL 方言迁移
--enable-sql            清除之前记录的 skip-sql，重新启用 SQL 路由判断
```

`--stage` 默认是 `auto`。显式指定阶段时，从该阶段开始/恢复，并在成功后自动继续后续阶段；每个后置阶段都有前置状态校验，不能借助 stage 参数绕过 baseline、compatibility、SQL、build 或 package scan 等必要步骤。仍不提供 `work-base`、`build-command`、`ai-migration-command`、`verify-command`、`architecture-command` 等外部覆盖参数。

`--stage` 语义：

| 值 | 行为 | 关键门禁 |
|---|---|---|
| `auto` | 根据 `workflow.next_stage` 自动开始/续跑 | 默认模式 |
| `prepare` | 从 prepare 开始并继续后续流程 | 无额外门禁 |
| `inspect` | 从项目识别开始并继续 | 工作区由入口创建/复用 |
| `baseline` | 重新执行基线构建并继续 | 必须已有 inspect 识别结果 |
| `compatibility` | 重新执行源码兼容性扫描并继续 | baseline 必须成功 |
| `sql` | 进入/恢复 SQL handoff，并在收口成功后继续 build | compatibility 必须成功 |
| `build` | 从最终构建恢复 | compatibility 必须成功；先执行一次 SQL handoff gate |
| `package_scan` | 重新扫描当前最终 JAR/WAR 并继续 verify | final build 必须成功，SQL 路由必须一致 |
| `verify` | 重新执行最终验证 | package scan 必须成功且已有最终制品 |

## 前置条件

- 待迁移项目必须是本地可访问的 Java 项目目录。
- Python 3 可用。
- Git 可用，用于建立隔离工作副本的迁移基线。
- 项目自身的 Maven、Gradle 或 Ant 构建入口及依赖可用；构建命令由 Skill 自动识别。
- DevKit `ai-migration` 工具通过 `assets/migration-tools.json` 获取。
- 如需 SQL 迁移，需要提供源数据库和目标数据库类型，或由 `<work_dir>/database-route.json` 提供数据库路由。

## ai-migration 工具获取

`assets/migration-tools.json` 固定包含 `devKit-ai-migration-tool`：

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

获取规则：

1. 只读取 `assets/migration-tools.json`，不再接受命令行参数或环境变量覆盖 `ai-migration` 命令。
2. `download_url` 非空时优先下载，仅支持 `.zip`、`.tar`、`.tar.gz` 压缩包；下载后解压到 `<work_dir>/tools/devKit-ai-migration-tool/` 并递归查找 `ai-migration`。
3. `download_url` 为空时使用 `local_path`。`local_path` 必须是完整绝对路径，可指向包含 `ai-migration` 的本地工具目录，也可指向 `.zip`、`.tar`、`.tar.gz` 压缩包；不接受相对路径、裸可执行文件或其他压缩格式。
4. `local_path` 为目录时，每次获取都会先清理工作目录中的旧工具副本，再完整复制到 `<work_dir>/tools/devKit-ai-migration-tool/payload/`。
5. `download_url` 与 `local_path` 都为空时直接 `BLOCKED / AI_MIGRATION_TOOL_SOURCE_EMPTY`。
6. `.tar/.tar.gz` 工具包中的相对符号链接按“最终解析目标是否仍在解压根目录内”判断安全性；安全的 `../` sibling 链接允许解压，真正越界的链接仍拒绝。
7. 源码扫描统一执行 `ai-migration porting src-mig ... -r csv`；制品扫描统一执行 `ai-migration porting pkg-mig ... -r csv`，显式只生成 CSV 报告。
8. DevKit 源码/制品扫描统一以 `returncode` 为准：0 直接进入后续步骤；非 0 时仅使用 `*_zh.csv` 作为修复依据并进入修复流程。

## 使用方式

最简执行：

```bash
python3 scripts/run_migration.py \
  --source /path/to/java-project
```

需要 SQL 改造时：

```bash
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --source-db mysql \
  --target-db openGauss
```

明确无需 SQL 改造时：

```bash
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --skip-sql
```

同一项目普通中断可再次执行同一条命令，由默认 `--stage auto` 自动续跑。需要明确恢复点时，可显式指定 `--stage`。正常情况下 SQL finalize 后由内置 `sql_resume_controller.py` 自动执行 `--stage build`；`--stage sql` / `--stage build` 仍可作为人工或外部编排恢复入口，并执行相同 SQL handoff gate。
SQL Skill 完成后的两个推荐恢复方式：

```bash
# 重新进入 SQL 阶段，读取独立 SQL Skill 的结果，成功后自动继续 build/package_scan/verify
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --source-db mysql \
  --target-db openGauss \
  --stage sql

# 或直接以 build 作为恢复点；内部仍会先执行一次 SQL handoff gate
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --source-db mysql \
  --target-db openGauss \
  --stage build
```

`--stage build` **不是无条件跳过 SQL**。入口会先读取 SQL 迁移结果、校验待办决策，并幂等应用 `source_code.patch`；只有 SQL 收口成功后才继续 `build → package_scan → verify`。其它 stage 同样有前置门禁，例如 `package_scan` 必须已有成功 build，`verify` 必须已有成功 package scan 和最终制品。


## 工作流程

```text
本地Java项目
    ↓
prepare
创建隔离工作副本和Git基线
    ↓
inspect
自动识别Maven/Gradle/Ant构建入口
    ↓
baseline
迁移前完整构建
    ↓
compatibility
ai-migration源码扫描与ARM64兼容改造
    ↓
sql
按需调用独立sql-migration
    ↓
build
迁移后重新构建
    ↓
package_scan
最终JAR/WAR执行ai-migration porting pkg-mig
    ↓
verify
固定执行uname -m进行ARM64架构验证
    ↓
SUCCESS / COMPLETED_WITH_ACTIONS
```

## 输出产物

主要产物位于默认工作目录 `~/.java-arm-migration/work/<project-id>/`：

```text
<work_dir>/
├── migration-result.json
├── workspace.json
├── workspace/source/
├── sql-handoff.json
├── reports/
│   ├── ai-migration-source/
│   ├── ai-migration-package/
│   ├── source-compatibility.patch
│   └── final-source-changes.patch
├── output/
└── sql-migration/
    └── <task_id>/
        ├── sql-task.json
        └── reports/source_code.patch
```

最终状态：

- `SUCCESS`：迁移、制品扫描、SQL 状态和 ARM64 架构验证均满足完成条件。
- `COMPLETED_WITH_ACTIONS`：已生成候选制品，但仍有 SQL 或 ARM64 架构验证待办；`action_required` 与 `completion_actions` 会同步给出这些未完成动作。
- 其他等待、修复或阻塞状态：根据 `action_required`、`sql_skill` 和 `workflow` 继续处理。

## 常见问题

### 1. 为什么不直接修改原项目？

Skill 会把项目复制到独立工作区并建立 Git 基线，迁移修改只发生在工作副本中。

### 2. 项目构建方式识别失败怎么办？

项目必须提供可识别的 Maven、Gradle 或 Ant 标准构建入口；无法识别时返回 `BLOCKED / BUILD_COMMAND_NOT_DETECTED`，需要先修正或标准化项目构建入口后再执行 Skill。

### 3. 基线构建失败后会继续迁移吗？

不会。基线构建失败返回 `NEEDS_AGENT_FIX / FIX_BASELINE_BUILD`，修复工作副本中的原有构建问题后重新执行同一条顶层命令即可续跑。

### 4. SQL 迁移是否属于本 Skill 内部实现？

不是。需要 SQL 适配时，本 Skill 仍向独立 `sql-migration` Skill提供四参数接口，但 `WORK_DIR` 是 `<work_dir>/sql-migration/<task_id>/`。Java 侧持久化 `sql-handoff.json` 并启动 resume controller；SQL finalize 后自动唤醒 Java `--stage build`。Controller 异常丢失时，下一次 Java 入口执行会 reconciliation 后继续。

### 5. 为什么最终状态是 `COMPLETED_WITH_ACTIONS`？

通常表示仍有 SQL 待确认，或当前执行环境不是 ARM64。具体原因查看 `migration-result.json.action_required` 和 `completion_actions`；两者不会再出现一个为空、另一个有待办的不一致。源码兼容扫描中的 DevKit 建议项不属于待办，可在 `result_summary.source_scan_advisories` 查看。


## SQL 自动唤醒与任务隔离

进入 SQL 阶段后，Java Skill 创建唯一 `task_id` 与 `<work_dir>/sql-handoff.json`。SQL Skill 的四参数接口保持不变，但 `WORK_DIR` 指向 `<work_dir>/sql-migration/<task_id>/`。内置 `scripts/sql_resume_controller.py` 以独立进程观察该 task 的 `reports/sql-migration-result.json`：

- `SUCCESS`：自动调用 Java `--stage build`；
- `COMPLETED_WITH_ACTIONS`：自动生成绑定结果/Patch SHA 的 `CONTINUE_WITH_PENDING` 决策后调用 `--stage build`，pending/manual-review 继续进入最终待办汇总；
- `FAILED/BLOCKED`：记录 `SQL_FAILED`，不进入 build。

若 watcher 因运行环境中断而丢失，`--stage auto` 在下次进入时会 reconciliation `sql-handoff.json` 和 task-scoped SQL 结果，避免 SQL 已完成但 Java 永久停留在等待状态。

## 源码 Patch 输出

最终结果同时记录三份 Patch：

- `<work_dir>/reports/source-compatibility.patch`：第一次 compatibility checkpoint 到源码扫码通过之间的修改，只用于表示 DevKit 源码扫码问题修复；
- `<work_dir>/sql-migration/<task_id>/reports/source_code.patch`：SQL Skill 产生的源码改造；
- `<work_dir>/reports/final-source-changes.patch`：从 Java 迁移 Git baseline 到最终工作区的全部源码变化。

路径会写入 `migration-result.json.patches` 和 `migration-result.json.result_summary`，并在最终命令输出中直接展示。
