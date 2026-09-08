# BishengJDK 特性开启参考

本文件基于毕昇 JDK 8 / 11 / 17 / 21 的官方 wiki 文档整理，记录各特性的确切开启方式与 flag。**始终用已安装的 BishengJDK 确认** —— 跑 `java -XX:+PrintFlagsFinal -version | grep -i <feature>` 并对照该版本 release notes，再向生产推荐。flag 名在主版本间会变。

> 重要区分：**JBolt**（代码段大页，降低 ITLB miss）与 **JBooster**（启动加速，Lazy AOT/CDS）是两个完全不同的特性，名字相近但无关。本 skill 的规则 2 指的是 **JBolt**。

## 毕昇融合 JDK（规则 4 的背景）

毕昇融合 JDK 基于 openEuler/bishengjdk-8 + bishengjdk-21 联合开发，**支持 Java 8 API 但内含 JDK 21 的特性**（ZGC、分代 ZGC、CompactString、Xlog、AggressiveCDS、JBolt 等）。绝大多数场景可直接替换 OpenJDK 8 并获得更好性能。这是规则 4 中 JDK 8 用户的首选升级目标——无需改代码即可拿到分代 ZGC 和 JBolt。

- 默认 GC：G1GC（`-XX:+UseG1GC`，默认启用）
- 分代 ZGC：`-XX:+UseZGC -XX:+ZGenerational`
- 非分代 ZGC：`-XX:+UseZGC`
- CompactString：默认启用，减少 String 内存占用
- 基础 CDS：默认启用（`-Xshare:on`），降低启动时间
- 日志统一为 Xlog 形式（`-Xlog:gc*` 等，不再用 `-XX:+PrintGCDetails`）

## JBolt — JIT 代码布局重排（规则 2）

JBolt **不是**代码大页，而是**代码布局重排**：利用采样获取运行时 JIT 方法的热点和调用链关系，再通过算法把热方法代码以较优方式集中重排，提高空间局部性，降低 icache/iTLB miss 率。主流 JIT 默认按编译时机把方法代码追加到 code cache，热方法多且散乱时，热代码跨多页 → icache/iTLB miss 高、前端瓶颈。JBolt 把热方法及调用链集中，让热 working set 收缩进少数 icache 行/TLB 表项。

> JBolt 与**代码段大页**是互补的两条路，可叠加：
> - **代码段大页**（通用 `-XX:+UseLargePages`，任何 JDK 可用）：把 code cache/heap 映射到 2M 页，减少 TLB 表项数（"每页覆盖量"）。
> - **JBolt 重排**（毕昇 JDK 专属）：缩小热 working set（"需覆盖的总量"）。
>
> **代码段大页开启**（杠杆 A）：
> 1. OS 配大页：`echo 9216 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`（按 heap+code cache 估算，留余量）；或 THP：`echo madvise > /sys/kernel/mm/transparent_hugepage/enabled`。
> 2. JVM 加 `-XX:+UseLargePages`（必要时 `-XX:LargePageSizeInBytes=2m`）。
> 3. `-XX:+PrintCodeCache` 确认 code cache 是否走大页（版本相关；若该版本不支持 code cache 大页，只对 heap 生效，ITLB 收益有限——此时 JBolt 更重要）。

### 版本前提

- **支持版本**：毕昇 JDK 11 / 17 / 21，分别从 **11.0.27、17.0.14、21.0.7** 子版本后开始支持，仅与 JDK 版本有关，无需额外安装软件包。
- **使能前提**（缺一则无法使用）：
  - JFR 未关闭（默认支持，不能有 `-XX:-FlightRecorder`）。
  - C2 编译器使能（不能 `-Xint`；AppCDS dump 等不使能编译器的场景也不可用）。
  - Segmented CodeCache 保留（Java 9 后默认使能；`-XX:-TieredCompilation`、`-XX:-SegmentedCodeCache`、`-XX:ReservedCodeCacheSize<240M` 会关闭导致不可用）。
- **软性限制**（不致命但可能异常）：Java 堆极小时 JFR 有内存要求（可用 `-XX:StartFlightRecording` 预试）；`--limit-modules` 模块裁剪可能使特权级隐式加载范围与预期不符。

### 方法一："一步式"模式（推荐）

一次运行自动完成采样及重排，支持多次采样重排。运行中可用 jcmd 控制。

```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt \
  -Xlog:jbolt=info -jar app.jar
```

