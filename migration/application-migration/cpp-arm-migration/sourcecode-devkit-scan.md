# 阶段 D：DevKit 扫描与源码适配

本文档描述如何运行华为鲲鹏 DevKit 对源码进行 x86 兼容性扫描，以及如何根据扫描报告对源码进行架构适配修改。

> **范围说明**：本文档涵盖 DevKit 工具调用、源码修改方法，以及构建系统配置（`.bazelrc`、`WORKSPACE_arm`、`CMakeLists.txt` 等）的架构适配。

> **前置条件**：阶段 C 用户确认已完成，私有依赖的 ARM 兼容性信息已获取。

---

## D.1 运行 DevKit 扫描

### D.1.1 定位 DevKit 工具

首先确认 DevKit 是否已安装，以及可执行文件的路径：

```bash
# 尝试从系统 PATH 中查找
which devkit 2>/dev/null

# 或在常见安装路径中查找（根据实际环境调整搜索范围）
find /opt /usr/local -name "devkit" -maxdepth 8 -type f 2>/dev/null | head -3

# 确认版本
<devkit路径> --version
```

若上述均未找到，**不得跳过扫描、也不得自行下载安装**。通过 `AskUserQuestion` 向用户决策如何处理（与 SKILL.md 阶段 D 硬性约束一致）：

```
question: "未在系统中检测到 DevKit，如何继续阶段 D 扫描？"
options:
  - id: provide_path   label: "我知道路径，手动提供 DevKit 安装路径"
  - id: download       label: "我去 https://www.hikunpeng.com/developer/devkit 下载安装后继续"
  - id: abort          label: "中止阶段 D"
```

按用户选择处理：
- **provide_path**：用户给出路径后，将其作为 `DEVKIT` 继续后续步骤；若该路径 `--version` 仍失败，回到本提问
- **download**：暂停阶段 D，等待用户安装完成并回报路径后继续（agent 不代为下载安装）
- **abort**：终止阶段 D，不进入 D.2

> DevKit 安装位置因环境而异、且下载安装属重操作，应由用户决策而非 agent 擅自执行。

### D.1.2 确认扫描参数

根据阶段 A `environment-prepare.md` 的构建系统检测结果，确定 `-b` 参数：

| 构建系统 | `-b` 参数值 |
|---------|------------|
| Bazel | `bazel` |
| CMake | `cmake` |
| Make/Makefile | `make` |
| Blade/SCons/其他 | `other` |

### D.1.3 执行扫描

```bash
# DEVKIT：devkit 可执行文件路径
# PROJECT_ROOT：项目根目录
# WORK_DIR：工作目录（见 SKILL.md 工作目录约定）

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

### D.1.4 读取并汇总扫描报告

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

**理解报告中的问题分类：**

| DevKit 问题类型 | 含义 | 修改策略 |
|---------------|------|---------|
| `x86 asm` / `inline asm` | x86 内联汇编 | 架构宏隔离，提供 ARM 替代实现或禁用 |
| `x86 intrinsics` | SSE/AVX intrinsics 函数调用 | 架构宏隔离，提供 NEON 替代或标量退化 |
| `x86 header` | x86 专属头文件（`immintrin.h` 等） | 架构宏保护 `#include` 语句 |
| `type size` | 类型大小/字节序依赖 | 改用 `uint32_t` 等明确宽度的类型 |
| `memory align` | 内存对齐假设 | 排查强制对齐的指针操作 |
| `compiler flag` | 源码中硬编码的 x86 编译标志 | 移入构建系统的架构专属配置段 |

---

## D.2 按报告逐条修改源码

扫描完成后，对报告中每一条问题按以下方法处理。所有修改须遵循**双架构兼容**原则：修改后 x86 和 ARM 均能正常编译，不删除任何原有的 x86 实现。

### D.2.1 处理 x86 专属头文件（`x86 header` 类型）

**问题定位**：DevKit 报告给出了包含 x86 专属头文件的源文件路径和行号，直接跳转到对应行。

**修改方法**：用架构宏将 `#include` 语句包裹起来。常见的 x86 专属头文件包括：
- `<immintrin.h>`、`<emmintrin.h>`、`<xmmintrin.h>`（SIMD intrinsics）
- `<cpuid.h>`（CPU 特性检测）
- `<sys/sysctl.h>`（BSD/macOS 专属，ARM Linux 无此文件）

修改模式：

```cpp
// 原始代码（直接 include，ARM 上编译失败）
#include <immintrin.h>

// 修改后（架构宏保护）
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>   // 若后续代码有 NEON 实现，则引入；否则此行可省略
#endif
```

若整个源文件都是 x86 专属的 SIMD 实现，可在文件顶部整体保护：

