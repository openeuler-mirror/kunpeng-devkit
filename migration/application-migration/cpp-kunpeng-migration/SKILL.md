---
name: cpp-kunpeng-migration
description: C/C++ 项目 x86→ARM（aarch64/鲲鹏）迁移的主控 Skill，专注于双架构同时兼容编译运行。提供将 C/C++ 项目从 x86 迁移到 ARM 并实现双架构同时兼容编译运行的能力，支持 Bazel/CMake/Make/Blade/SCons 构建系统，通过六阶段自动化流程（环境检测→依赖分析→用户确认→DevKit 扫描适配→编译验证循环→迁移总结报告）完成迁移。在用户要求把 C/C++ 项目适配/迁移到 ARM、鲲鹏、aarch64，或需要项目同时支持 x86 与 ARM 架构时触发。适用于 C/C++ 项目的 x86→ARM（鲲鹏）架构迁移。不适用于非 C/C++ 语言的 ARM 迁移、非鲲鹏架构的迁移。
---

# C/C++ 项目 Kunpeng 迁移主控 Skill

## 核心原则

- **双架构兼容**：所有修改必须使项目**同时**支持 x86 和 ARM 编译。通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，**不破坏原有 x86 能力**
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物放到项目目录之外的专用工作目录，不污染源码树
- **子 agent 边界**：阶段 1、2 以子 agent 模式执行，子 agent **不直接向用户提问**，所有需用户决策的项以结构化"待确认项"写入中间文件，由主编排在阶段 3 统一提问
- **一次性信息收集**：所有需要用户提供的信息**在阶段 3 一次性问清楚**，不在后续流程中反复打断用户
- **子仓库优先**：存在私有仓库依赖时，优先推动子仓库完成 Kunpeng 适配后再编译主仓库

---

## 整体流程

> **阶段 1（环境检测与准备，子 agent）** → **阶段 2（依赖分析，子 agent）** → **阶段 3（汇总子 agent 待确认项，等待用户回复）** → **阶段 4（DevKit 扫描 → 源码 & 构建适配，严格串行）** → **阶段 5（编译验证循环）** → **阶段 6（迁移总结报告）**

> **关键约束**：
> - 阶段 1、2 的子 agent **不向用户提问**，待确认项写入中间文件，由主编排在阶段 3 统一提问
> - 阶段 2 完成后，进入阶段 3 暂停等待用户回复，**未获得用户明确确认前不进入阶段 4**
> - 阶段 4 内部**严格串行**：必须先完成 DevKit 扫描并拿到报告，再开始源码/构建修改，**不可并行**
> - 阶段 4 和 5 的所有修改均需有**架构宏保护**，确保 x86 编译不受影响

---

## 工作目录约定

**在开始任何操作前，先确定并创建统一工作目录**。工作目录放在 **workspace 根目录的同级**（不是项目子目录），不污染源码树。

```bash
PROJECT_ROOT=<项目绝对路径>
WORKSPACE_ROOT=<IDE工作区根目录绝对路径>
WORK_DIR="$(dirname $WORKSPACE_ROOT)/$(basename $WORKSPACE_ROOT)-arm-migration"
mkdir -p $WORK_DIR/{reports,downloads,build,logs,devkit}
```

| 目录 | 用途 |
|------|------|
| `reports/` | DevKit 扫描报告、依赖分析报告、修改清单 |
| `downloads/` | 依赖源码包、Kunpeng 预编译库下载 |
| `build/` | 第三方库临时编译安装目录 |
| `logs/` | 每轮编译日志（`build_1.log`、`build_2.log`…） |
| `devkit/` | DevKit CLI 包解压安装目录（`devkit` 可执行文件所在） |

---

## 阶段时间戳记录

主编排在每个阶段的开始和结束时，向时间线日志追加记录，供阶段 6 生成时长统计：

```bash
# 阶段开始时
echo "PHASE_1_START|$(date '+%Y-%m-%d %H:%M:%S')" >> $WORK_DIR/reports/timeline.log

# 阶段结束时
echo "PHASE_1_END|$(date '+%Y-%m-%d %H:%M:%S')" >> $WORK_DIR/reports/timeline.log
```

