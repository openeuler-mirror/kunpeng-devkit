---
name: source-migration-scan
description: C/C++ 鲲鹏迁移的源码迁移扫描子 Skill。作为 cpp-kunpeng-migration 阶段 4 被调用，或用户需要对 C/C++ 项目执行鲲鹏 DevKit 扫描、处理 x86 专属代码或适配 aarch64 构建配置时使用。负责先生成并分析 DevKit 扫描报告，再依据报告完成架构相关源码和构建系统改造。不负责通用环境准备、依赖兼容性分析和最终编译验证。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
---

# 阶段 4：源码迁移扫描与适配

本文档描述如何运行华为鲲鹏 DevKit 对源码进行 x86 兼容性扫描，以及如何根据扫描报告对源码进行架构适配修改。

> **范围说明**：本文档涵盖 DevKit 工具调用、源码修改方法，以及构建系统配置的架构适配。

> **前置条件**：阶段 3 用户确认已完成，私有依赖的 kunpeng 兼容性信息已获取。

***

## 4.1 运行 DevKit 扫描

### 4.1.1 定位 DevKit 工具

首先确认 DevKit 是否已安装，以及可执行文件的路径：

```bash
# 尝试从系统 PATH 中查找
which devkit 2>/dev/null

# 或在常见安装路径中查找（根据实际环境调整搜索范围）
find /opt /usr/local -name "devkit" -maxdepth 8 -type f 2>/dev/null | head -3

# 确认版本
<devkit路径> --version
```

若上述均未找到，**不得跳过扫描**，**必须**向用户提问让其决策如何处理（与 SKILL.md 阶段 4 硬性约束一致）：

```
question: "未在系统中检测到 DevKit，如何继续阶段 4 扫描？"
options:
  - id: provide_path   label: "我知道路径，手动提供 DevKit 安装路径"
  - id: download       label: "由 Skill 自动下载安装 DevKit"
  - id: abort          label: "中止阶段 4"
```

按用户选择处理：

- **provide\_path**：用户给出路径后，将其作为 `DEVKIT` 继续后续步骤；若该路径 `--version` 仍失败，回到本提问
- **download**：由 agent 执行 DevKit 下载安装逻辑（详见下方 4.1.1.1），安装完成后继续后续步骤
- **abort**：终止阶段 4，不进入 4.2

#### 4.1.1.1 自动下载安装 DevKit

用户选择 `download` 时，agent **必须读取文件** `$SKILL_DIR/source-migration-scan/references/devkit-download.md` 按其中步骤执行：从华为云镜像站动态匹配最新 `DevKit-CLI-*-Linux-Kunpeng.tar.gz`，下载解压并验证 `--version`，最终将路径赋值给 `DEVKIT` 变量供 4.1.2 使用。失败时回到 4.1.1 提问。

### 4.1.2 确认扫描参数

根据阶段 1 `environment-prepare/SKILL.md` 的构建系统检测结果，确定 `-b` 与 `-c` 参数：

| 构建系统 | `-b` 参数值 | `-c` 参数值 |
| --- | --- | --- |
| Bazel | `bazel` | 不传 |
| CMake | `cmake` | `cmake` |
| Make/Makefile | `make` | `make` |
| Automake（先 configure 再 make） | `make` | `make` |
| Blade | `blade` | 不传 |
| SCons/其他 | `other` | 不传 |

### 4.1.3 执行扫描

```bash
DEVKIT_REPORT_DIR="$WORK_DIR/reports/devkit-$(date +%Y%m%d%H%M%S)"
mkdir -p $DEVKIT_REPORT_DIR

$DEVKIT porting src-mig \
  -i $PROJECT_ROOT \
  -b <bazel|cmake|make|blade|other> \
  -c <make|cmake> \
  -r all \
  -o $DEVKIT_REPORT_DIR \
  2>&1 | tee $WORK_DIR/reports/devkit-scan.log
```

> `-r all` 表示输出全部报告格式（json / html / csv）。

> `-c` 指定项目编译命令，**对扫描结果影响较大**，需精准识别项目实际编译命令后传入。仅 make / cmake 项目支持（`-c make` / `-c cmake`，对应上表）；bazel / blade / other 等构建系统**不传 `-c`**（命令中删去该行）。

> **扫描命令调不起来时**：若 `$DEVKIT porting src-mig` 无法启动（命令找不到、二进制报错、段错误、缺动态库等），视为已定位的 DevKit 包损坏或架构不符，不要反复重试扫描--回到 4.1.1.1 重跑 `source-migration-scan/scripts/devkit-download.sh` 重新下载安装后再回本步重试；重下仍失败则回 4.1.1 向用户提问。

### 4.1.4 读取并汇总扫描报告

> **重要约束**：本节使用专用脚本 `source-migration-scan/scripts/devkit-report-summary.sh` 流式处理报告，输出压缩型摘要文件。

使用脚本流式读取并汇总扫描报告：

```bash
bash $SKILL_DIR/source-migration-scan/scripts/devkit-report-summary.sh
```