**参数：**
- `-XX:JBoltSampleInterval`：采样持续时间（秒），默认 600。
- `-XX:JBoltCodeHeapSize`：JBolt 堆大小，默认 8MB。编译方法多的场景可能不够，建议设为原 Non-profiled 段大小的 **1/4~1/2**（用 `-XX:+PrintCodeCache` 查看原值，例：non-profiled used=16M → 设 4M~8M）。大小需与 page-size 对齐。
- （仅 JDK 11）`-XX:JBoltRescheduling=hh:mm,hh:mm`：每天固定时间自动采样，最多 10 个不重复时间（如 `07:30,16:30`）。同时只允许一个 JBolt 工作流程，前一次未结束则该时间被跳过。

**jcmd 控制（仅一步式）：**
| 命令 | 作用 |
|---|---|
| `jcmd <pid> JBolt.start [duration=<秒>]` | 开启一次自动采样并在持续时间结束后应用重排 |
| `jcmd <pid> JBolt.stop` | 立即停止当前采样并应用重排 |
| `jcmd <pid> JBolt.abort` | 停止但不应用重排 |
| `jcmd <pid> JBolt.dump filename=<file>` | 导出当前顺序表 |

**生效标志**：`-Xlog:jbolt=info` 输出 `JBolt reordering succeeds.` 即生效。

### 方法二："两步式"模式

采样和重排分两阶段分开运行。不支持 jcmd 控制。

**步骤 1 — DumpMode 采样**（采样持续到程序退出，需自然退出或 Ctrl+C，异常退出不生成）：
```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt -XX:+JBoltDumpMode \
  -XX:JBoltOrderFile=order.log -Xlog:jbolt=info -jar app.jar
```

**步骤 2 — LoadMode 加载顺序表重排**（需应用启动一段时间后才进行重排）：
```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt -XX:+JBoltLoadMode \
  -XX:JBoltOrderFile=order.log -Xlog:jbolt=info -jar app.jar
```

### 不要与 JBooster 混淆

JBooster（`-XX:+UseJBooster`，JDK 17，17.0.12 起）是**启动加速**特性（Lazy AOT + Aggressive CDS + Class Loader Resource Cache），需要 server/client 架构，与 ITLB/icache 无关。两者名字相近但完全不同。

## 多态 / megamorphic inline cache（规则 3）

原生 HotSpot 的 bimorphic 内联每个调用点最多处理 **2** 个接收者类型。3–5 个子类型时标准 C2 不会内联（megamorphic，走 vtable）。

**检测信号**：flame graph 中出现较多 `vtable_stub` 帧——这是 HotSpot 未内联虚调用的分派 stub，大量出现即说明走了 vtable 查表。用 `-XX:+PrintInlining` 可进一步确认是"too many receivers"导致未内联。

**多态内联优化不是标准 flag，需要联系 BishengJDK 专家出特定 POC 版本才能使能。** 毕昇融合 JDK 的选项列表中有 `ExpandSubTypeCheckAtParseTime`、`UseVtableBasedCHA` 等与虚分派相关的 flag，但它们并非针对 3–5 子类型内联的专门开关。因此有两条路径：

- **设计级修复（立即生效、有保障）**：若子类型固定，把 `List<RequestProcessor>` 换成持有具体类型字段的固定 Pipeline，每个调用变单接收者（monomorphic）→ C2 内联，`vtable_stub` 帧消失。或用 enum-keyed `switch`（编译为 tableswitch 直接调用，无 vtable）。适用于能改代码的场景。
- **BishengJDK POC 路径（无法改代码时）**：当 `vtable_stub` 占比高、确认是 3–5 子类型的多态调用点，联系 BishengJDK 专家提供含多态内联优化的 POC 版本。
- 先确认调用点确实是 3–5 子类型而非 megamorphic（重新检查类层次）。2 个→原生 bimorphic 已生效，无需本规则；**5 个以上→多态内联效果也不佳**，需重新设计分派。

## 分代 ZGC（规则 4）

| 版本 | ZGC 能力 | 开启方式 |
|---|---|---|
| **毕昇融合 JDK**（8+21 融合） | 分代 + 非分代 | 分代：`-XX:+UseZGC -XX:+ZGenerational`；非分代：`-XX:+UseZGC` |
| **BishengJDK 11** | 非分代（aarch64 扩展支持，原生 OpenJDK 11 不支持 aarch64 ZGC） | `-XX:+UnlockExperimentalVMOptions -XX:+UseZGC` |
| **BishengJDK 17** | 非分代 + TBI 优化 | `-XX:+UnlockExperimentalVMOptions -XX:+UseZGC -XX:+UseTBI`（TBI 仅 aarch64） |
| **BishengJDK 21** | 分代为默认 | `-XX:+UseZGC`（分代默认开启） |
| **BishengJDK 8**（非融合） | 无 ZGC | 需升级到融合 JDK 或 11/17/21 |

