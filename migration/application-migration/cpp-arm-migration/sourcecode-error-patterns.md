# 编译错误模式案例库

本案例库收录 C/C++ 项目 ARM 迁移过程中遇到的典型编译错误，每条案例包含：**错误现象 → 根因分析 → 修复方法 → 验证方式**。

案例按错误类型分组：
- **A 系列**：编译标志与构建配置类
- **B 系列**：头文件与 Include 类
- **C 系列**：类型、符号与 API 兼容性类
- **D 系列**：链接错误类
- **E 系列**：Bazel 构建系统类
- **F 系列**：编译器严格性差异类

---

## A 系列：编译标志与构建配置类

### A-01：x86 编译标志在 ARM 上报错

**错误现象：**
```
error: '-mf16c' is not supported by this configuration
error: option '-mpopcnt' cannot be specified
unrecognized option '-mssse3'
unrecognized option '-mavx2'
error: '-march=haswell' is not a recognized option
```

**根因分析：**  
`.bazelrc` 或 `Makefile` 的全局配置段中存在 x86 专属 CPU 扩展标志（`-mf16c`、`-msse`、`-mavx`、`-mpopcnt`、`-mssse3`），这些标志对 ARM 编译器无效，导致编译失败。

**修复方法（Bazel）：**
```bash
# 1. 定位问题行
grep -n "mf16c\|msse\|mavx\|mpopcnt\|mssse3\|march=.*86\|march=haswell" \
  $PROJECT_ROOT/.bazelrc

# 2. 将这些行从全局段移到 linux_x86 专属段
```

修改前：
```
# .bazelrc 全局段（对所有架构生效，ARM 上会失败）
build --cxxopt="-mf16c"
build --copt="-mf16c"
build --cxxopt="-mpopcnt"
```

修改后：
```
# .bazelrc：全局段删除 x86 专属标志
# （全局段只保留 -O3 -fPIC -std=c++11 -Wall 等通用标志）

# x86 专属段（--config=linux_x86 时生效）
build:linux_x86 --cxxopt="-mf16c"
build:linux_x86 --copt="-mf16c"
build:linux_x86 --cxxopt="-mpopcnt"

# ARM 专属段（--config=linux_aarch64 时生效）
build:linux_aarch64 --cxxopt="-march=armv8-a"
build:linux_aarch64 --cxxopt="-fsigned-char"
```

**验证：**
```bash
grep "linux_x86\|linux_aarch64" $PROJECT_ROOT/.bazelrc | head -20
# 确认 x86 专属标志已在 linux_x86 段，不在全局段
```

---

### A-02：`char` 符号性差异导致数据处理错误（非编译报错，运行时隐患）

**错误现象：**  
编译通过，但运行时出现字符串处理或数据解析错误（如负值判断错误、字符比较异常）。

**根因分析：**  
x86 平台上 `char` 默认为有符号（`signed char`），ARM 平台上 `char` 默认为**无符号**（`unsigned char`）。依赖 `char` 符号性的代码在 ARM 上行为不一致。

**修复方法：**  
在 ARM 编译配置段添加 `-fsigned-char`，强制 ARM 上的 `char` 与 x86 一致：

```
# .bazelrc ARM 段
build:linux_aarch64 --cxxopt="-fsigned-char"
build:linux_aarch64 --copt="-fsigned-char"
```

或在 CMakeLists.txt 的 ARM 分支中添加：
```cmake
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsigned-char")
endif()
```

---

## B 系列：头文件与 Include 类

### B-01：x86 intrinsics 头文件找不到

**错误现象：**
```
fatal error: 'immintrin.h' file not found
fatal error: 'emmintrin.h' file not found
fatal error: 'xmmintrin.h' file not found
```

**根因分析：**  
这些头文件是 x86 SIMD intrinsics，ARM 编译器不提供。

**修复方法：**

```cpp
// 修改前
#include <immintrin.h>  // AVX
#include <emmintrin.h>  // SSE2

// 修改后
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#include <emmintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>   // ARM NEON（按需引入，可选）
#endif
```

若整个文件都是 x86 SIMD 实现，可在文件顶部整体保护：
```cpp
// foo_simd_x86.cpp - 仅用于 x86 平台
#if defined(__x86_64__) || defined(_M_X64)

#include <immintrin.h>
// ... 全部 x86 实现

#endif  // __x86_64__
```

---

### B-02：x86/BSD 专属系统头文件

**错误现象：**
```
fatal error: 'sys/sysctl.h' file not found
fatal error: 'asm/processor.h' file not found
fatal error: 'sys/io.h' file not found
fatal error: 'cpuid.h' file not found
```

