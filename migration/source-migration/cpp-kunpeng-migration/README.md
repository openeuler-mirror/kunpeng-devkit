# cpp-kunpeng-migration Skill

将 C/C++ 项目从 x86 自动迁移到 ARM（aarch64 / 鲲鹏），实现双架构同时兼容编译运行的 AI 编程技能包。

---

## 目录

- [简介](#简介)
- [功能特性](#功能特性)
- [适用场景](#适用场景)
- [前置条件](#前置条件)
- [安装方式](#安装方式)
  - [opencode](#opencode)
  - [Claude Code](#claude-code)
  - [CatPaw IDE](#catpaw-ide)
  - [其他编程 Agent](#其他编程-agent)
- [使用方式](#使用方式)
- [工作流程](#工作流程)
- [输出产物](#输出产物)
- [常见问题](#常见问题)
- [Skill 目录结构](#skill-目录结构)

---

## 简介

`cpp-kunpeng-migration` 是一个面向 C/C++ 项目的 ARM 架构迁移自动化 Skill。它将迁移过程拆解为 **六阶段流水线**（环境检测 → 依赖分析 → 用户确认 → 源码迁移扫描 → 编译验证循环 → 迁移总结报告），由主 agent 驱动子 agent 协作完成，最大限度减少人工介入。

---

## 功能特性

- **五大构建系统支持**：Bazel / CMake / Make / Blade / SCons 自动识别与适配
- **六阶段自动化流水线**：从环境检测到总结报告全流程闭环
- **依赖兼容性探测**：自动分析所有外部依赖的 ARM 兼容性，命中免检清单的依赖自动切换，冲突项结构化输出供用户决策
- **DevKit 扫描集成**：调用鲲鹏 DevKit 工具扫描源码 x86 专属问题（内联汇编 / intrinsics / 头文件 / 类型大小等），生成修改建议
- **模型驱动编译修复循环**：由模型直接分析编译错误并生成修复，多轮迭代直至通过
---

## 适用场景

- C/C++ 项目需要从 x86 迁移到 ARM（鲲鹏 aarch64）架构
- 项目使用 Bazel / CMake / Make / Blade / SCons 作为构建系统
- 私有仓库依赖需要推动 ARM 适配后再编译主仓库

---

## 前置条件

**必须项**：

| 依赖项 | 要求 |
|--------|------|
| 目标环境 | ARM（aarch64 / 鲲鹏）服务器，具备编译条件 |
| AI 编码助手 | 支持 Skill 机制、可对接 LLM 且在ARM服务器（鲲鹏）上部署（如 opencode / Claude Code / CatPaw 等） |
| 构建工具 | GCC / Make / CMake / Bazel / Blade / SCons（按项目实际使用的构建系统准备，或者联网可下载） |
| AI Migration Tool / DevKit | 阶段 4 扫描所需；优先复用本地 `ai-migration` 工具包，找不到时经确认后按配置下载，随后由其获取并调用 DevKit CLI |

**额外选项**：

| 依赖项 | 要求 |
|--------|------|
| 依赖源码/组件 | 如项目存在依赖的源码仓库、依赖库等其他组件，需额外提供（源码包或仓库路径），或目标环境支持联网下载 |

---

## 安装方式

`cpp-kunpeng-migration` 遵循开放 Skill 标准（核心为 `SKILL.md` + YAML 前置声明），可在 opencode、Claude Code、CatPaw IDE 等支持 Skill 的编程 Agent 中通用。

### opencode

将 `cpp-kunpeng-migration` 文件夹放入以下目录：

```bash
# 项目级（随 Git 共享）
<项目根目录>/.opencode/skills/

# 个人级（当前用户所有项目生效）
~/.config/opencode/skills/
```

### Claude Code

将 `cpp-kunpeng-migration` 文件夹放入以下目录：

```bash
# 项目级
<项目根目录>/.claude/skills/

# 个人级
~/.claude/skills/
```

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
# Linux（鲲鹏 aarch64，CatPaw IDE 部署在 ARM 服务器上）
~/.catpaw/skills/
```

安装后重启 CatPaw IDE 即可全局调用。

#### 方式三：ZIP 包可视化导入

1. 将 `cpp-kunpeng-migration` 文件夹打包为 ZIP（根目录需包含 `SKILL.md`）
2. 打开 CatPaw → 设置（齿轮图标）→ 规则与技能 → 技能
3. 点击「+ 创建」→ 选择压缩包导入，AI 自动解析配置
4. 选择"项目级"或"全局级"，确认安装

### 其他编程 Agent

任何支持开放 Skill 标准（`SKILL.md` + YAML 前置声明）的 AI 编程助手均可使用本 Skill。将 `cpp-kunpeng-migration` 文件夹放入对应工具的技能目录即可，具体路径请参考该工具的文档。

---

## 使用方式

### 步骤一：打开 AI 对话窗口

在已安装 Skill 的编程 Agent 中打开 AI 对话：

- **CLI 类**（如 opencode、Claude Code）：在终端启动对应命令进入对话（如 `opencode`、`claude`）
- **IDE 类**（如 CatPaw IDE）：打开 AI 对话窗口（按 `Ctrl+L` / `Cmd+L`）

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
按 cpp-kunpeng-migration skill 六阶段流程执行（1 环境检测 → 2 依赖分析 → 3 用户确认 → 4 源码迁移扫描 → 5 编译验证循环 → 6 迁移总结报告）。
- 所有源码修改须有 __aarch64__ 架构宏保护，不破坏 x86 能力
```

也可以直接描述迁移意图触发 Skill：

```text
帮我把 /home/user/my-project 这个 C++ 项目适配到 ARM 鲲鹏架构，项目用 Bazel 构建，需要同时支持 x86 和 ARM 编译。
```

### 步骤三：按阶段交互

Skill 启动后会自动按六阶段流程执行。**关键交互点在阶段 3**——主 agent 会汇总阶段 1、2 的待确认项，一次性通过 `AskUserQuestion` 向你提问，你需要：

1. 回答环境检测和依赖分析中需决策的问题（版本不一致处理、依赖冲突处理等）
2. 确认已命中免检清单的依赖切换操作
3. 确认是否开始正式迁移

阶段 3 回复后，Skill 自动完成阶段 4（扫描适配）和阶段 5（编译验证循环），最终在阶段 6 输出迁移总结报告。

---

## 工作流程

> 流程图展示完整六阶段。

```
┌─────────────────────────────────────────────────────────────────┐
│  阶段 1：环境检测与准备（子 agent）                                │
│  检测 ARM 环境编译器/构建工具/依赖版本，自动修复不一致项            │
│  输出：environment_check_report.md + stage_1_pending_items.md    │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 2：依赖分析与 ARM 兼容性探测（子 agent）                     │
│  全面分析外部依赖，评估 ARM 兼容性，命中免检清单自动标记切换        │
│  输出：dependency_analysis_<项目名>.md                           │
│       + stage_2_pending_items.md + stage_2_switch_list.md       │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 3：汇总待确认项 + 等待用户确认（主 agent，必须交互）         │
│  一次性提问所有待确认项 → 用户回复 → 登记免检清单 → 确认切换分支   │
│  未获用户明确确认前不进入阶段 4                                  │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 4：源码迁移扫描与适配（严格串行）                           │
│  4.1 DevKit 扫描生成报告 → 4.2 根据报告完成源码/构建修改          │
│  扫描未结束不得开始修改，所有修改须有架构宏保护                   │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 5：编译验证循环                                             │
│  循环编译 → 错误两级查询修复（速查表 → 案例库）→ 重新编译          │
│  命中阻塞性问题时向用户提问，按用户方案更新配置后继续               │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 6：迁移总结报告                                             │
│  汇总各阶段执行时长、修改文件清单、重要提示与建议                  │
│  输出：migration_summary_report.md                               │
└─────────────────────────────────────────────────────────────────┘
```

## 输出产物

Skill 会在 workspace 根目录同级创建专用工作目录（不污染源码树），目录名为 `<workspace>-arm-migration`。迁移完成后，最终交付物保存在其中的 `output/` 下：

| 文件 | 说明 |
|------|------|
| `migration_summary_report.md` | **迁移总结报告**（各阶段时长、修改文件清单、重要提示与建议） |
| `migration.patch` | 迁移 patch（源码 + 构建配置改动，排除二进制文件） |

其余过程产物由 Skill 自动管理，无需用户关注。

---

## 常见问题

### Q: Skill 没有被触发怎么办？

确认 `SKILL.md` 文件名全大写，且位于正确的技能目录下。CatPaw IDE 需重启后识别新安装的 Skill。也可在对话中显式点名："使用 `cpp-kunpeng-migration` 技能，帮我迁移项目"。

### Q: AI Migration Tool 或 DevKit 未安装怎么办？

阶段 4 扫描前会按优先级查找用户提供的 `AI_MIGRATION_DIR`、`/opt/huawei/devkit/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration` 和工作目录中的 Kunpeng 工具包。均未找到时，Skill 会先按默认配置自动尝试 AI Migration Tool 直链下载；只有直链下载、解压或校验失败后，才通过 `AskUserQuestion` 让你选择：手动提供已有路径 / 重试或手动下载工具包 / 中止。工具包就绪后，再通过 `${AI_MIGRATION_DIR}/ai-migration source-migration download` 获取 DevKit CLI；不会跳过扫描。

### Q: 私有仓库依赖无 ARM 版本怎么办？

阶段 2 会检测到该情况并生成待确认项。在阶段 3 你可以选择：从源码编译 / 提供已有包路径 / 禁用该模块。若选择推动子仓库完成 ARM 适配，可先跳过该依赖，适配完成后再重新编译主仓库。

---

## Skill 目录结构

```
cpp-kunpeng-migration/
├── SKILL.md                                          # 主控入口（六阶段流程编排）
├── README.md                                         # 使用说明
├── prompt.md                                         # 提示词模板
├── environment-prepare/                              # 阶段 1 子 Skill：环境检测与准备
│   ├── environment-prepare.md
│   ├── references/
│   │   ├── build-tools-reference.md                  # 构建工具下载链接
│   │   ├── bazel-handling.md                         # Bazel 构建系统处理
│   │   ├── blade-handling.md                         # Blade 构建系统处理
│   │   └── protobuf-version-check.md                 # protobuf 版本核对
│   └── assets/
│       ├── environment-check-report-template.md      # 环境检测报告模板
│       └── pending-items-template.md                 # 待确认项模板
├── dependency-analysis/                              # 阶段 2 子 Skill：依赖分析与 ARM 兼容性探测
│   ├── dependency-analysis.md                        # 依赖分析子 Skill 主控
│   ├── references/
│   │   ├── repo-analysis-flow.md                     # 单仓库分析闭环步骤
│   │   ├── compat-and-binary-detect.md               # 通用 Kunpeng 兼容性探测 + 预编译二进制识别
│   │   ├── kunpeng-confirmed-write.md                # 阶段 3：写入确认清单 + 执行切换
│   │   └── build-system-dep-scan.md                  # 四构建系统合集（Bazel/CMake/Blade/SCons 按章节按需加载）
│   └── assets/
│       ├── kunpeng_confirmed_template.md             # ARM 适配确认清单模板（首次使用复制到 $WORK_DIR 作可写实例）
│       └── report-template-example.md                # 报告输出模板
├── source-migration-scan/                            # 阶段 4 子 Skill：源码迁移扫描与适配
│   ├── source-migration-scan.md                      # 完整扫描 + 适配流程
│   ├── references/
│   │   ├── devkit-download.md                        # DevKit CLI 下载说明
│   │   ├── build-system-flags.md                     # 构建系统编译标志适配
│   │   ├── inline-asm-migration.md                   # 内联汇编迁移
│   │   ├── intrinsics-migration.md                   # intrinsics 指令迁移
│   │   ├── mkl-migration.md                          # MKL 库迁移
│   │   └── x86-header-migration.md                   # x86 专属头文件迁移
│   └── scripts/
│       ├── devkit_download.sh                        # DevKit 自动下载安装脚本
│       ├── devkit_report_summary.sh                  # 扫描报告汇总脚本
│       ├── devkit_summary_read.sh                    # 扫描报告读取脚本
│       └── ksl_install.sh                            # KSL 安装脚本
├── sourcecode-build-verify/                          # 阶段 5 子 Skill：编译验证与循环修复
│   ├── sourcecode-build-verify.md
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
    ├── migration-summary.md
    └── assets/
        └── migration_summary_report_template.md      # 迁移总结报告模板
```

---

## 参考资源

- [鲲鹏 DevKit](https://www.hikunpeng.com/developer/devkit) — 获取 DevKit 工具
- [SKILL.md](cpp-kunpeng-migration/SKILL.md) — 完整的六阶段流程编排文档
- [prompt.md](prompt.md) — 使用提示词模板
