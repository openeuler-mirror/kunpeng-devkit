---
name: cpp-kunpeng-migration
description: C/C++ 项目 x86→鲲鹏（aarch64）源码迁移主控 Skill。当用户需要将 C/C++ 项目适配到鲲鹏平台，或实现 x86 与鲲鹏双架构兼容构建和运行时使用。支持 Bazel、CMake、Make、Blade、SCons 等构建系统，负责环境检测、依赖分析、兼容性改造、编译验证及问题迭代。不用于非 C/C++ 项目或非鲲鹏平台迁移。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
---

# C/C++ 项目 Kunpeng 迁移主控 Skill

## 核心原则

- **双架构兼容**：所有修改必须使项目**同时**支持 x86 和 鲲鹏架构 编译。通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，**不破坏原有 x86 能力**
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物放到项目目录之外的专用工作目录，不污染源码树
- **子 agent 边界**：阶段 1、2 以子 agent 模式执行，子 agent **不直接向用户提问**，所有需用户决策的项以结构化"待确认项"写入中间文件，由主 agent 在阶段 3 统一提问
- **一次性信息收集**：所有需要用户提供的信息**在阶段 3 一次性问清楚**，不在后续流程中反复打断用户
- **子仓库优先**：存在私有仓库依赖时，优先推动子仓库完成 Kunpeng 适配后再编译主仓库

---

## 整体流程

> 阶段 1（环境检测与准备，子 agent）→ 阶段 2（依赖分析，子 agent）→ 阶段 3（汇总待确认项，等待用户回复）→ 阶段 4 → 阶段 5 → 阶段 6

> **关键约束**：
> - 阶段 3 确认闸门：待确认项汇总后暂停等待用户回复，**未获得用户明确确认前不进入阶段 4**
> - 阶段 4 内部**严格串行**：必须先完成 DevKit 扫描并拿到报告，再开始源码/构建修改，**不可并行**
> - 阶段 4 和 5 的所有修改均需有**架构宏保护**，确保 x86 编译不受影响

---

## 工作目录约定

**在开始任何操作前，先确定并创建统一工作目录**。工作目录放在 **project 根目录的同级**（不是项目子目录），不污染源码树。

```bash
PROJECT_ROOT=<项目绝对路径>
WORK_DIR="$(dirname $PROJECT_ROOT)/$(basename $PROJECT_ROOT)-arm-migration"
mkdir -p $WORK_DIR/{reports,output,downloads,build,logs,devkit}
```

| 目录 | 用途 |
|------|------|
| `reports/` | DevKit 扫描报告、依赖分析报告、修改清单 |
| `output/` | 最终展示产物：总结报告、迁移 patch |
| `downloads/` | 依赖源码包、Kunpeng 预编译库下载 |
| `build/` | 第三方库临时编译安装目录 |
| `logs/` | 每轮编译日志（`build_1.log`、`build_2.log`…） |
| `devkit/` | DevKit CLI 包解压安装目录（`devkit` 可执行文件所在） |

---

## 阶段时间戳记录

主 agent 在每个阶段的开始和结束时，向时间线日志追加记录，供阶段 6 生成时长统计：

```bash
# 阶段开始时
echo "PHASE_1_START|$(date '+%Y-%m-%d %H:%M:%S')" >> $WORK_DIR/reports/timeline.log

# 阶段结束时
echo "PHASE_1_END|$(date '+%Y-%m-%d %H:%M:%S')" >> $WORK_DIR/reports/timeline.log
```

阶段编号：1 / 2 / 3 / 4 / 5 / 6。若某阶段因人工介入未正常结束，记录 `PHASE_X_ABORT|<时间戳>`。

---

## 子 agent 待确认项输出契约

阶段 1、2 子 agent 把需用户决策的项按本契约写入中间文件（子 agent 边界与调起方式见「核心原则」与文末「调起约定与跨助手适配」）。

### 待确认项文件

| 阶段 | 中间文件路径 | 内容 |
|------|------------|------|
| 阶段 1 | `$WORK_DIR/reports/stage_1_pending_items.md` | 环境检测版本不一致项 |
| 阶段 2 | `$WORK_DIR/reports/stage_2_pending_items.md` | 依赖冲突项 |
| 阶段 2 | `$WORK_DIR/reports/stage_2_switch_list.md` | 命中 `kunpeng_confirmed.md` 的待切换依赖（已知 Kunpeng 适配，无需提问，供阶段 3.4 切换） |

