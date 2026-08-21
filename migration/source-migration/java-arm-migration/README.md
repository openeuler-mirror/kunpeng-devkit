# java-arm-migration

## 简介

`java-arm-migration` 用于将**本地有源码 Java 项目**迁移到 ARM64 环境。Skill 在隔离工作副本中完成项目识别、基线构建、源码兼容性分析、按需 SQL 迁移、最终构建、JAR/WAR 制品扫描以及 ARM64 验证，不直接修改原始项目目录。

当前顶层执行入口为 `scripts/run_migration.py`，所有阶段共用 `<work_dir>/migration-result.json`，支持通过 `--stage auto` 自动执行和断点续跑。

## 功能特性

- 支持 Maven、Gradle、Ant Java 项目识别与构建。
- 自动创建隔离工作副本和 Git 基线，保护原始源码。
- 基线构建通过后再进入兼容性改造，避免把原有构建问题混入迁移问题。
- 使用 DevKit `porting src-mig` 进行源码兼容性检查。
- 检查项目中的架构敏感代码和原生库。
- 按需调用独立 `sql-migration` Skill，只传递 `PROJECT_PATH`、`WORK_DIR`、`SOURCE_DB`、`TARGET_DB` 4个参数。
- 迁移完成后重新构建，并对最终 JAR/WAR 执行 DevKit `pkg-mig` 扫描。
- 支持 ARM64 架构验证和可选运行/验收命令。
- 支持 `WAITING_FOR_SKILL`、`WAITING_FOR_USER`、`NEEDS_AGENT_FIX` 等中断状态后继续执行。

## 适用场景

- 本地存在完整 Java 源码，需要从 x86 环境迁移到 ARM64。
- Java 项目需要调整源码、依赖或构建配置以适配 ARM64。
- 项目包含 MyBatis、JDBC 或其他数据库访问代码，并可能需要 SQL 方言迁移。
- 需要对迁移后的 JAR/WAR 制品进行 ARM64 兼容性扫描和运行验证。

## 前置条件

- 待迁移项目必须是本地可访问的 Java 项目目录。
- Python 3 可用。
- Git 可用，用于建立隔离工作副本的迁移基线。
- 项目自身的构建工具和构建依赖可用；无法自动识别时需要提供 `--build-command`。
- DevKit 可通过 `--devkit-command` 或当前运行环境获取。
- 如需 SQL 迁移，需要明确源数据库和目标数据库类型。
- 如需完成运行验收，需要提供可在 ARM64 环境执行的 `--verify-command`。

## Skill 目录结构

```text
java-arm-migration/
├── SKILL.md
├── README.md
├── prompt.md
├── scripts/
│   ├── run_migration.py              # 顶层执行入口
│   └── migration_common.py           # 公共状态和配置工具
├── java-source-migration/
│   ├── SKILL.md
│   └── scripts/
│       ├── prepare_workspace.py       # 隔离工作副本与Git基线
│       └── source_migration.py        # prepare/inspect/baseline/compatibility/sql
└── java-build-verification/
    ├── SKILL.md
    └── scripts/
        └── build_verification.py      # build/package_scan/verify
```

## 使用方式

最简执行：

```bash
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --stage auto
```

常用可选参数：

```text
--work-base             自定义迁移工作目录根路径
--build-command         指定项目构建命令
--devkit-command        指定DevKit CLI命令或路径
--source-db             SQL源数据库类型
--target-db             SQL目标数据库类型
--skip-sql              明确不执行SQL方言迁移
--verify-command        ARM64运行/验收命令
--architecture-command  架构检查命令，默认 uname -m
```

同一项目恢复执行时继续使用：

```bash
python3 scripts/run_migration.py \
  --source /path/to/java-project \
  --stage auto
```

入口会根据 `migration-result.json.workflow.next_stage` 自动从中断位置继续。

## 工作流程

```text
本地Java项目
    ↓
prepare
创建隔离工作副本和Git基线
    ↓
inspect
识别Maven/Gradle/Ant及项目结构
    ↓
baseline
迁移前完整构建
    ↓
compatibility
DevKit源码扫描与ARM64兼容改造
    ↓
sql
按需调用独立sql-migration
    ↓
build
迁移后重新构建
    ↓
package_scan
最终JAR/WAR DevKit pkg-mig扫描
    ↓
verify
ARM64架构与运行/验收验证
    ↓
SUCCESS / COMPLETED_WITH_ACTIONS
```

其中源码迁移阶段由 `java-source-migration` 子 Skill 负责，最终构建与验证阶段由 `java-build-verification` 子 Skill 负责。

## 输出产物

主要产物位于项目对应的迁移工作目录中：

```text
<work_dir>/
├── migration-result.json             # 顶层状态、阶段、结果和待办
├── workspace.json                    # 工作区元数据
├── workspace/source/                 # 隔离源码工作副本
├── reports/
│   ├── devkit-source/                # 源码兼容性扫描结果
│   └── devkit-package/               # 最终制品扫描结果
├── output/                            # 最终候选JAR/WAR
└── sql-migration/                     # 启用SQL迁移时的独立SQL工作目录
```

最终结果主要通过 `migration-result.json` 判断：

- `SUCCESS`：迁移、制品扫描、ARM64架构和运行/验收验证均满足完成条件。
- `COMPLETED_WITH_ACTIONS`：已生成候选制品，但仍存在 SQL、架构或运行验证待办。
- 其他等待或阻塞状态：根据 `action_required`、`sql_skill` 和 `workflow` 继续处理。

## 常见问题

### 1. 为什么不直接修改原项目？

Skill 会把项目复制到独立工作区，并建立 Git 基线。迁移修改只发生在工作副本中，便于比较、回滚和验证。

### 2. 项目构建方式识别失败怎么办？

通过 `--build-command` 显式提供构建命令，然后重新执行 `--stage auto`。

### 3. 基线构建失败后会继续迁移吗？

不会。基线构建失败会返回 `NEEDS_AGENT_FIX / FIX_BASELINE_BUILD`，修复原有构建问题后再继续。

### 4. SQL 迁移是否属于本 Skill 内部实现？

不是。需要 SQL 适配时，本 Skill 调用独立 `sql-migration` Skill，并保持4参数接口。SQL完成后重新执行 `--stage auto` 继续后续阶段。

### 5. 为什么最终状态是 `COMPLETED_WITH_ACTIONS` 而不是 `SUCCESS`？

通常表示候选制品已经生成，但仍有 SQL 待确认、ARM64验证待完成，或没有配置运行/验收命令。具体原因查看 `migration-result.json.completion_actions`。
