# Bazel x86/ARM 双架构切换模式参考

本文档从多个迁移项目中提炼的 Bazel x86→ARM 双架构切换通用模式，供新项目迁移时直接参考复用。

---

## 5 层架构全景

```
┌──────────────────────────────────────────────────────────┐
│  层5: 源码条件编译  #if defined(__aarch64__)             │
│       头文件路径 / SIMD 兼容                               │
├──────────────────────────────────────────────────────────┤
│  层4: WORKSPACE 切换  WORKSPACE_x86 / WORKSPACE_arm      │
│       依赖版本差异 / 预编译库 vs 源码编译                   │
├──────────────────────────────────────────────────────────┤
│  层3: BUILD select()  5 种模式                           │
│       A补依赖/B独有链接/C宏切换/D SIMD兼容层/E COPTS拆分 │
├──────────────────────────────────────────────────────────┤
│  层2: .bazelrc 配置  linux_x86 / linux_aarch64 config     │
│       编译标志 / ABI / 规避 / 源码编译开关                  │
├──────────────────────────────────────────────────────────┤
│  层1: platforms/BUILD  基础定义                            │
│       config_setting + platform 声明                      │
└──────────────────────────────────────────────────────────┘
```

**构建命令**：
- x86: `bazel build //... --config=linux_x86`
- ARM: `bazel build //... --config=linux_aarch64`

---

## 层1：平台定义层 `platforms/BUILD`

**作用**：定义架构识别的"锚点"，供所有 `select()` 和 `.bazelrc` 引用。

**通用模板**（原样复用）：

```python
package(default_visibility = ["//visibility:public"])

# 配置设置：用于 BUILD 文件中的 select() 分支
config_setting(
    name = "is_x86_64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    visibility = ["//visibility:public"],
)

config_setting(
    name = "is_aarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
    visibility = ["//visibility:public"],
)

# 平台目标：用于 .bazelrc 中的 --platforms 和 --config
platform(
    name = "linux_x86",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
)

platform(
    name = "linux_aarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
)
```

**关键要点**：
- `config_setting` → BUILD 文件中 `select()` 用的条件键
- `platform` → `.bazelrc` 中 `--platforms=` 用的目标
- 两者必须**共用**相同的 `constraint_values`，否则 select 和 config 不联动

---

## 层2：编译配置层 `.bazelrc`

**作用**：将 x86 专属编译标志从全局抽取到 `linux_x86` config，ARM 专属标志放入 `linux_aarch64` config。

**通用模板**：

```bash
##===x86特定配置===##
build:linux_x86 --cpu=k8
build:linux_x86 --platforms=//platforms:linux_x86
build:linux_x86 --copt=-march=native
build:linux_x86 --copt=-mfma
build:linux_x86 --copt=-mavx2
build:linux_x86 --copt=-mno-avx512f
build:linux_x86 --copt=-fpic

##===aarch64特定配置===##
build:linux_aarch64 --cpu=aarch64
build:linux_aarch64 --platforms=//platforms:linux_aarch64
build:linux_aarch64 --copt=-march=armv8.2-a

# ── ABI / 符号性（通用，必加）──
build:linux_aarch64 --cxxopt="-D_GLIBCXX_USE_CXX11_ABI=0"
build:linux_aarch64 --cxxopt="-fsigned-char"
build:linux_aarch64 --copt="-fsigned-char"

# ── 编译器规避（视依赖库版本而定，高版本可删）──
build:linux_aarch64 --cxxopt="-fno-gcse"
build:linux_aarch64 --copt="-fno-gcse"
build:linux_aarch64 --cxxopt="-fno-cse-follow-jumps"
build:linux_aarch64 --cxxopt="-fno-move-loop-invariants"

# ── 源码编译开关（视依赖库是否源码编译而定）──
build:linux_aarch64 --define <feature_a>=true   # 源码编译开关（如启用 thrift 支持）
build:linux_aarch64 --define <feature_b>=true   # 源码编译开关（如启用日志库集成）
```

