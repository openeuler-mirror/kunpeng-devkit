# 构建系统依赖分析

本文件按构建系统分章节收录 Bazel / CMake / Blade / SCons 四类项目的依赖分析流程。各章节相互独立，**按需加载**：根据 [repo-analysis-flow.md](repo-analysis-flow.md) Step 1 识别到的构建系统，只读取下方对应章节，其余跳过——不要整篇载入，避免占用上下文。

> **章节索引**：
> - [CMake 构建系统依赖分析](#cmake-构建系统依赖分析)
> - [Blade 构建系统依赖分析](#blade-构建系统依赖分析)
> - [Bazel 构建系统依赖分析](#bazel-构建系统依赖分析)
> - [SCons 构建系统依赖分析](#scons-构建系统依赖分析)

---

# CMake 构建系统依赖分析

> **按需加载**：仅当 [repo-analysis-flow.md](repo-analysis-flow.md) Step 1 识别到构建系统为 **CMake** 时加载本文件，否则跳过。

---

## 子模块自动签出检查（加载本文件后第一步）

CMake 项目常通过 `execute_process(... git submodule update ...)` 或 `find_package(Git)` 配合自定义命令在 `cmake` 阶段自动拉取/重置子模块。这种逻辑会在切换 ARM 分支后**重新覆盖回原默认分支**，是 CMake 项目 ARM 迁移的高频踩坑点。

```bash
# 检查是否存在 git submodule 自动签出（含子目录 CMakeLists.txt，不只顶层）
# 不要把 FetchContent_MakeAvailable 算进来——它是构建期下载依赖的正当机制
#    （见下方「解析 CMake 依赖声明」表），误当自动签出去注释会直接破坏依赖拉取
grep -rn "git submodule\|GIT_SUBMODULE" \
  --include="CMakeLists.txt" --include="*.cmake" \
  --exclude-dir=build --exclude-dir=.git \
  <项目根目录>/ 2>/dev/null

# 检查是否有 cmake 阶段调用 git reset / git checkout
# execute_process 可能跨行书写，grep 不跨行——命中数偏少时需人工翻看 execute_process 块
grep -rn "execute_process.*git\|git reset\|git checkout" \
  --include="CMakeLists.txt" --include="*.cmake" \
  --exclude-dir=build --exclude-dir=.git \
  <项目根目录>/ 2>/dev/null
```

**若存在自动签出逻辑**：

> **CMake 项目 ARM 迁移最高频踩坑点 —— 必须在依赖分析报告头部以醒目方式提示用户**
>
> - 在依赖分析报告**最前面**单独成节标注 警告，不要混在普通依赖列表里
> - 根因：`cmake -B build` 配置期会执行这段 `git submodule update`，以"修复未初始化子模块"的名义把已手动切到 ARM 分支的子模块**默默重置回默认分支**，而且**不会报错**。每次 cmake 重新配置都重置一次——不只第一次，清 build 目录重来也会
> - 症状极具迷惑性：`git submodule status` 显示分支正确，但 cmake 重新配置后回退；编译错误在"x86 残留"与"找不到 ARM 符号"间反复横跳，极易误判为依赖问题
>
> **处置分两步，且都必须在阶段 5 首次 `cmake -B build` 之前完成**：
>
> **第 1 步 — 关掉 cmake 的动态重置（CMake 侧，持久改造，不是一次性注释）**
>
> 不要删除自动签出逻辑，改为可控开关；ARM 路径（`OFF`）直接跳过 `execute_process`，让 cmake 配置期完全不触碰子模块分支。这是写进 CMakeLists 的持久改造，每次 cmake 重新配置都生效，清 build 目录重来也不会失效：
>
> ```cmake
> option(AUTO_SUBMODULE "Auto checkout submodules" ON)
> if(AUTO_SUBMODULE)
>     # x86 默认路径：保留原自动签出行为
>     execute_process(COMMAND git submodule update --init --recursive ...)
> endif()
> # ARM 路径（-DAUTO_SUBMODULE=OFF）：整个 execute_process 被跳过，分支由第 2 步钉定
> ```
>
> ARM 构建命令（阶段 5.1）显式传 `-DAUTO_SUBMODULE=OFF`。
>
> **第 2 步 — 把每个子模块钉到用户指定的固定分支（git 侧，逐个子模块）**
>
> 关掉动态重置只是"不再被覆盖"，子模块仍停在不确定状态，必须主动钉定，否则 cmake 不重置、但分支本身可能也没切对：
>
> - 每个含自动签出的子模块，其 ARM 分支作为**待确认项**在阶段 3 收集，走与其它 Git 依赖相同的确认闭环（见 [compat-and-binary-detect.md](compat-and-binary-detect.md) Part A 的 A.2/A.4 与 [kunpeng-confirmed-write.md](kunpeng-confirmed-write.md)）。不同子模块的 ARM 分支名往往不同（`arm64` / `aarch64` / `kunpeng`…），**逐个子模块确认，不共用一个分支**
> - 阶段 3 末尾、阶段 5 首次 `cmake -B build` **之前**，先 init 再逐个钉定（init 会把工作区停在默认 commit，随后的 checkout 覆盖为 ARM 分支，故 checkout 必须在后、且为最后一步）：
>   ```bash
>   git submodule update --init --recursive                          # 确保子模块工作区就位（含嵌套）
>   git -C <子模块路径> checkout <用户为该子模块确认的ARM分支或commit>   # 逐个钉到固定分支/commit
>   ```
> - **嵌套子模块要逐层钉定**：`--recursive` 会拉起嵌套子模块，父模块的 cmake 同样会在配置期重置它们，故每个层级的嵌套子模块都要按其各自确认的分支/commit 钉定，不能只钉顶层
> - **分支或 commit 皆可**：清单记录的是「ARM 适配分支/commit」，有些子模块的 ARM 适配只在某个 commit、无命名分支，`git checkout <commit>` 同样有效（detached HEAD 也能被第 1 步的 OFF 开关保护住不被重置）
> - 钉定后状态持久（存于子模块自身 .git，不在 build 目录），只要第 1 步开关生效，cmake 重新配置不会覆盖。**钉定后不得再手动跑 `git submodule update`**（会重置回默认 commit），分支维持靠第 1 步的 `OFF` 开关
>
> **留痕**：在 `$WORK_DIR/reports/user_decisions.txt` 中记录**每个子模块钉定的分支**（不只是"是否已禁用"），阶段 5 前再次核对。

---

## 解析 CMake 依赖声明

```bash
# 主 CMakeLists.txt
cat <项目根目录>/CMakeLists.txt

# cmake 子模块文件（FindXxx.cmake、依赖配置等）
find <项目根目录>/cmake -name "*.cmake" -type f 2>/dev/null

# 模块化拆分的 CMakeLists（子目录）
find <项目根目录> -name "CMakeLists.txt" -not -path "*/build/*" -not -path "*/.git/*" | head -20
```

CMake 通过以下命令声明外部依赖，每种对应不同的来源类型：

| 命令 | 依赖来源 | ARM 迁移关注点 |
|------|---------|---------------|
| `find_package(Foo REQUIRED)` | 系统已安装包 | 检查 ARM 系统包管理器是否提供该包 |
| `FetchContent_Declare` + `FetchContent_MakeAvailable` | 远端 Git/HTTP（构建期下载） | 检查远端是否有 ARM 分支或源码可重编 |
| `ExternalProject_Add` | 远端 Git/HTTP（编译期独立构建） | 同上，且需检查 `CONFIGURE_COMMAND`/`BUILD_COMMAND` 中是否硬编码 x86 标志 |
| `add_subdirectory(third_party/xxx)` | 仓库内嵌源码 | 检查内嵌源码是否含 x86 专属指令 |
| `target_link_libraries(... /path/to/libxxx.a)` | 硬编码二进制路径 | 大概率是 x86 预编译，需找 ARM 版替代 |
| `link_directories(/usr/lib64/...)` | 硬编码库目录 | 检查路径在 ARM 上是否存在（ARM 通常为 `/usr/lib/aarch64-linux-gnu`） |

**各命令需提取的关键字段**：

| 命令 | 关键字段 | 说明 |
|------|---------|------|
| `find_package` | 包名、`REQUIRED`/`OPTIONAL`、`<X.Y>` 版本 | 定位包名和版本要求 |
| `FetchContent_Declare` | `NAME`、`GIT_REPOSITORY`/`URL`、`GIT_TAG`/`URL_HASH` | 定位仓库地址和版本 |
| `ExternalProject_Add` | `NAME`、`URL`/`GIT_REPOSITORY`、`CONFIGURE_COMMAND`、`BUILD_COMMAND` | 同上 + 检查构建命令架构标志 |

---

## 识别预编译二进制依赖

CMake 项目中预编译二进制通常通过以下方式引入，在 ARM 上很容易直接报 `File in wrong format`：

```bash
# 1. 硬编码 .so/.a 路径
grep -rn 'target_link_libraries.*\.\(so\|a\)\b' \
  <项目根目录>/CMakeLists.txt <项目根目录>/cmake/ \
  --include="*.cmake" --include="CMakeLists.txt"

# 2. IMPORTED 库目标
grep -rn "add_library.*IMPORTED\|set_target_properties.*IMPORTED_LOCATION" \
  <项目根目录>/CMakeLists.txt <项目根目录>/cmake/

# 3. find_library 返回的硬编码路径变量是否被强制覆盖
grep -rn "set(.*_LIBRARY .*\.\(so\|a\))" <项目根目录>/CMakeLists.txt <项目根目录>/cmake/
```

> 检测到的预编译二进制由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 4 统一交给 [compat-and-binary-detect.md](compat-and-binary-detect.md) Part B 判断架构与溯源源码。

---

## 编译标志检查（ABI=0 工具链与 x86 专属标志）

```bash
# x86 专属编译标志
grep -rn "msse\|mavx\|mf16c\|mpopcnt\|march=.*86\|march=core\|march=native" \
  <项目根目录>/CMakeLists.txt <项目根目录>/cmake/ \
  --include="*.cmake" --include="CMakeLists.txt"

# C++ ABI 标志（_GLIBCXX_USE_CXX11_ABI=0 强绑老 ABI，跨 GCC 版本有兼容风险）
grep -rn "_GLIBCXX_USE_CXX11_ABI" \
  <项目根目录>/CMakeLists.txt <项目根目录>/cmake/

# 工具链文件硬编码 x86 编译器
find <项目根目录> -name "*.toolchain.cmake" -o -name "toolchain*.cmake" \
  | xargs grep -l "x86_64\|gcc-7" 2>/dev/null
```

**ABI=0 工具链注意**：使用 `_GLIBCXX_USE_CXX11_ABI=0` 编译的 ARM 库**必须**与项目自身保持一致，否则会出现 `undefined reference to std::string` 等链接错误。在依赖分析报告中需将该项作为**全局编译约束**单独提示。

---

## CMake 源码溯源

> 源码溯源由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 4 统一调用 [compat-and-binary-detect.md](compat-and-binary-detect.md) Part B 执行。CMake 项目在 B.3「第一优先级」会于 `$REPO_PATH/CMakeLists.txt` 与 `$REPO_PATH/cmake/*.cmake` 中搜索依赖名，自动找到 `FetchContent_Declare`/`ExternalProject_Add` 的源码地址。

---

## CMake 子模块依赖分析

> 子模块递归由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 5 统一处理——子模块被识别为 CMake 项目时会重新加载本文件执行扫描，无需在此重复定义。

---

## CMake 注意事项

| 注意事项 | 说明 | 建议操作 |
|---------|------|---------|
| **子模块自动签出** | `cmake -B build` 会重新拉取/重置子模块，覆盖手动切换的 ARM 分支 | 改 `AUTO_SUBMODULE` 开关 + ARM 传 `-DAUTO_SUBMODULE=OFF`；阶段 5 前逐个子模块 `git checkout` 钉到用户确认的 ARM 分支（见本文档「子模块自动签出检查」第 1/2 步） |
| **`find_package` 缓存** | `CMakeCache.txt` 缓存了 x86 路径，切到 ARM 后不会重新查找 | 切换前 `rm -rf build/` 完全清理后再重新 `cmake -B build` |
| **预编译 IMPORTED 库** | `IMPORTED_LOCATION` 直接指向 x86 二进制 | 改为按 `CMAKE_SYSTEM_PROCESSOR` 选择 x86/ARM 路径分支 |
| **`pkg-config` 路径** | x86 系统的 `.pc` 文件可能写死 `/usr/lib64`，ARM 上路径不同 | 在 ARM 环境中重新生成 / 用 `CMAKE_PREFIX_PATH` 覆盖 |
| **`CMAKE_HOST_SYSTEM_PROCESSOR`** | 仅反映构建主机架构，不反映目标架构 | 跨架构时使用 `CMAKE_SYSTEM_PROCESSOR`，在工具链文件中显式声明 |
| **`add_compile_options` 全局生效** | 写在顶层的 `-mavx` 会污染所有子目标 | 改为对单个目标 `target_compile_options(... PRIVATE $<$<BOOL:${X86_64}>:-mavx>)` |
| **`ExternalProject_Add` 构建命令硬编码** | `CONFIGURE_COMMAND`/`BUILD_COMMAND` 中可能写死 `--host=x86_64-linux-gnu` | 改为透传 `${CMAKE_HOST_SYSTEM_PROCESSOR}` 或参数化 |

---

# Blade 构建系统依赖分析

> **按需加载**：仅当 [repo-analysis-flow.md](repo-analysis-flow.md) Step 1 识别到构建系统为 **Blade** 时加载本文件，否则跳过。

---

## 扫描 BLADE_ROOT 全局配置

```bash
cat <项目根目录>/BLADE_ROOT
```

BLADE_ROOT 中声明的全局依赖项：

| 配置字段 | 含义 | ARM 迁移关注点 |
|----------|------|---------------|
| `cc_config.extra_incs` | 全局头文件搜索路径 | 检查路径是否指向目标架构版本的目录 |
| `cc_config.cxxflags` | 全局编译标志 | 检查是否含 x86 专属标志（如 `-mavx`），是否缺少 ARM 必需标志（如 `-fsigned-char`） |
| 代码生成工具路径（protoc/thrift 等） | 代码生成工具二进制路径 | 检查是否指向目标架构版本 |
| 代码生成工具头文件路径 | 生成代码依赖的头文件路径 | 检查是否指向目标架构版本 |

---

## 扫描 thirdparty 目录下的 BUILD 文件

```bash
# 列出 thirdparty 下所有组件
ls <项目根目录>/thirdparty/

# 每个组件的 BUILD 文件决定了依赖来源
cat <项目根目录>/thirdparty/<组件名>/BUILD
```

Blade thirdparty 依赖的三种模式：

| 模式 | BUILD 特征 | 依赖来源 | ARM 适配方式 |
|------|-----------|---------|-------------|
| **聚合代理** | `deps = ['//thirdparty/X/X_arm:lib']` | 指向子目录 | 修改 BUILD 中 deps 指向 `_arm` 版本 |
| **预编译库** | `prebuilt = 1` + `srcs`/自动查找 | `lib64_release/*.so`/`*.a` | 需存在 ARM 版预编译文件（同名目录含 `_arm` 后缀） |
| **源码编译** | `srcs = ['*.cc', '*.cpp']` | 仓库内源码 | 检查源码中是否含 x86 专属指令（SSE/AVX/内联汇编） |

### ARM 库查找路径

当 `thirdparty/<组件名>/` 下不存在 `*_arm` 子目录时，需检查统一管理目录 `thirdparty_arm/`：

```bash
# 优先在 thirdparty 下查找 ARM 子目录
find <项目根目录>/thirdparty -maxdepth 2 -type d -name "*_arm*"

# 若未找到，则在 thirdparty_arm 下查找
find <项目根目录>/thirdparty_arm -maxdepth 2 -type d -name "*_arm*"
```

> `thirdparty_arm/` 是 ARM 库的统一管理目录，结构与 `thirdparty/` 一致（`thirdparty_arm/<组件名>/<ARM子目录>`）。
> 构建前需将所需库从 `thirdparty_arm/` 回迁到 `thirdparty/` 对应位置，详见 [kunpeng-confirmed-write.md](kunpeng-confirmed-write.md)「Blade 项目：thirdparty_arm 回迁」。

---

## 识别 BUILD/BUILD.x86 双架构分离

```bash
# 检测 thirdparty 下的 BUILD.x86 文件（说明项目已做 x86/ARM 分离）
find <项目根目录>/thirdparty -name "BUILD.x86" -type f | sort

# 对比 BUILD 与 BUILD.x86 的差异
diff <项目根目录>/thirdparty/<组件名>/BUILD \
     <项目根目录>/thirdparty/<组件名>/BUILD.x86
```

> Blade 项目常见的 ARM 适配策略：当前 `BUILD` 为 ARM 版（指向 `*_arm` 子目录），
> `BUILD.x86` 为 x86 版（指向原 x86 子目录）。切换架构时替换 BUILD 文件即可。

---

## 识别系统库依赖

```bash
# Blade 中 # 前缀表示系统库
grep -rn '"#.*"' <项目根目录>/thirdparty/*/BUILD <项目根目录>/*/BUILD \
  2>/dev/null | grep -o '"#[^"]*"' | sort -u
```

系统库（`#pthread`, `#dl`, `#ssl`, `#crypto` 等）由系统包管理器提供，
在 ARM Linux 上通常直接可用，无需额外适配。

---

## Blade thirdparty 组件智能分组

> 分析时将 so 文件按**组件名**聚合，而非逐个列出 so 文件名。例如 `libxxx1.so`, `libxxx2.so` → 统一归为 **boost** 组件。

当 thirdparty 下组件较多时，按以下维度分组输出报告：

| 分组 | 判定条件 | 报告展示方式 |
|------|---------|-------------|
| **预编译库（有 ARM 版）** | 存在 `*_arm` 子目录且 BUILD 已指向 | 列表展示组件名，省略 so 文件名 |
| **预编译库（无 ARM 版）** | 仅有 x86 so/a，无 `_arm` 子目录 | 逐个展示组件名 + 缺失说明 |
| **源码编译库** | BUILD 中有 `srcs` 字段 | 列出组件名，标注需检查 x86 专属指令 |
| **纯头文件库** | BUILD 中仅有 `export_incs` | 列表展示组件名，标注无需适配 |

---

## Blade 项目私有依赖补充

对 Blade 项目，[compat-and-binary-detect.md](compat-and-binary-detect.md) Part A 识别私有依赖时还需检查 thirdparty 目录下预编译包（`prebuilt = 1`）的来源。若 thirdparty 中某组件只有 x86 二进制（无 `*_arm` 子目录），且该组件来自内部对象存储（如 `*.internal-storage.example.com` 等内部域名），则标记为私有预编译依赖，需获取 ARM 版本。

## 预编译二进制识别与溯源

> 架构判断与源码溯源由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 4 统一调用 [compat-and-binary-detect.md](compat-and-binary-detect.md) Part B 执行。Blade 项目的 `lib64_release/*.so`/`*.a` 会被 B.1 扫描到、B.2 判架构，若为 x86 进入 B.3 溯源（第一优先级会检查 `BUILD` 文件的源码来源字段）。

---

## Blade 注意事项

- thirdparty 目录下组件较多时，按组件名聚合输出（而非逐个 so 文件名）
- 关注 `prebuilt = 1` 标记的预编译库是否含 `*_arm` 版本
- BLADE_ROOT 中 `extra_incs`/`cxxflags` 是否指向 ARM 版路径
- 检查 BUILD/BUILD.x86 双架构分离是否完整（每个有 BUILD.x86 的组件都应有 ARM 版 BUILD）
- ARM 库查找顺序：先查 `thirdparty/<组件名>/` 下是否有 `*_arm` 子目录，若无则查 `thirdparty_arm/<组件名>/`；找到后需回迁到 `thirdparty/` 下构建系统才能识别
- 若项目目录下同时存在 `SConstruct` 文件，需额外检查其中的 x86 编译标志（`-msse`/`-mavx`/`-m64`）；参考本文 [SCons 构建系统依赖分析](#scons-构建系统依赖分析) 中「SCons 关键检查项」一节

---

# Bazel 构建系统依赖分析

> **按需加载**：仅当 [repo-analysis-flow.md](repo-analysis-flow.md) Step 1 识别到构建系统为 **Bazel** 时加载本文件，否则跳过。

---

## 解析 WORKSPACE 依赖声明

```bash
# 读取 WORKSPACE 文件，提取所有外部依赖声明
cat <项目根目录>/WORKSPACE
```

Bazel 通过 `WORKSPACE` 文件声明外部依赖，三种规则对应不同来源：

| 规则 | 依赖来源 | ARM 迁移关注点 |
|------|---------|---------------|
| `git_repository` / `new_git_repository` | 远端 Git 仓库（有源码） | 检查是否有 ARM 分支或 ARM 相关提交历史 |
| `http_archive` | HTTP 下载（可能是预编译包） | 需检查下载的包是否为预编译二进制（见本文件「识别 `http_archive` 预编译包」一节） |
| `new_local_repository` | 本地系统路径 | 检查路径在 ARM 系统上是否存在 |

**各规则需提取的关键字段**：

| 规则 | 关键字段 | 说明 |
|------|---------|------|
| `git_repository` | `name`, `remote`, `tag`/`commit` | 定位依赖名称和版本 |
| `http_archive` | `name`, `url`, `sha256` | 定位下载地址和完整性校验 |
| `new_local_repository` | `name`, `path` | 定位本地路径 |

---

## 识别 `http_archive` 预编译包

`http_archive` 下载的包可能是**源码包**也可能是**预编译二进制包**，需检查对应的 `.BUILD`（或 `BUILD`）文件来判断：

| `.BUILD` 文件特征 | 判定结果 | ARM 迁移影响 |
|------------------|---------|-------------|
| `srcs = glob(["lib/**/*.so*"])` 或 `glob(["lib64/lib*.a*"])` | **预编译库** | 需获取 ARM 版本或从源码重新编译 |
| `filegroup` 指向 `bin/` 目录 | **预编译可执行文件** | 同上 |
| 无 `.cc`/`.cpp` srcs，仅有 `.h` | **纯头文件库** | 通常无需适配，检查是否有平台宏 |
| 有 `.cc`/`.cpp` srcs | **源码编译** | 可直接在 ARM 上编译，检查是否有 x86 专有代码 |

**检查命令**：

```bash
# 查看 http_archive 对应的 BUILD 文件内容
# 方式 1：若 BUILD 文件内联在 WORKSPACE 中
grep -A20 'name = "<依赖名>"' <项目根目录>/WORKSPACE

# 方式 2：若使用独立 BUILD 文件（通常在 third_party/ 或 .bazel 版本管理目录下）
find <项目根目录> -name "<依赖名>.BUILD" -o -name "BUILD.bazel" | xargs grep -l "<依赖名>"
```

---

## Bazel 源码溯源

> 源码溯源由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 4 统一调用 [compat-and-binary-detect.md](compat-and-binary-detect.md) Part B 执行。Bazel 项目在 B.3「第一优先级」会于 `$REPO_PATH/WORKSPACE` 中搜索依赖名，自动找到 `git_repository`/`http_archive` 的源码地址。

---

## Bazel 子模块依赖分析

> 子模块递归由 [repo-analysis-flow.md](repo-analysis-flow.md) Step 5 统一处理——子模块被识别为 Bazel 项目时会重新加载本文件执行扫描，无需在此重复定义。

---

## Bazel 注意事项

| 注意事项 | 说明 | 建议操作 |
|---------|------|---------|
| **重复 `http_archive` 名称** | 同一 `name` 多次声明时 Bazel 使用第一个 | 检查 WORKSPACE 中是否有重复声明 |
| **`git_repository` ARM 分支** | 私有 Git 仓库可能存在 ARM 适配分支 | 执行 `git ls-remote --heads <remote>` 检查远端分支 |
| **`http_archive` 预编译包架构** | 下载的包可能仅含 x86 二进制 | 用 `file` 命令验证架构，或检查 URL 中是否含 `x86`/`amd64` 等关键字 |
| **私有 `git_repository`** | SSH 形式指向内部 Git 域名的依赖 | 标记为需 ARM 兼容性检查，检查提交历史中的 ARM 关键字 |
| **`strip_prefix` 与目录结构** | `http_archive` 的 `strip_prefix` 影响包解压后路径 | 确认 ARM 版本的包目录结构一致 |
| **`build_file` 指向** | `http_archive` 通过 `build_file` 指定外部 BUILD 文件 | 切换 ARM 版本时需同步更新 BUILD 文件中的 srcs 路径 |

---

# SCons 构建系统依赖分析

> **按需加载**：主要用于**纯 SCons 项目**（有 `SConstruct` 且无 `BLADE_ROOT`）时加载本文件。若项目同时有 `BLADE_ROOT`（即使用 Blade），以 Blade 分析为主，不加载本文件；但仍可参考本文件「SCons 关键检查项」一节检查 `SConstruct` 中的 x86 编译标志。

---

## 读取 SCons 构建文件

```bash
# 读取 SConstruct 主文件
cat <项目根目录>/SConstruct

# 读取所有 SConscript 子文件
find <项目根目录> -name "SConscript" -type f | sort
```

---

## SCons 依赖声明方式

| SCons 语法 | 含义 | ARM 迁移关注点 |
|-----------|------|---------------|
| `env.Program('foo', ['foo.cc'], LIBS=['bar'])` | 链接系统库 | 检查系统库在 ARM 上是否可用 |
| `env.SharedLibrary('bar', ['bar.cc'])` | 构建共享库 | 检查源码中 x86 专属指令 |
| `env.StaticLibrary('baz', ['baz.cc'])` | 构建静态库 | 同上 |
| `env.Append(CXXFLAGS=['-msse4'])` | 编译标志 | x86 专属标志，ARM 需条件化或移除 |
| `env.Append(LIBPATH=['/usr/lib64'])` | 库搜索路径 | 检查路径在 ARM 上是否存在（ARM 通常为 `/usr/lib64` 或 `/usr/lib/aarch64-linux-gnu`） |
| `env.ParseConfig('pkg-config --cflags --libs foo')` | 通过 pkg-config 获取依赖 | 在 ARM 上重新执行 pkg-config 获取正确的 ARM 路径 |

---

## SCons 关键检查项

```bash
# 检查 SConstruct 中硬编码的 x86 编译标志
grep -rn "-msse\|-mavx\|-mf16c\|-mpopcnt\|-m64" <项目根目录>/SConstruct <项目根目录>/*/SConscript

# 检查硬编码的库路径
grep -rn "/usr/lib64\|/lib64\|/usr/lib/x86_64" <项目根目录>/SConstruct <项目根目录>/*/SConscript

# 检查 SCons 版本
scons --version
```

---

## SCons 版本兼容性

| SCons 版本 | Python 支持 | ARM 关注点 |
|-----------|------------|------------|
| SCons 2.x | 仅 Python 2 | 不支持 Python 3，无法在现代 ARM 系统上运行 |
| SCons 3.x | Python 2 + 3 | 基本可用，但缺少 aarch64 优化支持 |
| SCons 4.x+ | 仅 Python 3 | 推荐，原生支持 aarch64 架构检测 |

> 若项目自带 SCons（如 `builder/scons/bin/scons`），注意其版本可能仅支持 Python 2（如 SCons 2.3.0）。
> 在 ARM 环境上若系统 Python 为 3.x，需安装系统级 SCons 4.x 或通过 Blade 间接调用。

---

## SCons 注意事项

- Blade 内部集成 SCons 作为构建引擎，纯 SCons 项目（无 BLADE_ROOT）需单独分析
- 关注 `env.Append(CXXFLAGS=['-m64'])` 等 x86 编译标志和硬编码库路径
- SCons 2.x 不支持 Python 3，需使用 SCons 4.x+ 或 Blade 自带的 SCons（通过 `builder/scons/bin/scons` 调用，但注意版本兼容性）
