# CMake 构建系统依赖分析

> ⚠️ **按需加载**：仅当 [analyze-one-repo.md](analyze-one-repo.md) Step 1 识别到构建系统为 **CMake** 时加载本文件，否则跳过。

---

## 子模块自动签出检查（加载本文件后第一步）

CMake 项目常通过 `execute_process(... git submodule update ...)` 或 `find_package(Git)` 配合自定义命令在 `cmake` 阶段自动拉取/重置子模块。这种逻辑会在切换 ARM 分支后**重新覆盖回原默认分支**，是 CMake 项目 ARM 迁移的高频踩坑点。

```bash
# 检查 CMakeLists 中是否存在 git submodule 自动签出
grep -rn "git submodule\|GIT_SUBMODULE\|FetchContent_MakeAvailable" \
  <项目根目录>/CMakeLists.txt <项目根目录>/cmake/ 2>/dev/null

# 检查是否有 cmake 阶段调用 git reset / git checkout
grep -rn "execute_process.*git" <项目根目录>/CMakeLists.txt <项目根目录>/cmake/ 2>/dev/null
```

**若存在自动签出逻辑**：

> 🚨 **CMake 项目 ARM 迁移最高频踩坑点 —— 必须在依赖分析报告头部以醒目方式提示用户**
>
> - 在依赖分析报告**最前面**单独成节标注 ⚠️ 警告，不要混在普通依赖列表里
> - 明确告知用户：**阶段 C 末尾切换子模块分支之前必须先注释这段自动签出逻辑**，否则后续 `cmake -B build` 会以"修复未初始化子模块"的名义把已经手动切到 ARM 分支的子模块**默默重置回默认分支**，而且**不会报错**
> - 该问题症状极具迷惑性：表面上 `git submodule status` 显示分支正确，但每次重新生成 build 目录后会回退；编译错误也会从"x86 残留"摇摆到"找不到 ARM 符号"反复横跳，极易误判为依赖问题
> - 在 `$WORK_DIR/reports/user_decisions.txt` 中**必须**留痕记录该项是否已注释，阶段 C 末尾切换前再次确认
>
> 建议的注释方式不是直接删除，而是改为可控开关（保留 x86 路径）：
>
> ```cmake
> option(AUTO_SUBMODULE "Auto checkout submodules" ON)
> if(AUTO_SUBMODULE)
>     execute_process(COMMAND git submodule update --init --recursive ...)
> endif()
> ```
>
> 然后在 ARM 构建命令中显式传 `-DAUTO_SUBMODULE=OFF`。

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
| `target_link_libraries(... /path/to/libxxx.a)` | 硬编码二进制路径 | ⚠️ 大概率是 x86 预编译，需找 ARM 版替代 |
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

> 检测到的预编译二进制由 [analyze-one-repo.md](analyze-one-repo.md) Step 4 统一交给 [common-binary-detect.md](common-binary-detect.md) 判断架构与溯源源码。

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

> 预编译二进制的源码溯源逻辑已统一移入 [common-binary-detect.md](common-binary-detect.md)，此处不再重复。
> 由 [analyze-one-repo.md](analyze-one-repo.md) Step 4 统一调用 `common-binary-detect.md` 执行。
>
> 对于 CMake 项目，`common-binary-detect.md` Section 3「第一优先级」会在 `$REPO_PATH/CMakeLists.txt` 与 `$REPO_PATH/cmake/*.cmake` 中搜索依赖名，自动找到 `FetchContent_Declare`/`ExternalProject_Add` 中的源码地址。

---

## CMake 子模块依赖分析

> 子模块递归逻辑已统一由 [analyze-one-repo.md](analyze-one-repo.md) Step 5 处理。
> 当子模块被识别为 CMake 项目时，[analyze-one-repo.md](analyze-one-repo.md) 会重新加载本文件对该子模块执行依赖扫描，无需在此重复定义。

---

## CMake 注意事项

| 注意事项 | 说明 | 建议操作 |
|---------|------|---------|
| **子模块自动签出** | `cmake -B build` 会重新拉取/重置子模块，覆盖手动切换的 ARM 分支 | 阶段 C 末尾切换分支前先注释相关 `execute_process(... git submodule ...)` |
| **`find_package` 缓存** | `CMakeCache.txt` 缓存了 x86 路径，切到 ARM 后不会重新查找 | 切换前 `rm -rf build/` 完全清理后再重新 `cmake -B build` |
| **预编译 IMPORTED 库** | `IMPORTED_LOCATION` 直接指向 x86 二进制 | 改为按 `CMAKE_SYSTEM_PROCESSOR` 选择 x86/ARM 路径分支 |
| **`pkg-config` 路径** | x86 系统的 `.pc` 文件可能写死 `/usr/lib64`，ARM 上路径不同 | 在 ARM 环境中重新生成 / 用 `CMAKE_PREFIX_PATH` 覆盖 |
| **`CMAKE_HOST_SYSTEM_PROCESSOR`** | 仅反映构建主机架构，不反映目标架构 | 跨架构时使用 `CMAKE_SYSTEM_PROCESSOR`，在工具链文件中显式声明 |
| **`add_compile_options` 全局生效** | 写在顶层的 `-mavx` 会污染所有子目标 | 改为对单个目标 `target_compile_options(... PRIVATE $<$<BOOL:${X86_64}>:-mavx>)` |
| **`ExternalProject_Add` 构建命令硬编码** | `CONFIGURE_COMMAND`/`BUILD_COMMAND` 中可能写死 `--host=x86_64-linux-gnu` | 改为透传 `${CMAKE_HOST_SYSTEM_PROCESSOR}` 或参数化 |