**关键要点**：
- 原先散落在全局的 x86 专属标志（`-march=native`、`-mfma`、`-mavx2`）必须**移出全局区**，只放在 `linux_x86` config 下
- ARM 独有的 `-fsigned-char`、`-D_GLIBCXX_USE_CXX11_ABI=0` 放在 `linux_aarch64` config 下
- `--define` 机制用于控制 BUILD 文件中 `config_setting` 的分支（如 `with_thrift=true` 触发 RPC 框架的 thrift 编译模式）
- `-fpic` 在 x86 上可用，但 ARM 上源码编译大库时可能导致 GOT 表溢出，x86 独有

**`.bazelrc` 改动前→后对照**：

修改前（全局标志，ARM 编译报错）：
```bash
build -c opt
build --copt=-Wall
build --copt=-mfma
build --cxxopt=-std=c++11
build --copt=-mno-avx512f
build --copt=-march=native
build --copt=-g
build --copt=-fpic
```

修改后（按架构分离）：
```bash
build -c opt
build --copt=-Wall
build --cxxopt=-std=c++11
build --copt=-g

##===x86特定配置===##
build:linux_x86 --cpu=k8
build:linux_x86 --platforms=//platforms:linux_x86
build:linux_x86 --copt=-march=native
build:linux_x86 --copt=-mfma
build:linux_x86 --copt=-mno-avx512f
build:linux_x86 --copt=-fpic

##===aarch64特定配置===##
build:linux_aarch64 --cpu=aarch64
build:linux_aarch64 --platforms=//platforms:linux_aarch64
build:linux_aarch64 --copt=-march=armv8.2-a
build:linux_aarch64 --cxxopt="-D_GLIBCXX_USE_CXX11_ABI=0"
build:linux_aarch64 --cxxopt="-fsigned-char"
build:linux_aarch64 --copt="-fsigned-char"
...
```

---

## 层3：依赖切换层 `BUILD` 文件中的 `select()`

**作用**：在 BUILD 文件中，根据架构选择不同的 deps/linkopts/copts/defines。

### 模式A：ARM 补充额外依赖（x86 无 / ARM 有）

**场景**：ARM 源码编译某些库后，需要额外引入内部依赖的头文件路径（x86 用预编译库时不需要）。

```python
deps = [
    "@<dep-repo>//third_party/<lib-a>:<lib-a>",
] + select({
    "//platforms:is_aarch64": [
        "@<dep-repo>//internal/<lib-b>:<lib-b>",   # 源码编译后需要额外头文件路径
        "@<dep-repo>//internal/<lib-c>:<lib-c>",   # 源码编译后需要额外头文件路径
    ],
    "//conditions:default": [],
}) + [
    "@<dep-repo>//third_party/<lib-d>:<lib-d>",
```

### 模式B：x86 独有依赖/链接（x86 有 / ARM 无）

**场景**：x86 使用预编译库链接（如 `-l<rpc-lib>`），ARM 源码编译后已通过 deps 隐式链接，不再需要这些链接选项。

```python
linkopts = [
    "-luuid",
    "-lpthread",
] + select({
    "//platforms:is_x86_64": [
        "-l<rpc-lib>",       # x86 预编译库
        "-l<config-lib>",    # x86 预编译库
        "-l<ssl-lib>",
        "-lz",
    ],
    "//platforms:is_aarch64": [],  # ARM 已通过 deps 源码编译
    "//conditions:default": [],
}) + [
    "-ldl",
    "-lrt"
]
```

### 模式C：编译选项/宏的条件切换

**场景**：ARM 平台缺少某些宏定义（如 PTHREAD_STACK_MIN），需要手动补充。

```python
copts = [
    "-fopenmp",
] + select({
    "//platforms:is_aarch64": [
        "-DPTHREAD_STACK_MIN=16384",  # ARM 上某些依赖库版本缺少此宏定义
    ],
    "//platforms:is_x86_64": [],
    "//conditions:default": [],
}),
```

### 模式D：ARM 特有链接库（avx2ki 兼容层）

**场景**：ARM 上使用 avx2ki 兼容层替代 x86 AVX2 intrinsics 时，需要额外链接 avx2ki 库。