> **脚本前置条件**：环境变量 `DEVKIT_REPORT_DIR` 已设置（由 4.1.3 阶段确定）。脚本自动探测 CSV 表头列索引（兼容 DevKit 不同版本列顺序差异）。
>
> **脚本输出**：
> - `$DEVKIT_REPORT_DIR/summary.txt`
> - `$WORK_DIR/reports/devkit_summary.json` 
>
> **脚本退出码**：
>
> | 退出码 | 含义 |
> |-------|------|
> | 0 | 成功（报告目录为空时也返回 0，仅输出"无问题"摘要） |
> | 1 | 环境校验失败（`DEVKIT_REPORT_DIR` 未设置或不存在） |
> | 2 | 未找到任何 CSV/HTML 报告文件 |
> | 3 | CSV 表头格式不符合预期（无 `PortingCategory` 或 `Level` 列） |
>
> 失败时按退出码定位：检查目录与文件存在性（1/2）、表头兼容性（3）。
>
> **JSON 摘要生成工具自动降级**（脚本内部处理，无需手动干预）：
>
> | 优先级 | 工具 | 适用场景 |
> |-------|------|----------|
> | 1 | `jq` | 服务器标准工具（首选） |
> | 2 | `python3` | 鲲鹏服务器通常自带（推荐预装） |
> | 3 | `python2` | 旧系统兜底 |
> | 4 | `awk` 手工拼接 | 极简环境最后兜底（语法未校验，标记 `_fallback: awk_manual_no_jq_no_python`） |
>
> 脚本按 jq → python3 → python2 → awk 顺序自动选择可用工具，**任何环境下均能生成可读取的 JSON 摘要**，但仅 jq 路径会做语法校验。降级路径下若需严格 JSON 校验，事后用 `python3 -m json.tool devkit_summary.json` 二次校验即可。

**读取 JSON 摘要供后续阶段使用：**

```bash
# 后续阶段统一通过专用脚本读取摘要，三级工具（jq / python3 / awk）兜底已封装在脚本内
bash $SKILL_DIR/source-migration-scan/scripts/devkit-summary-read.sh <field>
```

> **脚本**：`source-migration-scan/scripts/devkit-summary-read.sh`，封装 jq → python3 → python2 → awk 降级路径，**任何环境下均可读取生成的 JSON 摘要**，无需 agent 自行判断工具可用性。
>
> **支持的字段**：
>
> | 字段 | 用途 | 典型用法 |
> |------|------|---------|
> | `rule_categories` | Rule 级问题类别列表（每行一个） | 4.2.0-prelude / 4.2.0 / 4.2.5 触发条件判定 |
> | `categories` | 按 Category 统计的总数 | 输出 `category<TAB>total<TAB>rule` 三列 |
> | `rule_detail_sample` | Rule 明细示例 | 输出 `[CATEGORY] LOCATION: SUGGESTION` |
> | `all` | 依次输出以上三段（空行分隔） | 调试/全量预览 |
> | `has_rule` | 判定 Rule 类别是否非空 | `if bash $SKILL_DIR/source-migration-scan/scripts/devkit-summary-read.sh has_rule >/dev/null; then ...` |
> | `has <CATEGORY>` | 判定指定类别是否在 Rule 列表中 | `bash $SKILL_DIR/source-migration-scan/scripts/devkit-summary-read.sh has INTRINSICS` |
>
> **脚本退出码**：
>
> | 退出码 | 含义 |
> |-------|------|
> | 0 | 成功（has_rule/has 检查且条件满足） |
> | 1 | 参数/环境错误（参数缺失、`WORK_DIR` 未设置、JSON 文件不存在或为空） |
> | 2 | 字段名无效 |
> | 11 | `has_rule` 检查：Rule 类别列表为空 |
> | 12 | `has <CATEGORY>` 检查：未找到该类别 |
>
> **后续阶段读取约定**：4.2.0-prelude、4.2.0、4.2.5 等章节统一通过 `bash $SKILL_DIR/source-migration-scan/scripts/devkit-summary-read.sh <field>` 读取摘要，**不得**直接 `cat` 报告 CSV 文件或内联 `jq`/`python3`/`awk` 代码，避免上下文膨胀与工具可用性判断逻辑散落。

**理解报告中的问题修改级别：**

| DevKit 问题修改级别 | 修改策略 |
| --- | --- |
| 规则项（Rule） | **必须**采用 DevKit 扫描报告中的建议进行修改，不可跳过 |
| 建议项（Suggestion） | 参考 DevKit 扫描报告中的建议进行修改，酌情执行 |

**报告中常见问题类型（PortingCategory）及对应修改级别：**