**ZGC TBI 优化（BishengJDK 17，aarch64 独有）**：利用 ARMv8 TBI（Top Byte Ignore）硬件特性实现 Colored Pointer，替换 Multi Mapping 三视图方案。`-XX:+UseTBI` 仅 aarch64 提供。收益：dTLB Load Miss 降至基线 76%，L1-dcache 命中提升 7.65%（SPECjbb2015，鲲鹏 920）。

**ZGC 注意事项**：
- ZGC 用 mmap 三视图映射，`top` 中 RES 可达 Xmx 的 3 倍（正常现象）。
- 需调大 `/proc/sys/vm/max_map_count`，公式：`(max_capacity / zpagesizemin) * 3 * 1.2`。
- ZGC 默认开启 NUMA 支持（堆分配尽量 NUMA-local），但 JVM 限制在某个 CPU 子集时自动禁用。
- ZGC 不支持 Class unloading、`UseCompressedOops`、JVMCI(Graal)。
- 大页：`-XX:+UseLargePages` 配合 ZGC 提升性能，需先在 OS 配置大页池。
- `tmpfs`（`/dev/shm`）空间不足会报错，可用 `-XX:ZPath` 指定空间足够的路径。

**基线 ZGC 调参**：`-Xms`=`-Xmx`（避免 commit/uncommit 抖动）；`-XX:SoftMaxHeapSize`；`-XX:ZUncommitDelay`（默认 300s）；`-XX:ParallelGCThreads`（STW 阶段，默认 CPU 核数 60%）；`-XX:ConcGCThreads`（并发阶段，默认 12.5%）。

## NUMA-aware 分配（规则 6）

毕昇 JDK 8/11 为 G1GC 扩展了 NUMA-Aware 支持（原生 OpenJDK 8/11 的 G1 不支持）；**仅 G1GC 支持，ParallelGC 不支持**。

- **开启**：`-XX:+UseG1GC -XX:+UseNUMA`（仅 G1GC 下生效，ParallelGC 不支持）。
- **原理**：TLAB、Eden、Survivor 的 Region 选取采用就近原则，CPU 优先使用本地内存。
- **实测收益**：SPECjbb2015 内存读写性能提升 20–30%。
- **前提**：多节点 NUMA，用 `numactl --hardware` / `lscpu` 确认 >1 节点。
- **单节点绑定时无需 UseNUMA**：`numactl --cpunodebind=N --membind=N java ...` 将 JVM 绑定到单个节点后，所有分配只落该节点，无需再使能 `-XX:+UseNUMA`。
- **JDK 17/21 / 融合 JDK**：ZGC 自身 NUMA-aware，无需 `-XX:+UseNUMA`。

## KAE Provider — 硬件加解密（规则 7）

KAE = Kunpeng Accelerator Engine，鲲鹏 920 片上加解密/哈希加速器。JDK 以 JCA `Provider` 形式集成。

- **Provider 类名**：`org.openeuler.security.openssl.KAEProvider`（**不是** `org.kunpeng.security.*`）。
- **前提**：Taishan 平台 + KAE 加速引擎软件已安装；OpenSSL **1.1.1a+**（**不支持 OpenSSL 3**）；KAE2.0 安装需 root，非 root 用户需获取 `/dev/hisi_*` 和 `/var/log/kae.*` 读写权限。
- **注册方式 1（Security API）**：`Security.insertProviderAt(new KAEProvider(), 1);`
- **注册方式 2（java.security）**：
  - JDK 8：`$JAVA_HOME/jre/lib/security/java.security`
  - JDK 9+ / 17：`$JAVA_HOME/conf/security/java.security`
  ```
  security.provider.1=org.openeuler.security.openssl.KAEProvider
  security.provider.2=...  # 其余 provider 顺延，至少保留基础 provider 在最后作回退
  ```
- **环境变量**：`export OPENSSL_ENGINES=/usr/local/lib/engines-1.1`
- **KAE2.0 注意**：需加 `-Dkae.libcrypto.useGlobalMode=true` 或在 `kaeprovider.conf` 中设 `kae.libcrypto.useGlobalMode=true`（注意官方文档此处有拼写 `ture`，正确值应为 `true`）。
- **配置文件**：`jre/lib/kaeprovider.conf`（JDK 8）/ `conf/kaeprovider.conf`（JDK 9+），可用 `-Dkae.conf=<path>` 覆盖。系统属性优先级高于 conf 文件。