阶段编号：1 / 2 / 3 / 4 / 5 / 6。若某阶段因人工介入未正常结束，记录 `PHASE_X_ABORT|<时间戳>`。

---

## 子 agent 待确认项输出契约

阶段 1、2 以子 agent 模式执行（调起方式见文末「调起约定与跨助手适配」）。子 agent **不向用户提问**，而是把需用户决策的项按本契约写入中间文件，由主编排在阶段 3 统一提问。

### 待确认项文件

| 阶段 | 中间文件路径 | 内容 |
|------|------------|------|
| 阶段 1 | `$WORK_DIR/reports/stage_1_pending_items.md` | 环境检测版本不一致项 |
| 阶段 2 | `$WORK_DIR/reports/stage_2_pending_items.md` | 依赖冲突项 |
| 阶段 2 | `$WORK_DIR/reports/stage_2_switch_list.md` | 命中 `kunpeng_confirmed.md` 的待切换依赖（已知 Kunpeng 适配，无需提问，供阶段 3.4 切换） |

### 待确认项格式（YAML 风格代码块）

每条待确认项为一个 YAML 代码块，便于主编排解析：

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

1. 无待确认项时文件标注"无待确认项"（主编排据此跳过提问）；用户回复由主编排写入 `$WORK_DIR/reports/user_decisions.txt`
2. **命中 `kunpeng_confirmed.md` 的依赖不生成待确认项**：改为写入待切换清单（stage_2_switch_list.md）

---

## 阶段 1：环境检测与准备（子 agent）

> **执行方式：阶段 1 以子 agent 模式执行 environment-prepare/SKILL.md（子 agent environment-prepare），调起方式见文末「调起约定与跨助手适配」。**
>
> **子 agent 边界**：子 agent **不向用户提问**，检测到的版本不一致项按「子 agent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_1_pending_items.md`，由主编排在阶段 3 统一提问。

**本阶段目标**：确认 Kunpeng 环境具备编译条件，输出环境检测报告到 `$WORK_DIR/reports/environment_check_report.md`，并输出待确认项清单到 `$WORK_DIR/reports/stage_1_pending_items.md`。

**阶段 1 完成后**：读取待确认项清单，**暂不提问**，直接进入阶段 2（待确认项在阶段 3 统一提问）。

### 阶段 1 子 agent 调用指令

主编排拉起阶段 1 子 agent 执行。完整执行步骤见 [SKILL.md](environment-prepare/SKILL.md)。

读取该文件全文，将其中 `<项目绝对路径>`、`<工作目录绝对路径>`、`<skill目录绝对路径>` 替换为实际值后作为子 agent 提示词传入（具体调起 API 与工具映射见文末「调起约定与跨助手适配」；`description: "阶段1-环境检测与准备"`）。

**待确认项场景**（每个冲突项 = 一条待确认项，子 agent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| Bazel 项目要求 X.Y，Kunpeng 已装 X'.Y' | `"Bazel 项目需要 X.Y，ARM 已安装 X'.Y'，如何处理？"` 选项：安装项目指定版本 / 使用已安装版本 / 中止 |
| protoc 版本与项目 protobuf 版本不匹配 | `"ARM 上 protoc 为 X，项目使用 protobuf Y，如何处理？"` 选项：为 ARM 重新编译匹配版 protoc / 中止 |
| Blade 版本不支持 arm64 | `"Blade 版本过旧不支持 arm64，需要升级，是否确认？"` 选项：确认升级 / 中止 |
| 所有工具版本均一致 | 追加一条"确认继续"总项即可 |

---

## 阶段 2：依赖分析与 Kunpeng 兼容性探测（子 agent）

> **执行方式：阶段 2 以子 agent 模式执行 dependency-analysis/SKILL.md（子 agent dependency-analysis），调起方式见文末「调起约定与跨助手适配」。**
>
> **子 agent 边界**：子 agent **不向用户提问**，检测到的依赖冲突项按「子 agent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_2_pending_items.md`；命中 `kunpeng_confirmed.md` 的依赖（已知 Kunpeng 适配）写入 `$WORK_DIR/reports/stage_2_switch_list.md` 待切换清单，由主编排在阶段 3 统一处理。

