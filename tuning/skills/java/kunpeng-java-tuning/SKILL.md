---
name: kunpeng-java-tuning
description: 在 Kunpeng (aarch64/ARM) 处理器 + BishengJDK 上调优和优化 Java 应用性能。应用一套 8 项经过验证的优化清单，覆盖 fastutil 容器替换、ITLB miss 降低（JBolt / 代码大页）、多态内联、毕昇融合JDK + 分代 ZGC 升级、AllocatePrefetchLines 调优、NUMA-aware 分配、KAE 加解密加速、以及 KAE 加速的 GZIP/ZIP。当用户提到 Java 性能、JVM 调优、GC 停顿、热点、profiling（topdown、perf、flame graph）、ITLB/cache miss、BishengJDK、毕昇、Kunpeng、TaiShan、ARM/aarch64 优化，或正在进行 Java 性能调优/优化、想要加速运行在 Kunpeng 硬件上的 Java 应用时——即使没有明确说"调优"或点名平台——都应使用本 skill。当用户分享 JDK 版本/厂商信息、JVM flags、profiling 输出、topdown CSV，或使用了 HashMap/HashSet（装箱 key）、加解密（javax.crypto/Cipher/SSL）、GZIP/ZIP 的 Java 代码并寻求优化建议时，也应触发。
---

# Kunpeng Java 性能调优

本 skill 针对运行在 Kunpeng (aarch64) 处理器 + BishengJDK 上的 Java 负载，应用一套 8 项经过实战检验的优化清单。每条规则都有**检测条件**（在用户的数据/代码中寻找什么）和**建议**（改什么、如何开启）。各特性的确切 flag 见 `references/bisheng-features.md`（该文件基于毕昇 JDK 8/11/17/21 官方 wiki 整理）。

目标不是把 8 条规则一股脑倒给用户，而是根据用户提供的证据匹配规则，产出一份按优先级排序、可执行的建议清单。

## 本 skill 的适用场景

广泛触发。用户可能在 Kunpeng/TaiShan 服务器上，使用 BishengJDK（或可切换过来的其他 JDK），想要更快。你应预期收到的输入：

- **Profiling 数据**：topdown 分析（frontend-bound、backend-bound、bad-speculation、retiring）、`perf stat`/`perf record` 输出、ITLB miss 率、LLC miss 率、flame graph、热点方法列表。
- **JVM/JDK 配置**：`java -version` 输出、厂商（Oracle/OpenJDK/Bisheng/毕昇融合JDK/Temurin）、GC 设置、在用的全部 `-XX:` flags。
- **运行时/进程信息**：`numactl --hardware`、`/proc/cpuinfo`、`lscpu`、内存拓扑、进程 RSS。
- **代码**（相关时）：展示容器、加解密或压缩的源码。某些规则（1、8、9）本质上是代码驱动的，当 profiling 指向这些领域时，应主动要求看相关代码。

如果用户未提供足够信息来评估某条规则，要么请求补全缺失数据，要么在报告中注明该规则"无法评估 —— 需要某数据"。

## 如何使用本 skill

1. **收集上下文。** 总结你能推断出的环境：JDK 厂商 + 版本、在用 GC、处理器/NUMA 拓扑、以及主导的 profiling 信号（例如"backend-bound 62%，ITLB miss 8%"）。如果某条高优先级规则缺少关键信息，在产出最终建议前先问用户——但只问你确实会用到的。

2. **逐条评估 8 条规则。** 对每条规则，给出以下三种结论之一：**适用**（证据符合检测条件）、**不适用**（证据表明不相关，或已优化）、**无法评估**（数据缺失）。诚实地应用规则的检测逻辑——不要推荐用户已开启的优化，也不要推荐数据不支持的优化。

3. **产出建议**，使用下文格式。只有检测到**可以进行调优**的规则（证据符合检测条件、且当前未优化）才进入建议清单，按影响从大到小排序。已是最优、不相关、或数据缺失无法判定的规则一律不出现。

4. **要具体。** 每条建议给出确切的 JVM flag、确切的代码改动，或确切的配置文件编辑。模糊的建议（"考虑调优 prefetch"）没有用——给出具体值及其背后的理由。


## 8 条调优规则

