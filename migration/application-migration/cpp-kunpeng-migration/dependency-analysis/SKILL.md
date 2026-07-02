---
name: dependency-analysis
description: C/C++ 项目 ARM 迁移的阶段 2 子 Skill，专注于依赖分析与 Kunpeng 兼容性探测环节。提供全面分析项目所有外部依赖（Bazel/CMake/Blade/SCons/Git Submodule/手动脚本）的能力，评估每个依赖的 ARM 兼容性，识别预编译二进制架构，递归分析子模块依赖，命中免检清单的依赖自动记录待切换。在作为 cpp-kunpeng-migration 主 Skill 的阶段 2 子 Skill 被调用时触发，当用户需要单独分析项目依赖的 ARM 兼容性、检查预编译二进制架构、排查私有库依赖、或查询 kunpeng_confirmed.md 免检清单时也应直接触发。适用于 C/C++ 项目的 x86→ARM（鲲鹏）架构迁移的依赖分析。不适用于非 C/C++ 语言的 ARM 迁移、非鲲鹏架构的迁移。
---

# C++ 项目依赖分析

> **执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段 2 子 Skill 调用，由主编排以子 agent 模式拉起执行（调起方式见主 SKILL 文末「调起约定与跨助手适配」）。当用户需要单独分析项目依赖的 ARM 兼容性、检查预编译二进制架构、排查私有库依赖、或查询 kunpeng_confirmed.md 免检清单时也可直接调用本子 Skill。
>
> **子 agent 边界**：子 agent **不向用户提问**，检测到的依赖冲突项按「子 agent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_2_pending_items.md`；命中 `kunpeng_confirmed.md` 的依赖写入 `$WORK_DIR/reports/stage_2_switch_list.md` 待切换清单，由主编排在阶段 3 统一处理。

## 输入参数

主编排读取本文件全文，将下列占位符替换为实际值后作为子 agent 提示词传入：

- `<项目绝对路径>` → `PROJECT_ROOT`
- `<工作目录绝对路径>` → `WORK_DIR`
- `<skill目录绝对路径>` → `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

参数定义：

- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <cpp-kunpeng-migration skill 目录绝对路径>（主编排传入）

支持以下 C++ 构建系统的依赖分析：

| 系统 | 关键文件 | 依赖声明方式 |
|------|----------|-------------|
| **Bazel** | `WORKSPACE`, `*.BUILD` | `http_archive`, `git_repository`, `new_local_repository` |
| **CMake** | `CMakeLists.txt`, `cmake/*.cmake` | `FetchContent_Declare`, `ExternalProject_Add`, `find_package` |
| **Blade** | `BLADE_ROOT`, `BUILD`（每个目录） | `cc_library(prebuilt=1)`, `deps=[//thirdparty/...]`, `#系统库` |
| **SCons** | `SConstruct`, `SConscript` | `Program()`, `SharedLibrary()`, `env.Library()` |
| **Git Submodule** | `.gitmodules` | `[submodule]` |
| **手动脚本** | `*.sh`（`wget`/`curl`） | 直接下载 URL |
| **系统包管理** | `*.sh`（`yum`/`apt`） | `yum install`, `apt-get install` |

---

## 主流程

### 第一步：从环境检测报告读取构建系统

> **从阶段 1 环境检测报告中读取**，不再重复检测。

```bash
REPORT="$WORK_DIR/reports/environment_check_report.md"
cat "$REPORT"
```

> **若环境检测报告不存在**（用户跳过阶段 1 直接执行阶段 2），则回退到自行检测：
> ```bash
> find <项目根目录> -maxdepth 3 \
>   \( -name "WORKSPACE" -o -name "CMakeLists.txt" \
>   -o -name "BLADE_ROOT" -o -name "SConstruct" \
>   -o -name ".gitmodules" -o -name "*.sh" \) | sort
> ```

---

### 第二步：读取免检清单（全局去重）

**在启动任何仓库分析之前**，先读取全局免检清单，避免对已确认兼容的依赖重复探测：

```bash
cat "$SKILL_DIR/dependency-analysis/references/kunpeng_confirmed.md" 2>/dev/null
```

将免检清单的内容缓存在上下文中，供后续每次调用 [compat-and-binary-detect.md](references/compat-and-binary-detect.md) 时使用（Part A 的 A.5 比对）。