**本阶段目标**：全面分析项目所有外部依赖，评估每个依赖的 Kunpeng 兼容性，输出依赖分析报告，并输出待确认项清单与待切换清单。

**阶段 2 完成后**：读取待确认项清单与待切换清单，**暂不提问**，进入阶段 3（待确认项在阶段 3 统一提问，待切换清单在阶段 3.4 经用户确认后切换）。

### 阶段 2 子 agent 调用指令

主编排拉起阶段 2 子 agent 执行。完整执行步骤见 [SKILL.md](dependency-analysis/SKILL.md)。

读取该文件全文，将其中 `<项目绝对路径>`、`<工作目录绝对路径>`、`<skill目录绝对路径>` 替换为实际值后作为子 agent 提示词传入（具体调起 API 与工具映射见文末「调起约定与跨助手适配」；`description: "阶段2-依赖分析与ARM兼容性探测"`）。

**待确认项场景**（每个冲突项 = 一条待确认项，子 agent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| 私有库无 Kunpeng 预编译包 | `"libXXX 无 Kunpeng 版本，如何处理？"` 选项：从源码编译 / 提供已有包路径 / 禁用该模块 |
| 私有库有 ARM 分支但不确定是否可用 | `"@xxx ARM 分支 arm64 是否可用？"` 选项：可用 / 不确定请等待 / 跳过 |
| 依赖版本冲突（项目需求 A.B， Kunpeng 环境只有 A'.B'） | `"XXX 项目需求版本 A.B，Kunpeng 环境已有 A'.B'，如何处理？"` 选项：使用 A'.B' / 升级 / 中止 |
| x86 专属功能（AVX 加速等）在 ARM 是否保留 | `"AVX 加速模块在 ARM 是否保留？"` 选项：保留（NEON 替代）/ 禁用 |
| 所有依赖均已确认 | 追加一条"确认开始迁移"总项 |

---

## 阶段 3：汇总子 agent 待确认项 + 等待用户确认

> **硬性约束**：本阶段**必须调用运行环境的交互式提问工具**（Claude Code 的 `AskUserQuestion` / CatPaw 的 `AskQuestion` 等，全表见文末「调起约定与跨助手适配」）**阻塞等待用户真实回复**，**严禁以纯文本输出问题代替**——纯文本无结构化选项、不阻塞、易被自答，会架空本阶段确认闸门。阶段 1、2 的子 agent 已将待确认项写入中间文件，本阶段由主编排统一收集并提问。即使没有疑问项，也必须向用户确认"是否继续"，**严禁跳过直接进入阶段 4，不得在用户明确回复前自行推进**。

### 3.1 汇总两份待确认项清单

读取阶段 1、2 两个子 agent 输出的待确认项中间文件：

```bash
cat $WORK_DIR/reports/stage_1_pending_items.md
cat $WORK_DIR/reports/stage_2_pending_items.md
```

合并去重后形成统一待确认清单。每条待确认项含 `id`、`category`（环境检测 / 依赖分析）、`question`、`options`。

### 3.2 向用户提问（强制）

> 「向用户提问」指调用交互式提问工具提交结构化 question（含 `id`/`prompt`/`options`）并阻塞，**不是在回复正文里打一段问句**。

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
1. **登记**：把用户确认的依赖 Kunpeng 适配信息按依赖库写入 [kunpeng_confirmed.md](dependency-analysis/references/kunpeng_confirmed.md)
2. **确认切换**：把待切换清单**逐项向用户确认**后，立即把构建配置分支/commit/URL 切换为清单记录的 Kunpeng 版本
3. **校验**：切换后逐项核对分支是否真切到 Kunpeng 版（一句话提醒：切错会让后续编译错误极难排查）

