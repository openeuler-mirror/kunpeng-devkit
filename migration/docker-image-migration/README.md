# docker-image-migration Skill

将 x86_64 Docker 镜像自动迁移到 linux/arm64（鲲鹏）平台，覆盖有 Dockerfile 的直接迁移与无 Dockerfile 的镜像逆向重构两类场景的 AI 编程技能包。

---

## 目录

- [简介](#简介)
- [功能特性](#功能特性)
- [适用场景](#适用场景)
- [环境要求](#环境要求)
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

`docker-image-migration` 是一个面向 Docker 镜像的 ARM 架构迁移自动化 Skill。它将迁移过程拆解为 **场景选择 → 启动门禁 → 任务上下文注入 → 场景阶段执行 → 报告生成与知识沉淀** 的主控流程，由主 Skill 统一调度，根据是否存在 Dockerfile 路由到不同子场景文件，最大限度减少人工介入。

**核心设计原则**：

- **单一事实来源**：全局调度、告警和失败规则以 `SKILL.md` 为准；场景文件只定义该场景特有的阶段和动作，不重复定义调度与重试策略
- **非侵入式探测**：不在 x86_64 机器上执行系统级变更（安装系统软件、修改系统配置、改写软件源等）；需要运行 x86_64 容器的采集/扫描操作统一通过工作目录中的 `ai-migration` 预编译二进制经 SSH 远程调用（`${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>`），不用 `python3` 直接运行脚本；需要系统级变更时必须先获得用户明确确认
- **系统环境变更确认**：任何对宿主机（ARM64 主控端或 x86_64 远程采集机）系统环境的变更（安装/升级软件、修改配置、启停服务、修改用户组等），执行前必须交互式请求用户确认，未确认前不得执行；容器内操作和工作目录文件读写不在此列
- **有证据才判定**：所有失败判定都必须附证据，失败前必须先检索 `references/build_knowledge_reference.md`，只有「已检索且无可用方案」时才能进入失败判定

---

## 功能特性

- **双场景路由**：自动识别有 Dockerfile与无 Dockerfile两类场景，按对应子 Skill 流程执行
- **启动门禁检查**：迁移前依次校验输入与配置、Docker、Registry 与镜像源、软件包源四类门禁，任一未通过不得跳过
- **受控并发执行**：支持1-5 的并发任务调度，主 Agent 串行写入汇总文件与知识库，避免并发覆盖
- **DevKit pkg-mig 集成**：调用鲲鹏 DevKit 工具对 native 库进行结构化扫描，识别 x86_64 不兼容文件
- **失败自动修复**：基于知识库驱动错误修复，未收录的修复标记 待人工复核
- **知识沉淀与中断恢复**：阶段记录文件支持断点续跑；已成功且具备复用价值的修复可沉淀进知识库（需用户确认）
- **多架构兼容探测**：自动检测当前机器能否构建 ARM64 镜像，不能构建时跳过实际构建步骤，仅在报告中标记"环境架构不匹配"

---

## 适用场景

- x86_64 Docker 镜像需要迁移到鲲鹏平台
- 存在可访问的 Dockerfile 和源码/构建上下文，希望基于源码重新构建 ARM64 镜像
- 仅有镜像本身可访问（无 Dockerfile），需要通过 manifest/history/layer 逆向重构 ARM64 Dockerfile
- 批量镜像迁移，需要并发执行与统一汇总报告
- 私有镜像仓内部镜像迁移，需要处理内网 Git/PyPI/Registry 依赖

> **不适用范围**：Windows 容器迁移、非 Docker 场景（裸机或 VM）、仅需人工替换单行的极简任务、history 完全不可读且镜像不可运行的场景。

---

## 环境要求

| 依赖项                    | 要求                                                         |
| ------------------------- | ------------------------------------------------------------ |
| 目标架构                  | ARM（aarch64 / 鲲鹏）服务器，具备编译条件                    |
| Docker                    | CLI 与 daemon 可用，具备构建权限，建议启用 BuildKit          |
| Docker Buildx             | 建议安装，优先用于获取 manifest 与 history                   |
| DevKit                    | 鲲鹏 DevKit 已安装（native 库扫描所需，`which devkit` 可查） |
| `ai-migration` 可执行文件 | 镜像采集与分析的统一命令入口（**预编译二进制**），子命令格式 `ai-migration image-migration <subcommand>`（提供 `collect-x86` / `collect` / `analyze` / `diff` / `env` / `layout` / `get-safe-name` 子命令）。ARM 工具包（`DevKit-AI-Migration-Tool-<version>-Linux-Kunpeng`）和 x86 工具包（`...-Linux-x86-64`）在 ARM64 主控端和 x86_64 采集机上按优先级定位：先查 DevKit 安装目录 `/opt/huawei/devkit`（`ls /opt/huawei/devkit/DevKit-AI-Migration-Tool-*/ai-migration`），无则查**工作目录**（`ls <工作目录>/DevKit-AI-Migration-Tool-*/ai-migration`），仍无则下载。采集相关代码已随二进制嵌入 `_internal/`，**不存在可直接运行的 `collect.py`、`analyze.py` 等 Python 脚本**，所有机器禁止用 `python3` 直接调用采集/分析/扫描命令。`/opt/huawei/devkit` 与工作目录均无时，从 `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}` 下载对应架构工具包（版本号 `${AI_MIGRATION_TOOL_VERSION}`，二者在 `config_reference.md` §9 集中维护）到工作目录，本机网络不通时由另一台机器下载后传输，两台机器网络均不可用且两处均无工具包时请求用户上传或提供路径。详细定位与获取方法见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「工具定位」 |
| x86_64 采集机             | 无 Dockerfile 逆向重构场景的采集主力（manifest + history + layer 均在 x86_64 采集机采集）；需要采集 x86_64 镜像的 manifest + history、采集 layer 或执行 inspect 时必需。要求一台可 SSH 的 x86_64 机器，可获取 x86 工具包（`ai-migration` 可执行文件，优先复用 `/opt/huawei/devkit` 安装目录，无则置入工作目录）+ Docker 可用。有 Dockerfile 的直接迁移场景无需此机器 |
| CatPaw IDE                | 版本 ≥ 3.3.21（如使用 CatPaw IDE 运行 Skill）                |

---

## Skill 目录结构

```
docker-image-migration/
├── SKILL.md                                          # 主控入口（场景路由 + 启动门禁 + 全局执行红线）
├── templates/
│   ├── dockerfile_migration_report_template.md       # 单项目报告 + 总览报告 JSON 模板（dockerfile-migration 场景）
│   └── image_reconstruction_report_template.md       # 单项目报告 + 总览报告 JSON 模板（image-reconstruction 场景）
├── asserts/
│   └── decision_matrix.md                        # 逆向分析决策矩阵模板
└── references/
    ├── build_knowledge_reference.md                  # 构建错误知识库
    ├── config_reference.md                           # 配置参数说明与默认值（用户可自定义配置参数）
    ├── devkit_pkg_mig_reference.md                   # DevKit pkg-mig 工具可用性检查与扫描规范
    ├── image_collector_cli_reference.md              # image-migration 统一命令参考（collect / collect-x86 / analyze / diff / env / layout / get-safe-name；含采集边界、环境依赖、Registry 读取优先级）
    ├── x86_remote_setup_reference.md                 # x86_64 远程采集机环境准备参考（工具包定位 / 环境检查）
    ├── dockerfile_migration.md                       # 子场景 A：有 Dockerfile 直接迁移流程说明
    └── image_reconstruction.md                       # 子场景 B：无 Dockerfile 逆向重构流程说明
```

> 注：x86_64 采集机采集所需的 `x86_remote_collector/` 代码（env / layout / get-safe-name 子命令实现 + `.sh` 内层脚本）已**嵌入工作目录中工具包的预编译二进制 `_internal/`**，运行时由 `ai-migration` 自动加载。

---

## 安装方式

`docker-image-migration` 遵循开放 Skill 标准（核心为 `SKILL.md` + YAML 前置声明），可在 CatPaw IDE、VS Code、Claude Code 等支持 Skill 的编程 Agent 中通用。

### CatPaw IDE

#### 方式一：项目级安装（推荐，随项目共享）

将 `docker-image-migration` 整个文件夹复制到项目根目录的 `.catpaw/skills/` 下：

```bash
# 在项目根目录执行
mkdir -p .catpaw/skills
cp -r <path-to>/docker-image-migration .catpaw/skills/
```

安装后重启 CatPaw IDE，在 AI 对话窗口调用技能，出现"调用 skills"提示即成功。

#### 方式二：全局级安装（跨项目复用）

将 `docker-image-migration` 文件夹复制到全局技能目录：

```bash
# Windows
C:\Users\<你的用户名>\.catpaw\skills\

# macOS / Linux
~/.catpaw/skills/
```

安装后重启 CatPaw IDE 即可全局调用。

#### 方式三：ZIP 包可视化导入

1. 将 `docker-image-migration` 文件夹打包为 ZIP（根目录需包含 `SKILL.md`）
2. 打开 CatPaw → 设置（齿轮图标）→ 规则与技能 → 技能
3. 点击「+ 创建」→ 选择压缩包导入，AI 自动解析配置
4. 选择"项目级"或"全局级"，确认安装

### VS Code (GitHub Copilot)

将 `docker-image-migration` 文件夹放入以下任一目录：

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

将 `docker-image-migration` 文件夹放入以下目录：

```bash
# 项目级
<项目根目录>/.claude/skills/

# 个人级
~/.claude/skills/
```

Claude Code 支持 Subagent 特性，并发模式（`WORKER_COUNT >= 2`）的子 Agent 调度与 Claude Code 的 Subagent 机制天然契合。

### 其他编程 Agent

任何支持开放 Skill 标准（`SKILL.md` + YAML 前置声明）的 AI 编程助手均可使用本 Skill。将 `docker-image-migration` 文件夹放入对应工具的技能目录即可，具体路径请参考该工具的文档。

---

## 使用方式

### 步骤一：打开 AI 对话窗口

在已安装 Skill 的 IDE 中打开 AI 对话窗口（CatPaw IDE 按 `Ctrl+L` / `Cmd+L`）。

### 步骤二：提供镜像信息并触发 Skill

在对话窗口中填入镜像信息并发送：

```text
请帮我将以下 Docker 镜像从 x86_64 迁移到 ARM64（鲲鹏 linux/arm64）。

【场景信息】（二选一）
- 有 Dockerfile 场景：Dockerfile 路径 + 构建上下文路径
- 无 Dockerfile 场景：已采集产物路径（manifest/history/layer）；若未提供，需提供可访问源镜像以便自动采集

【访问凭据】（可选，仅在需要认证时提供）
- Registry / Git / 软件源访问凭据

【执行要求】
按 docker-image-migration skill 流程执行（场景选择 → 启动门禁 → 任务上下文注入 → 场景阶段执行 → 报告生成与知识沉淀）。
- 所有失败判定必须附证据，失败前必须先检索 references/build_knowledge_reference.md
```

也可以直接描述迁移意图触发 Skill，Skill 会根据提供的资源自动选择对应场景：

**场景一：有 Dockerfile（五阶段流程）**

```text
帮我把 /home/user/my-app 这个项目迁移到 ARM64 鲲鹏架构，Dockerfile 在 /home/user/my-app/Dockerfile，构建上下文为 /home/user/my-app/。
```

**场景二：无 Dockerfile（六阶段流程）**

```text
帮我把 registry.example.com/team/app:v1 这个 x86 镜像迁移到 ARM64 鲲鹏架构，没有 Dockerfile，需要逆向重构。
```

### 步骤三：按场景交互

Skill 启动后会自动按流程执行。**关键交互点**包括：

1. **信息补齐**：当输入信息不完整时，Skill 会暂停并通过交互提示引导用户补齐所需信息（待迁移镜像、Dockerfile 或采集产物路径、访问凭据等），信息补齐前不会继续执行
2. **门禁未通过**：当配置占位符未替换、镜像不存在、Registry 不可达等情况发生时，Skill 会暂停并请求用户确认后再继续
3. **镜像层采集确认**：在无 Dockerfile 场景下，若 ARM64 主机无法采集镜像层信息，Skill 会提示用户确认是否继续（继续可能导致构建结果不完整）
4. **DevKit 安装决策**：当未检测到 DevKit 时，Skill 会提示用户选择：手动提供安装路径 / 中止扫描

场景阶段执行完成后，Skill 自动生成单项目报告与批次总览报告。

---

## 工作流程

```
┌──────────────────────────────────────────────────────────────────┐
│  阶段 1：迁移场景选择                                                │
│  检测输入资源，路由到对应子场景                                        │
│  有 Dockerfile + 源码 → dockerfile-migration                      │ 
│  无 Dockerfile + 镜像可访问 → image-reconstruction                 │
└───────────────────────────┬──────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  阶段 2：启动门禁检查（顺序执行，任一未通过不得跳过）                      │
│  依次校验四类门禁：                                                  │
│  1. 输入与配置：GIT_HOSTS / INTERNAL_REGISTRIES 等已填实际值          │
│  2. Docker 环境、架构与磁盘：生成 DOCKER_CTX + ARCH_COMPAT           │
│  3. Registry 与镜像可达性：生成 NETWORK_CTX，镜像不存在必须暂停         │
│  4. 软件包源可达性：apt / pypi / npm / maven 等源探测                │
└───────────────────────────┬──────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  阶段 3：注入任务上下文                                              │
│  传递 TASK_CTX + 核心原则 + 全局执行红线 + 执行质量约束                 │
│  子 Agent 进入场景流程前必须先读取并确认上述规则                         │
└───────────────────────────┬──────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  阶段 4：按场景执行迁移流程                                          │
│  有 Dockerfile（5 步）：                                           │
│  1 解析 Dockerfile → 2 生成迁移决策 → 3 生成 ARM64 Dockerfile        │
│  → 4 构建验证 → 5 运行测试                                          │
│  无 Dockerfile（6 步）：                                            │
│  1 采集并分析镜像 → 2 生成迁移决策 → 3 提取内网资源                      │
│  → 4 重建 Dockerfile → 5 构建验证 → 6 测试                          │
│  标记失败前必须先检索 references/build_knowledge_reference.md 对应章节 │
└───────────────────────────┬──────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│  阶段 5：报告生成与知识沉淀                                           │
│  单项目报告 build_reports/<project>.json 完成后立即写入               │
│  全部项目完成后写 _summary.json（主 Agent 串行汇总）                   │
│  已成功且具复用价值的 NOVEL 修复经用户确认后纳入知识库                    │ 
└──────────────────────────────────────────────────────────────────┘
```

### 工作目录

Skill 会在执行目录下生成专用工作目录：

```
arm_builds_<YYYYMMDD>/
├── dockerfiles/<project>/    # 生成的 Dockerfile.arm64 + 原文件备份
├── analysis/<project>/       # 无 Dockerfile 场景的采集产物（manifest/history/layer）+ 决策矩阵
├── build_reports/            # 单项目报告 <project>.json + 总览报告 _summary.json
└── _build_context/<project>/ # 离线提取的内网资源（docker cp 产物）
```

---

## 输出产物

迁移完成后，工作目录的 `arm_builds_<YYYYMMDD>/` 下会生成以下关键产物：

| 文件                                            | 阶段     | 说明                                      |
| ----------------------------------------------- | -------- | ----------------------------------------- |
| `Dockerfile.arm64`                              | 场景阶段 | 生成的 ARM64 Dockerfile（含变更标记注释） |
| `Dockerfile.x86_orig`                           | 场景阶段 | 原 Dockerfile 备份（有 Dockerfile 场景）  |
| `manifest.json` / `history.json` / `layer.json` | 采集     | 无 Dockerfile 场景的镜像元数据采集产物    |
| `decision_matrix.md`                            | 决策     | 无 Dockerfile 场景的分析决策矩阵          |
| `build_reports/<project>.json`                  | 报告     | 单项目迁移报告（状态、变更、警告、证据）  |
| `build_reports/_summary.json`                   | 汇总     | 批次总览报告（成功率、干预记录、耗时）    |

---

## 常见问题

### Q: Skill 没有被触发怎么办？

确认 `SKILL.md` 文件名全大写，且位于正确的技能目录下。CatPaw IDE 需重启后识别新安装的 Skill。也可在对话中显式点名："使用 `docker-image-migration` 技能，帮我迁移镜像"。

### Q: DevKit 未安装怎么办？

native 库扫描阶段若未检测到 `devkit`，Skill 会通过 `AskUserQuestion` 让你选择：手动提供安装路径 / 中止当前扫描。不会跳过扫描或自行下载安装。

### Q: 构建持续失败无法自动修复怎么办？

每次失败前 Skill 会先检索 `references/build_knowledge_reference.md` 对应章节并记录命中章节号。仅当「检索无可用方案」或「已按方案尝试仍失败」时，才写 `FAILED(...)` 结论，报告中最少记录：失败命令与退出码、关键日志、检索章节、已尝试修复动作。未收录的修复先标记 `NOVEL` 待人工复核。

### Q: 私有内网镜像无 ARM64 版本怎么办？

阶段 1 会探测内网镜像的 ARM64 tag 候选（`-arm64`/`_arm64`/`-aarch64` 等）。所有候选均无效时：能从原镜像 metadata 确定等价公开基础镜像时生成 `[FALLBACK-TO-PUBLIC-BASE]` 候选（语义可能变化时需用户确认）；无法证明等价时标记 `FAILED(INTERNAL_IMAGE_UNAVAILABLE)`，由主 Agent 汇总待确认项。

### Q: 无 Dockerfile 场景下 ARM64 主机无法采集 layer 怎么办？

ARM64 主机无法运行 x86_64 容器，也无法 `docker pull`/`docker history` x86_64 镜像，因此 manifest + history + layer 均需在 x86_64 采集机采集。可通过两种方式处理：

1. **远程 x86_64 采集机（推荐）**：x86_64 采集机上定位 x86 工具包（优先 `/opt/huawei/devkit` 安装目录，无则工作目录，仍无则按下载/跨机传输/请求用户的优先级获取），通过 SSH 远程调用预编译二进制采集：`collect-x86` 采集 manifest+history（`${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 --mode base <image> --output <dir>`）、`env` 采集 layer。采用流程：x86_64 采集 manifest+history+layer → scp 回传 ARM64 → `analyze` 分析并打包。详细流程见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「拆分采集流程」和 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)。
2. **跳过 layer 采集**：无远程 x86_64 采集机时，Skill 会交互式提示："无法采集 layer 层信息，是否继续迁移？继续后构建镜像可能不完整。建议先在 x86_64 机器采集 layer 并上传后再迁移。" 用户确认继续后，ARM64 端用 `collect`（仅 registry 元数据）采集 manifest + registry history，记录 `LAYER_NOT_COLLECTED` 并继续；不继续则停止迁移等待用户上传手动采集产物。

### Q: 当前环境不能执行 ARM64 构建怎么办？

`ARCH_COMPAT=blocked` 时按场景降级处理：

- **有 Dockerfile 场景**：经用户确认可只执行阶段 1–3（解析/决策/生成），状态标记为 `FAILED` 且 `failure_reason=ARCH_BLOCKED`，不得写成迁移成功
- **无 Dockerfile 场景**：停止本地重构构建，提示切换到可用的 ARM64 或模拟构建机；可在当前环境继续完成采集与分析（阶段 1–2）

### Q: 隔离环境（AIRGAP_MODE）如何使用？

`AIRGAP_MODE=true` 时所有依赖必须走内网，公网域名标注 `[WARN-PUBLIC-URL]`。需配置 `INTERNAL_PYPI_HOSTS`、`GIT_HOSTS`、`INTERNAL_REGISTRIES` 等内网地址。启动门禁会校验内网源已配置，未配置时停止公网访问动作并请求补充配置。

### Q: 迁移会影响原有 x86 镜像吗？

不会。所有修改生成在新文件 `Dockerfile.arm64` 中，原 Dockerfile 备份为 `Dockerfile.x86_orig`，原镜像不受影响。生成的 ARM64 镜像使用 `OUTPUT_TAG_PREFIX`（默认 `arm64`）作为 tag 前缀，与原镜像隔离。

---

## 参考资源

- [鲲鹏 DevKit](https://www.hikunpeng.com/developer/devkit) — 获取 DevKit 工具
- [SKILL.md](SKILL.md) — 主控流程编排文档
- [config_reference.md](references/config_reference.md) — 配置参数说明与默认值
- [build_knowledge_reference.md](references/build_knowledge_reference.md) — 构建错误知识库
- [image_collector_cli_reference.md](references/image_collector_cli_reference.md) — `./ai-migration image-migration` 统一命令参考（`collect` / `collect-x86` / `analyze` / `diff` / `env` / `layout` / `get-safe-name`；含采集边界、环境依赖、Registry 读取优先级）
- [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md) — x86_64 远程采集机环境准备与工具包定位参考