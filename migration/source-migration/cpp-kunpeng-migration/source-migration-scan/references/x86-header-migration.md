# x86 专属头文件处理案例

> **做什么**：将 x86 专属头文件（`<immintrin.h>` / `<xmmintrin.h>` 等）用架构宏保护，鲲鹏侧按 `AVX_STRATEGY` 引入对应替代头文件。跳转到报告给出的源文件行号后，**先读取文件定位上下文**，再按本案例修改。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | DevKit 报告条目 | `PortingCategory.ATTRIBUTE` + `modification_level=Rule` + 文件路径 + 行号 |
| 输入 | `AVX_STRATEGY` | 阶段 2 用户决策（`ksl` / `neon` / `disable`） |
| 输出 | 源码修改 | x86 侧保留，鲲鹏侧按策略引入 `<avx2ki.h>` 或 `<arm_neon.h>` |

## 常见 x86 专属头文件列表

| 头文件 | 说明 | 鲲鹏替代（`AVX_STRATEGY=ksl`） | 鲲鹏替代（`AVX_STRATEGY=neon`） |
|--------|------|----------|----------|
| `<immintrin.h>` | AVX/AVX2 intrinsics | 引入 `<avx2ki.h>`（KSL 兼容层） | 引入 `<arm_neon.h>` 并手写 NEON |
| `<emmintrin.h>` | SSE2 intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<xmmintrin.h>` | SSE intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<nmmintrin.h>` | SSE4.2 intrinsics（含 CRC32） | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<pmmintrin.h>` | SSE3 intrinsics（含 FTZ/DAZ） | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<smmintrin.h>` | SSE4.1 intrinsics | 引入 `<avx2ki.h>` | 引入 `<arm_neon.h>` 并手写 NEON |
| `<cpuid.h>` | CPU 特性检测（x86 专属） | 无直接替代，需改用系统接口 | 无直接替代，需改用系统接口 |

## 修改案例

### 案例 1：单 include 包裹（典型）

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
> - `AVX_STRATEGY=neon`：鲲鹏侧引入 `<arm_neon.h>`，需将 `_mm*` 调用手动改写为 NEON `v*` intrinsics（详见 [intrinsics-migration.md](references/intrinsics-migration.md)）

### 案例 2：整个源文件整体保护（整个文件都是 x86 专属 SIMD）

```cpp
// 文件顶部整体保护，ARM 上跳过整个文件
#if defined(__x86_64__) || defined(_M_X64)

// ... 文件全部内容 ...

#endif  // __x86_64__
```

## 执行流程

1. **定位**：使用文件读取工具跳转到 DevKit 报告中的行号
2. **确认头文件**：比对案例 1 表格，确认属于哪类头文件
3. **应用案例**：
   - 整文件都是 x86 SIMD → 案例 2
   - 局部 include → 案例 1，按 `AVX_STRATEGY` 二选一
4. **验证**：双架构编译通过（参考 [source-migration-scan.md](source-migration-scan.md) 4.3 节）

## 失败处置

| 现象 | 处置 |
|------|------|
| 头文件不在案例 1 表格中 | 视为低频头文件，参考 `<cpuid.h>` 行单独处理（无标准替代） |
| 鲲鹏侧编译报 `avx2ki.h: No such file` | 检查 4.2.0 是否成功安装 KSL；`AVX_STRATEGY=neon` 时移除 `USE_AVX2KI` 宏分支 |
| 鲲鹏侧编译报 `arm_neon.h` 缺失 | aarch64 工具链异常，重新安装 `gcc-aarch64-linux-gnu` 或检查 `-march=armv8-a` |
| x86 侧编译失败 | 检查 `__x86_64__` 宏分支是否完整保留原 include |