优先级指引："High" 规则是基础性或影响面广的；"Medium" 规则视情况而定；"Low" 规则是精调。始终让证据覆盖这些默认值——匹配到强 profiling 信号的规则无论默认值如何都是 High。

---

### 规则 1 — 用 fastutil 替换装箱基本类型作为 key 的容器

**优先级:** High（适用时）

**检测:** 代码中使用 `HashMap`、`HashSet` 或 `ConcurrentHashMap`，其 **key**（理想情况下还有 value）是装箱基本类型包装类：`Long`、`Integer`、`Short`、`Byte`、`Double`、`Float`。寻找类似 `HashMap<Long, Integer>`、`HashSet<Long>`、`Map<Integer, X>` 的声明，尤其是在热路径或高频代码中。**间接信号（代码不可见时）：** Java 类直方图（`jmap -histo` / JFR 对象直方图）中 `java.lang.Long`、`java.lang.Integer` 等包装类实例数偏多，且火焰图中 `HashMap.*`、`putVal`、`getNode`、`hash` 等容器操作帧占比可观——此时应提示用户排查是否存在以装箱基本类型为 key 的容器可优化。

**建议:** 替换为对应的 fastutil 类型特化类。这消除了每次 `get`/`put`/`contains` 的自动装箱，并大幅减少内存（无包装对象、无每条目装箱）。fastutil 把基本类型直接存在底层数组里。

**如何应用:** 详见 `references/fastutil-mappings.md` 的完整类型→类映射表。要点：加 Maven 依赖 `net.sf.fastutil:fastutil`；`HashMap<Long,Integer>` → `Long2IntOpenHashMap`；`merge(k,v,fn)` → `addTo(k,v)`（无 lambda、无装箱）；注意 absent key 默认返回 0 的迁移坑；fastutil 不提供并发 map（保留 `ConcurrentHashMap` 或分片加锁）。

**补充（无法改数据结构时）:** 毕昇 JDK 11+ 的 **LazyBox** 特性（`-XX:+UnlockExperimentalVMOptions -XX:+AggressiveUnboxing -XX:+LazyBox`）在 C2 中推迟装箱时机，减少多余装箱。但有对象一致性坑（`==` 比较可能失效，需改 `equals()`），详见 `references/bisheng-features.md`。

**为何有效:** 原生 `HashMap<Long,V>` 中每个 `Long` key 都是堆上分配的包装对象，查询时仍要装箱。类型特化 map 两头都省，降低分配率和每次查询 CPU——往往是查找密集型负载单项 ROI 最高的代码改动。

---

### 规则 2 — 降低 icache/iTLB miss（代码段大页 + JBolt 重排）

**优先级:** icache/iTLB miss 率升高时为 High

**检测:** profiling 显示**icache/iTLB miss 率偏高**。来源：`perf stat` 中 `iTLB-load-misses`/`icache-misses` 偏高、topdown 显示可观的 **frontend-bound** 时间（指令取回停顿）、或 flame graph 中时间集中在大段代码段。典型场景：JIT 编译的热方法多且在 code cache 中分布散乱。aarch64 上 ITLB/icache 小，大的代码工作集会频繁 miss。

**建议:** 两条互补的杠杆，可叠加：
- **杠杆 A — 代码段大页（通用、简单）**：把 code cache 映射到 2M 大页（替代 4K），每个 TLB 表项覆盖多得多的指令，直接减少 ITLB 表项压力。任何 JDK 均可用，无需额外软件包。
- **杠杆 B — JBolt 重排（毕昇 JDK 专属、更深）**：采样热点方法及调用链，用算法把热方法集中重排，缩小热代码 working set，降低 icache/iTLB miss。仅与毕昇 JDK 版本有关，无需额外安装软件包。

**如何应用:**

**杠杆 A — 代码段大页：**
1. 先在 OS 配置大页（2M）。按 code cache + heap 估算页数，例如 16G heap ≈ 8192 页，留余量设 9216：
   ```bash
   echo 9216 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
   cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages   # 确认
   ```
   或用透明大页（THP，更省心但可能增大延迟峰值）：`echo madvise > /sys/kernel/mm/transparent_hugepage/enabled`。