**支持算法**：摘要（MD5、SHA256、SHA384、SM3）；AES（ECB/CBC/CTR/GCM）；SM4（ECB/CBC/CTR/OFB）；HMac（MD5/SHA1/SHA224/SHA256/SHA384/SHA512）；RSA（512–4096 位）；DH；ECDH；RSA 签名。**EC 算法在 Kunpeng 920 上不支持硬件加速**（`kae.ec.useKaeEngine` 为预留，EC 仍走 OpenSSL 软算）。

**重要默认值**（8u352+ 的 `useKaeEngine` 属性）：

| 属性 | 默认 | 说明 |
|---|---|---|
| `kae.digest.useKaeEngine` | **true** | 摘要走硬件 |
| `kae.aes.useKaeEngine` | **false** | **AES 默认走软件！** 需显式设 true 才硬件加速 |
| `kae.sm4.useKaeEngine` | true | SM4 走硬件 |
| `kae.hmac.useKaeEngine` | **false** | **HMac 默认走软件！** |
| `kae.rsa.useKaeEngine` | true | RSA 走硬件 |
| `kae.engine.disabledAlgorithms` | `sha256,sha384` | 默认禁用 sha256/sha384 硬件 |

即：装好 KAE Provider 后，**AES 和 HMac 默认仍是软算**，需显式 `kae.aes.useKaeEngine=true`、`kae.hmac.useKaeEngine=true` 才会卸载到硬件。TLS 场景的 AES/GCM 务必检查此项。

- **日志**：`-Dkae.log=true`，日志默认在 `${user.dir}/kae.log`，用 `kae.log.file=<path>` 改路径。日志中 `enable KAE hardware acceleration` = 硬件加速生效，`Use openssl soft calculation` = 软算。
- **支持版本**：BishengJDK 8（8u342 起，属性增强 8u352 起）、BishengJDK 11、BishengJDK 17（17.0.12 起）。

## KAE 加速 GZIP / ZIP（规则 8）

通过动态库适配，使 `java.util.zip` 的 GZIP/ZLIB 相关 class 调用 KAE zlib 接口，把 deflate/inflate 卸载到鲲鹏 920 硬件。

- **开启（两步，缺一不可）**：
  1. 预加载 KAE libz.so（默认路径 `/usr/local/kaezip/lib/`）：
     ```
     export LD_PRELOAD=/usr/local/kaezip/lib/libz.so
       # 或
     export LD_LIBRARY_PATH=/usr/local/kaezip/lib/
     ```
  2. JVM 参数：`-DGZIP_USE_KAE=true`
- **不是** `-XX:+UseKaeZip` flag —— 是一个 `-D` 系统属性 + `LD_PRELOAD`。
- **支持的 class**：`GZIPOutputStream`、`GZIPInputStream`、`ZipOutputStream`、`ZipInputStream`。
- **KAE zlib 支持** ZLIB 和 GZIP 数据格式，同步模式，压缩比 ≈2。
- **限制**：仅 aarch64；**不支持流式解压**；当 `avail_in` 为 1 时有已知 bug（kae zlib 会调整为 0 导致错误）。
- **日志**：编辑 `/var/log/kaezip.cnf`（`debug_level=debug`），`export KAEZIP_CONF_ENV=/var/log`，日志在 `/var/log/kaezip.log`。开日志会降性能。
- **支持版本**：自毕昇 JDK 8u422 起支持。
- **验证**：观察 `/var/log/kaezip.log`，出现 `kae zip deflate init success`、`kaezip deflate end` 代表硬件生效。

## LazyBox — JIT 级装箱延迟（规则 1 的补充）

毕昇 JDK 11 引入。HotSpot C2 中推迟装箱时机，只在必要时装箱，减少多余装箱操作。适用于无法改数据结构、但热路径有装箱的场景（如泛型 `T extends Number` 的 `intValue()` 调用）。

- **开启**：`-XX:+UnlockExperimentalVMOptions -XX:+AggressiveUnboxing -XX:+LazyBox`（需同时开 AggressiveUnboxing）。
- **调试**：`-XX:+PrintLazyBox` 打印状态。
- **限制**：开启 `UseAOT` 和 `EnableJVMCI` 后不生效。
- **注意（重要缺陷）**：推迟装箱会导致装箱对象不一致 —— `Integer a = Integer.valueOf(v); data.a = a; data.b = a;` 开启后 `data.a == data.b` 可能为 **false**（两个不同对象）。因此涉及装箱类型比较时**避免 `==`，用 `equals()`**。