### 待确认项格式（YAML 风格代码块）

每条待确认项为一个 YAML 代码块，便于主 agent 解析：

```yaml
- id: env_bazel_version            # 全局唯一，env_ 前缀=阶段1，dep_ 前缀=阶段2
  category: 环境检测                # 环境检测 / 依赖分析
  question: "Bazel 项目需要 4.0.0，ARM 已安装 5.0.0，如何处理？"
  options:
    - id: install_required
      label: "安装项目指定版本 4.0.0"
    - id: use_installed
      label: "使用已安装版本 5.0.0"
    - id: abort
      label: "中止"
  context: "项目 .bazelversion 指定 4.0.0；arm64 bazel --version 输出 5.0.0"  # 可选，决策依据
  priority: P1                      # 可选，仅阶段2，P0/P1/P2/P3
```

### 输出规则

1. 无待确认项时文件标注"无待确认项"（主 agent 据此跳过提问）；用户回复由主 agent 写入 `$WORK_DIR/reports/user_decisions.txt`
2. **命中 `kunpeng_confirmed.md` 的依赖不生成待确认项**：改为写入待切换清单（stage_2_switch_list.md）

---

## 阶段 1：环境检测与准备（子 agent）

> 以子 agent 模式执行 [environment-prepare.md](environment-prepare/environment-prepare.md)（`description: "阶段1-环境检测与准备"`）；调起方式、路径变量传入、子 agent 边界统一见文末「调起约定与跨助手适配」。冲突项写入 `$WORK_DIR/reports/stage_1_pending_items.md`（格式见「子 agent 待确认项输出契约」），**不在本阶段提问**。

**本阶段目标**：确认 Kunpeng 环境具备编译条件，输出环境检测报告到 `$WORK_DIR/reports/environment_check_report.md`，并输出待确认项清单到 `$WORK_DIR/reports/stage_1_pending_items.md`。

**阶段 1 完成后**：读取待确认项清单，直接进入阶段 2（待确认项在阶段 3 统一提问）。

**待确认项场景**（每个冲突项 = 一条待确认项，子 agent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| Bazel 项目要求 X.Y，Kunpeng 已装 X'.Y' | `"Bazel 项目需要 X.Y，ARM 已安装 X'.Y'，如何处理？"` 选项：安装项目指定版本 / 使用已安装版本 / 中止 |
| protoc 版本与项目 protobuf 版本不匹配 | `"ARM 上 protoc 为 X，项目使用 protobuf Y，如何处理？"` 选项：为 ARM 重新编译匹配版 protoc / 中止 |
| Blade 版本不支持 arm64 | `"Blade 版本过旧不支持 arm64，需要升级，是否确认？"` 选项：确认升级 / 中止 |
| 磁盘可用空间低于阈值 | `"项目代码 X MB，估算所需空间 Y GB，当前可用 Z GB，如何处理？"` 选项：更改产物落盘地址到空间充足的分区 / 中止 |
| 所有工具版本均一致 | 追加一条"确认继续"总项即可 |

---

## 阶段 2：依赖分析与 Kunpeng 兼容性探测（子 agent）

> 以子 agent 模式执行 [dependency-analysis.md](dependency-analysis/dependency-analysis.md)（`description: "阶段2-依赖分析与ARM兼容性探测"`）；调起方式、路径变量传入、子 agent 边界统一见文末「调起约定与跨助手适配」。冲突项写入 `$WORK_DIR/reports/stage_2_pending_items.md`；命中 `kunpeng_confirmed.md` 的依赖写入 `$WORK_DIR/reports/stage_2_switch_list.md` 待切换清单（格式见「子 agent 待确认项输出契约」），**不在本阶段提问**。

**本阶段目标**：全面分析项目所有外部依赖，评估每个依赖的 Kunpeng 兼容性，输出依赖分析报告，并输出待确认项清单与待切换清单。