2. JVM 加 `-XX:+UseLargePages`（必要时 `-XX:LargePageSizeInBytes=2m`）。该 flag 主要覆盖 heap，部分 JDK 版本也覆盖 code cache / metaspace。
3. 用 `-XX:+PrintCodeCache` 确认 code cache 是否走了大页（版本相关，若该版本不支持 code cache 大页，则本杠杆只对 heap 生效，ITLB 收益有限——此时 JBolt 更重要）。

**杠杆 B — JBolt 重排：**
支持毕昇 JDK 11/17/21（分别从 11.0.27、17.0.14、21.0.7 起），仅需使用对应版本的毕昇 JDK，无需额外安装软件包。前提：JFR 未关闭（不能有 `-XX:-FlightRecorder`）、C2 使能（不能 `-Xint`）、Segmented CodeCache 未关（不能有 `-XX:-TieredCompilation`/`-XX:-SegmentedCodeCache`/`-XX:ReservedCodeCacheSize<240M`）。

推荐"一步式"模式（自动采样+重排，可多次）：
```
java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt -Xlog:jbolt=info -jar app.jar
```
运行中可用 jcmd 控制：`jcmd <pid> JBolt.start [duration=<秒>]` 触发采样重排、`JBolt.stop` 立即停止并应用、`JBolt.abort` 停止不应用、`JBolt.dump filename=<file>` 导出顺序表。`-Xlog:jbolt=info` 输出 `JBolt reordering succeeds.` 即生效。关键参数：`-XX:JBoltSampleInterval`（采样时长，默认 600 秒）、`-XX:JBoltCodeHeapSize`（默认 8MB，建议设为原 Non-profiled 段大小的 1/4~1/2，用 `-XX:+PrintCodeCache` 查看原值）。另有"两步式"模式（DumpMode 采样→LoadMode 加载顺序表），适合离线生成顺序表的场景，详见 `references/bisheng-features.md`。

**注意：JBolt ≠ JBooster** —— JBooster（`-XX:+UseJBooster`，JDK 17）是启动加速（Lazy AOT/CDS），与 ITLB 无关，别搞混。

**为何有效:** JIT 默认按编译时机把方法代码追加到 code cache，热方法多且散乱时热代码跨多页 → icache/iTLB miss 高、前端瓶颈。大页（杠杆 A）用 2M 页让每个 TLB 表项覆盖更多指令，减少表项数；JBolt（杠杆 B）把热方法及调用链集中重排，缩小热 working set，让热代码落进少数 icache 行/TLB 表项。前者减"每页覆盖量"，后者减"需覆盖的总量"，互补叠加。

---

### 规则 3 — 为少数子类型的调用点优化多态内联

**优先级:** Medium

**检测:** flame graph 中出现较多 **`vtable_stub`** 帧——这是 HotSpot 处理未被内联的虚调用的分派 stub，大量出现说明虚调用未内联、走了 vtable 查表路径。进一步确认该调用点的接收者类型有**少量具体实现（约 3 到 5 个）**：不是 bimorphic（恰好 2 个，HotSpot 已能内联），也不是真正的 megamorphic（很多类型，内联无意义）。可用 `-XX:+PrintInlining` 确认是"too many receivers"导致未内联。

**建议:** 多态内联优化能让 JIT 对 3–5 个接收者类型推测性内联，仅在类型失配时回退 vtable。但该优化**不是标准 flag**，需要联系 BishengJDK 专家出一个特定 POC 版本才能使能。因此给出两条路径：立即生效的**设计级修复**（无需等 POC），以及走 **BishengJDK POC** 获取 JIT 级多态内联。

**如何应用:**
1. **首选（设计级修复，立即生效、有保障）**：若子类型固定（如 4 个），把 `List<RequestProcessor>` 换成持有具体类型字段的固定 Pipeline，每个 `handle` 调用变为单接收者（monomorphic）→ C2 内联，`vtable_stub` 帧消失。或用 enum-keyed `switch`（编译为 tableswitch 直接调用，无 vtable）。适用于能改代码的场景。
2. **BishengJDK POC 路径（无法改代码、或希望 JIT 自动处理时）**：当 flame graph 的 `vtable_stub` 占比高、且确认是 3–5 子类型的多态调用点，联系 BishengJDK 专家提供含多态内联优化的 POC 版本。这是"改不动业务代码时的 JIT 级解法"。
3. 先确认调用点确实是 3–5 子类型而非 megamorphic（重新检查类层次）。2 个→原生 bimorphic 已生效，无需本规则；**5 个以上→多态内联效果也不佳**，需重新设计分派。

