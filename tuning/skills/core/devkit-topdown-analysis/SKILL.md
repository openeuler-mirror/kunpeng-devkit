---
name: devkit-topdown-analysis
description: Top-down微架构分析技能。分析devkit_topdown.txt数据文件，或对话里有topdown指标相关信息时（比如memory bound、frontend bount、L1 bound等）触发，提取微架构瓶颈指标、识别Frontend/Backend Bound、生成微架构级调优建议。当用户需要微架构分析或编译器优化时触发此技能。
---

## 适用场景

当用户提供`devkit_topdown.txt`数据文件，或需要：
- 微架构瓶颈分析
- 编译器优化
- CPU性能调优
- Frontend/Backend Bound分析

---

## 数据文件

**输入文件**: `devkit_topdown.txt`


## 指标小节

### Frontend Bound

**根因**：前端取指或解码成为瓶颈，无法及时供给后端指令。

**优化手段**：
1. 检查编译器优化等级是否足够（建议 -O2 及以上）
2. 启用 LTO（链接时优化）或 PGO（反馈导向优化）

---

### Ptag_stall

**根因**：大量并发 load/store 导致 Physical Register Tag 耗尽，新指令无法分配寄存器标签而停顿。

**优化手段**：
1. 启用大页，减少 TLB miss
2. 修改代码提高空间局部性，降低并发访存压力

详细：  
Ptag 指的是 Physical Register Tag（物理寄存器标签），是乱序执行流水线中 rename 阶段的核心资源。  
Ptag 的作用：指令进入 → Rename → 分配 Ptag → 进入 ROB/Issue Queue → 执行 → 广播 Ptag → 提交释放 Ptag

Ptag_stall 的成因

当空闲 Ptag 列表为空时，rename 阶段无法为新指令分配物理寄存器标签，流水线停顿 → Ptag_stall

典型触发场景：

- 大量长延迟指令（如 cache miss 的 load）在 ROB 中飞行，长时间持有 Ptag 不释放
- 并发独立的内存访问越多，同时占用的 Ptag 越多
- Ptag 池耗尽 → 新指令无法 rename → 停顿
---

### Memory Bound

**根因**：访存延迟或带宽成为后端主要瓶颈。

**优化手段**：
1. 通过 `perf spe` 采集分析代码访存数据
2. 分析子项（DTLB / Misalign / Resource Full 等）定位具体 bound 类型

---

### DTLB

**根因**：TLB 缺失导致地址翻译延迟。

**优化手段**：
1. 内核开启 64K 大页
2. 使用静态大页
3. 绑核减少进程迁移带来的 TLB 重填开销
4. 链接 jemalloc 优化内存分配

---

### Misalign

**根因**：访存地址未对齐，硬件需要多次访问才能完成一次读写。

**优化手段**：
1. 编译选项强制对齐：`-falign-functions=64 -falign-loops=64`

---

### Resource Full

**根因**：L1D cache 内部资源（MSHR、Fill Buffer、Writeback Buffer、Store Buffer）耗尽，新访存请求无法被 L1D 接收。

**优化手段**：
1. 减少 L1D miss，降低对内部资源的占用

---

### Instruction Type

**根因**：特殊 load 指令（原子、独占、NC 设备、load64）无法走 L1D 快速路径，被取消后重新发射走专用路径，产生额外延迟。

**优化手段**：
1. 合并批量原子操作，将多个原子操作缩减为一次

详细：  
The counter counts each load uop which is canceled because it is a special load instruction (atomic, load exclusive, NC device load, load64) when
it is L1 bound.  

即：当 L1D 是瓶颈时，因 load uop 属于特殊指令类型而被取消并重新发射的次数。  
为什么特殊 load 会被 cancel？  
普通 load（LDR）走 L1D 的快速路径：虚地址索引 → TLB 查物理 tag → cache line 比较 → 数据返回，全流水线化。

---

### Forward Hazard

**根因**：store 和 load 存在数据依赖（store→load forwarding 失败或延迟），无法并发执行多条 load/store。

详细：  
Store 指令写入数据后，数据先进入 Store Buffer，尚未 commit 到 L1D cache。如果紧接着一条 Load 指令读取同一地址，Load 无法从 L1D cache 获取数据，
必须等待 Store Buffer 转发（Store-to-Load Forwarding）。  

Store buf[0] = val   → 数据进入 Store Buffer（未 commit 到 L1D）  
                          ↓
Load  val = buf[0]   → 必须等 Store Buffer 转发数据，产生停顿  

---

### Structure Hazard

**根因**：多条访存微操作在同一周期竞争同一 L1D pipeline 硬件资源，资源有限导致部分 uop 等待。

详细：  
Structure Hazard（结构冲突）是 L1D cache 访问管线中的硬件资源竞争。当多条访存微操作在同一周期需要同一个 L1D pipeline 硬件资源（tag 比较单元、
数据阵列读端口、地址生成器等），但该资源只有有限份数，部分微操作必须等待，产生停顿。  

---

### Snoop Pending

**根因**：L2 正在等待其他核的 snoop 响应，多核间缓存一致性协议带来延迟。

**优化手段**：
1. 减小脏行比例，降低 snoop 触发频率
2. 预取到 L2，减少缓存行驱逐次数
3. 使用 non temporal store，数据直写 L3
4. 避免多核写同一 L3 区域，降低共享
5. 用 `devopt` 分析是否存在伪共享问题

详细：  
三个条件同时满足：  

1. 核心因 L1D miss 而停顿 — load 指令在等数据  
2. L2 未发出 demand 请求到 L3 — 请求停留在 L2 内部，还没发出去  
3. L2 中有请求处于 snoop pending 状态 — L2 正在等待其他核的 snoop 响应  
触发场景：脏行驱逐时的 snoop 协议  

---

### L3 Bound

**根因**：L3 cache 访存延迟或带宽成为瓶颈，可能涉及跨片访存或伪共享。

**优化手段**：
1. 用 `devopt` 分析伪共享问题
2. 用 `devkit tuner numafast` 分析跨片访存
3. 采集 L2 miss 事件分析代码，尝试预取优化