**阶段 2 完成后**：读取待确认项清单与待切换清单，进入阶段 3（待确认项在阶段 3 统一提问，待切换清单在阶段 3.4 经用户确认后切换）。

**待确认项场景**（每个冲突项 = 一条待确认项，子 agent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| 私有库无 Kunpeng 预编译包 | `"libXXX 无 Kunpeng 版本，如何处理？"` 选项：从源码编译 / 提供已有包路径 / 禁用该模块 |
| 私有库有 ARM 分支但不确定是否可用 | `"@xxx ARM 分支 arm64 是否可用？"` 选项：可用 / 不确定请等待 / 跳过 |
| 依赖版本冲突（项目需求 A.B， Kunpeng 环境只有 A'.B'） | `"XXX 项目需求版本 A.B，Kunpeng 环境已有 A'.B'，如何处理？"` 选项：使用 A'.B' / 升级 / 中止 |
| x86 专属 AVX 指令在 ARM 是否保留 | `"AVX 加速指令在 ARM 如何替代？"` 选项：使用鲲鹏加速库 KSL / 使用 NEON 替代 AVX / 禁用 |
| x86 专属 Intel 数学库 MKL 在 ARM 是否保留 | `"Intel 数学库 MKL 在 ARM 如何替代？"` 选项：使用鲲鹏数学库 KML 替代 MKL / 使用 OpenBLAS 替代 MKL / 禁用 |
| 所有依赖均已确认 | 追加一条"确认开始迁移"总项 |

---

## 阶段 3：汇总子 agent 待确认项 + 等待用户确认

> **硬性约束**：本阶段**必须调用交互式提问工具阻塞等待用户真实回复**（工具映射与"不得用纯文本代替"规则见文末「调起约定与跨助手适配」）——纯文本无结构化选项、不阻塞、易被自答，会架空确认闸门。阶段 1、2 子 agent 已将待确认项写入中间文件，本阶段统一收集并提问；即使无疑问项也必须确认"是否继续"，**未获用户明确回复前不得进入阶段 4**。

### 3.1 汇总两份待确认项清单

读取阶段 1、2 两个子 agent 输出的待确认项中间文件：

```bash
cat $WORK_DIR/reports/stage_1_pending_items.md
cat $WORK_DIR/reports/stage_2_pending_items.md
```

合并去重后形成统一待确认清单。每条待确认项含 `id`、`category`（环境检测 / 依赖分析）、`question`、`options`。

### 3.2 向用户提问（强制）

> 「向用户提问」= 调用交互式提问工具提交结构化 question（含 `id`/`prompt`/`options`）并阻塞，**不是在回复正文里打问句**（详见文末「调起约定与跨助手适配」）。

**每个独立决策点 = 一个 question 条目**。即使全部可自动推断，也要至少追加：

```
question id="confirm_proceed"
prompt="以上是环境检测与依赖分析摘要，是否确认开始 Kunpeng 迁移？"
options:
  - id="yes"   label="确认，开始迁移"
  - id="review" label="我需要先确认某些依赖，请等待"
  - id="abort"  label="中止"
```

> 若待确认项数量超过单次提问上限（多数助手的提问工具单次最多 4 个 question），分批提问，每批不超过 4 个。

### 3.3 等待用户回复（严格阻塞）

收到回复后：
- 将用户选择逐条记录到 `$WORK_DIR/reports/user_decisions.txt`
- 对"跳过"项记录降级方案；对"中止"立即终止流程

### 3.4 登记清单 + 确认切换 + 校验

> **必须读取文件 `dependency-analysis/references/kunpeng-confirmed-write.md` 获取完整执行步骤。**

本步骤在阶段 3 末尾一次性完成三件事：
1. **登记**：把用户确认的依赖 Kunpeng 适配信息按依赖库写入 `$WORK_DIR/kunpeng_confirmed.md`
2. **确认切换**：把待切换清单**逐项向用户确认**后，立即把构建配置分支/commit/URL 切换为清单记录的 Kunpeng 版本
3. **校验**：切换后逐项核对分支是否真切到 Kunpeng 版（一句话提醒：切错会让后续编译错误极难排查）

> **分支切换必须用户确认**：清单记录的 ARM 分支未必与当前项目实际一致，切错会导致编译错误极难排查、迁移成本陡增——未获用户逐项确认不得执行任何切换命令。切换在阶段 3 末尾完成，阶段 4 不再涉及分支切换。