**为何有效:** `vtable_stub` 意味着每次调用都做 vtable 加载 + 间接跳转，阻碍内联及其启用的常量折叠/逃逸分析。多态内联让常见路径变成直接调用；设计级修复则从源头消除虚分派。两者都能让 `vtable_stub` 帧从火焰图消失。

---

### 规则 4 — 升级到毕昇融合 JDK 并使用分代 ZGC

**优先级:** High（基础性，JDK 较旧/非 Bisheng 时）

**检测:** 运行时是**非 Bisheng 厂商的 JDK 8，或 1.8.412 以下的 BishengJDK 8**，或任何缺乏现代低停顿 GC 的 JDK。检查 `java -version` 和厂商字符串。

**建议:** 对 JDK 8 用户，首选升级到**毕昇融合 JDK**（基于 bishengjdk-8 + bishengjdk-21，支持 Java 8 API 但内含 JDK 21 特性），并选择**分代 ZGC**。融合 JDK 可直接替换 OpenJDK 8，无需改代码即可拿到分代 ZGC、JBolt、CompactString 等。融合 JDK 的分代 ZGC 开启：`-XX:+UseZGC -XX:+ZGenerational`。

**如何应用（按版本）:**
- **JDK 8 用户 → 毕昇融合 JDK**：`-XX:+UseZGC -XX:+ZGenerational`（分代）或 `-XX:+UseZGC`（非分代）。默认 GC 是 G1GC；选 ZGC 需显式指定。
- **BishengJDK 11**：aarch64 上扩展支持了 ZGC（原生 OpenJDK 11 不支持 aarch64 ZGC），但为**非分代**：`-XX:+UnlockExperimentalVMOptions -XX:+UseZGC`。无分代模式，计划后续迁 17/21 拿分代。
- **BishengJDK 17**：ZGC + TBI 优化：`-XX:+UnlockExperimentalVMOptions -XX:+UseZGC -XX:+UseTBI`（TBI 仅 aarch64，用 ARMv8 Top Byte Ignore 实现 Colored Pointer，dTLB miss 降至 76%）。
- **BishengJDK 21**：分代 ZGC 为默认：`-XX:+UseZGC`。
- **基线调参**：`-Xms`=`-Xmx`；`-XX:SoftMaxHeapSize`；`-XX:ZUncommitDelay`。注意 ZGC 的 RES 可达 Xmx 3 倍（三视图映射，正常）；需调大 `/proc/sys/vm/max_map_count`。详见 `references/bisheng-features.md`。

**为何有效:** 旧 JDK 8（尤其非 Bisheng）缺少多年 aarch64 JIT 工作、容器感知、低停顿 GC。分代 ZGC 大幅削减大 heap 停顿，年轻代过滤减少标记量——大 heap GC 吞吐第一大招。融合 JDK 让 JDK 8 用户零代码改动拿到这些。

---

### 规则 5 — 根据 topdown 数据调优 AllocatePrefetchLines

**优先级:** Medium（精调，数据驱动）

**检测:** topdown / cache 数据显示**backend-bound** 时间升高，且与**新分配对象上的 L1/L2 miss** 相关（分配路径占主导，对象在被缓存预热前就被访问）。结合进程的对象大小分布和分配率。

**建议:** 调整 `-XX:AllocatePrefetchLines`（及相关 `-XX:AllocatePrefetchStyle`、`-XX:AllocatePrefetchStepSize`、`-XX:AllocateInstancePrefetchLines`），使 JIT 的分配预取匹配实际访问模式。

**如何应用:**
1. 读 topdown backend-bound 百分比和分配点周围的 LLC/L1 miss 率。
2. 决定取值（在 Kunpeng aarch64 上最优值远高于直觉）：
   - 对象小且立即全部访问 → 更少、更紧密的预取行。
   - 对象中等且只有部分字段热 → 把 `AllocatePrefetchLines` 调到热字段跨度。
   - 访问模式稀疏/指针追逐 → `AllocatePrefetchStyle=2` 配合更大步长。
   - **实测基准**：在某 Kunpeng 负载上，`AllocatePrefetchLines=27` 带来约 **8% 提升**；但 `=35` 时性能**劣化**。说明该参数**非单调**——存在拐点，过度预取不仅无益还会拖累。
   - 调优策略：从默认（通常 `1`）出发，**先试 27**（已验证的有效区间），然后二分探查上下界（如 24、30），每步测 backend-bound / 吞吐；越过拐点（本例 27→35 之间）立即回退。