```cpp
// 文件顶部整体保护，ARM 上跳过整个文件
#if defined(__x86_64__) || defined(_M_X64)

// ... 文件全部内容 ...

#endif  // __x86_64__
```

---

### D.2.2 处理 intrinsics 函数调用（`x86 intrinsics` 类型）

**问题定位**：报告给出使用了 `_mm256_*`、`_mm_*`、`__m256i` 等 x86 SIMD API 的具体位置。

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

---

### D.2.3 处理内联汇编（`x86 asm` 类型）

**问题定位**：报告给出含 `__asm__` / `asm volatile` 的源文件位置。

**修改方法**：架构宏隔离，并为 ARM 提供等价实现。

常见内联汇编场景及 ARM 替代方式：

| x86 汇编用途 | x86 写法 | ARM 替代 |
|-------------|---------|---------|
| 读 CPU 时钟周期 | `rdtsc` | `mrs %0, cntvct_el0`（系统计数器） |
| 内存屏障 | `mfence` / `sfence` | `__sync_synchronize()` 或 `asm volatile("dmb ish")` |
| 原子操作 | `lock xadd` | `__atomic_*` 系列 GCC 内置函数（跨架构兼容） |
| 位扫描（BSF/BSR） | `bsf %1, %0` | `__builtin_ctz()` / `__builtin_clz()`（跨架构兼容） |

修改模式：

```cpp
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

> **优先使用 GCC 内置函数替代内联汇编**：`__builtin_popcount()`、`__builtin_ctz()`、`__builtin_clz()` 等均支持 ARM64，编译器会自动选择最优指令，无需手动区分架构。

---

### D.2.4 处理类型大小/字节序依赖（`type size` 类型）

**问题定位**：报告标记了依赖特定类型大小的代码，例如假设 `int` 为 32 位、`long` 为 64 位等。

**修改方法**：

```cpp
// 问题：依赖 long 的具体大小（Linux x86_64 和 ARM64 上 long 均为 64 位，但跨 OS 时不同）
long value = some_function();

// 修改为：使用 <stdint.h> 中的明确宽度类型
int64_t value = some_function();
```

字节序处理（通常 x86 和 ARM 均为小端，跨字节序时才需要处理）：

```cpp
// 若涉及网络字节序或文件格式，使用标准函数
#include <arpa/inet.h>
uint32_t network_val = htonl(host_val);   // 主机序 → 网络序（跨平台安全）
uint32_t host_val    = ntohl(network_val); // 网络序 → 主机序
```

---

### D.2.5 处理内存对齐假设（`memory align` 类型）

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

---

## D.3 修改完整性验证

全部报告条目处理完毕后，执行以下检查，确认没有遗漏：

### D.3.1 残留 x86 专属头文件检查

```bash
# 检查是否还有未隔离的 x86 intrinsics 头文件（过滤掉已有架构宏保护的行）
grep -rn "#include.*\(immintrin\|emmintrin\|xmmintrin\|nmmintrin\|smmintrin\|cpuid\.h\)" \
  $PROJECT_ROOT --include="*.cc" --include="*.cpp" --include="*.h" \
  | grep -v "__x86_64__\|_M_X64\|aarch64\|#if"
# 若有输出，说明仍有未保护的 include，需要继续处理
```

### D.3.2 残留 intrinsics 调用检查

```bash
# 检查是否还有未隔离的 SIMD 类型或函数
grep -rn "_mm256_\|_mm512_\|_mm_\|__m128\|__m256\|__m512" \
  $PROJECT_ROOT --include="*.cc" --include="*.cpp" --include="*.h" \
  | grep -v "__x86_64__\|aarch64\|//.*_mm" | head -20
```

### D.3.3 记录修改清单

```bash
# 将本阶段的所有修改记录到工作目录
git -C $PROJECT_ROOT diff --stat 2>/dev/null \
  >> $WORK_DIR/reports/source_changes.txt
```

---

## D.4 修改完成检查清单

- [ ] DevKit 扫描报告已读取并按类型汇总
- [ ] 所有 `x86 header` 类型问题已用架构宏保护 `#include`
- [ ] 所有 `x86 intrinsics` 类型问题已处理（NEON 替代或标量退化）
- [ ] 所有 `x86 asm` / `inline asm` 类型问题已用架构宏隔离
- [ ] 所有 `type size` 类型问题已改用明确宽度类型
- [ ] 所有 `memory align` 类型问题已排查并处理
- [ ] 残留检查通过（grep 无遗漏输出）
- [ ] 修改清单已记录到 `$WORK_DIR/reports/source_changes.txt`
- [ ] 确认所有修改中 x86 代码路径未被删除（最小侵入）
