---
name: cpp-arm-migration
description: 将 C/C++ 项目从 x86 迁移到 ARM（aarch64/鲲鹏），目标是使项目**同时**在 x86 和 ARM 上编译运行（双架构兼容）。支持 Bazel/CMake/Make/Blade/SCons 等主流构建系统。五阶段流程：① 环境检测与准备（subagent）；② 依赖分析（subagent，含 ARM 兼容性探测）；③ 汇总 subagent 待确认项并等待用户确认；④ DevKit 扫描 → 构建配置 + 源码适配（严格串行，先扫描再修改）；⑤ 循环编译验证直到成功。
---

# C/C++ 项目 ARM 迁移主控 Skill

## 核心原则

- **双架构兼容**：所有修改必须使项目**同时**支持 x86 和 ARM 编译。通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，**不破坏原有 x86 能力**
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物放到项目目录之外的专用工作目录，不污染源码树
- **subagent 边界**：阶段 A、B 以 subagent 模式执行，subagent **不直接调用 `AskUserQuestion`**，所有需用户决策的项以结构化"待确认项"写入中间文件，由主编排在阶段 C 统一提问
- **一次性信息收集**：所有需要用户提供的信息**在阶段 C 一次性问清楚**，不在后续流程中反复打断用户
- **子仓库优先**：存在私有仓库依赖时，优先推动子仓库完成 ARM 适配后再编译主仓库

---

## 整体流程

> **阶段 A（环境检测与准备，subagent）** → **阶段 B（依赖分析，subagent）** → **阶段 C（汇总 subagent 待确认项，等待用户回复）** → **阶段 D（DevKit 扫描 → 源码 & 构建适配，严格串行）** → **阶段 E（编译验证循环）**

> ⚠️ **关键约束**：
> - 阶段 A、B 的 subagent **不调用 `AskUserQuestion`**，待确认项写入中间文件，由主编排在阶段 C 统一提问
> - 阶段 B 完成后，进入阶段 C 暂停等待用户回复，**未获得用户明确确认前不进入阶段 D**
> - 阶段 D 内部**严格串行**：必须先完成 DevKit 扫描并拿到报告，再开始源码/构建修改，**不可并行**
> - 阶段 D 和 E 的所有修改均需有**架构宏保护**，确保 x86 编译不受影响

---

## 工作目录约定

**在开始任何操作前，先确定并创建统一工作目录**。工作目录放在 **workspace 根目录的同级**（不是项目子目录），不污染源码树。

```bash
PROJECT_ROOT=<项目绝对路径>
WORKSPACE_ROOT=<IDE工作区根目录绝对路径>
WORK_DIR="$(dirname $WORKSPACE_ROOT)/$(basename $WORKSPACE_ROOT)-arm-migration"
mkdir -p $WORK_DIR/{reports,downloads,build,logs,stubs}
```

| 目录 | 用途 |
|------|------|
| `reports/` | DevKit 扫描报告、依赖分析报告、修改清单 |
| `downloads/` | 依赖源码包、ARM 预编译库下载 |
| `build/` | 第三方库临时编译安装目录 |
| `logs/` | 每轮编译日志（`build_1.log`、`build_2.log`…） |
| `stubs/` | 为无 ARM 版本的私有内部库创建的桩仓库 |

---

## subagent 待确认项输出契约

阶段 A、B 以 subagent 模式执行，subagent **不调用 `AskUserQuestion`**，而是把需用户决策的项按本契约写入中间文件，由主编排在阶段 C 统一提问。

### 待确认项文件

| 阶段 | 中间文件路径 | 内容 |
|------|------------|------|
| 阶段 A | `$WORK_DIR/reports/stage_a_pending_items.md` | 环境检测版本不一致项 |
| 阶段 B | `$WORK_DIR/reports/stage_b_pending_items.md` | 依赖冲突项 |
| 阶段 B | `$WORK_DIR/reports/stage_b_switch_list.md` | 命中 `arm_confirmed.md` 的待切换依赖（已知 ARM 适配，无需提问，供阶段 C.4 切换） |

### 待确认项格式（YAML 风格代码块）

每条待确认项为一个 YAML 代码块，便于主编排解析：

```yaml
- id: env_bazel_version            # 全局唯一，env_ 前缀=阶段A，dep_ 前缀=阶段B
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
  priority: P1                      # 可选，仅阶段B，P0/P1/P2/P3
```

### 输出规则