> **在清单中命中（按依赖库名定位到 ARM 适配区块）的依赖，已知 ARM 适配方案**：在报告中**展示一条**并标注「已知 ARM 适配，待阶段 3 末尾切换」，把区块记录的 ARM 分支/commit/URL/备注记下供阶段 3 末尾切换，不再探测、不再询问用户。

---

### 第三步：主循环 — 递归分析所有仓库

加载 [repo-analysis-flow.md](references/repo-analysis-flow.md)，对**主仓库**执行完整分析：

```
输入：
  REPO_PATH  = <项目根目录绝对路径>
  REPO_NAME  = <项目名>
  REPO_DEPTH = 0

执行：repo-analysis-flow.md（Step 1 → Step 2 → Step 3 → Step 4 → Step 5 → Step 6）
```

`repo-analysis-flow.md` 内部会自动：
- 检测主仓构建系统，加载对应专用分析文件
- 调用 [compat-and-binary-detect.md](references/compat-and-binary-detect.md) Part A 执行 ARM 兼容性探测
- 调用 [compat-and-binary-detect.md](references/compat-and-binary-detect.md) Part B 执行预编译二进制识别与溯源
- 递归处理所有子模块，每个子仓**独立检测构建系统**

最终返回包含所有层级信息的结构化结果，用于第四步聚合。

---

### 第四步：生成报告（写入文件 + 输出到客户端）

> **输出方式**：报告以 Markdown 格式**写入** `$WORK_DIR/reports/dependency_analysis_<项目名>.md`，同时将完整内容**输出到客户端对话界面**。
>
> ```bash
> # 报告写入路径
> REPORT_FILE="$WORK_DIR/reports/dependency_analysis_<项目名>.md"
> # 使用文件写入将报告内容写入该路径
> ```

#### 报告精简原则

以下情况判定为「必定兼容」，从整个报告的所有章节中**完全省略**：

| 判定条件 | 说明 |
|----------|------|
| 开源库源码已内嵌于仓库（`deps/`/`third_party/` 目录），且无 x86 专有汇编或平台宏 | 有完整 C/C++ 源码，直接重编译即可 |
| 系统通用包（gflags、zlib、openssl、lz4、zstd、curl、leveldb、pthread 等）通过 `find_package`/`yum`/`apt` 安装 | 主流 Linux ARM 发行版均有对应包 |
| 仓库内置二进制确认全部为**测试数据**（仅被测试框架引用，不链接进生产代码） | 不影响移植 |
| 通用跨平台工具脚本（Perl/Python 脚本，如 lcov）确认无二进制依赖 | 脚本类工具无架构绑定 |

**只要符合上述任意一条，对应依赖在报告的所有章节中完全不出现。**

> **命中 `kunpeng_confirmed.md` 的依赖单独处理**：按依赖库名命中区块的依赖**不属于**「必定兼容、完全省略」，而是在报告中**展示一条**并标注「已知 ARM 适配，待阶段 3 末尾切换」（让用户看到哪些依赖复用了历史成果），把 ARM 分支/commit/URL/备注记下供阶段 3 末尾切换，**不进入报告末尾的「待用户手动确认清单」**。

#### 报告末尾必须输出「待用户手动确认清单」

**只要存在任何待确认项，此章节不可省略**：

```markdown
## 待用户手动确认清单

> **移植提速建议：优先推动私有子仓库完成 ARM 适配，再编译主仓库**
>
> 当项目存在私有仓库依赖时，应优先联系各子仓库维护团队完成 ARM 适配并发布稳定版本，
> 主仓库只需更新构建配置中对应的版本号即可直接构建，无需在主仓库侧做任何代码改动。

以下依赖为**私有地址**且**未发现任何 ARM 兼容性证据**，请逐条确认：

- [ ] `<依赖名>` (`<url>`) — 未发现 ARM 分支或相关提交历史，请确认该库是否兼容 ARM/aarch64
- [ ] `<依赖名>` (`<url>`) — 预编译二进制，架构未知，请提供 ARM 版本或源码
```

> 强制要求：
> - 所有 标记的依赖**必须**出现在此清单中
> - 「配置与 `kunpeng_confirmed.md` 不一致」的依赖也**必须**在此清单中提示
> - 建议按依赖深度标注优先级（P0 = 基础通信/IO 库，P1 = 核心基础设施客户端，P2 = 通用工具类库）

#### 报告模板

见 [report-template-example.md](assets/report-template-example.md)。

---

## 全局注意事项

