# Intrinsics 函数处理案例

> **做什么**：将 x86 AVX/SSE intrinsics 函数调用按 `AVX_STRATEGY` 改造为 avx2ki 兼容层、NEON 手写实现或标量退化。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | DevKit 报告条目 | `PortingCategory.INTRINSICS` 或 `INTRINSICS_LIBRARY` + 文件路径 + 行号 + 函数名 |
| 输入 | `AVX_STRATEGY` | 阶段 2 用户决策（`ksl` / `neon` / `disable`） |
| 输出 | 源码修改 | x86 侧保留；鲲鹏侧按策略分支 |

## 三种策略与 `AVX_STRATEGY` 的对应关系

| `AVX_STRATEGY` | 推荐策略 | 适用场景 |
|----------------|---------|---------|
| `ksl` | 4.2.3.1(a) avx2ki 兼容层 | 改造成本最低，KSL 覆盖大多数 `_mm*` 函数 |
| `neon` | 4.2.3.1(b) NEON 手写 + 4.2.3.2 策略 A | 性能最优，无 KSL 依赖 |
| `disable` | 4.2.3.2 策略 C | 仅适用于可选的性能优化路径，核心功能不可用此策略 |

## 案例 1：avx2ki 兼容层（`AVX_STRATEGY=ksl`）

avx2ki.h 是鲲鹏 KSL 提供的 x86 intrinsics 到 ARM NEON 的映射头文件，大多数 `_mm*` 函数均有对应映射。**原有 `_mm*` 调用代码无需修改**，仅切换头文件：

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

## 案例 2：手写 NEON 实现（`AVX_STRATEGY=neon`）

不使用 avx2ki，改为引入 `<arm_neon.h>` 并将 `_mm*` 调用手动改写为 NEON `v*` intrinsics。

### 常见映射对照

| x86 AVX/SSE intrinsic | 用途 | ARM NEON 替代 |
|----------------------|------|--------------|
| `_mm256_loadu_ps` | 加载 8 个 float | `vld1q_f32`（每次 4 个，需两条） |
| `_mm256_storeu_ps` | 存储 8 个 float | `vst1q_f32`（每次 4 个，需两条） |
| `_mm256_add_ps` | 8 路 float 加 | `vaddq_f32`（每次 4 路，需两条） |
| `_mm_loadu_ps` | 加载 4 个 float | `vld1q_f32` |
| `_mm_storeu_ps` | 存储 4 个 float | `vst1q_f32` |
| `_mm_add_ps` | 4 路 float 加 | `vaddq_f32` |

### 改写样例

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

## 案例 3：avx2ki 不覆盖的 intrinsics 手动替换

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

## 案例 4：完整三种策略（用于选择最佳实现方式）

### 策略 A：架构宏隔离 + 提供 ARM NEON 替代实现（推荐，性能不退化）

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

### 策略 B：架构宏隔离 + 标量退化（适用于非热点路径，编码成本低）

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

### 策略 C：整体禁用该功能（仅适用于可选的性能优化路径）

```cpp
// 仅在 x86 上启用该优化特性
#if defined(__x86_64__) || defined(_M_X64)
void register_simd_optimizer() {
    // 注册 SIMD 加速处理器
}
#endif
```

> **策略与 `AVX_STRATEGY` 的对应关系**：
> - `AVX_STRATEGY=disable` → 统一采用策略 C（整体禁用该 SIMD 功能）
> - `AVX_STRATEGY=neon` → 优先采用策略 A（手写 NEON 替代），非热点路径可用策略 B（标量退化）
> - `AVX_STRATEGY=ksl` → 优先采用案例 1（avx2ki 兼容层），最简改造

## 执行流程

1. **定位**：使用文件读取工具跳转到 DevKit 报告中的行号
2. **确认函数**：在 case 2 / 案例 3 表格中查找对应 intrinsics
3. **按 `AVX_STRATEGY` 选择案例**：
   - `ksl` 且函数在 avx2ki 覆盖范围 → 案例 1
   - `neon` → 案例 2
   - 函数不在 avx2ki 覆盖范围 → 案例 3
4. **如需完整策略选择** → 案例 4（A/B/C 三选一）
5. **验证**：双架构编译通过（参考 [source-migration-scan.md](source-migration-scan.md) 4.3 节）

## 失败处置

| 现象 | 处置 |
|------|------|
| 编译报 `undefined reference to '_mm*'` | `AVX_STRATEGY=ksl` 时检查 `-lavx2ki` 链接；`neon` 时检查是否漏写 NEON 分支 |
| NEON 改写后性能下降 | 拆 256 位为两条 128 位是常态，参考案例 2 映射表 |
| intrinsics 函数未在案例 3 表格中 | 视为 avx2ki 不覆盖，参考 `_BitScanReverse64` 模式用 ARM 等价内置替换 |
| x86 侧编译报语法错误 | 检查 `__x86_64__` 分支是否完整保留原代码（双架构兼容原则） |