**根因分析：**  
这些头文件在 x86/BSD 上存在，但 ARM Linux 不提供。

**修复方法：**

```cpp
// sys/sysctl.h（仅 BSD/macOS）
#if !defined(__linux__) || (defined(__linux__) && !defined(__aarch64__))
#include <sys/sysctl.h>
#endif

// cpuid.h（x86 专属）
#if defined(__x86_64__) || defined(_M_X64)
#include <cpuid.h>
#endif
```

---

### B-03：第三方库 BUILD 文件缺少头文件声明

**错误现象：**
```
fatal error: 'libxxx/foo.h' file not found
```
但 `foo.h` 确实存在于项目中。

**根因分析：**  
第三方库的 Bazel `.BUILD` 文件中 `cc_library` 规则缺少 `hdrs` 或 `includes` 字段，导致 ARM 环境下头文件路径未被正确暴露。（x86 环境可能因为其他路径设置而偶然工作。）

**修复方法：**

```python
# 修改对应的 .BUILD 文件
cc_library(
    name = "foo",
    srcs = glob(["src/**/*.cpp"]),
    # 补充：明确声明头文件
    hdrs = glob(["include/**/*.h", "**/*.h"]),
    includes = ["include", "."],   # 确保头文件路径被暴露
    visibility = ["//visibility:public"],
)
```

---

## C 系列：类型、符号与 API 兼容性类

### C-01：AVX/SSE intrinsics 函数或类型未声明

**错误现象：**
```
error: '__m256i' was not declared in this scope
error: '_mm256_loadu_si256' was not declared in this scope
error: '__m128i' undeclared
error: '_mm_setzero_si128' was not declared
```

**根因分析：**  
AVX/SSE intrinsics 类型和函数在 ARM 上未定义，且未用架构宏保护。

**修复方法（有 ARM 替代实现）：**

```cpp
// 带 NEON 替代的完整示例
void byte_count(const uint8_t* data, size_t len, uint64_t* counts) {
#if defined(__x86_64__) || defined(_M_X64)
    // x86 AVX2 实现
    const __m256i* ptr = (const __m256i*)data;
    // ... AVX2 处理
    
#elif defined(__aarch64__)
    // ARM NEON 实现
    const uint8x16_t* ptr = (const uint8x16_t*)data;
    // ... NEON 处理
    
#else
    // 通用标量实现（fallback）
    for (size_t i = 0; i < len; i++) {
        counts[data[i]]++;
    }
#endif
}
```

**修复方法（仅隔离，退化为标量）：**

```cpp
// 整个 x86 特化函数用宏保护，ARM 使用通用版本
#if defined(__x86_64__) || defined(_M_X64)
void process_avx2(const float* src, float* dst, int n) {
    // ... AVX2 实现
}
#endif

void process(const float* src, float* dst, int n) {
#if defined(__x86_64__) || defined(_M_X64)
    if (has_avx2()) {
        process_avx2(src, dst, n);
        return;
    }
#endif
    // 通用实现
    for (int i = 0; i < n; i++) {
        dst[i] = src[i];
    }
}
```

---

### C-02：x86 rdtsc / CPU 时间戳指令

**错误现象：**
```
error: '__builtin_ia32_rdtsc' undeclared
invalid instruction 'rdtsc'
```

**根因分析：**  
`rdtsc` 是 x86 专属的 CPU 周期计数器读取指令，ARM 上需要使用系统寄存器替代。

**修复方法：**

```cpp
inline uint64_t get_cpu_cycles() {
#if defined(__x86_64__) || defined(_M_X64)
    uint32_t lo, hi;
    __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#elif defined(__aarch64__)
    uint64_t val;
    // ARM 系统计数器（精度取决于系统配置）
    __asm__ volatile ("mrs %0, cntvct_el0" : "=r"(val));
    return val;
#else
    // 使用标准时钟作为 fallback
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
#endif
}
```

---

### C-03：`__builtin_ia32_*` 等 x86 GCC built-in 函数

**错误现象：**
```
error: '__builtin_ia32_bsrl' undeclared
error: '__builtin_ia32_popcntdi2' undeclared
```

**根因分析：**  
`__builtin_ia32_*` 是 GCC/Clang 为 x86 提供的 builtin 函数，ARM 上不可用。

**修复方法：**

