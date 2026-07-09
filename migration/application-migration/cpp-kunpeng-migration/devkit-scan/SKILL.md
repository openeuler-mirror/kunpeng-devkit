---
name: devkit-scan
description: C/C++ 项目鲲鹏迁移的阶段 4 子 Skill，专注于 DevKit 扫描与源码/构建适配环节。提供运行华为鲲鹏 DevKit 对源码进行 x86 兼容性扫描的能力，并根据扫描报告完成源码架构适配修改（内联汇编、intrinsics、头文件、类型大小、内存对齐、预编译宏、MKL函数替换、avx2ki库安装）以及构建系统配置适配（aarch64 编译选项），严格串行执行——先完成扫描生成报告，再依据报告修改源码。在作为 cpp-kunpeng-migration 主 Skill 的阶段 4 子 Skill 被调用时触发，当用户需要单独运行 DevKit 扫描、处理 x86 专属代码适配、或下载安装 DevKit 工具时也应直接触发。适用于 C/C++ 项目的 x86→aarch64(鲲鹏）架构迁移，涵盖源码兼容性扫描、架构相关代码改写、构建系统鲲鹏适配等任务。
use_when: 适用c/c++语言的鲲鹏迁移。
do_not_ues_when: 不适用于非 C/C++ 语言的鲲鹏迁移、非鲲鹏架构的迁移。
---

# 阶段 4：DevKit 扫描与源码适配

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

用户选择 `download` 时，agent **必须读取文件** `devkit-download.md` 按其中步骤执行：从华为云镜像站动态匹配最新 `DevKit-CLI-*-Linux-Kunpeng.tar.gz`，下载解压并验证 `--version`，最终将路径赋值给 `DEVKIT` 变量供 4.1.2 使用。失败时回到 4.1.1 提问。

### 4.1.2 确认扫描参数

根据阶段 1 `environment-prepare/SKILL.md` 的构建系统检测结果，确定 `-b` 参数：

| 构建系统           | `-b` 参数值 |
| -------------- | -------- |
| Bazel          | `bazel`  |
| CMake          | `cmake`  |
| Make/Makefile  | `make`   |
| Blade/SCons/其他 | `other`  |

### 4.1.3 执行扫描

```bash
DEVKIT_REPORT_DIR="$WORK_DIR/reports/devkit-$(date +%Y%m%d%H%M%S)"
mkdir -p $DEVKIT_REPORT_DIR

$DEVKIT porting src-mig \
  -i $PROJECT_ROOT \
  -b <bazel|cmake|make|other> \
  -r all \
  -o $DEVKIT_REPORT_DIR \
  2>&1 | tee $WORK_DIR/reports/devkit-scan.log
```

> `-r all` 表示扫描所有问题类型，包括内联汇编、intrinsics、头文件、类型大小、内存对齐、编译标志等。

### 4.1.4 读取并汇总扫描报告

DevKit 通常输出 CSV 或 HTML 格式的报告，先确认报告文件：

```bash
# 查看生成的报告文件
ls $DEVKIT_REPORT_DIR

# CSV 格式：提取问题列表（跳过表头行）
find $DEVKIT_REPORT_DIR -name "*.csv" \
  -exec awk -F',' 'NR>1 {print NR, $0}' {} \; | head -60

# 按问题类型统计数量，了解整体规模
find $DEVKIT_REPORT_DIR -name "*.csv" \
  -exec awk -F',' 'NR>1 {print $3}' {} \; | sort | uniq -c | sort -rn
```

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

#### 4.2.0.1 下载 BoostKit KSL 包

```bash
# 创建工作目录
mkdir -p $WORK_DIR/ksl && cd $WORK_DIR/ksl

# 下载 BoostKit-ksl 包（包含 avx2ki.h 和 libavx2ki.so）
wget -O BoostKit-ksl_2.5.3.zip \
  "https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20BoostKit/Kunpeng%20BoostKit%2025.3.0/BoostKit-ksl_2.5.3.zip"

# 验证下载
ls -lh BoostKit-ksl_2.5.3.zip
```

#### 4.2.0.2 解压并安装 RPM 包

```bash
# 解压 zip 包
unzip BoostKit-ksl_2.5.3.zip -d BoostKit-ksl_2.5.3

# 查看解压内容，找到 rpm 包
find BoostKit-ksl_2.5.3 -name "*.rpm" | sort

# 安装所有 rpm 包（通常包含 ksl-devel 和 ksl 运行时包）
# 方式一：使用 dnf/yum 安装（推荐，自动处理依赖）
find BoostKit-ksl_2.5.3 -name "*.rpm" | xargs dnf install -y 2>/dev/null || \
find BoostKit-ksl_2.5.3 -name "*.rpm" | xargs yum install -y 2>/dev/null || \
find BoostKit-ksl_2.5.3 -name "*.rpm" -exec rpm -ivh --nodeps {} \;
```

#### 4.2.0.3 验证安装

```bash
# 验证头文件已安装
ls /usr/local/ksl/include/avx2ki.h 2>/dev/null || \
find /usr -name "avx2ki.h" 2>/dev/null | head -3

# 验证动态库已安装
ls /usr/local/ksl/lib/libavx2ki.so 2>/dev/null || \
find /usr -name "libavx2ki.so" 2>/dev/null | head -3

# 确认安装路径（后续编译选项中使用）
KSL_INCLUDE=$(dirname $(find /usr -name "avx2ki.h" 2>/dev/null | head -1))
KSL_LIB=$(dirname $(find /usr -name "libavx2ki.so" 2>/dev/null | head -1))
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

#### Bazel 项目

在 `.bazelrc` 的 aarch64 配置段中添加：

```python
# .bazelrc — aarch64 配置段

# Rule（必须，仅当报告有 `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目且 AVX_STRATEGY=ksl 时）：链接 avx2ki 动态库
# 若 AVX_STRATEGY=neon，则不添加以下 avx2ki 链接选项（NEON 头文件随工具链自带，无需额外链接）
build:linux_aarch64 --copt=-I/usr/local/ksl/include/
build:linux_aarch64 --cxxopt=-I/usr/local/ksl/include/
build:linux_aarch64 --linkopt=-L/usr/local/ksl/lib/
build:linux_aarch64 --linkopt=-lavx2ki
build:linux_aarch64 --linkopt=-lm

# Rule（必须）：移除 x86 AVX 相关编译选项（在 x86 配置段保留，aarch64 段不添加）
# 注意：在 BUILD 文件和 .bazelrc 中查找并移除/隔离 -mavx, -mavx2, -mavx512f, -msse4.1, -msse4.2, -msse2 等

# Suggestion（建议）：基础编译兼容选项
build:linux_aarch64 --copt=-fsigned-char
build:linux_aarch64 --cxxopt=-fsigned-char
build:linux_aarch64 --copt=-Werror=conversion
build:linux_aarch64 --cxxopt=-Werror=conversion
build:linux_aarch64 --copt=-march=armv8.5-a
build:linux_aarch64 --cxxopt=-march=armv8.5-a
# 若编译器/硬件不支持 armv8.5-a，将上述 armv8.5-a 改为 armv8-a
```

> **关于 `-mavx`/`-mavx2` 的处理（Rule 级别，必须）**：检查 `.bazelrc` 和各 `BUILD` 文件中是否存在 `-mavx`/`-mavx2` 等编译选项，通过架构宏或构建配置段进行隔离，确保这些选项只在 x86 配置下生效。

#### CMake 项目

在 `CMakeLists.txt` 中添加全局编译选项：

```cmake
# CMakeLists.txt
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # Rule（必须，仅当报告有 `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目且 AVX_STRATEGY=ksl 时）：链接 avx2ki 库
    # 若 AVX_STRATEGY=neon，则跳过以下 avx2ki 链接（NEON 无需额外库）
    include_directories(/usr/local/ksl/include/)
    link_directories(/usr/local/ksl/lib/)
    link_libraries(avx2ki m)

    # Rule（必须）：移除 x86 AVX 选项
    string(REPLACE "-mavx2" "" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
    string(REPLACE "-mavx2" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
    string(REPLACE "-mavx" "" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
    string(REPLACE "-mavx" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")

    # Suggestion（建议）：基础编译兼容选项
    add_compile_options(-fsigned-char -Werror=conversion -march=armv8.5-a)
    # 若编译器/硬件不支持 armv8.5-a，改为：
    # add_compile_options(-fsigned-char -Werror=conversion -march=armv8-a)
endif()
```

#### Make 项目

在 `Makefile` 中追加全局编译选项：

```makefile
# Makefile
ifeq ($(shell uname -m),aarch64)
    # Rule（必须，仅当报告有 `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目且 AVX_STRATEGY=ksl 时）：链接 avx2ki 动态库
    # 若 AVX_STRATEGY=neon，则跳过以下 avx2ki 链接（NEON 无需额外库）
    CFLAGS   += -I/usr/local/ksl/include/
    CXXFLAGS += -I/usr/local/ksl/include/
    LDFLAGS  += -L/usr/local/ksl/lib/ -lavx2ki -lm

    # Rule（必须）：移除 x86 AVX 相关选项
    CFLAGS   := $(filter-out -mavx -mavx2 -mavx512f -msse4.1 -msse4.2 -msse2,$(CFLAGS))
    CXXFLAGS := $(filter-out -mavx -mavx2 -mavx512f -msse4.1 -msse4.2 -msse2,$(CXXFLAGS))

    # Suggestion（建议）：基础编译兼容选项
    CFLAGS   += -fsigned-char -Werror=conversion -march=armv8.5-a
    CXXFLAGS += -fsigned-char -Werror=conversion -march=armv8.5-a
    # 若编译器/硬件不支持 armv8.5-a，改为 -march=armv8-a
endif
```

> **双架构兼容说明**：上述选项仅在鲲鹏构建时生效（通过构建系统的架构判断或配置段隔离），不影响 x86 编译。

***

### 4.2.2 处理 x86 专属头文件（`ATTRIBUTE` 类型，Rule 级别）

> **Rule（必须）**：报告中 `PortingCategory.ATTRIBUTE` 类型且 `modification_level` 为 `Rule` 的条目，建议为 `"Insert this code snippet into the x86 macro branch."`，即**必须**将 x86 专属头文件用架构宏保护。

**问题定位**：DevKit 报告给出了包含 x86 专属头文件的源文件路径和行号，直接跳转到对应行。

**常见 x86 专属头文件列表：**

| 头文件 | 说明 | 鲲鹏替代（`AVX_STRATEGY=ksl`） | 鲲鹏替代（`AVX_STRATEGY=neon`） |
|--------|------|----------|----------|
| `<immintrin.h>` | AVX/AVX2 intrinsics | 引入 `<avx2ki.h>`（KSL 兼容层） | 引入 `<arm_neon.h>` 并手写 NEON |
| `<emmintrin.h>` | SSE2 intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<xmmintrin.h>` | SSE intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<nmmintrin.h>` | SSE4.2 intrinsics（含 CRC32） | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<pmmintrin.h>` | SSE3 intrinsics（含 FTZ/DAZ） | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<smmintrin.h>` | SSE4.1 intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<cpuid.h>` | CPU 特性检测（x86 专属） | 无直接替代，需改用系统接口 | 无直接替代，需改用系统接口 |

**修改方法**：用架构宏将 `#include` 语句包裹，鲲鹏侧按 `AVX_STRATEGY` 引入对应头文件：

```cpp
// 原始代码（直接引用了 x86 的 intrinsic 头文件）
#include <xmmintrin.h>

// 修改后（Rule 级别：必须用架构宏保护）
#if defined(__x86_64__) || defined(_M_X64)
#include <xmmintrin.h>
#elif defined(__aarch64__) && defined(USE_AVX2KI)   // AVX_STRATEGY=ksl
#include <avx2ki.h>   // KSL 提供的 x86 intrinsics 到鲲鹏 NEON 兼容层
#elif defined(__aarch64__)                           // AVX_STRATEGY=neon
#include <arm_neon.h> // ARM 原生 NEON intrinsics，需手写 NEON 等价实现
#endif
```

> **说明**：上方代码示例同时展示了两种策略的写法，实际执行时按 `AVX_STRATEGY` 取值二选一：
> - `AVX_STRATEGY=ksl`：鲲鹏侧引入 `<avx2ki.h>`，原有 `_mm*` 调用无需修改
> - `AVX_STRATEGY=neon`：鲲鹏侧引入 `<arm_neon.h>`，需将 `_mm*` 调用手动改写为 NEON `v*` intrinsics（详见 4.2.3）

若整个源文件都是 x86 专属的 SIMD 实现，可在文件顶部整体保护：

```cpp
// 文件顶部整体保护，ARM 上跳过整个文件
#if defined(__x86_64__) || defined(_M_X64)

// ... 文件全部内容 ...

#endif  // __x86_64__
```

***

### 4.2.3 处理 intrinsics 函数调用（`INTRINSICS`/`INTRINSICS_LIBRARY` 类型，Rule 级别）

> **Rule（必须）**：报告中 `PortingCategory.INTRINSICS` 类型条目要求使用 avx2ki.h 替代（或 sse2neon.h）；`PortingCategory.INTRINSICS_LIBRARY`（avx2ki_option）要求添加 avx2ki 编译链接选项。两者均为 Rule 级别，**必须处理**。

**问题定位**：报告给出使用了 `_mm256_*`、`_mm512_*`、`_mm_*`、`_BitScanReverse64`、`_xgetbv`、`_MM_SET_FLUSH_ZERO_MODE`、`_MM_SET_DENORMALS_ZERO_MODE` 等 x86 专属 API 的具体位置。

#### 4.2.3.1 按 AVX_STRATEGY 选择替代策略

替代方案由 4.2.0-prelude 确定的 `AVX_STRATEGY` 决定，二选一：

##### （a）`AVX_STRATEGY=ksl`：使用 avx2ki.h 兼容层

avx2ki.h 是鲲鹏 KSL 提供的 x86 intrinsics 到 ARM NEON 的映射头文件，大多数 `_mm*` 函数均有对应映射：

```cpp
// 修改方法：将 x86 头文件替换为 avx2ki.h，原有 intrinsics 调用代码无需修改
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <avx2ki.h>   // avx2ki 提供与 immintrin.h 相同的 API 映射到 NEON
#endif

// 原有 intrinsics 代码可保持不变，avx2ki 负责在 aarch64 上完成映射
void process(const float* a, const float* b, float* out, int n) {
    for (int i = 0; i < n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_add_ps(va, vb));
    }
}
```

##### （b）`AVX_STRATEGY=neon`：手写开源 NEON 实现

不使用 avx2ki，改为引入 `<arm_neon.h>` 并将 `_mm*` 调用手动改写为 NEON `v*` intrinsics。常见映射对照：

| x86 AVX/SSE intrinsic | 用途 | ARM NEON 替代 |
|----------------------|------|--------------|
| `_mm256_loadu_ps` | 加载 8 个 float | `vld1q_f32`（每次 4 个，需两条） |
| `_mm256_storeu_ps` | 存储 8 个 float | `vst1q_f32`（每次 4 个，需两条） |
| `_mm256_add_ps` | 8 路 float 加 | `vaddq_f32`（每次 4 路，需两条） |
| `_mm_loadu_ps` | 加载 4 个 float | `vld1q_f32` |
| `_mm_storeu_ps` | 存储 4 个 float | `vst1q_f32` |
| `_mm_add_ps` | 4 路 float 加 | `vaddq_f32` |

```cpp
// 修改方法：将 x86 头文件替换为 arm_neon.h，并将 _mm* 调用改写为 NEON v* 调用
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>   // ARM 原生 NEON intrinsics
#endif

void process(const float* a, const float* b, float* out, int n) {
#if defined(__x86_64__) || defined(_M_X64)
    for (int i = 0; i < n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_add_ps(va, vb));
    }
#elif defined(__aarch64__)
    // ARM NEON 手写实现（AVX 256 位需拆为两条 128 位 NEON 指令）
    for (int i = 0; i < n; i += 8) {
        float32x4_t va1 = vld1q_f32(a + i);
        float32x4_t va2 = vld1q_f32(a + i + 4);
        float32x4_t vb1 = vld1q_f32(b + i);
        float32x4_t vb2 = vld1q_f32(b + i + 4);
        vst1q_f32(out + i, vaddq_f32(va1, vb1));
        vst1q_f32(out + i + 4, vaddq_f32(va2, vb2));
    }
#endif
}
```

> **NEON 方案注意**：AVX 寄存器宽 256 位，NEON 寄存器宽 128 位，一条 AVX 指令通常需拆成两条 NEON 指令；`_mm256_*` 系列无直接 1:1 映射，需逐个改写。

#### 4.2.3.2 对于 avx2ki 不覆盖的 intrinsics，使用架构宏隔离 + ARM 替代

**`_BitScanReverse64`**（位扫描，报告中 bfc_allocator.h 出现）：

```cpp
// Rule 级别，需手动替换
#if defined(__x86_64__) || defined(_M_X64)
    unsigned long index;
    _BitScanReverse64(&index, val);
    int result = (int)index;
#elif defined(__aarch64__)
    // ARM 替代：63 - clz 即最高有效位位置
    int result = 63 - __builtin_clzll(val);
#endif
```

**修改方法**：根据该段代码的业务重要性，选择以下策略之一：

**策略 A：架构宏隔离 + 提供 ARM NEON 替代实现**（推荐，性能不退化）

```cpp
// 以加法运算为例
void add_vectors(const float* a, const float* b, float* out, int n) {
#if defined(__x86_64__) || defined(_M_X64)
    // 原有 AVX 实现（保留不变）
    for (int i = 0; i < n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_add_ps(va, vb));
    }
#elif defined(__aarch64__)
    // ARM NEON 替代实现
    for (int i = 0; i < n; i += 4) {
        float32x4_t va = vld1q_f32(a + i);
        float32x4_t vb = vld1q_f32(b + i);
        vst1q_f32(out + i, vaddq_f32(va, vb));
    }
#else
    // 通用标量实现（fallback）
    for (int i = 0; i < n; i++) out[i] = a[i] + b[i];
#endif
}
```

**策略 B：架构宏隔离 + 标量退化**（适用于非热点路径，编码成本低）

```cpp
void process(const float* src, float* dst, int n) {
#if defined(__x86_64__) || defined(_M_X64)
    // 原有 x86 SIMD 实现（保留不变）
    // ...
#else
    // 非 x86 平台退化为标量，功能等价，性能可能降低
    for (int i = 0; i < n; i++) dst[i] = transform(src[i]);
#endif
}
```

**策略 C：整体禁用该功能**（仅适用于可选的性能优化路径，核心功能不可用此策略）

```cpp
// 仅在 x86 上启用该优化特性
#if defined(__x86_64__) || defined(_M_X64)
void register_simd_optimizer() {
    // 注册 SIMD 加速处理器
}
#endif
```

> **策略与 `AVX_STRATEGY` 的对应关系**：当 `AVX_STRATEGY=disable` 时，统一采用策略 C（整体禁用该 SIMD 功能）；当 `AVX_STRATEGY=neon` 时，优先采用策略 A（手写 NEON 替代），非热点路径可用策略 B（标量退化）。

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

修改模式（以 CPUID 为例，报告中 cpu_info.cc 出现）：

```cpp
// 原始代码（x86 CPUID 用于检测 CPU 特性）
inline void RunCpuid(uint32_t eax, uint32_t ecx, uint32_t* abcd) {
    uint32_t ebx, edx;
#if defined(__x86_64__)
    __asm__("cpuid"
            : "=a"(abcd[0]), "=b"(ebx), "=c"(abcd[2]), "=d"(edx)
            : "0"(eax), "2"(ecx));
    abcd[1] = ebx;
    abcd[3] = edx;
#elif defined(__aarch64__)
    // aarch64 无 CPUID 指令，建议改用 getauxval(AT_HWCAP) 检测 CPU 特性
    abcd[0] = abcd[1] = abcd[2] = abcd[3] = 0;
#endif
}
```

```cpp
// 示例：读取时钟周期（rdtsc）
inline uint64_t get_timestamp() {
#if defined(__x86_64__) || defined(_M_X64)
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#elif defined(__aarch64__)
    uint64_t val;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(val));
    return val;
#else
    // 通用 fallback：使用标准时钟
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
#endif
}
```

> **优先使用 GCC 内置函数替代内联汇编**：`__builtin_popcount()`、`__builtin_ctz()`、`__builtin_clz()`、`__atomic_*` 系列等均支持 ARM64，编译器会自动选择最优指令，无需手动区分架构。

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

#### 4.2.5.1 安装数学库（按 MKL_STRATEGY 二选一）

##### （a）`MKL_STRATEGY=kml`：安装鲲鹏 KML 库

```bash
# 方式一：通过 dnf/yum 安装 KML（推荐）
# KML 通常随鲲鹏 BoostKit 软件包分发
dnf install -y kml-devel 2>/dev/null || yum install -y kml-devel 2>/dev/null

# 方式二：从华为官网下载 KML 软件包（按上方 DevKit 报告链接获取最新版）
# 下载后按软件包内 README 安装

# 验证 KML 安装
ls /usr/local/kml/include/cblas.h 2>/dev/null || \
find /usr -name "cblas.h" 2>/dev/null | grep -i kml | head -3

# 验证 KML 库文件
ls /usr/local/kml/lib/libkml*.so 2>/dev/null || \
find /usr -name "libkml*.so" 2>/dev/null | head -3
```

##### （b）`MKL_STRATEGY=openblas`：安装开源 OpenBLAS 库

```bash
# 方式一：通过 dnf/yum 安装 OpenBLAS（推荐）
dnf install -y openblas-devel 2>/dev/null || yum install -y openblas-devel 2>/dev/null \
  || apt-get install -y libopenblas-dev 2>/dev/null

# 方式二：从源码编译（按 https://www.openblas.net 指引获取最新版）
# tar xf OpenBLAS-*.tar.gz && cd OpenBLAS-* && make && make PREFIX=/usr/local/openblas install

# 验证 OpenBLAS 安装（头文件）
ls /usr/include/aarch64-linux-gnu/openblas_config.h 2>/dev/null || \
ls /usr/local/openblas/include/cblas.h 2>/dev/null || \
find /usr -name "cblas.h" 2>/dev/null | grep -i openblas | head -3

# 验证 OpenBLAS 库文件
ls /usr/lib64/libopenblas*.so 2>/dev/null || \
ls /usr/local/openblas/lib/libopenblas*.so 2>/dev/null || \
find /usr -name "libopenblas*.so" 2>/dev/null | head -3
```

#### 4.2.5.2 修改头文件引用

KML 与 OpenBLAS 均提供标准 CBLAS 接口，头文件切换方式相同：

```cpp
// 原始代码（引用 Intel MKL 头文件）
#include "mkl.h"         // Intel MKL 主头文件
// 或
#include "mkl_cblas.h"   // Intel MKL CBLAS 接口

// 修改后（aarch64 切换为标准 CBLAS 头文件，x86 保留 MKL）
#if defined(__aarch64__)
#include "cblas.h"       // KML / OpenBLAS 均提供标准 CBLAS 接口
// MKL 头文件路径通常为 /usr/local/kml/include/cblas.h（KML）
// OpenBLAS 头文件路径通常为 /usr/include/cblas.h 或 /usr/local/openblas/include/cblas.h（OpenBLAS）
#else
#include "mkl.h"
#endif
```

#### 4.2.5.3 常见 MKL 函数对应替换（API 兼容）

KML 与 OpenBLAS 均实现了标准 CBLAS/LAPACK 接口，函数签名与 Intel MKL 完全相同，**只需切换链接库即可**，无需修改函数调用代码本身：

| Intel MKL 函数 | 说明 | KML 替换（`MKL_STRATEGY=kml`） | OpenBLAS 替换（`MKL_STRATEGY=openblas`） | 是否需改代码 |
|---------------|------|---------|---------|------------|
| `cblas_sgemm` | 单精度矩阵乘（BLAS Level 3） | `cblas_sgemm`（KML） | `cblas_sgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_dgemm` | 双精度矩阵乘（BLAS Level 3） | `cblas_dgemm`（KML） | `cblas_dgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_cgemm` | 复数单精度矩阵乘 | `cblas_cgemm`（KML） | `cblas_cgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_zgemm` | 复数双精度矩阵乘 | `cblas_zgemm`（KML） | `cblas_zgemm`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_sgemv` | 单精度矩阵向量乘 | `cblas_sgemv`（KML） | `cblas_sgemv`（OpenBLAS） | 否，仅切换链接库 |
| `cblas_dgemv` | 双精度矩阵向量乘 | `cblas_dgemv`（KML） | `cblas_dgemv`（OpenBLAS） | 否，仅切换链接库 |
| `LAPACKE_sgetrf` | LU 分解 | `LAPACKE_sgetrf`（KML） | `LAPACKE_sgetrf`（OpenBLAS） | 否，仅切换链接库 |

> **注意**：若代码中使用了 MKL 专有扩展接口（如 `mkl_malloc`、`mkl_set_num_threads` 等），则需要额外处理：`mkl_malloc` → `aligned_alloc`（C11 标准），`mkl_set_num_threads` → OpenMP `omp_set_num_threads`。

#### 4.2.5.4 修改构建系统链接选项（按 MKL_STRATEGY 二选一）

将构建系统中链接 MKL 的选项替换为 KML 或 OpenBLAS：

##### （a）`MKL_STRATEGY=kml`：链接 KML

**Bazel 项目**（`.bazelrc` 或 `BUILD` 文件）：

```python
# 原始（链接 Intel MKL）
# --linkopt=-lmkl_rt 或 --linkopt=-lmkl_intel_lp64

# 修改后（aarch64 链接 KML，x86 保留 MKL）
# .bazelrc
build:linux_aarch64 --linkopt=-L/usr/local/kml/lib/
build:linux_aarch64 --linkopt=-lkml_blas
build:linux_aarch64 --linkopt=-lkml_lapack
```

**CMake 项目**：

```cmake
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # 链接 KML
    include_directories(/usr/local/kml/include/)
    link_directories(/usr/local/kml/lib/)
    target_link_libraries(${TARGET_NAME} kml_blas kml_lapack)
else()
    # x86 保留 MKL 链接（不修改）
    target_link_libraries(${TARGET_NAME} mkl_rt)
endif()
```

**Make 项目**：

```makefile
ifeq ($(shell uname -m),aarch64)
    # Rule（必须）：替换 MKL 为 KML
    CFLAGS   += -I/usr/local/kml/include/
    LDFLAGS  := $(patsubst -lmkl%,,$(LDFLAGS))   # 移除所有 -lmkl* 选项
    LDFLAGS  += -L/usr/local/kml/lib/ -lkml_blas -lkml_lapack
endif
```

##### （b）`MKL_STRATEGY=openblas`：链接 OpenBLAS

**Bazel 项目**（`.bazelrc` 或 `BUILD` 文件）：

```python
# 原始（链接 Intel MKL）
# --linkopt=-lmkl_rt 或 --linkopt=-lmkl_intel_lp64

# 修改后（aarch64 链接 OpenBLAS，x86 保留 MKL）
# .bazelrc
build:linux_aarch64 --linkopt=-L/usr/local/openblas/lib/
build:linux_aarch64 --linkopt=-lopenblas
# 若通过系统包管理器安装，OpenBLAS 默认在 /usr/lib64，可省略 -L
```

**CMake 项目**：

```cmake
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
    # 链接 OpenBLAS
    find_package(OpenBLAS REQUIRED)
    target_link_libraries(${TARGET_NAME} ${OpenBLAS_LIBRARIES})
else()
    # x86 保留 MKL 链接（不修改）
    target_link_libraries(${TARGET_NAME} mkl_rt)
endif()
```

**Make 项目**：

```makefile
ifeq ($(shell uname -m),aarch64)
    # Rule（必须）：替换 MKL 为 OpenBLAS
    CFLAGS   += -I/usr/local/openblas/include/
    LDFLAGS  := $(patsubst -lmkl%,,$(LDFLAGS))   # 移除所有 -lmkl* 选项
    LDFLAGS  += -L/usr/local/openblas/lib/ -lopenblas
    # 若通过系统包管理器安装，可省略 -I/-L，直接 -lopenblas
endif
```

***



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
- [ ] **4.2.0** 若报告含 `INTRINSICS_LIBRARY`（avx2ki_option）或 `INTRINSICS` 类型 Rule 条目且 `AVX_STRATEGY=ksl`：avx2ki KSL 库已下载安装（`avx2ki.h` 和 `libavx2ki.so` 可访问）；若 `AVX_STRATEGY=neon` 则走 4.2.0-alt 确认 NEON 工具链可用；否则跳过
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

