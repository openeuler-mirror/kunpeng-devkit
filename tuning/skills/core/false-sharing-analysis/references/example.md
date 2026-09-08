# 参考示例：相邻线程计数器的端到端分析

本文件是非规范性的示例，用于说明如何解析 `devopt` 展示的 `FS` 记录并映射到真实项目源码。它不要求 agent 在实际项目中创建这个场景，也不替代用户提供的 `devopt` 证据和真实项目源码。

示例展示如何映射证据并修改直接相关的源码。

## 1. 项目场景

假设项目已有 `WorkerStats`，两个固定工作线程分别更新自己的完成计数：

```cpp
// include/worker_stats.h
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

struct WorkerStats {
    std::array<std::atomic<std::uint64_t>, 2> completed{};
};
```

## 2. 采样记录与源码映射

`devopt.sh script -t memory` 的展示记录如下：

```text
FS 1: 0x400e6c <-> 0x400e6c Type:SS CacheLineAddr:0x17ac40c0 Access Info: A:+0x23,1B;B:+0x1a,1B
   A: worker@/home/user/workspace/false-sharing-master/false:59
   B: worker@/home/user/workspace/false-sharing-master/false:59
```

解析与映射过程：

- 两个 PC 都是 `0x400e6c`，符号化端点都指向 `worker@/home/user/workspace/false-sharing-master/false:59`；
- 根据 `Access Info`，字节区间分别为 `[35, 36)` 与 `[26, 27)`，不重叠，因此是伪共享候选；
- 同一 PC 和源码行可以通过索引或指针访问不同字节，不能据此否定伪共享；
- 必须继续读取第 59 行完整表达式，确认两个并发执行单元访问不同逻辑值，并用对象布局证明它们属于同一缓存行。缺少这些证据时只能标记为“候选”。

只有取得采样进程实际使用的匹配二进制和调试符号时，才可用 PC 辅助确认源码位置，例如：

```bash
addr2line -Cfie <binary> 0x400e6c
gdb -batch -ex 'file <binary>' -ex 'info line *0x400e6c' -ex 'disassemble /m worker'
```

也可按环境使用 `objdump`、DWARF、`pahole` 或 `offsetof`/`sizeof` 探针。agent 环境中的另一次本地构建只能辅助理解源码语义；其 PC 与采样 PC 不同不能证明采样来自旧构建。工具不存在或符号不匹配时不安装、不猜测，只降低结论置信度并说明缺失证据。

当源码访问表达式、线程所有权和对象布局均与记录吻合时，可将对应的独立字段或数组元素标为“已确认”的伪共享。

## 3. 项目源码修改

下面的 `WorkerStats` 仅用于展示确认伪共享后的布局修改方式，不声称它就是上面 `worker:59` 记录对应的源码。只有用户明确要求修复、修改或优化且提供了相关源码时才实施修改。只改动伪共享直接涉及的类型、字段和访问点，不修改 `Makefile`、CMake 文件、构建脚本或其他无关文件。

选择对齐包装类型，让数组的元素对齐和步长都覆盖目标缓存行：

```cpp
// include/worker_stats.h
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

inline constexpr std::size_t kCacheLineSize = 64; // 示例目标机已确认；项目常量优先

struct alignas(kCacheLineSize) WorkerCounter {
    std::atomic<std::uint64_t> value{};
};

struct WorkerStats {
    std::array<WorkerCounter, 2> completed{};
};
```

访问点相应改为：

```cpp
stats.completed[index].value.fetch_add(1, std::memory_order_relaxed);
```

这里不能只给整个 `WorkerStats` 添加 `alignas(64)`：那只保证对象起始地址，不会分隔两个数组元素。也不能只在 `atomic` 后写一个未经计算的 padding，因为不同平台的 `sizeof`、对齐和数组步长可能不同。
