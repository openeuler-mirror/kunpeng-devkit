# 版本兼容性案例库（V 系列）— 脱敏样例

> 仅保留 V-01 一条案例作为格式参考。

| ID | 起始行 | 摘要 |
|----|--------|------|
| V-01 | 7 | 依赖库版本不兼容导致头文件冲突 |
| V-02 | 60 | CXX ABI 不兼容导致链接失败（全局 -D_GLIBCXX_USE_CXX11_ABI=0） |

---

### V-01：依赖库版本不兼容导致头文件冲突

**错误现象：**
```
error: '<类名>' has no member named '<方法名>'
fatal error: <头文件路径>: No such file or directory
```

**根因分析：**
x86 预编译依赖库版本与 ARM 环境自带的版本不兼容。`_GLIBCXX_USE_CXX11_ABI` 宏设置不同导致 C++ 标准库 ABI 不兼容，预编译 .so 在 ARM 上无法正确链接。ARM 需要源码编译匹配版本并设置 `ABI=0`。

**修复方法：**

修改前：
```python
# WORKSPACE 中使用 x86 预编译依赖
http_archive(
    name = "<dep>_x86",
    urls = ["https://<仓库地址>/<dep>-x86-<版本>.tar.gz"],
)
```

修改后：
```python
# WORKSPACE 中添加 ARM 源码编译依赖
http_archive(
    name = "<dep>_aarch64",
    urls = ["https://<源码地址>/<dep>/archive/v<版本>.tar.gz"],
    strip_prefix = "<dep>-<版本>",
)

# BUILD 中条件选择
<dep>_dep = select({
    "//<platforms>:is_aarch64": "@<dep>_aarch64//:<target>",
    "//<platforms>:is_x86_64": "@<dep>_x86//:<target>",
    "//conditions:default": "@<dep>_x86//:<target>",
})
```

**适用场景：**
使用 Bazel 构建的 C/C++ 项目，x86 使用预编译依赖、ARM 需源码编译不同版本

**验证方式：**
```bash
bazel build //... --config=linux_aarch64
```

**扫描规则：**
（V 系列不填写扫描规则）

---

### V-02：CXX ABI 不兼容导致链接失败

**错误现象：**
```
undefined reference to 'std::__cxx11::basic_string<...>'
undefined reference to 'std::string'  (链接预编译 .so 时)
/usr/bin/ld: cannot find -l<dep>
# 或运行时：
symbol lookup error: ... undefined symbol: _ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE...
```

> **判定特征**：链接阶段报 `std::__cxx11::*` 或 `basic_string` 相关的 undefined reference，且涉及多个预编译依赖库；通常编译期通过、链接期或运行期失败。

**根因分析：**
GCC 5 引入了新的 C++11 ABI（`_GLIBCXX_USE_CXX11_ABI=1`），旧 ABI 为 `0`。x86 预编译依赖库若使用旧 ABI（=0）编译，而 ARM 环境的系统库 / 编译器默认使用新 ABI（=1），两者混合链接时 `std::string`、`std::list` 等的符号 mangling 不一致，导致链接失败或运行时符号缺失。

> **关键判断**：当链接错误集中在 `std::__cxx11::*`、`basic_string`、`_ZNSt7__cxx11*` 等符号，且项目依赖多个预编译 `.so`/`.a`，应优先怀疑 CXX ABI 不一致。

**修复方法：**

> ⚠️ **全局统一原则**：CXX ABI 必须在**主项目和所有依赖库**上保持一致。若任一预编译库无法更换为源码编译，则必须将全部目标（含主项目）统一设为 `ABI=0` 后重新编译，不可只改部分。

**第1步：确认依赖库的 ABI 取值**

```bash
# 检查预编译 .so 使用的 ABI（1=新ABI，0=旧ABI）
nm -D --defined-only <dep>.so | grep -q "__cxx11" && echo "ABI=1" || echo "ABI=0"

# 批量检查所有依赖库
find <依赖目录> -name "*.so" -exec sh -c \
  'echo -n "$1: "; nm -D --defined-only "$1" 2>/dev/null | grep -q "__cxx11" && echo "ABI=1(新)" || echo "ABI=0(旧)"' _ {} \;
```

**第2步：统一全局编译选项为 `-D_GLIBCXX_USE_CXX11_ABI=0`**

按构建系统在**全局配置**中添加，确保主项目和所有源码编译的依赖库均生效：

#### Bazel 项目

```python
# .bazelrc —— 全局段（对所有架构生效），或仅 aarch64 段
build --copt=-D_GLIBCXX_USE_CXX11_ABI=0
build --cxxopt=-D_GLIBCXX_USE_CXX11_ABI=0
# 若仅需 ARM 段生效：
# build:linux_aarch64 --copt=-D_GLIBCXX_USE_CXX11_ABI=0
# build:linux_aarch64 --cxxopt=-D_GLIBCXX_USE_CXX11_ABI=0
```

#### CMake 项目

```cmake
# CMakeLists.txt 顶部（全局生效）
add_compile_options(-D_GLIBCXX_USE_CXX11_ABI=0)
# 或仅 ARM 段：
# if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
#     add_compile_options(-D_GLIBCXX_USE_CXX11_ABI=0)
# endif()
```

#### Make 项目

```makefile
# Makefile
CXXFLAGS += -D_GLIBCXX_USE_CXX11_ABI=0
```

**第3步：清理并重新编译所有依赖库**

> 关键：仅改主项目不够，所有源码编译的依赖库必须带上相同的 ABI 宏重新编译，否则链接仍会失败。

```bash
# 清理所有已编译产物（Bazel）
bazel clean --expunge

# 清理所有已编译产物（CMake）
rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR

# 清理所有已编译产物（Make）
make clean

# 重新编译（编译命令会自动带上全局 -D_GLIBCXX_USE_CXX11_ABI=0）
# 回到 sourcecode-build-verify.md E.2 主循环重新执行编译
```

**修改前（不一致状态）：**
```python
# 主项目用新 ABI（默认=1），依赖库用旧 ABI（=0）→ 链接失败
# .bazelrc 无 ABI 设置
```

**修改后（统一旧 ABI）：**
```python
# .bazelrc
build --copt=-D_GLIBCXX_USE_CXX11_ABI=0
build --cxxopt=-D_GLIBCXX_USE_CXX11_ABI=0
```

**适用场景：**
- x86 预编译依赖库使用旧 ABI（`_GLIBCXX_USE_CXX11_ABI=0`），ARM 上混用新旧 ABI 导致链接/运行失败
- 主项目依赖多个预编译 `.so`/`.a`，无法全部更换为源码编译
- 项目需要同时链接新旧 ABI 编译的库（必须统一为其中一种，通常统一为 0 兼容旧库）

> **反向情况**：若所有依赖库均为新 ABI（=1）而主项目误设为 0，同样会失败。此时将主项目改为不设置该宏（默认=1）或显式设 `=1`。

**验证方式：**
```bash
# 1. 重新编译成功后，检查主产物符号 ABI 一致
nm -D <主产物>.so | grep "__cxx11" | head -3   # 应与依赖库的 ABI 一致

# 2. 编译验证
bazel build //... --config=linux_aarch64   # 或对应构建系统命令

# 3. 运行时验证（若有运行测试）
ldd <可执行文件>  # 确认无 undefined symbol
```

**扫描规则：**
（V 系列不填写扫描规则）

---