```cpp
// 示例：popcount（位计数）
inline int popcount64(uint64_t x) {
#if defined(__x86_64__) || defined(_M_X64)
    return __builtin_popcountll(x);  // x86 上可能使用 POPCNT 指令
#elif defined(__aarch64__)
    return __builtin_popcountll(x);  // ARM64 GCC 也支持 __builtin_popcount
#else
    // 通用实现
    x = x - ((x >> 1) & 0x5555555555555555ULL);
    x = (x & 0x3333333333333333ULL) + ((x >> 2) & 0x3333333333333333ULL);
    return (int)(((x + (x >> 4)) & 0x0f0f0f0f0f0f0f0fULL) * 0x0101010101010101ULL >> 56);
#endif
}
```

---

### C-04：`-D__const__=` 宏破坏 ARM glibc

**错误现象：**
```
error: expected unqualified-id before '__attribute__' token
error: expected ')' before '__attribute__'
```
或者大量 `glibc` 系统头文件报出奇怪的解析错误。

**根因分析：**  
某些第三方库（如 mrpc/brpc）的 BUILD 文件中设置了 `-D__const__=`，将 `__const__` 宏定义为空字符串。在 x86 上偶然可以工作，但 ARM 上 glibc 系统头文件大量使用 `__const__` 关键字，被替换为空后导致语法错误。

**修复方法：**

找到设置 `-D__const__=` 的 BUILD 或 `.BUILD` 文件：

```bash
grep -rn "\-D__const__=" $PROJECT_ROOT \
  --include="*.BUILD" --include="BUILD" --include="*.bazel"
```

修改前：
```python
cc_library(
    name = "mrpc",
    copts = [
        "-D__const__=",
        "-O2",
    ],
    ...
)
```

修改后（使用 `select()` 按架构区分）：
```python
cc_library(
    name = "mrpc",
    copts = [
        "-O2",
    ] + select({
        "//platforms:is_aarch64": ["-D__const__=__unused__"],  # ARM：映射为已知属性，不破坏 glibc
        "//conditions:default": ["-D__const__="],              # x86：保持原有行为
    }),
    ...
)
```

> **注意**：`-D__const__=__unused__` 将 `__const__` 定义为 GCC 内置属性，不会破坏 glibc。也可以直接在 ARM 段省略这个宏：`"//platforms:is_aarch64": []`，但需要验证被引用库不依赖这个宏的原有行为。

---

### C-05：`longjmp` 与 `__builtin_setjmp` 的差异

**错误现象：**
```
error: incompatible types when assigning to type 'jmp_buf' from type 'struct __jmp_buf_tag *'
```

**根因分析：**  
`jmp_buf` 在不同架构上的定义不同，直接赋值跨架构不可移植。

**修复方法：**  
使用标准 POSIX 接口，不直接操作 `jmp_buf` 内部字段：
```cpp
jmp_buf saved;
if (setjmp(saved) == 0) {
    // 正常路径
} else {
    // 从 longjmp 恢复
}
```

---

## D 系列：链接错误类

### D-01：链接了 x86 架构的预编译库

**错误现象：**
```
error adding symbols: File in wrong format
/usr/bin/ld: ./lib/libfoo.a: error adding symbols: file in wrong format
collect2: error: ld returned 1 exit status
```

**根因分析：**  
`WORKSPACE_arm` 中仍引用了 x86 预编译的 `.so` 或 `.a` 文件（原始的 x86 URL 未替换）。

**修复方法：**

```bash
# 1. 确认问题文件的架构
file ./lib/libfoo.a
# 预期输出：... ELF 64-bit LSB relocatable, x86-64 (需要替换)

# 2. 在 WORKSPACE_arm 中找到对应的 http_archive 声明
grep -B2 -A10 "libfoo\|foo_x86" $PROJECT_ROOT/WORKSPACE_arm

# 3. 将 URL 替换为 ARM 版本
# 修改前（x86 预编译包）：
http_archive(
    name = "foo",
    urls = ["https://<your-package-repo>/foo-v1.2.3-linux-x86_64.tar.gz"],
    sha256 = "<x86-sha256>",
)

# 修改后（ARM 预编译包）：
http_archive(
    name = "foo",
    urls = ["https://<your-package-repo>/foo-v1.2.3-linux-aarch64.tar.gz"],
    sha256 = "<aarch64-sha256>",  # 需更新为 ARM 版本的 sha256
)
```

---

### D-02：符号未定义（链接时）

**错误现象：**
```
undefined reference to 'ClassName::method()'
undefined reference to 'SomeFunction(int, const std::string&)'
```

**根因分析：**  
通常有以下几种情况：
1. ARM 版库的 ABI 与调用方不一致（如编译时用了不同 `--std=c++11/14/17`）
2. ARM 版库实际缺少该符号（实现差异）
3. 使用了桩库，但桩未实现对应符号（编译时 inline，链接时报错）