3. 通过 `-XX:AllocatePrefetchLines=N` 应用，并重新测量 backend-bound 占比。

**为何有效:** JIT 可对每次 TLAB 分配发出预取；预取的 cache 行*数量*必须匹配对象实际被消费的方式。太少 = 首个字段访问停顿；太多 = 预取了用不到的 cache 行，既浪费内存带宽、污染 cache，又可能与有效负载争用预取资源。Kunpeng aarch64 的 cache 行 / TLB 特性使最优值偏高（实测 27 附近），但拐点也陡（35 即劣化）——所以这是个"先靠实测基准定锚点、再小幅二分"的参数，而非线性"越大越好"。

---

### 规则 6 — 在 BishengJDK 8/11 上开启 NUMA-aware 分配

**优先级:** High（多节点 NUMA 硬件上）

**检测:** 运行时是 **BishengJDK 8 或 11**，使用 G1GC，且 JVM flags 中**没有** `-XX:+UseNUMA`，且机器是多节点 NUMA（用 `lscpu` 显示多个 NUMA 节点，或 `numactl --hardware` 验证）。

**建议:** 开启 G1GC 的 NUMA-Aware 特性。毕昇 JDK 8/11 为 G1GC 扩展了 NUMA-Aware 支持（原生 OpenJDK 8/11 的 G1 不支持）；**仅 G1GC 支持，ParallelGC 不支持**。开启后 TLAB、Eden、Survivor 的 Region 选取采用就近原则，CPU 优先使用本地内存。实测 SPECjbb2015 内存读写性能提升 20–30%。

**如何应用:**
1. 确认多节点 NUMA：`numactl --hardware` 应列出 >1 节点。
2. JVM 跨多节点时加 `-XX:+UseG1GC -XX:+UseNUMA`（**仅 G1GC 下生效，ParallelGC 不支持**）——G1GC 的 Region 选取采用就近原则，各线程优先使用本地内存。
3. 若将整个 JVM 绑定到单个节点（`numactl --cpunodebind=N --membind=N java ...`），则所有分配只落该节点，**无需再使能 `-XX:+UseNUMA`**。
4. JDK 17/21 / 融合 JDK：ZGC 自身 NUMA-aware，无需 `-XX:+UseNUMA`。详见 `references/bisheng-features.md`。

**为何有效:** 多路/多节点 Kunpeng 上，默认 first-touch 分配可能把线程对象散布到各节点，每次访问付出跨节点延迟。NUMA-aware TLAB 保持分配本地化，大而低风险。

---

### 规则 7 — 为加解密负载开启 KAE Provider

**优先级:** High（加解密为热点时）

**检测:** 应用使用加解密 —— TLS/SSL 握手、`javax.crypto.Cipher`、`MessageDigest`、`Mac`、`KeyAgreement`、RSA/AES/SM2/SM3/SM4，或大量哈希。在 flame graph 中表现为 `sun.security.*`、`libcrypto` 里的时间。

**建议:** 开启 **KAE Provider** —— 鲲鹏 920 片上加解密加速器的 JCA Provider。Provider 类名是 `org.openeuler.security.openssl.KAEProvider`（**不是** `org.kunpeng.security.*`）。

**如何应用:**
1. 确认前提：Taishan 平台 + KAE 加速引擎软件已安装；OpenSSL **1.1.1a+**（**不支持 OpenSSL 3**）；KAE2.0 需 root 安装。
2. 注册 Provider（两种方式）：
   - Security API：`Security.insertProviderAt(new KAEProvider(), 1);`
   - java.security 文件：JDK 8 改 `jre/lib/security/java.security`，JDK 9+ 改 `conf/security/java.security`，加 `security.provider.1=org.openeuler.security.openssl.KAEProvider`，其余 provider 顺延。
