# cpp-kunpeng-migration Skill

将 C/C++ 项目从 x86 自动迁移到 ARM（aarch64 / 鲲鹏），实现双架构同时兼容编译运行的 AI 编程技能包。

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

`cpp-kunpeng-migration` 是一个面向 C/C++ 项目的 ARM 架构迁移自动化 Skill。它将迁移过程拆解为 **六阶段流水线**（环境检测 → 依赖分析 → 用户确认 → DevKit 扫描适配 → 编译验证循环 → 迁移总结报告），由主编排驱动 subagent 协作完成，最大限度减少人工介入。

**核心设计原则**：

- **双架构兼容**：所有修改使项目**同时**支持 x86 和 ARM 编译，通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，不破坏原有 x86 能力
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物放到项目目录之外的专用工作目录，不污染源码树
- **一次性信息收集**：所有需用户提供的信息在阶段 3 一次性问清楚，不在后续流程中反复打断

---

## 功能特性

- **五大构建系统支持**：Bazel / CMake / Make / Blade / SCons 自动识别与适配
- **六阶段自动化流水线**：从环境检测到总结报告全流程闭环
- **subagent 协作架构**：阶段 1、2 以 subagent 模式执行，隔离上下文，主编排统一收集待确认项后一次性提问
- **依赖兼容性探测**：自动分析所有外部依赖的 ARM 兼容性，命中免检清单的依赖自动切换，冲突项结构化输出供用户决策
- **DevKit 扫描集成**：调用鲲鹏 DevKit 工具扫描源码 x86 专属问题（内联汇编 / intrinsics / 头文件 / 类型大小等），生成修改建议
- **编译错误两级查询**：速查表（`build-error-quickfix.md`）→ 案例库（`migration-cases/`）兜底，快速定位修复方案
- **ARM 适配知识积累**：`kunpeng_confirmed.md` 持久化已确认的 ARM 适配依赖，跨项目复用

---

## 适用场景

- C/C++ 项目需要从 x86 迁移到 ARM（鲲鹏 aarch64）架构
- 项目需要同时支持 x86 与 ARM 双架构编译运行
- 项目使用 Bazel / CMake / Make / Blade / SCons 作为构建系统
- 私有仓库依赖需要推动 ARM 适配后再编译主仓库

---

## 前置条件

| 依赖项 | 要求 |
|--------|------|
| 目标环境 | ARM（aarch64 / 鲲鹏）服务器，具备编译条件 |
| 源环境 | x86_64 服务器（用于环境信息对比） |
| DevKit | 鲲鹏 DevKit 已安装（阶段 4 扫描所需，`which devkit` 可查） |
| 构建工具 | GCC / Make / CMake / Bazel / Blade / SCons（按项目实际使用的构建系统准备） |
| CatPaw IDE | 版本 ≥ 3.3.21（如使用 CatPaw IDE 运行 Skill） |

---

## Skill 目录结构

```
cpp-kunpeng-migration/
├── SKILL.md                                          # 主控入口（六阶段流程编排）
├── environment-prepare/                              # 阶段 1 子 Skill：环境检测与准备
│   ├── SKILL.md
│   └── references/
│       └── build-tools-reference.md                  # 构建工具下载链接
├── dependency-analysis/                              # 阶段 2 子 Skill：依赖分析与 ARM 兼容性探测
│   ├── SKILL.md                                      # 依赖分析主编排
│   ├── references/
│   │   ├── repo-analysis-flow.md                     # 单仓库分析闭环步骤
│   │   ├── compat-and-binary-detect.md               # 通用 Kunpeng 兼容性探测 + 预编译二进制识别
│   │   ├── kunpeng-confirmed-write.md                # 阶段 3：写入确认清单 + 执行切换
│   │   ├── kunpeng_confirmed.md                      # 已确认 Kunpeng 适配的依赖库清单
│   │   └── build-system-dep-scan.md                  # 四构建系统合集（Bazel/CMake/Blade/SCons 按章节按需加载）
│   └── assets/
│       └── report-template-example.md                # 报告输出模板
├── devkit-scan/                                      # 阶段 4 子 Skill：DevKit 扫描与源码/构建适配
│   ├── SKILL.md                                      # 完整扫描 + 适配流程
│   ├── references/
│   │   └── devkit-download.md                        # DevKit CLI 下载说明
│   └── scripts/
│       └── devkit-download.sh                        # DevKit 自动下载安装脚本
├── sourcecode-build-verify/                          # 阶段 5 子 Skill：编译验证与循环修复
│   ├── SKILL.md
│   └── references/
│       ├── build-error-quickfix.md                   # 编译错误快速修复速查表
│       ├── bazel-dual-arch-pattern.md                # Bazel 双架构切换模式参考
│       └── migration-cases/                          # ARM 迁移案例库
│           ├── generic-kunpeng-migration-index.md    # 路由索引：通用迁移问题
│           ├── version-compatibility-index.md        # 路由索引：版本兼容性
│           ├── project-specific-index.md             # 路由索引：项目特定问题
│           ├── generic-kunpeng-migration-cases.md    # 通用 Kunpeng 适配详细案例
│           ├── version-compatibility-cases.md        # 版本兼容性详细案例
│           └── project-specific-cases.md             # 项目特定详细案例
└── migration-summary/                                # 阶段 6：迁移总结报告
    ├── SKILL.md
    └── assets/
        └── migration_summary_report_template.md      # 迁移总结报告模板
```
（prompt.md 位于父目录 application-migration/ 下）
---