## JProfileCache — 预编译热点方法（额外特性，非 9 规则之一）

毕昇 JDK 8（8u452 起）。启动阶段编译线程与业务请求竞争 CPU，导致性能爬坡慢。JProfileCache 基于上次运行的 profiling 信息，再次启动时先触发热点方法编译，使进程快速抵达峰值性能。

- **场景**：CPU 资源受限、编译线程 CPU 占比高、启动后无法快速达峰值。
- **两步使用**：
  1. 生成编译信息文件：
     ```bash
     java -XX:-ClassUnloading -XX:-CMSClassUnloadingEnabled -XX:-ClassUnloadingWithConcurrentMark \
       -XX:+UnlockExperimentalVMOptions -XX:ProfilingCacheFile=jprofilecache.log \
       -XX:+JProfilingCacheRecording -XX:JProfilingCacheRecordTime=30 -jar app.jar
     ```
  2. 加载编译信息并预编译：
     ```bash
     java -XX:+UnlockExperimentalVMOptions -XX:+JProfilingCacheCompileAdvance -XX:-TieredCompilation \
       -XX:ProfilingCacheFile=jprofilecache.log -XX:JProfilingCacheDeoptTime=0 -jar app.jar
     ```
  3. 触发编译：`jcmd <pid> JProfilecache -notify`；检查：`jcmd <pid> JProfilecache -check`（返回 `Last compilation task has compile finished` 即完成）。
- **参数**：`JProfilingCacheRecording`（记录开关）、`JProfilingCacheRecordTime`（记录时长秒，默认 0）、`ProfilingCacheFile`（文件路径）、`JProfilingCacheCompileAdvance`（编译开关）、`JProfilingCacheDeoptTime`（退优化定时秒，默认 1200，设 0 取消）。
- **约束**：需关类卸载（`-XX:-ClassUnloading`；CMS 加 `-XX:-CMSClassUnloadingEnabled`；G1 加 `-XX:-ClassUnloadingWithConcurrentMark`）；禁用 CDS（`-XX:-UseSharedSpaces`，不能用 `-Xshare:on`）；不支持纯解释执行；需开 `-XX:+ProfileInterpreter`；需关分层编译（`-XX:-TieredCompilation`）。
- **注意**：使能后峰值性能可能短暂劣化，方法退优化重编后改善。

## DynamicMaxHeap — 运行时动态堆上限（额外特性，非 9 规则之一）

毕昇 JDK 8（8u452 起）。容器资源扩容后，OpenJDK 最大堆只能启动时指定无法动态扩。DynamicMaxHeap 允许运行时通过 jcmd 修改堆上限，无需重启 JVM。

- **场景**：容器资源扩容后需动态扩展堆内存上限。
- **开启**：
  ```bash
  java -XX:DynamicMaxHeapSizeLimit=4g -XX:MaxHeapSize=1g -XX:+UseG1GC
  # 可选日志：-XX:+TraceDynamicMaxHeap
  ```
- **运行时调整**：`jcmd <pid> GC.change_max_heap 2g`（单位 k/K/m/M/g/G，默认 Byte）。成功返回 `GC.change_max_heap success`。
- **约束**：仅 G1GC；`DynamicMaxHeapSizeLimit` 必须 > `MaxHeapSize`；不能设 `-XX:OldSize`/`-XX:NewSize`/`-XX:MaxNewSize`；`UseAdaptiveGCBoundary` 需 false、`UseAdaptiveSizePolicy` 需 true（均默认）；不能同时用 `-XX:+G1Uncommit`；上限 >32GB 则禁用压缩指针。
- **注意**：调低到当前堆使用量以下可能触发 Young/Full GC 引起性能波动。

## 通用验证流程

生产报告推荐任何 flag 前：

1. 跑 `java -XX:+PrintFlagsFinal -version 2>&1 | grep -i <feature>` 确认 flag 在用户 BishengJDK 构建中存在及默认值。
2. 对照已安装版本的 release notes（`java -version` 的 build 串标识版本）。
3. 在相同负载的 staging 实例上测试后再上生产。
4. 对 flag 拼写不确定时，给出特性名 + 验证命令，而非猜测 —— 错误 flag 比"请验证"更糟。
5. 本文件已自包含毕昇 JDK 8/11/17/21 特性的总结。完整 BoostKit 加速库文档（JBooster/JProfileCache/DynamicMaxHeap/堆转储增强的原文）见同目录 `boostkit-jdk-accel.md`。