**校验通过后**，阶段 3 结束，进入阶段 4。

---

## 阶段 4：源码迁移扫描与适配（严格串行）

> **必须立即读取文件 `source-migration-scan.md` 获取完整执行步骤。**

**本阶段目标**：先运行 DevKit 扫描发现源码 x86 专属问题，**扫描结束后**再根据报告结果完成构建系统配置适配与源码修改。

> **硬性约束（严格串行，不可并行）**：
>
> 阶段 4 内部分为**两个不可并行的子步骤**：
>
> 1. **4.1 DevKit 扫描**（门控步骤）：必须先完成 DevKit 扫描并生成报告，**在此期间不得进行任何源码或构建配置修改**
> 2. **4.2 构建配置 + 源码适配**：**必须等待 4.1 扫描结束后**，根据扫描报告的指导再开始修改。扫描报告会明确指出哪些文件存在 x86 专属问题及修改建议，直接指导 4.2 的修改范围和优先级
>
> **不可并行的原因**：DevKit 扫描结果对后续修改有**直接指导作用**——它会定位需要修改的源文件、指出问题类型（内联汇编 / intrinsics / 头文件 / 类型大小等）、给出修改建议。如果先修改再扫描，可能遗漏问题或做重复/冲突修改。因此**必须先等扫描结束、拿到报告，再开始源码和构建适配**。
>
> 阶段 4 开始前必须先定位包含 `ai-migration` 可执行文件的 Kunpeng AI Migration Tool 工具包：优先检查用户提供的 `AI_MIGRATION_DIR`、`/opt/huawei/devkit/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration` 和 `$WORK_DIR/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration`；均未找到时，先按 `source-migration-scan.md` 4.1.1 的默认配置自动尝试直链下载，只有下载、解压或校验失败后才进入确认流程，请求用户提供路径、确认重试/手动下载或中止。定位成功后将工具包目录记录为 `AI_MIGRATION_DIR`，所有 `source-migration` 子命令统一使用 `${AI_MIGRATION_DIR}/ai-migration`，不直接查找或调用 Skill 目录下的脚本。
>
> 阶段 4 只做源码迁移扫描与适配——依赖分支切换已在阶段 3 末尾完成，此处不再切换。
>
> **DevKit 扫描报告是阶段 5 错误修复的最高优先级参考依据，路径 `$WORK_DIR/reports/devkit-*/`。**

**阶段 4 完成后**，进入阶段 5。
---

## 阶段 5：编译验证循环

> **必须立即读取文件 `sourcecode-build-verify.md` 获取完整执行步骤。**

**本阶段目标**：循环执行编译验证，直到编译成功或人工介入。

**错误修复优先级（两级查询，详见 sourcecode-build-verify.md 5.2/5.5 节）**：
- **第1级**：查 [build-error-quickfix.md](sourcecode-build-verify/references/build-error-quickfix.md) 速查表（扁平关键字表，扫描快），命中则按「修复」列描述修复
- **第2级**：速查表未命中时，查 [migration-cases/](sourcecode-build-verify/references/migration-cases/) 案例库（generic/version/project 路由索引 → 详细案例，结构化教案兜底），命中则按案例修复；**每次查询须在交互界面输出醒目标识**（格式见 sourcecode-build-verify.md 5.5 节）
- **阻塞性问题**：遇到代码仓权限、依赖库版本严重不符、编译环境严重不符等阻塞性问题时，停止自动修复并**必须向用户提问**，请用户选择处理方案（详见 sourcecode-build-verify.md 2.1 节）
- **报告目录不存在**：回到阶段 4 重新执行 DevKit 扫描，不得跳过

**阶段 5 编译成功后**，进入阶段 6。

---

## 阶段 6：迁移总结报告

> **必须立即读取文件 `migration-summary.md` 获取完整执行步骤。**

**本阶段目标**：汇总整个迁移过程，生成结构化总结报告，包含各阶段执行时长、修改文件清单及修改点描述、重要提示与建议；并生成 patch 文件（含源码 + 构建配置改动，排除 `.so`/`.a` 等二进制文件）供归档与跨环境应用。