1. **无待确认项也要输出文件**：写入空清单并标注"无待确认项"，主编排据此跳过该阶段提问
2. **占位符必须替换**：`<X.Y>`、`<依赖名>` 等占位符必须替换为实际检测值
3. **不写入用户回复**：待确认项文件只描述"待问什么"，用户回复由主编排写入 `$WORK_DIR/reports/user_decisions.txt`
4. **命中 `arm_confirmed.md` 的依赖不生成待确认项**：改为写入待切换清单（stage_b_switch_list.md）

---

## 阶段 A：环境检测与准备（subagent）

> ⛔ **硬性约束：阶段 A 必须通过 `task` 工具拉起 subagent 执行，严禁在主编排中直接执行阶段 A 的检测命令。**
>
> **subagent 边界**：阶段 A 以 subagent 模式执行 environment-prepare.md。subagent **不调用 `AskUserQuestion`**，检测到的版本不一致项按「subagent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_a_pending_items.md`，由主编排在阶段 C 统一提问。

**本阶段目标**：确认 ARM 环境具备编译条件，输出环境检测报告到 `$WORK_DIR/reports/environment_check_report.md`，并输出待确认项清单到 `$WORK_DIR/reports/stage_a_pending_items.md`。

**阶段 A 完成后**：读取待确认项清单，**暂不提问**，直接进入阶段 B（待确认项在阶段 C 统一提问）。

### 阶段 A subagent 调用指令

主编排必须使用 `task` 工具拉起阶段 A subagent，调用参数如下：

```
task(
  subagent_type: "general-agent",
  description: "阶段A-环境检测与准备",
  prompt: """你是一个 ARM 迁移环境检测 subagent。请按以下步骤执行阶段 A：环境检测与准备。

## 你的输入参数
- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <cpp-arm-migration skill 目录绝对路径>（主编排传入）

## 你的执行步骤
1. 先 read_file("$SKILL_DIR/environment-prepare.md") 获取完整执行步骤
2. 先 read_file("$SKILL_DIR/build-tools-reference.md") 获取构建工具下载链接
3. 按照 environment-prepare.md 的 1.1 ~ 1.7 步骤逐一执行环境检测
4. 使用 run_terminal_cmd 执行所有检测命令
5. 使用 read_file / grep 等工具读取项目构建配置

## 你的输出要求（硬性约束）
1. **必须**使用 write 工具将环境检测报告写入 $WORK_DIR/reports/environment_check_report.md
2. **必须**使用 write 工具将待确认项写入 $WORK_DIR/reports/stage_a_pending_items.md（格式见下方）
3. 即使无待确认项，也必须写入空清单并标注"无待确认项"
4. **严禁**调用 AskUserQuestion 工具（你没有向用户提问的权限）
5. **严禁**修改项目源码或构建配置（你只做检测和报告）
6. 完成后，在你的最终回复中输出：
   - 环境检测结论（是否具备编译条件）
   - 识别到的构建系统类型
   - 待确认项数量
   - 报告文件路径

## 待确认项格式
每条待确认项为一个 YAML 代码块：
```yaml
- id: env_<名称>            # env_ 前缀
  category: 环境检测
  question: "<具体问题>"
  options:
    - id: <选项id>
      label: "<选项标签>"
  context: "<决策依据>"
```

现在开始执行阶段 A 环境检测。"""
)
```

> ⚠️ 主编排在调用 `task` 时，必须将 `<项目绝对路径>`、`<工作目录绝对路径>`、`<skill目录绝对路径>` 替换为实际值后传入 prompt。

**待确认项场景**（每个冲突项 = 一条待确认项，subagent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| Bazel 项目要求 X.Y，ARM 已装 X'.Y' | `"Bazel 项目需要 X.Y，ARM 已安装 X'.Y'，如何处理？"` 选项：安装项目指定版本 / 使用已安装版本 / 中止 |
| protoc 版本与项目 protobuf 版本不匹配 | `"ARM 上 protoc 为 X，项目使用 protobuf Y，如何处理？"` 选项：为 ARM 重新编译匹配版 protoc / 中止 |
| Blade 版本不支持 arm64 | `"Blade 版本过旧不支持 arm64，需要升级，是否确认？"` 选项：确认升级 / 中止 |
| 所有工具版本均一致 | 追加一条"确认继续"总项即可 |

---

## 阶段 B：依赖分析与 ARM 兼容性探测（subagent）

> ⛔ **硬性约束：阶段 B 必须通过 `task` 工具拉起 subagent 执行，严禁在主编排中直接执行阶段 B 的依赖分析步骤。**
>
> **subagent 边界**：阶段 B 以 subagent 模式执行 dependency-analysis.md。subagent **不调用 `AskUserQuestion`**，检测到的依赖冲突项按「subagent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_b_pending_items.md`；命中 `arm_confirmed.md` 的依赖（已知 ARM 适配）写入 `$WORK_DIR/reports/stage_b_switch_list.md` 待切换清单，由主编排在阶段 C 统一处理。