> **分支切换必须用户确认**：清单记录的 ARM 分支未必与当前项目实际一致，切错会导致编译错误极难排查、迁移成本陡增——未获用户逐项确认不得执行任何切换命令。切换在阶段 3 末尾完成，阶段 4 不再涉及分支切换。

**校验通过后**，阶段 3 结束，进入阶段 4。

---

## 阶段 4：DevKit 扫描 → 构建配置 + 源码适配（严格串行）

> **必须立即读取文件 `devkit-scan/SKILL.md` 获取完整执行步骤。**

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
> `which devkit` 返回空时不允许跳过扫描，必须向用户提问让其决策：手动提供安装路径 / 由 Skill 自动下载安装 / 中止（详见 devkit-scan/SKILL.md 4.1.1）。
>
> 阶段 4 只做 DevKit 扫描与源码/构建适配——依赖分支切换已在阶段 3 末尾完成，此处不再切换。
>
> **DevKit 扫描报告是阶段 5 错误修复的最高优先级参考依据，路径 `$WORK_DIR/reports/devkit-*/`。**

**阶段 4 完成后**，进入阶段 5。
---

## 阶段 5：编译验证循环

> **必须立即读取文件 `sourcecode-build-verify/SKILL.md` 获取完整执行步骤。**

**本阶段目标**：循环执行编译验证，直到编译成功或人工介入。

**错误修复优先级（两级查询，详见 sourcecode-build-verify/SKILL.md 5.2/5.5 节）**：
- **第1级**：查 [build-error-quickfix.md](sourcecode-build-verify/references/build-error-quickfix.md) 速查表（扁平关键字表，扫描快），命中则按「修复」列描述修复
- **第2级**：速查表未命中时，查 [migration-cases/](sourcecode-build-verify/references/migration-cases/) 案例库（generic/version/project 路由索引 → 详细案例，结构化教案兜底），命中则按案例修复；**每次查询须在交互界面输出醒目标识**（格式见 sourcecode-build-verify/SKILL.md 5.5 节）
- **代码仓权限问题**：遇到代码仓无权限时，**严禁在服务器其他目录查找代码仓**，必须向用户提问，请用户提供已下载的代码仓路径（详见 sourcecode-build-verify/SKILL.md 5.2.1 节）
- **报告目录不存在**：回到阶段 4 重新执行 DevKit 扫描，不得跳过

**阶段 5 完成后**（编译成功或触发人工介入），进入阶段 6。

---

## 阶段 6：迁移总结报告

> **必须立即读取文件 `migration-summary/SKILL.md` 获取完整执行步骤。**

**本阶段目标**：汇总整个迁移过程，生成结构化总结报告，包含各阶段执行时长、修改文件清单及修改点描述、重要提示与建议。

**触发条件**：
- 阶段 5 编译成功（5.8 已执行）→ 正常生成完整总结报告
- 阶段 5 触发人工介入（5.7 已输出人工介入报告）→ 生成总结报告，标注"人工介入"状态

**报告保存路径**：`$WORK_DIR/reports/migration_summary_report.md`

**报告生成后**：向用户醒目展示报告中的"必须执行"项和"建议关注"项。

---

## 子 Skill

本主 Skill 包含以下子模块，阶段 1、2 均为子 Skill（以子 agent 模式执行，含完整方法与输入/输出契约，由主编排拉起子 agent），阶段 4、5、6 为子 Skill（由主编排直接调用）：