```python
linkopts = [
    "-lgomp",
] + select({
    "//platforms:is_aarch64": [
        "-L/usr/local/ksl/lib",  # 兼容层库路径
        "-lavx2ki",              # AVX2→NEON 兼容层
    ],
    "//conditions:default": [],
}),
```

### 模式E：全局 COPTS 变量的条件拆分

**场景**：原 BUILD 文件顶部定义了全局 COPTS 变量包含 x86 专属标志。

修改前：
```python
COPTS = [
    "-mavx2",
    "-mfma",
    "-fpic",
    "-Wall",
    "-std=c++11",
]
```

修改后：
```python
COPTS = [
    "-fpic",
    "-Wall",
    "-std=c++11",
] + select({
    "//platforms:is_x86_64": [
        "-mavx2",
        "-mfma",
    ],
    "//conditions:default": [],
})
```

### select() 列表拼接语法要点

```python
# 正确：用 ] + select({...}) + [ 拼接
deps = [
    "common_dep1",
] + select({
    "//platforms:is_aarch64": ["arm_dep"],
    "//conditions:default": [],
}) + [
    "common_dep2",
]

# 错误：select() 不能放在列表字面量内部
deps = [
    "common_dep1",
    select({...}),  # 语法错误
    "common_dep2",
]
```

---

## 层4：WORKSPACE 切换层

**作用**：x86 和 ARM 的依赖仓版本不同（尤其是 RPC 框架/序列化库/日志库等），需要不同的 WORKSPACE 文件。

### 文件组织

```
原始：
  WORKSPACE          # x86 版

迁移后：
  WORKSPACE_x86      # 原 WORKSPACE 重命名
  WORKSPACE_arm      # ARM 版（新增）
  build.sh           # 构建时按架构选择 cp
```

### build.sh 通用模板

```bash
#!/bin/bash
export TEST_TMPDIR=../.bazel_tmpdir
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    cp WORKSPACE_arm WORKSPACE
    BAZEL_ARCH_CONFIG="--config=linux_aarch64"
else
    cp WORKSPACE_x86 WORKSPACE
    BAZEL_ARCH_CONFIG="--config=linux_x86"
fi
bazel build ... $BAZEL_ARCH_CONFIG --verbose_failures
```

### WORKSPACE_arm 与 WORKSPACE_x86 的典型差异

| 依赖类型 | x86 WORKSPACE | ARM WORKSPACE | 差异原因 |
|---------|-------------|-------------|---------|
| 公共依赖仓库 | tag: 稳定版 | branch: ARM 适配分支 | ARM 需要含内部依赖新版本的分支 |
| 内核/索引库 | branch: 主分支 | branch: ARM 适配分支 | ARM 需要 SIMD 兼容层适配 |
| RPC 框架 | 无（用预编译库 `-l<rpc-lib>`） | `new_git_repository` + `build_file` | ARM 因符号缺失/ABI不兼容需源码编译 |
| 序列化库 | 无（用预编译库） | `http_archive` 源码编译 | ARM 因 ABI 不兼容需源码编译 |
| 日志/参数库 | 无（用预编译库） | `http_archive` 源码编译 | 配合 RPC 框架源码编译 |
| 压缩库 | 无 | `new_local_repository` | 序列化库源码编译需要 |
| Bazel 工具库 | 无 | `http_archive` | 源码编译的第三方库 BUILD 依赖 |

### WORKSPACE_arm 新增依赖的典型写法