**修复方法：**

```bash
# 确认符号是否在 ARM 版库中存在
nm -D /path/to/libfoo-arm.so | grep "ClassName::method"
# 若输出为空，说明 ARM 版缺少该符号

# 确认 ABI 兼容性
strings /path/to/libfoo-arm.so | grep "cxx11\|GLIBCXX"
```

若桩未实现对应符号，补充桩实现：
```cpp
// 在桩头文件中添加
class ClassName {
public:
    void method() {}   // 空实现（仅满足编译链接，运行时为 no-op）
};
```

---

## E 系列：Bazel 构建系统类

### E-01：找不到平台目标

**错误现象：**
```
ERROR: no such target '//platforms:is_aarch64'
ERROR: no such target '//platforms:linux_aarch64'
```

**根因分析：**  
`platforms/BUILD` 文件中未定义 ARM 平台相关的 `config_setting` 和 `platform` 规则。

**修复方法：**  
参考 `sourcecode-devkit-scan.md` D.2.4 节，补全 `platforms/BUILD` 文件中的 ARM 定义。

---

### E-02：SSH 克隆私有仓库失败

**错误现象：**
```
ERROR: /path/to/WORKSPACE:XX:1: fetching new_git_repository rule //external:some_lib: \
  Host key verification failed.
ERROR: An error occurred during the fetch of repository 'some_lib'
```

**根因分析：**  
ARM 编译环境中没有配置 SSH 密钥（或密钥与 x86 环境不同），导致 `git clone` 失败。

**修复方法（方案一：添加 SSH 密钥）：**
```bash
# 将 SSH 公钥添加到内网 Git 服务器的授权列表
ssh-keygen -t ed25519 -C "arm-build"
cat ~/.ssh/id_ed25519.pub  # 将此公钥配置到 Git 服务器
```

**修复方法（方案二：本地桩替代，适用于编译期接口依赖）：**
```bash
# 创建本地桩（见 sourcecode-devkit-scan.md D.6 节）
STUB_DIR=$WORK_DIR/stubs/<库名>
mkdir -p $STUB_DIR && touch $STUB_DIR/WORKSPACE
```

在 `WORKSPACE_arm` 中：
```python
# 替换 git_repository 为 new_local_repository
new_local_repository(
    name = "<库名>",
    path = "<STUB_DIR绝对路径>",
    build_file = "//<库名>_stub.BUILD",
)
```

---

### E-03：Bazel 版本不支持某选项

**错误现象：**
```
Unrecognized option: --incompatible_blacklisted_protos_requires_proto_info
```

**根因分析：**  
ARM 环境中系统全局安装的 Bazel 版本与项目 `software.sh` 中内置的版本不一致，项目使用了系统 Bazel 而非项目内置的版本。

**修复方法：**

```bash
# 确认使用的 Bazel 版本
which bazel && bazel version

# 确认 software.sh 中 PATH 设置是否生效
source $PROJECT_ROOT/software.sh
which bazel && bazel version
```

若 `software.sh` 未正确设置 PATH，在 `software.sh` 开头强制设置：
```bash
# 将项目内置的 bazel_env 路径放在 PATH 最前面
export PATH="$BAZEL_ENV_ROOT/bazel_env/bin:$PATH"
```

---

### E-04：Protobuf 版本不兼容

**错误现象：**
```
error: This file was generated by an older version of protoc which is
incompatible with your Protocol Buffer headers.
```

**根因分析：**  
系统 `protoc` 版本与项目源码中 `.pb.h`（预生成的 protobuf 头文件）的版本不一致。

**修复方法：**  
参考 `setup.md` 1.6 节：

1. 确认项目所需的 protobuf 版本
2. 在 ARM 上源码编译安装匹配版本的 protoc
3. 使用匹配版本的 protoc 重新生成 `.pb.cc` / `.pb.h` 文件

---

## F 系列：编译器严格性差异类

### F-01：`jump to case label`（case 块局部变量）

**错误现象：**
```
error: jump to case label
note: crosses initialization of '...'
```

**根因分析：**  
`switch-case` 块中存在带初始化的局部变量声明，ARM GCC 对此的检查比 x86 GCC 更严格（实际上符合 C++ 标准，是 x86 GCC 的漏检）。

**修复方法：**