- **子仓库优先适配策略**：存在私有仓库依赖时，明确提示用户优先推动这些子仓库完成 ARM 适配；子仓库适配完成后，主仓库只需修改构建配置中的版本号，可显著降低整体移植成本
- **子仓库协调优先级**：基础通信/IO 库（P0）> 核心基础设施客户端库（P1）> 业务模块专用 SDK（P2）> 通用工具类库（P3）
- **开源判定豁免**：`github.com`/`gitlab.com` 等公开平台的依赖默认跳过 ARM 检查，但若版本超过 2 年未更新仍建议确认
- **私有对象存储地址**（如组织内部 S3/OSS）：需要在私有网络环境中访问，报告中需注明
- **输出方式**：报告以 Markdown 格式写入 `$WORK_DIR/reports/dependency_analysis_<项目名>.md`，同时输出到客户端对话界面

---

## 输出要求（硬性约束）

1. **必须**将依赖分析报告写入文件 `$WORK_DIR/reports/dependency_analysis_<项目名>.md`
2. **必须**将待确认项写入文件 `$WORK_DIR/reports/stage_2_pending_items.md`（格式见下方）
3. **必须**将待切换清单写入文件 `$WORK_DIR/reports/stage_2_switch_list.md`（格式见下方）
4. 即使无待确认项，也必须写入空清单并标注"无待确认项"
5. **严禁**向用户提问（你没有向用户提问的权限，需用户决策的项一律写入待确认项文件，由主编排在阶段 3 统一提问）
6. **严禁**修改项目源码或构建配置（你只做分析和报告）
7. 完成后，在你的最终回复中输出：
   - 依赖分析结论摘要
   - 识别到的依赖总数和分类
   - 待确认项数量
   - 待切换项数量（命中 kunpeng_confirmed.md 的依赖）
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

```
- dep_name: <依赖名>
  arm_branch: <ARM分支或commit>
  arm_url: <ARM版本URL（如有）>
  current_ref: <当前构建配置中的引用>
  switch_action: <具体切换操作描述>
  source: kunpeng_confirmed.md  # 来源
```

---

## 模块架构

本目录按职责拆分，文件分组如下：

### 核心文件（按执行顺序加载）

| 文件 | 职责 |
|------|------|
| [repo-analysis-flow.md](references/repo-analysis-flow.md) | 代码仓分析闭环：检测构建系统 → 分发依赖扫描 → 调用通用模块 → 递归子模块 |
| [compat-and-binary-detect.md](references/compat-and-binary-detect.md) | 通用共享模块：Part A ARM 兼容性探测（私有 URL 判断、远端分支检查、提交历史检查、免检清单比对）+ Part B 二进制文件扫描（扫描、架构判断、四级源码溯源、截断策略） |

### 构建系统专用合集（按需加载对应章节）

| 文件 | 章节 | 职责 |
|------|------|------|
| [build-system-dep-scan.md](references/build-system-dep-scan.md) | [#bazel](references/build-system-dep-scan.md#bazel-构建系统依赖分析) | WORKSPACE 依赖扫描、`http_archive` 预编译包识别 |
| [build-system-dep-scan.md](references/build-system-dep-scan.md) | [#cmake](references/build-system-dep-scan.md#cmake-构建系统依赖分析) | `FetchContent`/`ExternalProject_Add`/`find_package` 扫描、ABI=0 工具链、子模块自动签出检查 |
| [build-system-dep-scan.md](references/build-system-dep-scan.md) | [#blade](references/build-system-dep-scan.md#blade-构建系统依赖分析) | thirdparty 组件扫描、BUILD/BUILD.x86 双架构分离、ARM 库查找路径 |
| [build-system-dep-scan.md](references/build-system-dep-scan.md) | [#scons](references/build-system-dep-scan.md#scons-构建系统依赖分析) | x86 编译标志检查、Python 版本兼容性 |

### 跨阶段共享文档

| 文件 | 职责 | 调用方 |
|------|------|--------|
| [kunpeng-confirmed-write.md](references/kunpeng-confirmed-write.md) | 写入 ARM 确认清单、执行真实分支切换、切换后校验 | **阶段 3 主编排**（本子 skill 仅产生供其消费的待切换清单，不执行其中步骤） |
| [kunpeng_confirmed.md](references/kunpeng_confirmed.md) | ARM 适配已确认依赖知识库（按依赖库名索引，跨项目复用） | 阶段 2 读取（免检）、阶段 3 写入 |

### 输出模板

| 文件 | 用途 |
|------|------|
| [report-template-example.md](assets/report-template-example.md) | 依赖分析报告输出模板示例 |