```python
# 序列化库源码编译（ARM 上因 ABI 不兼容无法使用预编译版）
http_archive(
    name = "<protobuf-name>",
    urls = ["https://<package-repo>/protobuf-<version>-src.tar.gz"],
    strip_prefix = "<protobuf-prefix>",
)

# RPC 框架源码编译（ARM 上因符号缺失/ABI不兼容需源码编译）
new_git_repository(
    name = "<rpc-framework>",
    remote = "ssh://git@<your-host>/<rpc-repo>.git",
    branch = "<arm-adapted-branch>",
    build_file = "//:<rpc-framework>.BUILD",  # 自定义 BUILD 文件
)

# 日志库源码编译
http_archive(
    name = "<glog-name>",
    strip_prefix = "glog-<version>",
    urls = ["https://<package-repo>/glog-<version>.zip"],
)

# 参数库源码编译
http_archive(
    name = "<gflags-name>",
    strip_prefix = "gflags-<version>",
    urls = ["https://<package-repo>/gflags-<version>.tar.gz"],
)

# 系统库封装（序列化库源码编译需要）
new_local_repository(
    name = "zlib",
    build_file = "//:zlib.BUILD",
    path = "/usr",
)
```

### 辅助 BUILD 文件

源码编译第三方库时，通常需要自定义 BUILD 文件。例如封装系统库：

**zlib.BUILD**：
```python
package(default_visibility=["//visibility:public"])

cc_library(
    name = "zlib",
    linkopts = ["-lz"],
)
```

对于复杂的第三方库（如 RPC 框架），需要编写完整的 BUILD 文件，包含：
- `config_setting` 定义（如 `with_glog`、`with_thrift`）
- 源文件列表（`srcs`）
- 头文件列表（`hdrs`）
- 编译选项（`copts`，含架构 `select()`）
- 链接选项（`linkopts`，含架构 `select()`）
- 依赖关系（`deps`）

---

## 层5：源码条件编译层 `#if defined(__aarch64__)`

**作用**：C/C++ 源码中无法用 Bazel select() 控制的地方，用预处理器宏做条件编译。

### 场景1：头文件路径差异

**场景**：某库在 x86 上使用预编译库（头文件路径带仓库前缀），ARM 上改为源码编译（头文件路径不带前缀）。

```cpp
#if defined(__aarch64__)
#include "<sub-module>/<header>.h"       // 源码编译，路径不带仓库前缀
#else
#include "<repo-name>/<sub-module>/<header>.h"  // 预编译库，路径带仓库前缀
#endif
```

### 场景2：SIMD intrinsics 兼容

**场景**：x86 使用 AVX2 intrinsics 头文件，ARM 使用兼容层替代。

```cpp
#ifdef __aarch64__
#include "avx2ki.h"    // ARM 兼容层（华为 BoostKit KSL，AVX2→NEON 映射）
#else
#include <immintrin.h> // x86 原生 AVX2/SSE intrinsics
#endif
```

### 场景3：第三方库 BUILD 中的 `__const__` 宏重定义

**场景**：某些第三方库源码中使用了 `__const__` 扩展关键字修饰函数，x86 GCC 能正确处理，但 ARM GCC 对此关键字的行为不同。

```python
COPTS = [
    ...
] + select({
    "//platforms:is_aarch64": ["-D__const__=__unused__"],  # ARM GCC 需重定义
    "//platforms:is_x86_64": ["-D__const__="],
    "//conditions:default": ["-D__const__="],
})
```

**原因**：`__const__` 在 x86 GCC 中表示函数无副作用，但 ARM GCC 解析行为不同，需通过 `select()` 在编译选项中重新定义此宏。

---

## 迁移检查清单

按层逐项检查：

- [ ] **层1**：创建 `platforms/BUILD`，定义 `is_x86_64`/`is_aarch64` config_setting 和 `linux_x86`/`linux_aarch64` platform
- [ ] **层2**：修改 `.bazelrc`，将 x86 专属标志移入 `linux_x86` config，添加 `linux_aarch64` config
- [ ] **层3**：修改 BUILD 文件中所有架构敏感的 deps/linkopts/copts/defines，用 `select()` 分支
- [ ] **层4**：创建 `WORKSPACE_arm`（含源码编译依赖）、`WORKSPACE_x86`（原文件重命名）、`build.sh`
- [ ] **层5**：修改 C/C++ 源码中架构敏感的 `#include`，用 `#if defined(__aarch64__)` 条件编译
- [ ] **验证**：`bazel build //... --config=linux_x86` 和 `--config=linux_aarch64` 分别编译通过