## 安装方式

`cpp-kunpeng-migration` 遵循开放 Skill 标准（核心为 `SKILL.md` + YAML 前置声明），可在 CatPaw IDE、VS Code、Claude Code 等支持 Skill 的编程 Agent 中通用。

### CatPaw IDE

#### 方式一：项目级安装（推荐，随项目共享）

将 `cpp-kunpeng-migration` 整个文件夹复制到项目根目录的 `.catpaw/skills/` 下：

```bash
# 在项目根目录执行
mkdir -p .catpaw/skills
cp -r <path-to>/cpp-kunpeng-migration .catpaw/skills/
```

安装后重启 CatPaw IDE，在 AI 对话窗口调用技能，出现"调用 skills"提示即成功。

#### 方式二：全局级安装（跨项目复用）

将 `cpp-kunpeng-migration` 文件夹复制到全局技能目录：

```bash
# Windows
C:\Users\<你的用户名>\.catpaw\skills\

# macOS / Linux
~/.catpaw/skills/
```

安装后重启 CatPaw IDE 即可全局调用。

#### 方式三：ZIP 包可视化导入

1. 将 `cpp-kunpeng-migration` 文件夹打包为 ZIP（根目录需包含 `SKILL.md`）
2. 打开 CatPaw → 设置（齿轮图标）→ 规则与技能 → 技能
3. 点击「+ 创建」→ 选择压缩包导入，AI 自动解析配置
4. 选择"项目级"或"全局级"，确认安装

### VS Code (GitHub Copilot)

将 `cpp-kunpeng-migration` 文件夹放入以下任一目录：

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

将 `cpp-kunpeng-migration` 文件夹放入以下目录：

```bash
# 项目级
<项目根目录>/.claude/skills/

# 个人级
~/.claude/skills/
```

Claude Code 支持 Subagent 特性，阶段 1、2 的 subagent 执行模式与 Claude Code 的 Subagent 机制天然契合。

### 其他编程 Agent

任何支持开放 Skill 标准（`SKILL.md` + YAML 前置声明）的 AI 编程助手均可使用本 Skill。将 `cpp-kunpeng-migration` 文件夹放入对应工具的技能目录即可，具体路径请参考该工具的文档。

---

## 使用方式

### 步骤一：打开 AI 对话窗口

在已安装 Skill 的 IDE 中打开 AI 对话窗口（CatPaw IDE 按 `Ctrl+L` / `Cmd+L`）。

### 步骤二：提供项目信息并触发 Skill

在对话窗口中填入项目信息并发送，参考 [prompt.md](prompt.md) 模板：

```text
请帮我将以下 C/C++ 项目从 x86 迁移到 ARM（鲲鹏 aarch64）。

【项目信息】
- 项目路径：<填写项目绝对路径>
- 构建系统：<Bazel / CMake / Make / Blade / SCons / 自动识别>
- 主编译目标：<填写主编译目标，不确定可留空>

【排除目录配置】（不必使用 Devkit 扫描这些目录的源码适配问题）
- third_party/        # 第三方库源码，由上游维护，不改动
- vendor/             # 外部依赖 vendored 源码
- deps/               # 内嵌依赖目录
- build/              # 构建产物
- out/                # 构建输出
- .git/               # 版本控制
- docs/               # 文档
- test/               # 测试目录（如不需迁移测试）
- <其他自定义排除目录>

【执行要求】
按 cpp-kunpeng-migration skill 六阶段流程执行（1 环境检测 → 2 依赖分析 → 3 用户确认 → 4 DevKit 扫描适配 → 5 编译验证循环 → 6 迁移总结报告）。
- 所有源码修改须有 __aarch64__ 架构宏保护，不破坏 x86 能力
```

也可以直接描述迁移意图触发 Skill：

```text
帮我把 /home/user/my-project 这个 C++ 项目适配到 ARM 鲲鹏架构，项目用 Bazel 构建，需要同时支持 x86 和 ARM 编译。
```

### 步骤三：按阶段交互

Skill 启动后会自动按六阶段流程执行。**关键交互点在阶段 3**——主编排会汇总阶段 1、2 的待确认项，一次性通过 `AskUserQuestion` 向你提问，你需要：

1. 回答环境检测和依赖分析中需决策的问题（版本不一致处理、依赖冲突处理等）
2. 确认已命中免检清单的依赖切换操作
3. 确认是否开始正式迁移

阶段 3 回复后，Skill 自动完成阶段 4（扫描适配）和阶段 5（编译验证循环），最终在阶段 6 输出迁移总结报告。