**本阶段目标**：全面分析项目所有外部依赖，评估每个依赖的 ARM 兼容性，输出依赖分析报告，并输出待确认项清单与待切换清单。

**阶段 B 完成后**：读取待确认项清单与待切换清单，**暂不提问**，进入阶段 C（待确认项在阶段 C 统一提问，待切换清单在阶段 C.4 经用户确认后切换）。

### 阶段 B subagent 调用指令

主编排必须使用 `task` 工具拉起阶段 B subagent，调用参数如下：

```
task(
  subagent_type: "general-agent",
  description: "阶段B-依赖分析与ARM兼容性探测",
  prompt: """你是一个 ARM 迁移依赖分析 subagent。请按以下步骤执行阶段 B：依赖分析与 ARM 兼容性探测。

## 你的输入参数
- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <cpp-arm-migration skill 目录绝对路径>（主编排传入）

## 你的执行步骤
1. 先 read_file("$SKILL_DIR/dependency-analysis/dependency-analysis.md") 获取完整执行步骤（主编排文档）
2. 先 read_file("$SKILL_DIR/dependency-analysis/analyze-one-repo.md") 获取单仓库分析闭环步骤
3. 先 read_file("$SKILL_DIR/dependency-analysis/common-arm-probe.md") 获取 ARM 兼容性探测步骤
4. 先 read_file("$SKILL_DIR/dependency-analysis/common-binary-detect.md") 获取预编译二进制识别步骤
5. 根据阶段 A 识别的构建系统，read_file 对应的专用分析文件：
   - Bazel: "$SKILL_DIR/dependency-analysis/dependency-analysis-bazel.md"
   - CMake: "$SKILL_DIR/dependency-analysis/dependency-analysis-cmake.md"
   - Blade: "$SKILL_DIR/dependency-analysis/dependency-analysis-blade.md"
   - SCons: "$SKILL_DIR/dependency-analysis/dependency-analysis-scons.md"
6. 先 read_file("$SKILL_DIR/arm_confirmed.md") 读取免检清单
7. 按照上述文档的步骤逐一执行依赖分析
8. 使用 run_terminal_cmd / read_file / grep 等工具收集信息

## 你的输出要求（硬性约束）
1. **必须**使用 write 工具将依赖分析报告写入 $WORK_DIR/reports/dependency_analysis_<项目名>.md
2. **必须**使用 write 工具将待确认项写入 $WORK_DIR/reports/stage_b_pending_items.md（格式见下方）
3. **必须**使用 write 工具将待切换清单写入 $WORK_DIR/reports/stage_b_switch_list.md
4. 即使无待确认项，也必须写入空清单并标注"无待确认项"
5. **严禁**调用 AskUserQuestion 工具（你没有向用户提问的权限）
6. **严禁**修改项目源码或构建配置（你只做分析和报告）
7. 完成后，在你的最终回复中输出：
   - 依赖分析结论摘要
   - 识别到的依赖总数和分类
   - 待确认项数量
   - 待切换项数量（命中 arm_confirmed.md 的依赖）
   - 报告文件路径

## 待确认项格式
每条待确认项为一个 YAML 代码块：
```yaml
- id: dep_<依赖名>          # dep_ 前缀
  category: 依赖分析
  question: "<具体问题>"
  options:
    - id: <选项id>
      label: "<选项标签>"
  context: "<决策依据>"
  priority: P0/P1/P2/P3    # 依赖优先级
```

## 待切换清单格式
每条待切换项：
```yaml
- dep_name: <依赖名>
  arm_branch: <ARM分支或commit>
  arm_url: <ARM版本URL（如有）>
  current_ref: <当前构建配置中的引用>
  switch_action: <具体切换操作描述>
  source: arm_confirmed.md  # 来源
```

现在开始执行阶段 B 依赖分析。"""
)
```

> ⚠️ 主编排在调用 `task` 时，必须将 `<项目绝对路径>`、`<工作目录绝对路径>`、`<skill目录绝对路径>` 替换为实际值后传入 prompt。

**待确认项场景**（每个冲突项 = 一条待确认项，subagent 写入中间文件而非直接提问）：