```cpp
// 修改前（有问题）
switch (type) {
case TYPE_A:
    int x = compute();   // 错误：局部变量越过了 case TYPE_B 的入口
    break;
case TYPE_B:
    use(x);
    break;
}

// 修改后（给每个 case 块加花括号）
switch (type) {
case TYPE_A: {
    int x = compute();
    break;
}
case TYPE_B: {
    // x 在此不可见，各 case 块隔离
    do_something_else();
    break;
}
}
```

---

### F-02：严格别名（strict aliasing）错误

**错误现象：**
```
error: dereferencing type-punned pointer will break strict-aliasing rules
warning: ... (treated as error with -Werror)
```

**根因分析：**  
通过不相关类型的指针访问同一内存区域（type punning），ARM GCC 对 strict aliasing 的警告更积极，加上 `-Werror` 会变为编译错误。

**修复方法：**

```cpp
// 修改前（type punning，违反 strict aliasing）
float f = 3.14f;
uint32_t bits = *(uint32_t*)&f;  // 可能触发 strict aliasing 警告

// 修改后（使用 memcpy，编译器会优化为寄存器操作）
float f = 3.14f;
uint32_t bits;
memcpy(&bits, &f, sizeof(bits));
```

或者在编译选项中添加（不推荐，会禁用优化）：
```
-fno-strict-aliasing
```

---

### F-03：旧版 Boost 与 ARM 不兼容

**错误现象：**
```
error: missing binary operator before token "("
```
出现在 Boost 头文件中（通常是 `boost/config/compiler/gcc.hpp`）。

**根因分析：**  
Boost 1.65 之前的版本不识别 ARM 编译器版本宏，导致 `#if BOOST_GCC_VERSION > xxx` 等条件判断出现语法错误。

**修复方法：**

1. 升级 Boost 到 1.65+（推荐）
2. 或者在 Boost 的 `gcc.hpp` 头文件中添加 ARM 兼容补丁：

```cpp
// 在 gcc.hpp 中找到 BOOST_GCC_VERSION 定义后，临时添加（不推荐修改第三方库）
// 建议直接升级 Boost 版本
```

---

### F-04：`__attribute__((visibility))` 差异

**错误现象：**
```
warning: 'visibility' attribute ignored on type
```
（加 `-Werror` 后报错）

**修复方法：**  
确保 visibility 属性只用于函数/变量声明，不用于类型定义：

```cpp
// 修改前
class __attribute__((visibility("default"))) Foo { ... };  // 可能在某些 ARM 编译器上报警

// 修改后
class Foo { ... } __attribute__((visibility("default")));
// 或使用宏包装，更可移植：
#define EXPORT __attribute__((visibility("default")))
EXPORT class Foo { ... };
```

---

### F-05：整数提升与位运算差异

**错误现象：**  
编译通过，但运行时逻辑错误（位操作结果不符合预期）。

**根因分析：**  
ARM 上 `int` 和指针大小与 x86 相同，但某些位运算中如果依赖 `int` 宽度（如 `1 << 31`），在不同场景下可能有 UB（未定义行为）。

**修复方法：**

```cpp
// 修改前（依赖 int 宽度，可能有 UB）
uint32_t mask = 1 << 31;  // 1 是 int，左移到符号位是 UB

// 修改后（使用明确宽度的类型）
uint32_t mask = 1U << 31;  // 用无符号字面量
// 或
uint32_t mask = UINT32_C(1) << 31;
```

---

## 附录：常见 x86 架构宏速查

在修改源码时，使用以下宏进行架构检测：

| 宏 | 平台 | 说明 |
|----|------|------|
| `__x86_64__` | GCC/Clang x86_64 | Linux x86_64 首选 |
| `_M_X64` | MSVC x86_64 | Windows |
| `__i386__` | GCC/Clang x86_32 | |
| `__aarch64__` | GCC/Clang ARM64 | ARM64/AArch64 首选 |
| `__arm__` | GCC/Clang ARM32 | |
| `__ARM_NEON` | 支持 NEON 指令集 | 需 `#include <arm_neon.h>` |

**推荐的检测模式：**

```cpp
#if defined(__x86_64__) || defined(_M_X64)
    // x86_64 专属实现
#elif defined(__aarch64__)
    // ARM64 专属实现（或 NEON 优化实现）
#else
    // 通用实现（fallback）
#endif
```

**不推荐的写法（容易遗漏平台）：**

```cpp
// ❌ 不推荐：使用 #ifdef 而非 #if defined()，容易拼写错误
#ifdef __x86_64__

// ❌ 不推荐：仅写 ARM else，忽略其他架构（如 MIPS/RISC-V）
#if defined(__aarch64__)
    // ARM 实现
#else
    // 以为是 x86，实际上对所有非 ARM 平台都走这里
#endif
```
