# 按构建系统添加全局编译选项案例

> **做什么**：在 Bazel / CMake / Make 三类构建系统中为 aarch64 配置段追加或修改全局编译选项（avx2ki 链接、移除 x86 AVX 选项、基础兼容选项），保持双架构可编译。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | `AVX_STRATEGY` | 阶段 2 用户决策（`ksl` / `neon` / `disable`） |
| 输入 | DevKit 报告 | 是否含 `INTRINSICS_LIBRARY` / `INTRINSICS` Rule 条目 |
| 输入 | 构建系统类型 | Bazel（`.bazelrc` + `BUILD`）/ CMake（`CMakeLists.txt`）/ Make（`Makefile`） |
| 输出 | 构建系统文件修改 | aarch64 配置段追加 avx2ki 链接、移除 x86 AVX 选项、添加基础兼容选项 |

## 全局编译选项对照表

| 选项 | 级别 | 触发条件 | 用途 | 不处理的失败后果 |
|------|------|---------|------|------------------|
| `-I /usr/local/ksl/include/ -L /usr/local/ksl/lib/ -lavx2ki -lm` | **Rule** | `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目 + `AVX_STRATEGY=ksl` | 链接 avx2ki.so 动态库 | 无法使用 avx2ki.h 中的 intrinsics 兼容层，编译失败 |
| 引入 `<arm_neon.h>`（NEON 开源方案） | **Rule** | `INTRINSICS_LIBRARY`/`INTRINSICS` Rule 条目 + `AVX_STRATEGY=neon` | 使用 ARM 原生 NEON intrinsics | 无法编译 ARM SIMD 代码 |
| 移除 `-mavx` / `-mavx2` / `-mavx512f` / `-msse4.1` / `-msse4.2` / `-msse2` | **Rule** | 所有场景 | 鲲鹏平台不支持 AVX/SSE 指令集 | 编译报错，无法在鲲鹏平台构建 |
| `-fsigned-char` | Suggestion | 所有场景 | 强制 `char` 类型为有符号 | x86 默认有符号，aarch64 默认无符号，导致字符比较结果不同 |
| `-march=armv8.5-a` | Suggestion | 所有场景 | 指定目标鲲鹏架构版本 | 未指定时可能无法利用鲲鹏处理器指令集 |
| `-Werror=conversion` | Suggestion | 所有场景 | 将隐式类型转换提升为错误 | 隐式类型转换可能导致运行时行为不一致 |

> **`-march` 取值规则**：默认使用 `armv8.5-a`；若编译器版本过旧或目标硬件不支持 armv8.5-a，降级为 `armv8-a`。可用以下命令检测：
>
> ```bash
> echo | gcc -march=armv8.5-a -E -dM - 2>/dev/null | grep -q "__ARM_ARCH" \
>   && echo "支持 armv8.5-a" || echo "不支持，请降级为 armv8-a"
> ```

## 修改案例

### 案例 1：Bazel 项目

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

### 案例 2：CMake 项目

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

### 案例 3：Make 项目

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
endif()
```

> **双架构兼容说明**：上述选项仅在鲲鹏构建时生效（通过构建系统的架构判断或配置段隔离），不影响 x86 编译。

## 执行流程

1. **识别构建系统类型**：项目根目录扫描 `BUILD` / `WORKSPACE`（Bazel）、`CMakeLists.txt`（CMake）、`Makefile`（Make）
2. **按 `AVX_STRATEGY` 决定 avx2ki 链接选项**：
   - `ksl`：添加 `-I/usr/local/ksl/include/` 与 `-L/usr/local/ksl/lib/ -lavx2ki -lm`
   - `neon`：**不添加** avx2ki 链接（NEON 头文件随工具链自带）
   - `disable`：**不添加** avx2ki 链接
3. **移除 x86 AVX/SSE 选项**（Rule 级别，必须）：在 aarch64 配置段中过滤掉 `-mavx*` / `-mavx512*` / `-msse*`
4. **添加基础兼容选项**（Suggestion）：`-fsigned-char` / `-march=armv8.5-a`（或 `armv8-a`）/ `-Werror=conversion`
5. **验证**：双架构编译通过（参考 [source-migration-scan.md](source-migration-scan.md) 4.3 节）

## 失败处置

| 现象 | 处置 |
|------|------|
| 链接报 `cannot find -lavx2ki` | 确认 4.2 阶段已成功安装 KSL；检查 `LD_LIBRARY_PATH` 是否包含 `/usr/local/ksl/lib/` |
| `march=armv8.5-a` 编译器报错 | 降级为 `-march=armv8-a`；GCC ≥ 9 支持 armv8.5-a |
| x86 构建意外包含了 aarch64 段 | 检查 `.bazelrc` 是否用 `--config=linux_aarch64` 隔离；CMake 用 `if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")` 隔离；Make 用 `ifeq ($(shell uname -m),aarch64)` 隔离 |
| 字符比较结果与 x86 不一致 | 确认已添加 `-fsigned-char`；或在源码中显式使用 `signed char` |
| 隐式类型转换编译失败 | 确认已添加 `-Werror=conversion`；按编译错误逐个修正 |
