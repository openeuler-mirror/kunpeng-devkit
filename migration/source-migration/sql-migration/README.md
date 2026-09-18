# sql-migration Skill

将项目源码中的 SQL 从源数据库方言迁移到目标数据库方言，实现端到端 SQL 转换的 AI 编程技能包。

---

## 目录

- [简介](#简介)
- [功能特性](#功能特性)
- [适用场景](#适用场景)
- [前置条件](#前置条件)
- [Skill 目录结构](#skill-目录结构)
- [安装方式](#安装方式)
  - [CatPaw IDE](#catpaw-ide)
  - [VS Code (GitHub Copilot)](#vs-code-github-copilot)
  - [Claude Code](#claude-code)
  - [其他编程 Agent](#其他编程-agent)
- [使用方式](#使用方式)
- [工作流程](#工作流程)
- [输出产物](#输出产物)
- [常见问题](#常见问题)

---

## 简介

`sql-migration` 是一个面向项目源码中 SQL 语句的数据库迁移自动化 Skill。它将迁移过程拆解为 **四阶段流水线**（环境准备 → DevKit SQL 分析 → AI 辅助改造与验证 → 转换规则沉淀），由 DevKit 工具与 AI 协作完成，最大限度减少人工介入。

**核心设计原则**：

- **DevKit 优先，AI 兜底**：所有 SQL 先由 DevKit 工具自动转换；DevKit 无法处理的残余 SQL 再交给 AI 改造，并结合目标数据库 `EXPLAIN` 动态验证
- **非侵入式工作目录**：所有迁移产物放入 `$WORK_DIR`，不直接修改原始源码；源码改造结果通过标准 Patch 交付
- **按需读取源码**：SQL 提取与扫描由 DevKit 完成；AI 阶段只根据 `ai-workset.json` 中每个 item 内嵌的 `source_fragment` / `context_before` / `context_after` 做语义判断，仅在嵌入上下文不足时按 `fallback_read` 限定行范围补读一次局部源码
- **可验证可追溯**：AI 改造必须经过目标库 `EXPLAIN` 验证；无法验证或验证失败的 SQL 分别进入待确认或人工介入结果
- **环境准备与主流程分离**：统一入口 `sql_migration.sh` 负责环境准备（`WORK_DIR` 初始化、DevKit/JDK 定位或下载），DevKit 内部代码假设环境已就绪，只读取入口预置的 `devkit_path.txt` / `jdk_path.txt`

---

## 功能特性

- **四阶段自动化流水线**：从环境准备到规则沉淀全流程闭环
- **三条迁移路线自适应**：DevKit 支持路线（`route=A`，DevKit 完整支持，应用 Patch 后再次分析）→ DevKit 不支持路线（`route=B`，DevKit 仅提取）→ MySQL → Vastbase 路线（`route=C`，配合 vastbase-transform 工具），根据数据库组合自动选择
- **DevKit + AI 分工协作**：DevKit 负责提取 SQL、批量自动转换与 Patch 生成，AI 负责残余不兼容 SQL 的智能改造，二者互补
- **动态兼容性评估**：通过 `db-connection.json` 的 `flag` 字段控制是否启用目标库 `EXPLAIN` 动态验证；未启用时降级为静态分析
- **EXPLAIN 验证闭环**：AI 转换后的 SQL 通过目标库 `EXPLAIN` 验证语法正确性，PASS 进入 `migrated`，明确失败进入 `manual-review`，无法确定性验证进入 `pending_confirm`
- **转换规则自动沉淀**：EXPLAIN PASS 的 AI 转换按 **source_db + target_db + rule_pattern_key** 指纹去重后追加到规则库，跨项目复用
- **标准 Patch 交付**：所有源码修改通过 `source_code.patch` 交付，不污染原始源码树
- **断点恢复**：状态机驱动，支持任意阶段断点恢复；

---

## 适用场景

- 项目源码中的 SQL 需要从一种数据库迁移到另一种数据库（如 Oracle → DM、MySQL → Vastbase 等）
- 源码文件类型为 `.xml`（MyBatis Mapper）、`.java` 源码、`.cs` 源码或 `.sql` 脚本
- 希望自动化完成 SQL 方言转换，减少人工逐条修改的工作量
- 需要可验证、可追溯的迁移过程，确保转换后 SQL 在目标库可执行

---

## 前置条件

| 依赖项 | 要求 |
|--------|------|
| DevKit SQL Analysis | 鲲鹏 DevKit 已安装；未提供时由入口脚本 `download_devkit.sh` 自动定位或下载 |
| Java 运行环境 | JRE 由 DevKit 包内嵌或系统提供；JDK 仅在启用目标库动态验证时需要（用于编译 EXPLAIN 验证器），由入口脚本 `download_jdk.sh` 按需定位或下载 |
| Python | ≥ 3.7（用于报告解析与汇总报告生成） |
| 数据库连接（可选） | 源库/目标库 JDBC 连接信息配置在 `assets/db-connection.json` 中，`flag=true` 时启用动态兼容性评估 |
| 数据库驱动（可选） | 启用动态验证时需提供对应数据库的 JDBC Driver JAR 路径 |

---

## Skill 目录结构

```
sql-migration/
├── SKILL.md                                          # 主控文档（四阶段流程编排与状态机）
├── README.md
├── prompt.md                                         # 调用提示词模板
├── assets/
│   └── db-connection.json                            # 数据库连接配置（源库/目标库，flag 控制动态验证）
├── references/
│   ├── ai-sql-transformation.md                     # AI 辅助改造参考（输入边界、字段、收敛逻辑、规则沉淀）
│   └── rule-template.md                              # 转换规则沉淀格式模板（字段说明、规则示例）
└── scripts/
    ├── sql_migration.sh                               # [入口] 统一入口（环境准备 + 调用 sql_migration.py）
    ├── sql_migration.py                               # [入口] 迁移主控（状态机、阶段调度、断点恢复）
    ├── tools/                                         # [工具层] AI 协作、DevKit 环境准备与执行封装
    │   ├── finalize_ai_stage.py                       #   AI 阶段收敛（分类校验、规则沉淀、触发 FINALIZE）
    │   ├── build_ai_workset.py                        #   AI 工作集构建（to_do → ai-workset.json）
    │   ├── target_sql_validator.py                    #   目标库 EXPLAIN 验证器
    │   ├── download_devkit.sh                         #   DevKit 定位/下载（定位优先，下载兜底）
    │   ├── download_jdk.sh                            #   JDK 定位/下载（定位优先，下载兜底）
    │   ├── devkit-sql-migration.sh                    #   DevKit jar 执行封装
    │   ├── parse_report.py                            #   DevKit 报告解析与分类
    │   └── generate_report.py                         #   汇总报告生成（csv）
    ├── common/                                        # [公共模块] 被多方依赖的内部模块
    │   └── migration_common.py / sql_context.py       #   共享运行时工具、环境读取与路由解析
    └── stages/                                        # [阶段实现包] 阶段实现
        ├── prepare.py                                 #   PREPARE 阶段（源码备份、环境读取、路由）
        ├── analyze.py                                 #   ANALYZE 阶段（DevKit 分析、报告归一化）
        └── finalize.py                                #   FINALIZE 阶段（Patch、路径转换、汇总报告）
```

---

## 安装方式

`sql-migration` 遵循开放 Skill 标准（核心为 `SKILL.md` + YAML 前置声明），可在 CatPaw IDE、VS Code、Claude Code 等支持 Skill 的编程 Agent 中通用。

### CatPaw IDE

#### 方式一：项目级安装（推荐，随项目共享）

将 `sql-migration` 整个文件夹复制到项目根目录的 `.catpaw/skills/` 下：

```bash
# 在项目根目录执行
mkdir -p .catpaw/skills
cp -r <path-to>/sql-migration .catpaw/skills/
```

安装后重启 CatPaw IDE，在 AI 对话窗口调用技能，出现"调用 skills"提示即成功。

#### 方式二：全局级安装（跨项目复用）

将 `sql-migration` 文件夹复制到全局技能目录：

```bash
# Windows
C:\Users\<你的用户名>\.catpaw\skills\

# macOS / Linux
~/.catpaw/skills/
```

安装后重启 CatPaw IDE 即可全局调用。

#### 方式三：ZIP 包可视化导入

1. 将 `sql-migration` 文件夹打包为 ZIP（根目录需包含 `SKILL.md`）
2. 打开 CatPaw → 设置（齿轮图标）→ 规则与技能 → 技能
3. 点击「+ 创建」→ 选择压缩包导入，AI 自动解析配置
4. 选择"项目级"或"全局级"，确认安装

### VS Code (GitHub Copilot)

将 `sql-migration` 文件夹放入以下任一目录：

```bash
# 项目级（随 Git 共享）
<项目根目录>/.github/skills/
<项目根目录>/.claude/skills/
<项目根目录>/.agents/skills/

# 个人级（当前用户所有项目生效）
~/.copilot/skills/
~/.claude/skills/
```

在 Chat 面板中通过 `/skills` 命令可查看已安装的技能列表。

### Claude Code

将 `sql-migration` 文件夹放入以下目录：

```bash
# 项目级
<项目根目录>/.claude/skills/

# 个人级
~/.claude/skills/
```

### 其他编程 Agent

任何支持开放 Skill 标准（`SKILL.md` + YAML 前置声明）的 AI 编程助手均可使用本 Skill。将 `sql-migration` 文件夹放入对应工具的技能目录即可，具体路径请参考该工具的文档。

---

## 使用方式

### 步骤一：配置数据库连接（可选）

如需启用动态兼容性评估（EXPLAIN 验证），编辑 `assets/db-connection.json`，将源库或目标库的 `flag` 设为 `true` 并填写连接信息：

```json
{
  "source_db_conn": {
    "flag": false,
    "jdbc_url": "",
    "user": "",
    "password": "",
    "driver_jar_path": "",
    "driver_class_name": ""
  },
  "target_db_conn": {
    "flag": true,
    "jdbc_url": "jdbc:dm://192.168.1.100:5236",
    "user": "SYSDBA",
    "password": "your_password",
    "driver_jar_path": "/path/to/DmJdbcDriver.jar",
    "driver_class_name": "dm.jdbc.driver.DmDriver"
  }
}
```

> `flag=false` 时该库不启用动态验证，Skill 以静态分析模式运行。

### 步骤二：打开 AI 对话窗口

在已安装 Skill 的 IDE 中打开 AI 对话窗口（CatPaw IDE 按 `Ctrl+L` / `Cmd+L`）。

### 步骤三：提供项目信息并触发 Skill

在对话窗口中填入项目信息并发送：

```text
请帮我将以下项目中的 SQL 从 Oracle 迁移到 DM 数据库。

【项目信息】
- 项目路径：/home/user/my-project
- 源数据库：Oracle
- 目标数据库：DM
```

也可以直接描述迁移意图触发 Skill：

```text
帮我把 /home/user/my-project 项目中的 SQL 从 MySQL 迁移到 Vastbase，项目用 MyBatis，XML 文件里有大量动态 SQL。
```

### 步骤四：统一入口执行

Skill 通过统一入口 `sql_migration.sh` 执行，入口脚本先完成环境准备（`WORK_DIR` 初始化、DevKit/JDK 定位或下载），再调用 `sql_migration.py` 进入迁移主流程：

```bash
bash scripts/sql_migration.sh \
  --project-path "$PROJECT_PATH" \
  --source-db "$SOURCE_DB" \
  --target-db "$TARGET_DB" \
  [--work-dir "$WORK_DIR"]
```

首次执行和断点恢复使用同一入口。`SOURCE_DB` / `TARGET_DB` 必须由用户明确提供，Agent 不得通过扫描源码、配置文件、依赖等方式推断，缺失时必须向用户询问。

---

## 工作流程

```
┌─────────────────────────────────────────────────────────────────┐
│  统一入口 sql_migration.sh                                       │
│  初始化 WORK_DIR、定位/下载 DevKit、按需定位/下载 JDK              │
│  → 调用 sql_migration.py 进入状态机                              │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  PREPARE                                                        │
│  读取入口预置环境（devkit_path.txt / jdk_path.txt）               │
│  生成源码 a/b 副本、选择数据库迁移路线                             │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  ANALYZE                                                        │
│  调用 DevKit SQL Analysis、归一化报告                             │
│  DevKit 支持路线（route=A）应用 DevKit Patch 后再次分析            │
│  有残余 SQL 时生成 ai-workset.json                               │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
            有残余 SQL？──否──→ FINALIZE → COMPLETE
                   │
                   是
                   ▼
┌─────────────────────────────────────────────────────────────────┐
│  AI_TRANSFORMATION（WAITING_FOR_AI）                            │
│  AI 处理 ai-workset.json 中的残余 SQL，修改 source-code/b         │
│  写入 ai_target_sql / rule_pattern_key / rule_summary           │
│  完成后调用 finalize_ai_stage.py 收敛分类                         │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  FINALIZE                                                       │
│  目标库 EXPLAIN 验证（target flag=true 时）                       │
│  规则沉淀（EXPLAIN PASS 的 converted 项按模式键去重追加）          │
│  生成 source_code.patch、路径转换、汇总报告                       │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
                  WAITING_FOR_USER_DECISION
                  用户决定查看结果或重新迁移
```

### 工作目录

Skill 使用专用工作目录存放中间产物，默认 `<项目路径>/.devkit-sql-migration/`（不污染源码树），可通过 `--work-dir` 自定义位置：

```
<WORK_DIR>/
├── source-code/
│   ├── a/                           # 基准副本（不修改）
│   └── b/                           # 工作副本（AI 修改后）
├── reports/                         # 迁移报告与输出产物
├── downloads/                       # DevKit 工具包、JDK 下载包（重复迁移时保留）
├── logs/                            # 日志
├── sql-analysis/                    # DevKit SQL Analysis 工具（重复迁移时保留）
└── devkit-sql-migration-cache/      # 规则库（重复迁移时保留）
    └── rulers_<SOURCE>_to_<TARGET>.md
```

---

## 输出产物

迁移完成后，`$WORK_DIR/reports/` 下生成核心输出：

| 文件 | 说明 |
|------|------|
| `sql-migration-result.json` | **最终迁移结果**（状态、统计、各分类明细） |
| `source_code.patch` | **最终合并 Patch**（a/b 格式，可直接 `patch -p1` 应用） |
| `migration_summary.csv` | 汇总报告（SQL 分类统计、迁移状态） |
| `manual_review_report.json` | 需人工介入 SQL（EXPLAIN 验证失败或转换不完整） |
| `pending_confirm_sql.json` | 待确认 SQL（未启用动态验证或无法确定性验证） |

转换规则沉淀在 `$WORK_DIR/devkit-sql-migration-cache/rulers_<SOURCE>_to_<TARGET>.md`。其余文件（`env_check_report.json`、`ai-workset.json`、`to_do-migrated_sql.json` 等）为中间过程产物，仅用于流程内部流转。

---

## 常见问题

### Q: Skill 没有被触发怎么办？

确认 `SKILL.md` 文件名全大写，且位于正确的技能目录下。CatPaw IDE 需重启后识别新安装的 Skill。也可在对话中显式点名："使用 `sql-migration` 技能，帮我迁移项目中的 SQL"。

### Q: DevKit 未安装怎么办？

统一入口 `sql_migration.sh` 调用 `download_devkit.sh`，优先在脚本上两级目录（DevKit 内置分发场景）、`/opt`、`/home`、`/usr/lib`、工作目录定位已存在的 DevKit；定位不到时自动从华为云镜像站下载。整个过程无需人工介入。

### Q: 不配置数据库连接信息可以迁移吗？

可以。`assets/db-connection.json` 中对应库的 `flag=false` 时，该库不启用动态验证，Skill 以静态分析模式运行，AI 转换后的 SQL 输出至 `pending_confirm_sql.json`，由用户人工确认。

### Q: 支持哪些文件类型中的 SQL 迁移？

支持 `.xml`（MyBatis Mapper）、`.java` 源码文件、`.cs` 源码文件以及 `.sql` 脚本文件。其他格式文件中的 SQL 不在迁移范围内。

### Q: AI 转换会修改源码的业务逻辑吗？

不会。AI 仅修改 SQL 语句本身（方言函数替换、语法适配），严禁修改源码语义（变量名、控制流、业务逻辑）。所有修改通过标准 Patch 交付，可审查后决定是否应用。

### Q: EXPLAIN 验证失败怎么办？

EXPLAIN 验证失败的 SQL 进入 `manual_review_report.json`，标记"需人工介入"，不阻塞其他 SQL 的迁移。无法确定性验证的项（缺少 JDK、驱动、连接配置或无法形成可确定验证的 SQL）进入 `pending_confirm_sql.json`。

### Q: 如何复用历史转换规则？

FINALIZE 阶段会将 AI 验证通过的转换规则按 **source_db + target_db + rule_pattern_key** 指纹去重后，自动追加到 `$WORK_DIR/devkit-sql-migration-cache/rulers_<SOURCE>_to_<TARGET>.md`。后续项目迁移时，`build_ai_workset.py` 从该规则库检索相似规则作为 AI 的 `rule_candidates`。规则库随 `$WORK_DIR` 在同一 workspace 内跨项目复用。

### Q: 断点恢复怎么工作？

迁移主流程由状态机驱动，状态持久化在 `$WORK_DIR/sql-migration-state.json`。任意阶段中断后，再次调用统一入口（同参数）会读取状态文件，从上次中断的阶段继续，已完成阶段不重跑。环境缓存（`devkit_path.txt` / `jdk_path.txt`）持续存在，断点恢复时无需重新准备环境。

### Q: 二次迁移会清理之前的产物吗？

会。迁移完成后进入 `WAITING_FOR_USER_DECISION`，用户选择"重新迁移"时执行 `reset_command`（带 `--reset` 调用 `sql_migration.py`），清理 `source-code/`、`reports/`、`logs/` 下的旧产物并重建，保留 `downloads/`、`sql-analysis/`、`devkit-sql-migration-cache/` 及 `reports/devkit_path.txt`、`reports/jdk_path.txt` 环境缓存，避免重复定位/下载 DevKit 与 JDK。

### Q: 源数据库和目标数据库类型可以由 Agent 推断吗？

不可以。`SOURCE_DB` / `TARGET_DB` 为业务语义参数，Agent 不得通过扫描项目源码、读取配置文件/依赖、解析 `jdbc_url`、依据项目名称等方式推断。两者必须由用户明确提供；任一缺失时，Agent 必须立即停止执行并向用户询问。

---

## 参考资源

- [鲲鹏 DevKit](https://www.hikunpeng.com/developer/devkit) — 获取 DevKit 工具
- [SKILL.md](SKILL.md) — 完整的四阶段流程编排文档