| 问题类型 | 修改级别 | 说明 |
| --- | --- | --- |
| `INTRINSICS_LIBRARY`（avx2ki_option） | **Rule（必须）** | 需添加 avx2ki 编译选项并安装 KSL 包；具体替代方案由阶段 2 用户决策决定（KSL/avx2ki 或开源 NEON） |
| `COMPILER_OPTION`（-mavx/-mavx2 等不支持选项） | **Rule（必须）** | 鲲鹏不支持，必须移除或替换 |
| `ATTRIBUTE`（x86 专属头文件） | **Rule（必须）** | 必须放入 x86 宏分支保护 |
| `INTRINSICS`（`_mm*` 等 intrinsic 函数） | **Rule（必须）** | 必须使用 avx2ki.h 或 sse2neon.h 替代；具体替代方案由阶段 2 用户决策决定（KSL/avx2ki 或开源 NEON） |
| `INVALID_CATEGORY`（MKL 函数如 cblas_sgemm） | **Rule（必须）** | 必须替换为 KML 函数或 OpenBLAS 函数；具体替代方案由阶段 2 用户决策决定（KML 或 OpenBLAS） |
| `COMPILER_BUILTIN`（__builtin_cpu_supports 等） | **Rule（必须）** | 鲲鹏不支持，必须移除或改写 |
| `COMPILER_OPTION`（-fsigned-char/-march 等建议选项） | Suggestion（建议） | 建议添加以提升兼容性和性能 |
| `PRECOMPILED_MACRO`（#if 缺少 aarch64 分支） | Suggestion（建议） | 建议补充 `#elif defined(__aarch64__)` 分支 |
| `BUILTIN_ASSEMBLES`（x86 内联汇编指令） | Suggestion（建议） | 建议改为 ARM 等价指令或跨平台替代 |

## 4.2 源码/构建适配修改

扫描完成后，按以下顺序进行源码与构建配置适配。所有修改须遵循**双架构兼容**原则：修改后 x86 和 kunpeng 均能正常编译，不删除任何原有的 x86 实现。

> **修改顺序**：
> 1. 4.2.0-prelude（确定 AVX/MKL 替代策略）— 须最先完成，读取阶段 2 用户决策，确定后续 4.2.0~4.2.5 采用的替代方案
> 2. 4.2.0（安装 avx2ki KSL 库）— **仅当报告中存在 `INTRINSICS_LIBRARY`（avx2ki_option）或 `INTRINSICS` 类型的 Rule 级别问题，且用户在阶段 2 选择鲲鹏方案 KSL/avx2ki 时执行**；若用户选择开源 NEON 方案则跳过 KSL 安装，改走 4.2.0-alt
> 3. 4.2.1（aarch64 全局编译选项）— 编译前必做基础配置
> 4. 4.2.2 ~ 4.2.9 按 DevKit 扫描报告逐条处理源码问题（Rule 级别优先）

***

### 4.2.0-prelude 确定 AVX / MKL 替代策略

> **本节须最先执行**：从阶段 3 写入的 `$WORK_DIR/reports/user_decisions.txt` 读取用户对 AVX 指令和 MKL 库的替代决策，确定后续 4.2.0~4.2.5 各节采用的替代方案。两个维度相互独立，分别判定。

读取并解析用户决策文件：

```bash
cat $WORK_DIR/reports/user_decisions.txt
```

按用户选择确定两个策略变量（写入本次执行上下文，供后续各节分支使用）：

| 决策维度 | 阶段 2 用户选项 | 策略变量取值 | 后续执行路径 |
|---------|---------------|------------|-----------|
| AVX 指令替代 | 使用鲲鹏加速库 KSL | `AVX_STRATEGY=ksl` | 4.2.0 安装 KSL + avx2ki.h 兼容层（4.2.2/4.2.3 鲲鹏侧引入 `<avx2ki.h>`） |
| AVX 指令替代 | 使用 NEON 替代 AVX | `AVX_STRATEGY=neon` | 跳过 4.2.0 KSL 安装，改走 4.2.0-alt；4.2.2/4.2.3 鲲鹏侧引入 `<arm_neon.h>` 并手写 NEON 实现 |
| AVX 指令替代 | 禁用 | `AVX_STRATEGY=disable` | 4.2.3 策略 C（整体禁用该功能） |
| MKL 库替代 | 使用鲲鹏数学库 KML 替代 MKL | `MKL_STRATEGY=kml` | 4.2.5 走 KML 路径（安装 KML、切换链接库） |
| MKL 库替代 | 使用 OpenBLAS 替代 MKL | `MKL_STRATEGY=openblas` | 4.2.5 走 OpenBLAS 路径（安装 OpenBLAS、切换链接库） |
| MKL 库替代 | 禁用 | `MKL_STRATEGY=disable` | 4.2.5 整体禁用该模块 |

> **未读取到决策时的兜底**：若 `user_decisions.txt` 中缺失对应决策项，**必须向用户提问**确认 AVX 与 MKL 的替代方案，不得自行假定。

***

### 4.2.0 安装 avx2ki KSL 库（按需执行，Rule 级别）