**触发条件**：
- 阶段 5 编译成功 → 正常生成完整总结报告

**报告保存路径**：`$WORK_DIR/output/migration_summary_report.md`
**patch 保存路径**：`$WORK_DIR/output/migration.patch`（排除二进制文件）

**报告生成后**：向用户醒目展示报告中的"建议关注"项。

---

## 子 Skill

本主 Skill 包含以下子模块，阶段 1、2 均为子 Skill（以子 agent 模式执行，含完整方法与输入/输出契约，由主 agent 拉起子 agent），阶段 4、5、6 为子 Skill（由主 agent 直接调用）：

| 子模块 | 入口文件 | 用途 |
|----------|----------|------|
| `environment-prepare` | [environment-prepare.md](environment-prepare/environment-prepare.md) | 阶段 1 子 Skill：环境检测与编译环境准备（含输入/输出契约、待确认项格式） |
| `dependency-analysis` | [dependency-analysis.md](dependency-analysis/dependency-analysis.md) | 阶段 2 子 Skill：依赖分析与 Kunpeng 兼容性探测（含输入/输出契约、待确认项/待切换清单格式） |
| `source-migration-scan` | [source-migration-scan.md](source-migration-scan/source-migration-scan.md) | 阶段 4 子 Skill：源码迁移扫描与适配（含输入/输出契约、DevKit 下载与扫描流程） |
| `sourcecode-build-verify` | [sourcecode-build-verify.md](sourcecode-build-verify/sourcecode-build-verify.md) | 阶段 5 子 Skill：编译验证与循环修复（含 build-error-quickfix 速查表、migration-cases 案例库） |
| `migration-summary` | [migration-summary.md](migration-summary/migration-summary.md) | 阶段 6 子 Skill：迁移总结报告生成与 patch 导出（含各阶段时长统计、修改文件清单、重要提示、patch 生成排除二进制） |

> 各子 Skill 目录下的引用文档（references / scripts / assets）由子 Skill 自行管理，详见对应子 Skill 文档，主 Skill 不再逐一列举。

---

## 调起约定与跨助手适配

本 Skill 的阶段 1、2 以**子 agent** 模式执行（阶段 1 用 environment-prepare.md、阶段 2 用 dependency-analysis.md 的提示词模板）。为支持不同编程助手，调起方式与工具调用统一采用语义描述，具体 API 按运行环境映射。

### 子 agent 调起语义

主 agent 读取对应子 Skill 的入口文档，把已知的三个路径变量（`PROJECT_ROOT` / `WORK_DIR` / `SKILL_DIR`）传入后，**作为提示词拉起一个独立上下文的子 agent 执行**。子 agent 在自己的上下文里完成检测/分析，把报告与待确认项写入中间文件，最终向主 agent 返回摘要。

**子 agent 边界（重要）**：子 agent **不向用户提问**--所有需用户决策的项一律按「子 agent 待确认项输出契约」写入中间文件，由主 agent 在阶段 3 统一提问。这条边界是阶段 1、2 的核心约束：避免子 agent 在独立上下文里打断用户、也避免主 agent 漏收待确认项。正文各阶段不再重复此约束，统一以本节为准。

### 各助手映射（示例，可扩展）

| 编程助手 | 子 agent 调起方式 | 读取文件 | 写入文件 | 执行 shell 命令 | 向用户提问（必须用此工具，不得以纯文本代替） |
|---|---|---|---|---|---|
| Claude Code | Agent 工具（`subagent_type: general-purpose`） | Read | Write | Bash | `AskUserQuestion`（阻塞，headless 可用） |
| OpenCode | `task` 工具 | read | write | bash | question |
| CatPaw IDE | `task` 工具（`subagent_type` / `prompt` / `description`） | `read_file` | `write` | `run_terminal_cmd` | `AskQuestion` |

> 本 Skill 正文及 agent 模板中一律用「读取文件 / 写入文件 / 执行 shell 命令 / 向用户提问」等语义动词表述，运行时请按下表映射到你所用助手的对应工具。其中「向用户提问」是唯一可能被纯文本输出"假装"完成的动作——**必须落到上表工具，不得用回复正文代替**。