| 检测场景 | 问题示例 |
|---|---|
| 私有库无 ARM 预编译包 | `"libXXX 无 ARM 版本，如何处理？"` 选项：从源码编译 / 提供已有包路径 / 禁用该模块 |
| 私有库有 ARM 分支但不确定是否可用 | `"@xxx ARM 分支 arm64 是否可用？"` 选项：可用 / 不确定请等待 / 跳过 |
| 依赖版本冲突（项目需求 A.B， ARM 环境只有 A'.B'） | `"XXX 项目需求版本 A.B，ARM 环境已有 A'.B'，如何处理？"` 选项：使用 A'.B' / 升级 / 中止 |
| x86 专属功能（AVX 加速等）在 ARM 是否保留 | `"AVX 加速模块在 ARM 是否保留？"` 选项：保留（NEON 替代）/ 禁用 |
| 所有依赖均已确认 | 追加一条"确认开始迁移"总项 |

---

## 阶段 C：汇总 subagent 待确认项 + 等待用户确认

> ⛔ **硬性约束**：本阶段**必须调用 `AskUserQuestion` 工具**向用户提问，**严禁跳过直接进入阶段 D**。阶段 A、B 的 subagent 已将待确认项写入中间文件，本阶段由主编排统一收集并提问。即使没有疑问项，也必须通过 `AskUserQuestion` 确认"是否继续"，**不得在用户明确回复前自行推进**。

### C.1 汇总两份待确认项清单

读取阶段 A、B 两个 subagent 输出的待确认项中间文件：

```bash
cat $WORK_DIR/reports/stage_a_pending_items.md
cat $WORK_DIR/reports/stage_b_pending_items.md
```

合并去重后形成统一待确认清单。每条待确认项含 `id`、`category`（环境检测 / 依赖分析）、`question`、`options`。

### C.2 调用 AskUserQuestion 工具（强制）

**每个独立决策点 = 一个 question 条目**。即使全部可自动推断，也要至少追加：

```
question id="confirm_proceed"
prompt="以上是环境检测与依赖分析摘要，是否确认开始 ARM 迁移？"
options:
  - id="yes"   label="✅ 确认，开始迁移"
  - id="review" label="⏸ 我需要先确认某些依赖，请等待"
  - id="abort"  label="❌ 中止"
```

> 若待确认项数量超过 `AskUserQuestion` 单次上限（4 个 question），分批提问，每批不超过 4 个。

### C.3 等待用户回复（严格阻塞）

收到回复后：
- 将用户选择逐条记录到 `$WORK_DIR/reports/user_decisions.txt`
- 对"跳过"项记录降级方案；对"中止"立即终止流程

### C.4 登记清单 + 确认切换 + 校验

> ⚡ **`read_file("dependency-analysis/arm-confirmed-write.md")` 获取完整执行步骤。**

本步骤在阶段 C 末尾一次性完成三件事：
1. **登记**：把用户确认的依赖 ARM 适配信息按依赖库写入 [arm_confirmed.md](arm_confirmed.md)
2. **确认切换**：把待切换清单**逐项调用 `AskUserQuestion` 让用户确认**后，立即把构建配置分支/commit/URL 切换为清单记录的 ARM 版本
3. **校验**：切换后逐项核对分支是否真切到 ARM 版（一句话提醒：切错会让后续编译错误极难排查）

> ⛔ **分支切换必须用户确认**：清单记录的 ARM 分支未必与当前项目实际一致，切错会导致编译错误极难排查、迁移成本陡增——未获用户逐项确认不得执行任何切换命令。切换在阶段 C 末尾完成，阶段 D 不再涉及分支切换。

**校验通过后**，阶段 C 结束，进入阶段 D。

---

## 阶段 D：DevKit 扫描 → 构建配置 + 源码适配（严格串行）

> ⚡ **立即 `read_file("sourcecode-devkit-scan.md")` 获取完整执行步骤。**

**本阶段目标**：先运行 DevKit 扫描发现源码 x86 专属问题，**扫描结束后**再根据报告结果完成构建系统配置适配与源码修改。

> ⛔ **硬性约束（严格串行，不可并行）**：
>
> 阶段 D 内部分为**两个不可并行的子步骤**：
>
> 1. **D.1 DevKit 扫描**（门控步骤）：必须先完成 DevKit 扫描并生成报告，**在此期间不得进行任何源码或构建配置修改**
> 2. **D.2 构建配置 + 源码适配**：**必须等待 D.1 扫描结束后**，根据扫描报告的指导再开始修改。扫描报告会明确指出哪些文件存在 x86 专属问题及修改建议，直接指导 D.2 的修改范围和优先级
>
> **不可并行的原因**：DevKit 扫描结果对后续修改有**直接指导作用**——它会定位需要修改的源文件、指出问题类型（内联汇编 / intrinsics / 头文件 / 类型大小等）、给出修改建议。如果先修改再扫描，可能遗漏问题或做重复/冲突修改。因此**必须先等扫描结束、拿到报告，再开始源码和构建适配**。
>
> `which devkit` 返回空时不允许跳过扫描，必须通过 `AskUserQuestion` 询问用户 DevKit 安装路径。
>
> 阶段 D 只做 DevKit 扫描与源码/构建适配——依赖分支切换已在阶段 C 末尾完成，此处不再切换。
>
> **DevKit 扫描报告是阶段 E 错误修复的最高优先级参考依据，路径 `$WORK_DIR/reports/devkit-*/`。**