> **触发条件**（须同时满足）：
> 1. DevKit 扫描报告中存在以下任一情况：
>    - 报告中有 `PortingCategory.INTRINSICS_LIBRARY`（avx2ki_option）类型的 **Rule** 级别条目
>    - 报告中有 `PortingCategory.INTRINSICS` 类型的 **Rule** 级别条目，且建议使用 `avx2ki.h` 进行替换
> 2. **`AVX_STRATEGY=ksl`**（用户在阶段 2 选择鲲鹏加速库 KSL 方案）
>
> 若报告中**不存在**上述条目，**跳过本节**，直接进入 4.2.1。
>
> 若报告中存在上述条目但 **`AVX_STRATEGY=neon`**（用户选择开源 NEON 方案），**跳过本节 KSL 安装**，改走 [4.2.0-alt 安装/准备 NEON 开源实现](#4.2.0-alt)。
>
> 满足触发条件时**必须执行**：需在鲲鹏平台上安装 KSL（Kunpeng Standard Library）以提供 `avx2ki.h` 头文件和 `libavx2ki.so` 动态库，使 x86 AVX/SSE intrinsics 映射到鲲鹏 NEON 指令。

#### 4.2.0.1 下载并安装 BoostKit KSL 包

使用专用脚本 `source-migration-scan/scripts/ksl-install.sh` 完成下载、解压、安装 RPM 及验证，脚本封装了重试、完整性校验、RPM 工具自动选择（dnf > yum > rpm）和路径持久化逻辑：

```bash
bash $SKILL_DIR/source-migration-scan/scripts/ksl-install.sh
```

> **脚本前置条件**：环境变量 `WORK_DIR` 已设置（由阶段 1 确定）。
>
> **脚本输出**：
> - stdout 打印 `KSL_INCLUDE=<路径>` 与 `KSL_LIB=<路径>`
> - 路径同时写入 `$WORK_DIR/reports/ksl_path.txt`，供后续编译选项使用
>
> **脚本退出码**：
>
> | 退出码 | 含义 |
> |-------|------|
> | 0 | 成功 |
> | 1 | 参数/环境校验失败（`WORK_DIR` 未设置、缺少 `wget`/`unzip`/`find` 或 RPM 安装工具） |
> | 2 | 下载失败或文件不完整 |
> | 3 | 解压失败 |
> | 4 | 解压后未找到 RPM 包 |
> | 5 | RPM 安装失败 |
> | 6 | 安装后验证失败（未找到 `avx2ki.h` 或 `libavx2ki.so`） |
> | 7 | 路径持久化写入失败 |
>
> 失败时按退出码定位问题：检查网络（2）、zip 完整性（3）、包结构（4）、RPM 依赖（5）、安装路径（6）、磁盘/权限（7）。

#### 4.2.0.2 读取安装路径

脚本执行成功后，从 `$WORK_DIR/reports/ksl_path.txt` 读取后续编译选项所需的路径：

```bash
# 读取脚本持久化的安装路径
source $WORK_DIR/reports/ksl_path.txt
echo "KSL_INCLUDE=$KSL_INCLUDE"
echo "KSL_LIB=$KSL_LIB"
```

> **默认安装路径**：KSL 通常安装至 `/usr/local/ksl/`，即：
> - 头文件：`/usr/local/ksl/include/avx2ki.h`
> - 动态库：`/usr/local/ksl/lib/libavx2ki.so`

***

### 4.2.0-alt 准备开源 NEON 实现（按需执行，`AVX_STRATEGY=neon` 时走本节）

> **触发条件**（须同时满足）：
> 1. DevKit 扫描报告中存在 `INTRINSICS_LIBRARY`（avx2ki_option）或 `INTRINSICS` 类型的 **Rule** 级别条目
> 2. **`AVX_STRATEGY=neon`**（用户在阶段 2 选择「使用 NEON 替代 AVX」开源方案）
>
> 本节不安装 KSL/avx2ki，改为使用 ARM 原生 NEON intrinsics（`<arm_neon.h>`）替代 x86 AVX/SSE intrinsics。NEON 头文件随 GCC/Clang aarch64 工具链自带，无需额外下载安装。

#### 4.2.0-alt.1 确认 NEON 工具链可用

```bash
# 确认 aarch64 工具链自带 arm_neon.h
find /usr -name "arm_neon.h" 2>/dev/null | head -3

# 确认 NEON intrinsics 可编译（aarch64 默认启用 NEON）
echo '#include <arm_neon.h>
float32x4_t test(float32x4_t a, float32x4_t b){ return vaddq_f32(a,b); }' \
  | gcc -xc - -c -o /dev/null 2>&1 && echo "NEON 可用" || echo "NEON 不可用，请检查工具链"
```

#### 4.2.0-alt.2 NEON 方案与 avx2ki 方案的差异说明

| 对比项 | avx2ki（KSL，`AVX_STRATEGY=ksl`） | NEON（开源，`AVX_STRATEGY=neon`） |
|--------|--------------------------------|--------------------------------|
| 头文件 | `<avx2ki.h>` | `<arm_neon.h>` |
| 代码改动量 | 小（`_mm*` 函数调用保持不变，由 avx2ki 映射） | 大（需将 `_mm*` 调用手动改写为 `v*` NEON intrinsics） |
| 额外依赖 | 需安装 KSL 库并链接 `-lavx2ki` | 无额外依赖，工具链自带 |
| 性能 | 鲲鹏优化 | 取决于手写 NEON 实现质量 |

> **后续 4.2.1/4.2.2/4.2.3 中所有「鲲鹏侧引入 `<avx2ki.h>`」的指引，在本策略下均替换为「引入 `<arm_neon.h>` 并手写 NEON 等价实现」**，且 4.2.1 中 `-lavx2ki` 链接选项不再添加。

***

### 4.2.1 添加 aarch64 全局编译选项

> **aarch64 编译选项说明**：部分选项为 **Rule** 级别（必须），部分为 **Suggestion** 级别（建议）。Rule 级别不可跳过。

| 编译选项 | 修改级别 | 作用 | 不处理的风险 |
|---------|--------|------|-----------|
| `-I /usr/local/ksl/include/ -L /usr/local/ksl/lib/ -lavx2ki -lm` | **Rule（必须，仅当报告有 `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目且 `AVX_STRATEGY=ksl` 时）** | 链接 avx2ki.so 动态库 | 无法使用 avx2ki.h 中的 intrinsics 兼容层，编译失败 |
| 引入 `<arm_neon.h>`（NEON 开源方案） | **Rule（必须，仅当报告有 `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目且 `AVX_STRATEGY=neon` 时）** | 使用 ARM 原生 NEON intrinsics 替代 x86 AVX | 无法编译 ARM SIMD 代码 |
| 移除 `-mavx`/`-mavx2` 等 x86 AVX 编译选项 | **Rule（必须）** | 鲲鹏平台不支持 AVX 指令集 | 编译报错，无法在鲲鹏平台构建 |
| `-fsigned-char` | Suggestion（建议） | 强制 `char` 类型为有符号 | x86 默认有符号，aarch64 默认无符号，导致字符比较结果不同 |
| `-march=armv8.5-a` | Suggestion（建议） | 指定目标鲲鹏架构版本 | 未指定时可能无法利用鲲鹏处理器指令集 |
| `-Werror=conversion` | Suggestion（建议） | 将隐式类型转换提升为错误 | 隐式类型转换可能导致运行时行为不一致 |

> **`-march` 取值规则**：默认使用 `armv8.5-a`；若编译器版本过旧或目标硬件不支持 armv8.5-a，降级为 `armv8-a`。可通过以下命令检测：

```bash
echo | gcc -march=armv8.5-a -E -dM - 2>/dev/null | grep -q "__ARM_ARCH" \
  && echo "支持 armv8.5-a" || echo "不支持，请降级为 armv8-a"
```

**按构建系统添加全局编译选项：**

**详细修改案例（Bazel `.bazelrc` / CMake `CMakeLists.txt` / Make `Makefile` 三个完整模板、全局编译选项对照表、`-march` 检测命令、执行流程、失败处置）见** [references/build-system-flags.md](./references/build-system-flags.md)。本节仅给出执行摘要：

- **Bazel**：在 `.bazelrc` 的 `build:linux_aarch64` 配置段追加 `--copt` / `--cxxopt` / `--linkopt`
- **CMake**：用 `if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")` 隔离，必要时 `string(REPLACE ...)` 移除 `-mavx*`
- **Make**：用 `ifeq ($(shell uname -m),aarch64)` 隔离，`$(filter-out ...)` 移除 x86 指令
- **关键策略**：
  - `AVX_STRATEGY=ksl` → 添加 `-I/usr/local/ksl/include/` 与 `-L/usr/local/ksl/lib/ -lavx2ki -lm`
  - `AVX_STRATEGY=neon` → **不添加** avx2ki 链接（NEON 头文件随工具链自带）
  - 基础兼容选项：`-fsigned-char` / `-Werror=conversion` / `-march=armv8.5-a`（不支持则降级 `armv8-a`）
- **agent 工作流**：阅读 references → 识别构建系统类型 → 按 `AVX_STRATEGY` 决定 avx2ki 处理 → 移除 x86 AVX/SSE 选项 → 添加基础兼容 → 双架构编译验证

***

### 4.2.2 处理 x86 专属头文件（`ATTRIBUTE` 类型，Rule 级别）

> **Rule（必须）**：报告中 `PortingCategory.ATTRIBUTE` 类型且 `modification_level` 为 `Rule` 的条目，建议为 `"Insert this code snippet into the x86 macro branch."`，即**必须**将 x86 专属头文件用架构宏保护。

**问题定位**：DevKit 报告给出了包含 x86 专属头文件的源文件路径和行号，直接跳转到对应行。

**详细修改案例、头文件对照表与失败处置见** [references/x86-header-migration.md](./references/x86-header-migration.md)。本节仅给出执行摘要：

- **修改方法**：用架构宏将 `#include` 语句包裹，鲲鹏侧按 `AVX_STRATEGY` 引入 `<avx2ki.h>`（`ksl`）或 `<arm_neon.h>`（`neon`）
- **整体保护**：若整个源文件都是 x86 专属 SIMD，在文件顶部用 `#if defined(__x86_64__)` 整体包裹
- **常用头文件**：`<immintrin.h>` / `<emmintrin.h>` / `<xmmintrin.h>` / `<nmmintrin.h>` / `<pmmintrin.h>` / `<smmintrin.h>` / `<cpuid.h>`（详见 references 完整对照表）
- **agent 工作流**：阅读 references → 定位源文件 → 按 `AVX_STRATEGY` 二选一应用 → 双架构编译验证

***

### 4.2.3 处理 intrinsics 函数调用（`INTRINSICS`/`INTRINSICS_LIBRARY` 类型，Rule 级别）

> **Rule（必须）**：报告中 `PortingCategory.INTRINSICS` 类型条目要求使用 avx2ki.h 替代（或 sse2neon.h）；`PortingCategory.INTRINSICS_LIBRARY`（avx2ki_option）要求添加 avx2ki 编译链接选项。两者均为 Rule 级别，**必须处理**。

**问题定位**：报告给出使用了 `_mm256_*`、`_mm512_*`、`_mm_*`、`_BitScanReverse64`、`_xgetbv`、`_MM_SET_FLUSH_ZERO_MODE`、`_MM_SET_DENORMALS_ZERO_MODE` 等 x86 专属 API 的具体位置。

#### 4.2.3.1 按 AVX_STRATEGY 选择替代策略

替代方案由 4.2.0-prelude 确定的 `AVX_STRATEGY` 决定。**详细修改案例（avx2ki 兼容层代码、NEON 改写样例、常见 intrinsics 映射对照表、avx2ki 不覆盖函数的手动替换）见** [references/intrinsics-migration.md](./references/intrinsics-migration.md)。本节仅给出策略摘要：

| `AVX_STRATEGY` | 推荐案例 | 改造量 |
|----------------|---------|--------|
| `ksl` | 案例 1（avx2ki 兼容层） | 最小，仅切换头文件 |
| `neon` | 案例 2（手写 NEON）或案例 3（`__builtin_clzll` 等内置） | 中，需逐个改写 `_mm*` |
| `disable` | 案例 4 策略 C（整体禁用） | 最小，仅保留 x86 路径 |

> **NEON 方案注意**：AVX 寄存器宽 256 位，NEON 寄存器宽 128 位，一条 AVX 指令通常需拆成两条 NEON 指令；`_mm256_*` 系列无直接 1:1 映射，需逐个改写（详见 references 常见 intrinsics 映射对照表）。

#### 4.2.3.2 对于 avx2ki 不覆盖的 intrinsics，使用架构宏隔离 + ARM 替代

**详细修改案例（`_BitScanReverse64` 位扫描、策略 A/B/C 完整代码模板、策略与 `AVX_STRATEGY` 对应关系）见** [references/intrinsics-migration.md](./references/intrinsics-migration.md) 案例 3 与案例 4。

**策略选择速查**：
- **策略 A**（架构宏隔离 + ARM NEON 替代）— 性能不退化，推荐用于热点路径
- **策略 B**（架构宏隔离 + 标量退化）— 编码成本低，适用于非热点路径
- **策略 C**（整体禁用）— 仅适用于可选的性能优化路径，**核心功能不可用此策略**

***

### 4.2.4 处理内联汇编（`BUILTIN_ASSEMBLES` 类型，Suggestion_General 级别）

> **Suggestion（建议）**：报告中 `PortingCategory.BUILTIN_ASSEMBLES` 条目修改级别为 `Suggestion_General`，建议将 x86 特定汇编指令改为 ARM 等价指令或跨平台替代方案。

**问题定位**：报告给出含 `__asm__` / `asm volatile` 的源文件位置，以及具体的 x86 汇编指令（如 `MOV`、`CPUID`、`XCHG`、`XGETBV` 等）及其 ARM 替代建议。

**修改方法**：架构宏隔离，并为 aarch64 提供等价实现。

**报告中出现的 x86 汇编指令及 ARM 替代方式：**

| x86 汇编指令 | 用途 | ARM aarch64 替代 | 跨平台替代 |
| --- | --- | --- | --- |
| `MOV` | 数据传送 | `LDR`/`MOV`/`STR`（视操作数） | 直接使用 C 赋值语句 |
| `CPUID` | 读取 CPU 信息 | `mrs x0, MIDR_EL1` 读 CPU 型号 | `getauxval(AT_HWCAP)` |
| `XCHG` | 原子交换 | `SWP` / `LDXR`+`STXR` | `__atomic_exchange_n()` |
| `XGETBV` | 读取 XCR 寄存器 | `mrs %0, fpcr` 读浮点控制寄存器 | 条件编译禁用 |
| `rdtsc` | 读 CPU 时钟周期 | `mrs %0, cntvct_el0` | `clock_gettime(CLOCK_MONOTONIC)` |
| `mfence`/`sfence` | 内存屏障 | `dmb ish` / `dsb ish` | `__sync_synchronize()` |
| `lock xadd` | 原子加 | `ldadd` / `ldaddal` | `__atomic_fetch_add()` |
| `bsf`/`bsr` | 位扫描 | `rbit`+`clz` 组合 | `__builtin_ctz()` / `__builtin_clz()` |

> **详细修改模式（CPUID 案例、rdtsc 时钟周期案例、通用修改框架）见** [references/inline-asm-migration.md](./references/inline-asm-migration.md)。本节仅给出执行摘要：
>
> - **修改方法**：架构宏隔离（保留 x86 实现，aarch64 侧用 ARM 指令或 GCC 内置函数替代）
> - **优先策略**：优先使用 GCC 内置函数（`__builtin_popcount` / `__builtin_ctz` / `__builtin_clz` / `__atomic_*`），编译器自动选择最优指令，无需手动区分架构
> - **agent 工作流**：阅读 references → 在上表查找指令 → 按优先级选择替代 → 双架构编译验证

***



### 4.2.5 替换 Intel MKL 函数为 KML 或 OpenBLAS（`INVALID_CATEGORY` 类型，Rule 级别）

> **Rule（必须）**：报告中 `PortingCategory.INVALID_CATEGORY` 类型条目修改级别为 `Rule`，涉及 Intel MKL（Math Kernel Library）函数（如 `cblas_sgemm`、`cblas_dgemm`、`cblas_cgemm` 等），**必须**替换为 aarch64 平台等价的数学库函数。
>
> **替代方案由 4.2.0-prelude 确定的 `MKL_STRATEGY` 决定，二选一**：
> - `MKL_STRATEGY=kml`：使用鲲鹏数学库 KML（Kunpeng Math Library）
> - `MKL_STRATEGY=openblas`：使用开源 OpenBLAS
> - `MKL_STRATEGY=disable`：整体禁用该模块
>
> KML 与 OpenBLAS 均实现了标准 CBLAS/LAPACK 接口，函数签名与 Intel MKL 完全相同，**只需切换链接库即可**，无需修改函数调用代码本身；差异在于安装包、头文件路径与链接库名。

**问题定位**：报告给出了调用 MKL 函数的源文件路径和行号（如 `runtime_matmul_mkl.cc`、`mkl_matmul_op.cc`），以及 DevKit 的建议链接：
- KML 软件包获取：`https://www.hikunpeng.com/document/detail/en/kunpengaccel/math-lib/devg-kml/kunpengaccel_kml_16_0004.html`
- KML 迁移指南：`https://www.hikunpeng.com/document/detail/en/kunpengaccel/math-lib/migration/kunpengaccel_12_0001.html`
- OpenBLAS 获取：`https://www.openblas.net` 或通过系统包管理器安装

**详细修改案例（KML/OpenBLAS 安装命令、头文件引用修改、API 兼容函数表、Bazel/CMake/Make 链接模板、MKL 专有扩展接口处理）见** [references/mkl-migration.md](./references/mkl-migration.md)。本节仅给出执行摘要：

- **4.2.5.1 安装**：按 `MKL_STRATEGY` 二选一（`kml` → BoostKit KML 包；`openblas` → dnf/apt/源码安装）
- **4.2.5.2 头文件**：用 `#if defined(__aarch64__)` 切换 `cblas.h`（KML/OpenBLAS）与 `mkl.h`（x86）
- **4.2.5.3 函数调用**：CBLAS/LAPACK 接口与 MKL 完全兼容，**无需改函数调用代码**，仅切换链接库
- **4.2.5.4 构建系统**：按 `MKL_STRATEGY` 二选一修改 Bazel/CMake/Make 链接选项
- **MKL 专有扩展**：`mkl_malloc` → `aligned_alloc`、`mkl_set_num_threads` → `omp_set_num_threads`
- **agent 工作流**：阅读 references → 按 `MKL_STRATEGY` 二选一应用 → 双架构编译验证

### 4.2.6 处理类型大小/字节序依赖（`type size` 类型）

**问题定位**：报告标记了依赖特定类型大小的代码，例如假设 `int` 为 32 位、`long` 为 64 位等。

**修改方法**：

```cpp
// 问题：依赖 long 的具体大小（Linux x86_64 和 aarch64 上 long 均为 64 位，但跨 OS 时不同）
long value = some_function();

// 修改为：使用 <stdint.h> 中的明确宽度类型
int64_t value = some_function();
```

字节序处理（通常 x86 和 aarch64 均为小端，跨字节序时才需要处理）：

```cpp
// 若涉及网络字节序或文件格式，使用标准函数
#include <arpa/inet.h>
uint32_t network_val = htonl(host_val);   // 主机序 → 网络序（跨平台安全）
uint32_t host_val    = ntohl(network_val); // 网络序 → 主机序
```
***

### 4.2.7 处理内存对齐假设（`memory align` 类型）

**问题定位**：报告标记了使用对齐相关 API 或假设特定对齐的代码。

**ARM 对齐规则**：ARM 架构对未对齐内存访问更为敏感（某些指令要求严格对齐），而 x86 通常容忍未对齐访问。

**修改方法**：

```cpp
// 问题：假设任意地址可以按 16 字节对齐方式访问
// x86 容忍，ARM 上未对齐的 SIMD 加载可能触发 SIGBUS

// 修改：使用带 u（unaligned）后缀的加载指令，或确保数据已对齐
#if defined(__x86_64__)
    __m128i val = _mm_loadu_si128((__m128i*)ptr);  // 允许未对齐
#elif defined(__aarch64__)
    // vld1q 允许任意对齐，vld1q 等效于 _mm_loadu_si128
    uint8x16_t val = vld1q_u8((const uint8_t*)ptr);
#endif

// 或：在分配内存时确保对齐
void* buf = aligned_alloc(16, size);  // C11 标准，x86 和 ARM 均支持
```

***

## 4.3 修改完整性验证

全部报告条目处理完毕后，执行以下检查，确认没有遗漏：

### 4.3.1 残留 x86 专属头文件检查

```bash
# 检查是否还有未隔离的 x86 intrinsics 头文件（过滤掉已有架构宏保护的行）
grep -rn "#include.*\(immintrin\|emmintrin\|xmmintrin\|nmmintrin\|smmintrin\|cpuid\.h\)" \
  $PROJECT_ROOT --include="*.cc" --include="*.cpp" --include="*.h" \
  | grep -v "__x86_64__\|_M_X64\|aarch64\|#if"
# 若有输出，说明仍有未保护的 include，需要继续处理
```

### 4.3.2 残留 intrinsics 调用检查

```bash
# 检查是否还有未隔离的 SIMD 类型或函数
grep -rn "_mm256_\|_mm512_\|_mm_\|__m128\|__m256\|__m512" \
  $PROJECT_ROOT --include="*.cc" --include="*.cpp" --include="*.h" \
  | grep -v "__x86_64__\|aarch64\|//.*_mm" | head -20
```

### 4.3.3 记录修改清单

```bash
# 将本阶段的所有修改记录到工作目录
git -C $PROJECT_ROOT diff --stat 2>/dev/null \
  >> $WORK_DIR/reports/source_changes.txt
```

***

## 4.4 修改完成检查清单

**Rule 级别（必须完成）：**

- [ ] **4.2.0-prelude** 已读取 `user_decisions.txt` 并确定 `AVX_STRATEGY`（ksl/neon/disable）与 `MKL_STRATEGY`（kml/openblas/disable）
- [ ] **4.2.0** 若报告含 `INTRINSICS_LIBRARY`（avx2ki_option）或 `INTRINSICS` 类型 Rule 条目且 `AVX_STRATEGY=ksl`：`source-migration-scan/scripts/ksl-install.sh` 执行成功（exit 0），`$WORK_DIR/reports/ksl_path.txt` 已生成且 `avx2ki.h`/`libavx2ki.so` 可访问；若 `AVX_STRATEGY=neon` 则走 4.2.0-alt 确认 NEON 工具链可用；否则跳过
- [ ] **4.2.1（avx2ki）** 若 4.2.0 已执行（`AVX_STRATEGY=ksl`）：aarch64 编译选项中已添加 `-lavx2ki` 链接选项；若 `AVX_STRATEGY=neon` 则不添加 avx2ki 链接（NEON 无需额外库）；否则跳过
- [ ] **4.2.1** `-mavx`/`-mavx2` 等不支持选项已从 aarch64 构建中移除（Rule 必须）
- [ ] **4.2.2** 所有 `ATTRIBUTE` 类型问题（x86 专属头文件）已用架构宏保护，鲲鹏侧按 `AVX_STRATEGY` 引入 `avx2ki.h`（ksl）或 `arm_neon.h`（neon）
- [ ] **4.2.3** 所有 `INTRINSICS`/`INTRINSICS_LIBRARY` 类型问题已处理（`AVX_STRATEGY=ksl` 用 avx2ki.h 兼容层；`AVX_STRATEGY=neon` 手写 NEON 实现；或架构宏隔离 + ARM 替代）
- [ ] **4.2.5** 所有 `INVALID_CATEGORY` 类型问题（MKL 函数）已按 `MKL_STRATEGY` 替换：`kml` 替换为 KML 函数并链接 `-lkml_blas -lkml_lapack`；`openblas` 替换为 OpenBLAS 并链接 `-lopenblas`

**Suggestion 级别（建议完成）：**

- [ ] **4.2.1** 建议编译选项已添加：`-fsigned-char`、`-march=armv8.5-a`（或降级 `armv8-a`）、`-Werror=conversion`
- [ ] **4.2.4** 所有 `BUILTIN_ASSEMBLES` 类型内联汇编已用架构宏隔离，aarch64 侧提供 ARM 等价实现或 GCC 内置函数替代

**通用完整性检查：**

- [ ] **4.2.6** 所有 `type size` 类型问题已改用明确宽度类型（`int32_t`、`int64_t` 等）
- [ ] **4.2.7** 所有 `memory align` 类型问题已排查并处理（使用 `aligned_alloc` 或带 `u` 后缀的加载指令）
- [ ] 残留检查通过（`grep` 无遗漏的未保护 x86 头文件和 intrinsics 调用）
- [ ] 修改清单已记录到 `$WORK_DIR/reports/source_changes.txt`
- [ ] 确认所有修改中 x86 代码路径未被删除（最小侵入原则）

