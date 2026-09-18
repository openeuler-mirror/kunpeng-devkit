# x86 内联汇编处理案例

> **做什么**：将 x86 特定汇编指令改为 ARM aarch64 等价指令或跨平台替代方案（修改级别 `Suggestion_General`，建议非强制）。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | DevKit 报告条目 | `PortingCategory.BUILTIN_ASSEMBLES` + 文件路径 + 行号 + x86 指令名 |
| 输出 | 源码修改 | x86 侧保留；aarch64 侧用 ARM 指令或 GCC 内置函数替代 |

## x86 汇编指令及 ARM 替代对照

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

## 修改模式

### 模式 1：CPUID（报告中 cpu_info.cc 出现）

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

### 模式 2：rdtsc 时钟周期读取

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

### 模式 3：通用修改框架

```cpp
// 通用修改模式
#if defined(__x86_64__) || defined(_M_X64)
    // x86 实现（保留不变）
    __asm__ volatile("..." : ...);
#elif defined(__aarch64__)
    // aarch64 等价实现
    __asm__ volatile("..." : ...);
#else
    // 跨平台 fallback
#endif
```

## 优先策略

> **优先使用 GCC 内置函数替代内联汇编**：
> - `__builtin_popcount()` — 人口计数
> - `__builtin_ctz()` — 末尾零计数
> - `__builtin_clz()` — 前导零计数
> - `__atomic_*` 系列 — 原子操作
>
> 这些内置函数均支持 ARM64，编译器会自动选择最优指令，无需手动区分架构。

## 执行流程

1. **定位**：使用文件读取工具跳转到 DevKit 报告中的行号
2. **识别指令**：在 x86 汇编指令及 ARM 替代对照表中查找
3. **按优先级选择替代**：
   - 优先：GCC 内置函数（无需架构分支）
   - 次选：ARM 汇编指令（性能最优）
   - 最后：跨平台标准库函数（兼容性最好）
4. **架构宏隔离**：保留 x86 实现，aarch64 侧提供新实现
5. **验证**：双架构编译通过（参考 [source-migration-scan.md](source-migration-scan.md) 4.3 节）

## 失败处置

| 现象 | 处置 |
|------|------|
| 指令不在案例对照表中 | 视为低频指令，参考模式 3 通用框架手动处理 |
| `__builtin_clzll(0)` 行为未定义 | 在调用前确保输入非零，或参考 `_BitScanReverse64` 案例先判断 |
| aarch64 `mrs` 指令权限异常 | 检查是否在内核态或 EL0；用户态可访问的寄存器有限 |
| 性能下降 | 内置函数已为编译器优化；如仍不满足，检查是否漏掉 `-O2/-O3` 编译选项 |