**案例库参考**：阶段 D 的源码/构建适配可参考 [migration-cases/](migration-cases/) 中的历史案例。遇到类似错误时，先查 G/V/P 系列路由索引定位案例，再按案例中的修复方法执行。

**阶段 D 完成后**，进入阶段 E。

> 📚 **迁移知识采集**：阶段 D/E 中遇到的编译错误和修复方案，可在迁移完成后按 `case-collection-guide.md` + `migration-session-summary.md` 的流程批量提取写入案例库，供后续项目复用。

---

## 阶段 E：编译验证循环

> ⚡ **立即 `read_file("sourcecode-build-verify.md")` 获取完整执行步骤。**

**本阶段目标**：循环执行编译验证，直到编译成功或人工介入。

**错误修复优先级**（详见 sourcecode-build-verify.md E.2/E.5 节）：
- **P0**：优先查 DevKit 报告（`$WORK_DIR/reports/devkit-*/`），命中则直接按报告修复
- **P1**：DevKit 未命中时，查 [sourcecode-build-verify.md](sourcecode-build-verify.md) E.5 节的常见错误速查表
- **报告目录不存在**：⛔ 回到阶段 D 重新执行 DevKit 扫描，不得跳过

---

## 附加资源

| 文档 | 用途 |
|------|------|
| [environment-prepare.md](environment-prepare.md) | 阶段 A：环境检测与准备 |
| [build-tools-reference.md](build-tools-reference.md) | 阶段 A 配套：构建工具下载链接（内部定制版优先） |
| [dependency-analysis/dependency-analysis.md](dependency-analysis/dependency-analysis.md) | 阶段 B：依赖分析与兼容性探测主编排 |
| [dependency-analysis/arm-confirmed-write.md](dependency-analysis/arm-confirmed-write.md) | 阶段 C.4 / 阶段 D：写入 ARM 确认清单 + 执行真实切换 |
| [sourcecode-devkit-scan.md](sourcecode-devkit-scan.md) | 阶段 D：DevKit 扫描与源码/构建适配 |
| [sourcecode-build-verify.md](sourcecode-build-verify.md) | 阶段 E：编译验证与循环修复（E.5 节为常见错误速查表） |
| [arm_confirmed.md](arm_confirmed.md) | 已确认 ARM 适配的依赖库清单（按依赖库索引，阶段 B 查询命中 / 阶段 C 登记 + 确认切换分支） |
| [dependency-analysis/dependency-analysis-bazel.md](dependency-analysis/dependency-analysis-bazel.md) | Bazel 构建系统依赖分析（按需加载） |
| [dependency-analysis/dependency-analysis-blade.md](dependency-analysis/dependency-analysis-blade.md) | Blade 构建系统依赖分析（按需加载） |
| [dependency-analysis/dependency-analysis-cmake.md](dependency-analysis/dependency-analysis-cmake.md) | CMake 构建系统依赖分析（按需加载） |
| [dependency-analysis/dependency-analysis-scons.md](dependency-analysis/dependency-analysis-scons.md) | SCons 构建系统依赖分析（按需加载） |
| [migration-cases/](migration-cases/) | ARM 迁移案例库：3 个路由索引 + 3 个详细案例文件（G/V/P 系列） |
| [migration-cases-example/](migration-cases-example/) | 案例库脱敏样例（3 个路由索引 + 3 个详细案例，每类各一条） |
| [case-collection-guide.md](case-collection-guide.md) | 案例分类标准与写入格式规范 |
| [diff-collection.md](diff-collection.md) | Diff 采集与校验指南 |
| [migration-session-summary.md](migration-session-summary.md) | 迁移会话知识提取指南（编译成功后批量入库） |
| [arm-scan-rules.json](arm-scan-rules.json) | 自定义扫描规则库（与 arm_scan.py 配套） |
| [bazel-dual-arch-pattern.md](bazel-dual-arch-pattern.md) | Bazel x86/ARM 双架构切换模式参考（5 层架构 + 通用模板） |
| [arm_confirmed_by_project.md](arm_confirmed_by_project.md) | 按主代码仓索引的 ARM 分支/依赖版本信息（迁移产出记录） |
