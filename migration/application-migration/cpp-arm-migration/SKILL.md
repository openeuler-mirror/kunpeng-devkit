---
name: cpp-arm-migration
description: 将 C/C++ 项目从 x86 迁移到 ARM（aarch64/鲲鹏），目标是使项目**同时**在 x86 和 ARM 上编译运行（双架构兼容）。支持 Bazel/CMake/Make/Blade/SCons 等主流构建系统。五阶段流程：① 环境检测与准备；② 依赖分析（含 ARM 兼容性探测）；③ 等待用户确认；④ DevKit 扫描 + 构建配置 + 源码适配；⑤ 循环编译验证直到成功。
---

# C/C++ 项目 ARM 迁移主控 Skill

## 核心原则

- **双架构兼容**：所有修改必须使项目**同时**支持 x86 和 ARM 编译。通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，**不破坏原有 x86 能力**
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物放到项目目录之外的专用工作目录，不污染源码树
- **一次性信息收集**：所有需要用户提供的信息**在阶段 C 一次性问清楚**，不在后续流程中反复打断用户
- **子仓库优先**：存在私有仓库依赖时，优先推动子仓库完成 ARM 适配后再编译主仓库

---

## 整体流程

> **阶段 A（环境检测与准备）** → **阶段 B（依赖分析）** → **阶段 C（信息收集，等待用户回复）** → **阶段 D（DevKit 扫描 + 源码 & 构建适配）** → **阶段 E（编译验证循环）**

> ⚠️ **关键约束**：
> - 阶段 B 完成后，进入阶段 C 暂停等待用户回复，**未获得用户明确确认前不进入阶段 D**
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

## 阶段 A：环境检测与准备

> ⚡ **立即 `read_file("environment-prepare.md")` 获取完整执行步骤。**

**本阶段目标**：确认 ARM 环境具备编译条件，输出环境检测报告到 `$WORK_DIR/reports/environment_check_report.md`。

**阶段 A 完成后**：展示环境检测报告，**必须调用 `AskUserQuestion`** 针对每个**版本不一致项**单独提问，等待用户回复后方可进入阶段 B。

**必问场景**（每个冲突项 = 一个 question）：

| 检测场景 | 问题示例 |
|---|---|
| Bazel 项目要求 X.Y，ARM 已装 X'.Y' | `"Bazel 项目需要 X.Y，ARM 已安装 X'.Y'，如何处理？"` 选项：安装项目指定版本 / 使用已安装版本 / 中止 |
| protoc 版本与项目 protobuf 版本不匹配 | `"ARM 上 protoc 为 X，项目使用 protobuf Y，如何处理？"` 选项：为 ARM 重新编译匹配版 protoc / 中止 |
| Blade 版本不支持 arm64 | `"Blade 版本过旧不支持 arm64，需要升级，是否确认？"` 选项：确认升级 / 中止 |
| 所有工具版本均一致 | 追加一条“确认继续”总项即可 |

---

## 阶段 B：依赖分析与 ARM 兼容性探测

> ⚡ **立即 `read_file("dependency-analysis/dependency-analysis.md")` 获取完整执行步骤。**

**本阶段目标**：全面分析项目所有外部依赖，评估每个依赖的 ARM 兼容性，输出依赖分析报告。

**报告输出后**：进入阶段 C，必须调用 `AskUserQuestion` 针对每个**依赖版本冲突项**单独提问，**不得自行推进到阶段 D**。

**必问场景**（每个冲突项 = 一个 question）：

| 检测场景 | 问题示例 |
|---|---|
| 私有库无 ARM 预编译包 | `"libXXX 无 ARM 版本，如何处理？"` 选项：从源码编译 / 提供已有包路径 / 禁用该模块 |
| 私有库有 ARM 分支但不确定是否可用 | `"@xxx ARM 分支 arm64 是否可用？"` 选项：可用 / 不确定请等待 / 跳过 |
| 依赖版本冲突（项目需求 A.B， ARM 环境只有 A'.B'） | `"XXX 项目需求版本 A.B，ARM 环境已有 A'.B'，如何处理？"` 选项：使用 A'.B' / 升级 / 中止 |
| x86 专属功能（AVX 加速等）在 ARM 是否保留 | `"AVX 加速模块在 ARM 是否保留？"` 选项：保留（NEON 替代）/ 禁用 |
| 所有依赖均已确认 | 追加一条“确认开始迁移”总项 |

---

## 阶段 C：信息收集（强制等待用户确认）

> ⛔ **硬性约束**：本阶段**必须调用 `AskUserQuestion` 工具**向用户提问，**严禁跳过直接进入阶段 D**。即使没有疑问项，也必须通过 `AskUserQuestion` 确认"是否继续"，**不得在用户明确回复前自行推进**。

### C.1 整理待确认清单

收集阶段 B 依赖分析报告中所有「需用户决策」的 ⚠️ 项，加上：
1. 编译目标确认
2. 构建工具版本确认

### C.2 调用 AskUserQuestion 工具（强制）

**每个独立决策点 = 一个 question 条目**。即使全部可自动推断，也要至少追加：

```
question id="confirm_proceed"
prompt="以上是依赖分析摘要，是否确认开始 ARM 迁移？"
options:
  - id="yes"   label="✅ 确认，开始迁移"
  - id="review" label="⏸ 我需要先确认某些依赖，请等待"
  - id="abort"  label="❌ 中止"
```

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

> ⛔ **分支切换必须用户确认**：同仓库可能存在多个 ARM 分支且版本对应复杂，切错会导致编译错误极难排查、迁移成本陡增——未获用户逐项确认不得执行任何切换命令。切换在阶段 C 末尾完成，阶段 D 不再涉及分支切换。

**校验通过后**，阶段 C 结束，进入阶段 D。

---

## 阶段 D：DevKit 扫描 + 构建配置 + 源码适配

> ⚡ **立即 `read_file("sourcecode-devkit-scan.md")` 获取完整执行步骤。**

**本阶段目标**：运行 DevKit 扫描发现源码 x86 专属问题，同时完成构建系统配置适配与源码修改。

> ⛔ **硬性约束**：DevKit 扫描是阶段 D 的**门控步骤**，**必须先完成 DevKit 扫描并生成报告，才能进入构建配置适配和源码修改**。`which devkit` 返回空时不允许跳过，必须通过 `AskUserQuestion` 询问用户 DevKit 安装路径。
>
> 阶段 D 只做 DevKit 扫描与源码/构建适配——依赖分支切换已在阶段 C 末尾完成，此处不再切换。
>
> **DevKit 扫描报告是阶段 E 错误修复的最高优先级参考依据，路径 `$WORK_DIR/reports/devkit-*/`。**

**阶段 D 完成后**，进入阶段 E。

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