3. 设环境变量 `export OPENSSL_ENGINES=/usr/local/lib/engines-1.1`。KAE2.0 需 `-Dkae.libcrypto.useGlobalMode=true`。
4. **关键默认值**：`kae.aes.useKaeEngine` 和 `kae.hmac.useKaeEngine` **默认为 false**（AES/HMac 默认走软算！）。TLS 的 AES/GCM 需显式在 `kaeprovider.conf` 或系统属性中设 `kae.aes.useKaeEngine=true` 才卸载到硬件。摘要/SM4/RSA/DH 默认走硬件。
5. 支持算法：MD5/SHA256/SHA384/SM3（摘要）；AES（ECB/CBC/CTR/GCM）；SM4（ECB/CBC/CTR/OFB）；HMac；RSA（512–4096）；DH；ECDH；RSA 签名。**EC 在 Kunpeng 920 上不支持硬件加速**。
6. 验证：`-Dkae.log=true`，看 `${user.dir}/kae.log`，"enable KAE hardware acceleration" = 硬件生效。
7. 支持版本：BishengJDK 8（8u342 起，增强 8u352 起）、11、17（17.0.12 起）。详见 `references/bisheng-features.md`。

**为何有效:** 硬件加解密卸载大幅降低 TLS/cipher 负载的 CPU（对称加解密往往差一个数量级），把核让给应用逻辑。

---

### 规则 8 — 开启 KAE 加速的 GZIP / ZIP

**优先级:** Medium-High（压缩为热点时）

**检测:** 应用使用 `java.util.zip.GZIPInputStream`/`GZIPOutputStream`、`Deflater`/`Inflater`、`ZipInputStream`/`ZipOutputStream`，或基于它们的库（HTTP gzip、日志压缩、备份流水线），且压缩出现在 profile 中。

**建议:** 开启 KAE 加速 ZIP/GZIP，把 deflate/inflate 卸载到鲲鹏 920 硬件。**注意开启方式是 `LD_PRELOAD` + `-D` 系统属性，不是 `-XX:` flag**。

**如何应用:**
1. 安装 KAEzip（前置条件）。
2. 预加载 KAE libz.so：
   ```
   export LD_PRELOAD=/usr/local/kaezip/lib/libz.so
     # 或
   export LD_LIBRARY_PATH=/usr/local/kaezip/lib/
   ```
3. JVM 参数：`-DGZIP_USE_KAE=true`
4. 支持的 class：`GZIPOutputStream`、`GZIPInputStream`、`ZipOutputStream`、`ZipInputStream`。KAE zlib 支持 ZLIB 和 GZIP 格式，同步模式，压缩比 ≈2。
5. 限制：仅 aarch64；**不支持流式解压**；`avail_in` 为 1 时有已知 bug。
6. 验证：看 `/var/log/kaezip.log`，出现 `kae zip deflate init success` 代表硬件生效。
7. 支持版本：自毕昇 JDK 8u422 起支持。详见 `references/bisheng-features.md`。

**为何有效:** 压缩是 CPU 密集的；KAE deflate 卸载减少压缩/解压路径上的 CPU，提升 IO 相关负载（日志、HTTP、备份）的吞吐。

---

## 参考资料

当某条建议需要确切的 flag/provider/依赖时，查阅：

- `references/fastutil-mappings.md` —— 完整的 fastutil 类型→类映射表，包括 Object-value 情况、set、并发注意事项、以及 absent-key 默认值坑。
- `references/bisheng-features.md` —— 毕昇 JDK 8/11/17/21 特性的自包含总结：JBolt（代码重排，含两模式 + jcmd）、多态内联（含 flag 不确定 + POC 路径）、分代 ZGC（含融合 JDK/11/17/21 各版本对照 + TBI）、NUMA（G1GC 20–30%）、KAE Provider（含正确类名 + AES 默认软算的坑）、KAE ZIP（含 `LD_PRELOAD` + `-DGZIP_USE_KAE=true`）、LazyBox、JProfileCache、DynamicMaxHeap。
- `references/boostkit-jdk-accel.md` —— 鲲鹏 BoostKit 系统库 毕昇 JDK 加速库完整文档原文（JBooster/JProfileCache/DynamicMaxHeap/堆转储增强的权威出处），需要更深细节时查阅。

本 skill 自包含，不依赖外部项目目录。