| 子模块 | 入口文件 | 用途 |
|----------|----------|------|
| `environment-prepare` | [SKILL.md](environment-prepare/SKILL.md) | 阶段 1 子 Skill：环境检测与编译环境准备（含输入/输出契约、待确认项格式） |
| `dependency-analysis` | [SKILL.md](dependency-analysis/SKILL.md) | 阶段 2 子 Skill：依赖分析与 Kunpeng 兼容性探测（含输入/输出契约、待确认项/待切换清单格式） |
| `devkit-scan` | [devkit-scan/SKILL.md](devkit-scan/SKILL.md) | 阶段 4 子 Skill：DevKit 扫描与源码/构建适配（含输入/输出契约、DevKit 下载与扫描流程） |
| `sourcecode-build-verify` | [sourcecode-build-verify/SKILL.md](sourcecode-build-verify/SKILL.md) | 阶段 5 子 Skill：编译验证与循环修复（含 build-error-quickfix 速查表、migration-cases 案例库） |
| `migration-summary` | [migration-summary/SKILL.md](migration-summary/SKILL.md) | 阶段 6 子 Skill：迁移总结报告生成（含各阶段时长统计、修改文件清单、重要提示） |

---

## 调起约定与跨助手适配

本 Skill 的阶段 1、2 以**子 agent** 模式执行（阶段 1 用 environment-prepare/SKILL.md、阶段 2 用 dependency-analysis/SKILL.md 的提示词模板）。为支持不同编程助手，调起方式与工具调用统一采用语义描述，具体 API 按运行环境映射。

### 子 agent 调起语义

主编排把对应 agent 模板「提示词正文」段的占位符（`<项目绝对路径>` / `<工作目录绝对路径>` / `<skill目录绝对路径>`）替换为实际值后，**作为提示词拉起一个独立上下文的子 agent 执行**。子 agent 在自己的上下文里完成检测/分析，把报告与待确认项写入中间文件，最终向主编排返回摘要。

### 各助手映射（示例，可扩展）

| 编程助手 | 子 agent 调起方式 | 读取文件 | 写入文件 | 执行 shell 命令 | 向用户提问（必须用此工具，不得以纯文本代替） |
|---|---|---|---|---|---|
| Claude Code | Agent 工具（`subagent_type: general-purpose`） | Read | Write | Bash | `AskUserQuestion`（阻塞，headless 可用） |
| OpenCode | `task` 工具 | read | write | bash | question |
| CatPaw IDE | `task` 工具（`subagent_type` / `prompt` / `description`） | `read_file` | `write` | `run_terminal_cmd` | `AskQuestion` |

> 本 Skill 正文及 agent 模板中一律用「读取文件 / 写入文件 / 执行 shell 命令 / 向用户提问」等语义动词表述，运行时请按下表映射到你所用助手的对应工具。其中「向用户提问」是唯一可能被纯文本输出"假装"完成的动作——**必须落到上表工具，不得用回复正文代替**。

---

## 附加资源

> 各子 Skill 目录下的引用文档由子 Skill 自行管理，详见对应 SKILL.md。

| 文档 | 用途 |
|------|------|
| [SKILL.md](environment-prepare/SKILL.md) | 阶段 1 子 Skill：环境检测与编译环境准备（含方法、输入/输出契约、待确认项格式、构建工具下载链接 references/build-tools-reference.md） |
| [SKILL.md](dependency-analysis/SKILL.md) | 阶段 2 子 Skill：依赖分析与 Kunpeng 兼容性探测（含方法、输入/输出契约、待确认项/待切换清单格式、kunpeng_confirmed.md 免检清单） |
| [sourcecode-build-verify/SKILL.md](sourcecode-build-verify/SKILL.md) | 阶段 5 子 Skill：编译验证与循环修复（含 build-error-quickfix 速查表、migration-cases 案例库、bazel-dual-arch-pattern 模式参考） |
| [dependency-analysis/references/kunpeng-confirmed-write.md](dependency-analysis/references/kunpeng-confirmed-write.md) | 阶段 3.4：写入 ARM 确认清单 + 执行真实切换 |
| [devkit-scan/SKILL.md](devkit-scan/SKILL.md) | 阶段 4 子 Skill：DevKit 扫描与源码/构建适配（完整扫描+适配流程见 devkit-scan/SKILL.md，含 devkit-download.md 下载说明） |
| [migration-summary/SKILL.md](migration-summary/SKILL.md) | 阶段 6：迁移总结报告生成子 Skill |