---

## 工作流程

```
┌─────────────────────────────────────────────────────────────────┐
│  阶段 1：环境检测与准备（subagent）                                │
│  检测 ARM 环境编译器/构建工具/依赖版本，自动修复不一致项            │
│  输出：environment_check_report.md + stage_1_pending_items.md    │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 2：依赖分析与 ARM 兼容性探测（subagent）                     │
│  全面分析外部依赖，评估 ARM 兼容性，命中免检清单自动标记切换        │
│  输出：dependency_analysis_<项目名>.md                           │
│       + stage_2_pending_items.md + stage_2_switch_list.md       │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 3：汇总待确认项 + 等待用户确认（主编排，必须交互）           │
│  一次性提问所有待确认项 → 用户回复 → 登记免检清单 → 确认切换分支   │
│  未获用户明确确认前不进入阶段 4                                  │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 4：DevKit 扫描 → 构建配置 + 源码适配（严格串行）             │
│  4.1 DevKit 扫描生成报告 → 4.2 根据报告完成源码/构建修改          │
│  扫描未结束不得开始修改，所有修改须有架构宏保护                   │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 5：编译验证循环                                             │
│  循环编译 → 错误两级查询修复（速查表 → 案例库）→ 重新编译          │
│  直到编译成功或触发人工介入                                       │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 6：迁移总结报告                                             │
│  汇总各阶段执行时长、修改文件清单、重要提示与建议                  │
│  输出：migration_summary_report.md                               │
└─────────────────────────────────────────────────────────────────┘
```

### 工作目录

Skill 会在 workspace 根目录同级创建专用工作目录（不污染源码树）：

```
<workspace>-arm-migration/
├── reports/      # 扫描报告、依赖分析报告、修改清单、时间线日志
├── downloads/    # 依赖源码包、ARM 预编译库下载
├── build/        # 第三方库临时编译安装目录
├── logs/         # 每轮编译日志（build_1.log、build_2.log…）
└── stubs/        # 为无 ARM 版本的私有内部库创建的桩仓库
```

---

## 输出产物

迁移完成后，工作目录的 `reports/` 下会生成以下关键产物：

| 文件 | 阶段 | 说明 |
|------|------|------|
| `environment_check_report.md` | A | 环境基础信息 + 编译依赖状态汇总表 |
| `dependency_analysis_<项目名>.md` | B | 依赖分析报告（依赖清单、兼容性评估、分类结果） |
| `user_decisions.txt` | C | 用户决策记录 |
| `devkit-*/` | D | DevKit 扫描报告（源码 x86 专属问题及修改建议） |
| `build_<N>.log` | E | 每轮编译日志 |
| `timeline.log` | A-F | 各阶段开始/结束时间戳，用于时长统计 |
| `migration_summary_report.md` | F | **迁移总结报告**（最终交付物） |

---

## 常见问题

### Q: Skill 没有被触发怎么办？

确认 `SKILL.md` 文件名全大写，且位于正确的技能目录下。CatPaw IDE 需重启后识别新安装的 Skill。也可在对话中显式点名："使用 `cpp-kunpeng-migration` 技能，帮我迁移项目"。

### Q: DevKit 未安装怎么办？

阶段 4 扫描时若 `which devkit` 返回空，Skill 会通过 `AskUserQuestion` 让你选择：手动提供安装路径 / 自行下载安装后继续 / 中止。不会跳过扫描或自行下载安装。

### Q: 编译持续失败无法自动修复怎么办？

阶段 5 设置了人工介入机制。当自动修复达到阈值仍无法解决时，Skill 会输出人工介入报告并进入阶段 6 生成总结报告，标注"人工介入"状态，列出剩余未解决的问题。

### Q: 私有仓库依赖无 ARM 版本怎么办？

阶段 2 会检测到该情况并生成待确认项。在阶段 3 你可以选择：从源码编译 / 提供已有包路径 / 禁用该模块。若选择推动子仓库完成 ARM 适配，可先跳过该依赖，适配完成后再重新编译主仓库。

### Q: 迁移会影响原有 x86 编译吗？

不会。所有源码修改均有 `#if defined(__aarch64__)` 架构宏保护，构建配置通过 `select()` 分支区隔，确保 x86 编译能力不受影响。

### Q: 如何复用已确认的 ARM 适配依赖？

阶段 3 会将用户确认的依赖 ARM 适配信息写入 [kunpeng_confirmed.md](cpp-kunpeng-migration/dependency-analysis/references/kunpeng_confirmed.md)。后续项目迁移时，阶段 2 会读取该免检清单，命中的依赖自动标记为待切换，无需重复探测和提问。

---

## 参考资源

- [鲲鹏 DevKit](https://www.hikunpeng.com/developer/devkit) — 获取 DevKit 工具
- [SKILL.md](cpp-kunpeng-migration/SKILL.md) — 完整的六阶段流程编排文档
- [prompt.md](prompt.md) — 使用提示词模板
