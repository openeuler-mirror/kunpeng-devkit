# 鲲鹏 BoostKit 系统库 毕昇 JDK 加速库 文档（精简版）

> 原文版权 © 华为技术有限公司。本文件已去除版权声明、商标声明、安全/漏洞处理流程、目录、版本说明书（V1.x 更新/遗留问题/病毒扫描/配套文档/漏洞修补列表）、修订记录等元信息，仅保留用户指南正文（简介、安装、各特性使能方法）。

---

# 用户指南

## 简介

毕昇 JDK 是基于 OpenJDK 开发的 Huawei JDK 开源版本，基于鲲鹏处理器提供了一些加速能力，如堆转储增强、JBooster 特性和 JBolt 特性的加速。

- **堆转储增强特性**：通过屏蔽转储堆文件中的敏感信息，保护数据安全与隐私。
- **JBooster 特性**：提升应用启动速度、降低 CPU 占用、加快弹性伸缩的响应速度、降低云应用部署成本。
- **JBolt 特性**：优化代码缓存布局，降低 icache/iTLB miss 率，提升应用程序性能。
- **JProfileCache 特性**：提前编译热点方法，降低应用抵达 TPS 上限的时间。
- **DynamicMaxHeap 特性**：引入动态最大堆，允许在应用运行时动态调整堆上限。

毕昇 JDK 版本所支持的毕昇 JDK 加速特性如表 2-1 所示。

**表 2-1 毕昇 JDK 版本所支持的毕昇 JDK 加速特性**

| 毕昇 JDK 加速特性 | 毕昇 JDK 版本 |
| --- | --- |
| 堆转储增强特性 | 8 / 17（8u422 和 17.0.12 开始支持） |
| JBooster 特性 | 17（17.0.12 及之后开始支持） |
| JBolt 特性 | 11 / 17 / 21（11.0.27、17.0.14 和 21.0.7 子版本后开始支持） |
| JProfileCache 特性 | 8（8u452 开始支持） |
| DynamicMaxHeap 特性 | 8（8u452 开始支持） |

## 安装毕昇 JDK 加速库

毕昇 JDK 加速库是针对毕昇 JDK 的一个插件库，因此安装毕昇 JDK 加速库前需要先完成毕昇 JDK 的安装。

**已验证环境**

| 操作系统 | CPU 类型 |
| --- | --- |
| openEuler 22.03 LTS SP3 | 鲲鹏 920 5250 处理器 |
| openEuler 22.03 LTS SP3 | 鲲鹏 950 处理器 |

**安装步骤**

**步骤 1** 安装毕昇 JDK。

获取毕昇 JDK，请参见《毕昇 JDK 8 安装指南》、《毕昇 JDK 11 安装指南》、《毕昇 JDK 17 安装指南》或《毕昇 JDK 21 安装指南》安装毕昇 JDK。

**步骤 2** 获取毕昇 JDK 加速软件包，并进行软件包完整性校验。

1. 从鲲鹏社区获取对应的软件数字证书和毕昇 JDK 加速库软件安装包 `BoostKit-jdk_1.3.0.zip`，用户解压缩 zip 文件可获取到 RPM 和 DEB 安装包。

> **说明**  
> 使用软件包前请先阅读《鲲鹏应用使能套件 BoostKit 用户许可协议 2.0》，如确认继续使用，则默认同意协议的条款和条件。

2. 从华为企业业务网站获取校验工具和校验方法。
3. 参见步骤 2.2 中下载的《OpenPGP 签名验证指南》进行软件包完整性检查。

**步骤 3** 安装毕昇 JDK 加速软件包。

解压缩 zip 包后，可获取到 RPM 和 DEB 安装包，使用 rpm 或 dpkg 命令进行安装。命令中涉及的 `xxx` 代表版本号。

```bash
rpm -ivh boostkit-jdk-xxx.aarch64.rpm
```

或

```bash
dpkg -i boostkit-jdk-xxx.aarch64.deb
```

**步骤 4** 检查加速软件包是否安装成功。

使用 `ll`（`ls -l`）命令检查环境中是否含有毕昇 JDK 加速库特性加速包，不同 JDK 版本加速包命名方式不同，以下述命令为准。其中，命令中的"X"对应使用的 jdk 版本，如 `jdk-1.8.*` 版本中的"X"对应的是"8"。

- 毕昇 JDK 8 / 17：

```bash
ll /usr/lib64/libjvmX_kunpeng.so
```

- 毕昇 JDK 11 / 21：

```bash
ll /usr/lib64/libjvmX_Acc.so
```

----结束

## 使能堆转储增强特性

### 介绍

JVM 提供支持转储进程堆内容的能力，若 Java 进程的内存中保留了大量的敏感信息，dump 转储堆文件的操作将存在信息泄漏的安全风险。堆转储增强特性在保障 Heapdump 故障定位能力前提下，屏蔽了转储堆文件中的敏感信息。该特性尤其在重大涉密项目中，对数据安全与隐私保护有重大意义。

### 场景建议

需要通过 Heapdump 文件进行问题定位或性能分析，但不希望发生敏感信息泄漏。

### 使用约束

- 当毕昇 JDK 版本为 8 和 17 时支持堆转储增强特性，分别从毕昇 JDK 8u422 和 17.0.12 开始支持。
- 服务部署的 Java 版本要升级到支持该功能的 JDK 工具包对应的版本。
- 请参见"安装毕昇 JDK 加速库"完成毕昇 JDK 加速软件包的下载和安装。

### 使用方法

堆转储增强特性支持以下两种方式使能。

- 进程 VM 参数使能方式命令举例：

```bash
java -Xmx10M -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpRedact=full \
  -XX:RedactMapFile=/home/heapmap.txt -XX:RedactMap="password:abc,encrypt:cde" \
  MyClass -XX:RedactClassPath=/myClass/.../ReplaceValueAnnotation
```

- jmap 命令参数使能方式命令举例：

```bash
jmap -dump:HeapDumpRedact=<names/basic/full/annotation/diyrules/off>,\
  RedactMap="<key1:value1;key2:value2;...>",\
  RedactMapFile=<file path>,\
  RedactClassPath=</myClass/.../ReplaceValueAnnotation> <pid>
```

jmap 命令参数具体使用示例和方法请参见《Heapdump 匿名化用户使用说明书》。

以上命令参数说明如表 2-2 所示。

**表 2-2 堆转储增强特性使能命令参数说明**

| 参数 | 说明 |
| --- | --- |
| `-XX:HeapDumpRedact` | 指定匿名化模式。<br>- `names`：屏蔽敏感 symbols，需要用户指定映射表，可以由 `RedactMapFile` 指定在一个文件里，或者由 `RedactMap` 直接写在命令行中。<br>- `basic`：屏蔽 int/char/byte 数组，全部清零。<br>- `full`：names + basic。<br>- `annotation`：屏蔽敏感字段值，需要在开发阶段，由开发人员定义用来匿名化的注解类，dump 时指定类名（包含 classpath），注解类中的 value 替换掉字段值。<br>- `diyrules`：屏蔽敏感字段值，需要屏蔽的类和字段值信息由 `RedactMapFile` 指定在一个文件里，或者由 `RedactMap` 直接写在命令行中。<br>- `off`：默认行为，关闭 heapdump 匿名化即堆转储特性。 |
| `-XX:RedactMap` | 命令行中指定屏蔽敏感名字映射关系对，以英文分号作为组之间的分隔，以英文冒号作为映射对 key/value 的分隔。例如：`key1:value1;key2:value2...`。 |
| `-XX:RedactMapFile` | 通过文件获取要屏蔽敏感名字的映射关系。 |
| `-XX:RedactClassPath` | 指定敏感值替换的注解类。 |

## 使能 JBooster 特性

### 介绍

- 云场景下，应用有着"单个云应用实例分配资源少"与"云应用频繁地弹性伸缩"的特点，传统 JVM 应用启动慢的问题在此场景下更为严重。
- 云应用所需的 CPU 资源是由其启动时的负载与稳定运行时的负载（或业务峰值时所需负载）综合决定的。
- JBooster 特性通过数据共享、远程编译等形式来提升应用启动速度、降低 CPU 占用、加快弹性伸缩的响应速度、降低云应用部署成本。

### 场景建议

CPU 资源受限、类加载耗时长或编译耗时占比高，导致启动耗时长。

### 使用约束

- 当毕昇 JDK 版本为 17 时支持 JBooster 特性，从毕昇 JDK 17.0.12 及之后的版本开始支持。
- 客户端和服务端均部署在同一信任域内，由用户确保通信安全。
- 服务端编译 AOT 需要系统中安装 ld 指令。
  - 基于 RPM 包管理的操作系统（CentOS、Fedora、openEuler 等）使用 yum 安装 ld 指令：

    ```bash
    yum install binutils
    ```

  - 基于 Debian 包管理的操作系统（Ubuntu、Debian 等）使用 apt 安装 ld 指令：

    ```bash
    apt install binutils
    ```

### 使用方法

**步骤 1** 开启服务端 JBooster Server。

服务端启动成功后会输出 `The JBooster server is ready!`。使用 JBooster Server 的整个过程中需要保持服务端为启动状态，不能手动停止，如需执行其他命令需启动新的窗口。

```bash
$JAVA_HOME/bin/jbooster --server-port=<port>
```

> **说明**  
> 上述命令中的端口号 `<port>` 用户可自定义，端口限制范围为 1024~65535。  
> 使用 `jbooster --help` 命令来查看支持的命令行参数。

**步骤 2** 构建应用程序包。

本文以 `spring-petclinic-*.*.*-SNAPSHOT.jar` 为例进行应用程序的构建。构建过程中依赖 maven 工具，请确保构建环境已安装 maven。

```bash
git clone https://github.com/spring-projects/spring-petclinic.git
wget https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.6/apache-maven-3.9.6-bin.tar.gz
tar -xf apache-maven-3.9.6-bin.tar.gz
export PATH=$PWD/apache-maven-3.9.6/bin:$PATH
cd spring-petclinic
git reset --hard 2daa3993ee8dce8ec72cf96bc5ef7aee6e36f8fb
mvn package -DskipTests=true
```

> **说明**  
> mvn 的使用可能需要配置代理，请自行按实际情况配置。  
> 构建成功后，会在 `./target` 文件夹中生成一个 jar 包，jar 包名称为 `spring-petclinic-*.*.*-SNAPSHOT.jar`，其版本号随代码仓库更新而变化。

**步骤 3** 启用客户端。

第一次启用客户端，生成加速包，`JBoosterAddress` 需指定服务端的地址，端口号需和服务端一致。本文中的应用程序 `spring-petclinic-3.2.0.jar` 启动成功后会输出 `(process running for X.XXX)` 的日志，其中"X.XXX"即启动时间。客户端启动成功后可以使用 `CTRL+C` 键停止。

```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBooster \
  -XX:JBoosterAddress=127.0.0.1 -XX:JBoosterPort=<port> \
  -jar ./target/spring-petclinic-*.*.*-SNAPSHOT.jar
```

后续启用客户端可以获得加速效果，命令与第一次启用客户端一致，日志输出显示启动时间有比较明显的减少。上述命令中的端口号 `<port>` 用户可自定义，与步骤 1 中的 `<port>` 保持一致即可。

----结束

## 使能 JBolt 特性

### 介绍

主流 JIT 编译简单按照编译时机将方法代码追加到代码缓存区中，在热方法多且分布散乱时 icache/iTLB miss 就会引起较高的 CPU 惩罚，造成前端系统瓶颈。JBolt 特性利用采样手段获取运行时 JIT 方法的热点和调用链关系，再通过算法重排将热方法代码以较优方式集中，提高空间局部性，降低 icache/iTLB miss 率以提升程序性能。

### 场景建议

由 JIT CodeCache 引起的 icache/iTLB miss 率高（可使用性能分析工具跟踪 CPU 缓存命中率，如 Linux perf 命令等），应用程序热方法多且分布散乱的场景。

### 使用约束

- 当毕昇 JDK 版本为 11、17 和 21 版本时支持 JBolt 特性，分别从毕昇 JDK 11.0.27、17.0.14 和 21.0.7 子版本后开始支持。
- 应用支持使用 JFR。应用一般默认支持 JFR，除非通过 `-XX:-FlightRecorder` 参数关闭此功能。
- 应用需要使能 C2 编译器。在 `-Xint` 及诸如 AppCDS dump 等不使能编译器的场景下无法使用 JBolt 特性。
- 应用需要支持 Segmented CodeCache。JBolt 依赖 Java 9 之后的代码缓存分区特性（默认使能的），如果应用包含 `-XX:-TieredCompilation`、`-XX:-SegmentedCodeCache` 以及 `-XX:ReservedCodeCacheSize < 240M` 等，则会关闭这一特性，导致无法使用 JBolt。
- 以下情况列出的一些软性限制，不会导致直接启动失败，但可能运行时异常或不合预期，此时也不建议使用本特性。
  - 应用 Java 堆内存极小的情况，开启 JFR 有一定内存要求，建议预先通过 `-XX:StartFlightRecording` 参数尝试是否场景可支持 JFR 采样，内存不够会导致使用异常。
  - 应用限制 JVM 模块范围的情况，如使用 `--limit-modules` 进行模块裁剪等。特性通过特权级调用完成部分自动化功能，会隐式加载部分依赖，会使得实际限制范围和预期不符。

### （推荐）使用方法一："一步式"模式

"一步式"模式：一次运行过程中自动完成采样及重排，可支持进行多次采样重排过程。

**步骤 1** 使能 JBolt，启动后自动执行一次采样重排。强烈建议添加 `-Xlog:jbolt=info` 参数，该参数会在 JBolt 各个重要环节输出信息给控制台，采样完成后自动进行重排，重排完成后加了 `-Xlog` 信息会看到 `JBolt reordering succeeds.`，代表 JBolt 生效。此参数对"两步式"模式同样适用。命令行中 `spring-petclinic.jar` 是业务程序包举例，请结合具体使用程序进行替换。

```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt \
  -Xlog:jbolt=info -jar spring-petclinic.jar
```

> **说明**  
> "一步式"模式，支持如下几个参数组合使用：
> - `-XX:JBoltSampleInterval`：采样持续时间（秒）。无特殊情况默认不设置，默认值 600 秒，即采样时间持续 600 秒。
> - `-XX:JBoltCodeHeapSize`：JBolt 堆大小。默认值 8MB，此默认值在一些编译方法较多的场景（原本使用的 CodeCache 偏大）可能不够用，需要结合场景设置，设置的大小需与 page-size 对齐，可参考值为原本实际使用的 Non-profiled 段大小的 1/4~1/2（使用大小可用 `-XX:+PrintCodeCache` 参数查看，例：non-profiled used=16M，`JBoltCodeHeapSize` 建议设为 4M~8M 之间）。
> - （仅 JDK 11 支持）`-XX:JBoltRescheduling`：设置每天固定时间自动采样。定义格式必须为 `hh:mm`，多个时间使用逗号进行分隔（如：`JBoltRescheduling=07:30,16:30`），最多支持设置十个不重复时间（注：由于同时只能存在一个 JBolt 工作流程，因此如果设置的时间过近或手动采样等原因导致前一次流程未结束可能导致无法自动触发，未成功触发的时间在当天会被跳过）。

**步骤 2** 在"一步式"模式下，用户可以使用 jcmd 命令手动控制采样时机，在线启动 JBolt 热点重排。

当前支持以下 4 个命令，使用方式参考：`jcmd <pid> JBolt.xxx`。`<pid>` 为步骤 1 开启的 Java 进程 ID，结合具体业务进程在命令中替换。

- `JBolt.start`：开启一次自动采样并在持续时间结束后应用重排。可选 `duration` 参数，与 `-XX:JBoltSampleInterval` 意义相同，默认值即为 `JBoltSampleInterval` 的值。使用方式：

  ```bash
  $JAVA_HOME/bin/jcmd <pid> JBolt.start [duration=<sample interval>]
  ```

  > **说明**  
  > 此时正在采样重排中会开启不成功，可等待时间结束或使用 stop 或 abort 命令提前结束。

- `JBolt.stop`：立即停止当前采样并应用重排。使用方式：

  ```bash
  $JAVA_HOME/bin/jcmd <pid> JBolt.stop
  ```

- `JBolt.abort`：与 stop 相同但不会应用重排。使用方式：

  ```bash
  $JAVA_HOME/bin/jcmd <pid> JBolt.abort
  ```

- `JBolt.dump`：将当前应用中的顺序表导出。带一个 `filename` 必须参数指定有效文件路径。使用方式：

  ```bash
  $JAVA_HOME/bin/jcmd <pid> JBolt.dump filename=<eg: order.log>
  ```

----结束

### 使用方法二："两步式"模式

"两步式"模式：将采样和重排分为两个阶段分开运行。

**步骤 1** 使能 DumpMode，进行采样，采样持续到程序退出（需要程序自然退出或手动 `Ctrl+C`，如果是异常退出则不会生成），将顺序表导出到指定文件。

```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt -XX:+JBoltDumpMode \
  -XX:JBoltOrderFile=<eg: order.log> -Xlog:jbolt=info -jar spring-petclinic.jar
```

**步骤 2** 使用生成的顺序表文件，再次启动程序进行布局重排应用，该步骤需要应用启动一段时间后才可能会进行重排，生效的标志与一步式下相同，生效后可期望取得优化效果。

```bash
$JAVA_HOME/bin/java -XX:+UnlockExperimentalVMOptions -XX:+UseJBolt -XX:+JBoltLoadMode \
  -XX:JBoltOrderFile=<eg: order.log> -Xlog:jbolt=info -jar spring-petclinic.jar
```

> **说明**  
> "两步式"模式不支持 jcmd 命令控制采样时机的操作。

----结束

## 使能 JProfileCache 特性

### 介绍

Java 应用启动阶段存在热点方法即时编译与业务请求处理对 CPU 资源的竞争问题，可能因为编译延迟导致系统性能爬坡缓慢。JProfileCache 特性基于收集上一次运行的 Profiling 信息再次启动时先触发热点方法编译使用户 Java 进程快速抵达峰值性能。

### 场景建议

CPU 资源受限、编译线程 CPU 占比高，进程启动后无法快速抵达峰值性能。

### 使用约束

- 当毕昇 JDK 版本为 8 时支持 JProfileCache 特性，从毕昇 JDK 8u452 开始支持。
- 服务部署的 Java 版本要升级到支持该功能的 JDK 工具包对应的版本。
- 请参见"安装毕昇 JDK 加速库"完成毕昇 JDK 加速软件包的下载和安装。
- JProfileCache 特性目前为实验特性，使能 JProfileCache 特性需要在特性参数前面设置 `-XX:+UnlockExperimentalVMOptions`。
- JProfileCache 特性记录热点信息功能不支持类卸载需要设置 `-XX:-ClassUnloading`，并且如果使用 CMS 则需要设置 `-XX:-CMSClassUnloadingEnabled` 关闭 GC 时的类卸载，如果使用 G1 则需要设置 `-XX:-ClassUnloadingWithConcurrentMark` 关闭 GC 时的类卸载。
- JProfileCache 特性的记录热点信息和使能 JProfileCache 加载编译信息功能目前不支持类数据共享，且需要通过参数 `-XX:-UseSharedSpaces` 禁用 `UseSharedSpaces`，其他 `UseSharedSpaces` 相关参数如：`-Xshare:on`（会开启 `UseSharedSpaces`）也不可同时使用。
- JProfileCache 特性记录热点信息和使能 JProfileCache 加载编译信息功能目前不支持纯解释执行。
- JProfileCache 特性记录热点信息功能启用解释器的性能分析功能需要设置为开启 `-XX:+ProfileInterpreter`。
- JProfileCache 特性使能和 JProfileCache 加载编译信息功能目前不支持分层编译，需要设置启动参数 `-XX:-TieredCompilation`，分层编译默认打开。

### 使用方法

下面以 `spring-petclinic-2.7.3.jar` 程序为例简单说明 JProfileCache 的用法。

**步骤 1** 生成编译信息文件。

```bash
java -XX:-ClassUnloading -XX:-CMSClassUnloadingEnabled -XX:-ClassUnloadingWithConcurrentMark \
  -XX:+UnlockExperimentalVMOptions -XX:ProfilingCacheFile=jprofilecache.log \
  -XX:+JProfilingCacheRecording -XX:JProfilingCacheRecordTime=30 \
  -jar spring-petclinic-2.7.3.jar
```

**步骤 2** 使能 JProfileCache 加载编译信息。

```bash
java -XX:+UnlockExperimentalVMOptions -XX:+JProfilingCacheCompileAdvance -XX:-TieredCompilation \
  -XX:ProfilingCacheFile=jprofilecache.log -XX:JProfilingCacheDeoptTime=0 \
  -jar spring-petclinic-2.7.3.jar
```

**步骤 3** 触发编译。

1. 找到进程 pid 执行 jcmd 命令触发 JProfileCache 编译。

   ```bash
   jcmd <pid> JProfilecache -notify
   ```

   执行成功时会返回 `Command executed successfully`，执行失败会返回失败原因。

2. 查看编译是否已经完成，如果编译完成即可执行正常业务。

   ```bash
   jcmd <pid> JProfilecache -check
   ```

   如果编译完成会返回 `Last compilation task has compile finished`，执行失败会返回失败原因。

> **说明**  
> - 使能 JProfileCache 特性触发预编译后，Java 进程的峰值性能可能会存在一定的劣化，当 JProfileCache 编译的方法会被梯次退优化重编后，此时峰值性能会明显改善。  
> - 使能 JProfileCache 特性触发预编译后，如果设置一段时间后开始退优化 JProfileCache 编译的方法，理论上在方法退优化重新触发方法编译时，性能可能会有微波动，具体以业务实测为准。

----结束

以上命令参数说明如表 2-3 所示。

**表 2-3 JProfileCache 特性使能命令参数说明**

| 参数 | 说明 |
| --- | --- |
| `-XX:JProfilingCacheRecording` | 是否开启 JProfileCache 特性的记录热点信息功能。 |
| `-XX:JProfilingCacheRecordTime` | 记录编译信息的时间（单位为秒），默认情况下为 0。 |
| `-XX:ProfilingCacheFile` | 记录的编译信息生成到的文件路径。 |
| `-XX:JProfilingCacheCompileAdvance` | 是否开启 JProfileCache 特性的编译功能。 |
| `-XX:JProfilingCacheDeoptTime` | JProfileCache 会在指定时间使用退优化编译的方法。设置 `JProfilingCacheDeoptTime` 为 0 可以取消定时，默认为 1200（单位为秒）。如果看到日志 `all profilecache methods have been deoptimized` 表示 JProfileCache 触发编译的方法已经全部退优化。 |

## 使能 DynamicMaxHeap 特性

### 介绍

互联网客户目前普遍使用容器化部署应用的模式，容器场景下容器资源可垂直伸缩，当前 OpenJDK 的最大堆只能在启动时指定，无法动态扩缩，Java 应用无法使用到容器扩容出的内存。

DynamicMaxHeap 特性通过引入一个可被修改的动态最大堆概念，运行时通过 jcmd 命令修改最大堆的目标值来动态控制实际堆内存上限。使能 DynamicMaxHeap 特性，可允许用户在应用运行时动态更新 Java 堆内存的上限，而无需重启 JVM。

### 场景建议

容器资源扩容后，需要动态扩展堆内存上限，以使应用可以使用到容器扩容出的资源，从而提升性能的场景。

### 使用约束

- 当毕昇 JDK 版本为 8 时支持 DynamicMaxHeap 特性，从毕昇 JDK 8u452 版本后开始支持。且应用需要使用 G1 垃圾回收器。
- 应用必须显式指定动态堆扩展的上限值 `-XX:DynamicMaxHeapSizeLimit` 和最大堆的初始值 `-XX:MaxHeapSize`（即 `-Xmx`），以明确堆扩展的上下限；同时要求 `DynamicMaxHeapSizeLimit > MaxHeapSize`，以确保有堆向上扩展的空间。
- 应用不能显式设置 `-XX:OldSize` / `-XX:NewSize` / `-XX:MaxNewSize`；使用本特性时必须保持 `-XX:UseAdaptiveGCBoundary` 为 false（不显式设置时默认值即为 false），`-XX:UseAdaptiveSizePolicy` 为 true（不显式设置时默认值即为 true）。
- 本特性暂不支持和 G1Uncommit 共用，因此应用启动时不能设置 `-XX:+G1Uncommit`（不显式设置时默认值即为 false）。
- 开启本特性时，若应用启动时设置 `-XX:DynamicMaxHeapSizeLimit > 32GB`，则 JVM 将会禁用压缩指针。

### 使用方法

**步骤 1** 启动添加如下 JVM 参数使能 DynamicMaxHeap 特性。

- `-XX:+TraceDynamicMaxHeap`：bool，参数表示是否开启 DynamicMaxHeap 日志追踪功能。开启后，会记录堆上限扩展过程的日志和执行失败的具体原因，并输出到标准输出里，输出信息中包含 `ChangeMaxHeapOp` 关键字。
- `-XX:DynamicMaxHeapSizeLimit=<堆扩展的上限值>`：uintx，参数表示堆扩展的上限值，后续通过 jcmd 扩展的最大堆目标值不能超过此值。默认情况下为 96MB（与 `-XX:MaxHeapSize` 的默认值一致）。设置该值意味着要开启 DynamicMaxHeap 功能。该参数需配合 `-XX:MaxHeapSize`（即 `-Xmx`）一起使用，且大于 `-Xmx` 的值。目前仅支持 G1GC 下使用。该值超过 32GB 则禁用压缩指针，如果用户显式指定过压缩指针开启则弹出告警 `Max heap size too large for Compressed Oops` 并禁用压缩指针。不添加 `-XX:DynamicMaxHeapSizeLimit` 参数时默认特性不使能，不对原应用产生任何影响。
- `-XX:MaxHeapSize=<最大堆的初始值>`
- `-XX:+UseG1GC`：使能特性。

启动参数举例如下：

```bash
$JAVA_HOME/bin/java \
  -XX:+TraceDynamicMaxHeap \
  -XX:DynamicMaxHeapSizeLimit=4g \
  -XX:MaxHeapSize=1g \
  -XX:+UseG1GC \
```

开启特性的最少必需参数举例如下：

```bash
$JAVA_HOME/bin/java -XX:DynamicMaxHeapSizeLimit=4g -XX:MaxHeapSize=1g -XX:+UseG1GC
```

**步骤 2** 在运行时可以通过下述 jcmd 命令调整最大堆目标值。

```bash
$JAVA_HOME/bin/jcmd <PID> GC.change_max_heap <最大堆目标值>
```

> **说明**  
> 本特性新增 jcmd 命令 `GC.change_max_heap` 用于调整最大堆的目标值。
> - 使用方法：`jcmd <PID> GC.change_max_heap <最大堆目标值>`：该目标值数字只能是整数，可识别的单位字符为 `k`/`K`（代表 KB），`m`/`M`（代表 MB），`g`/`G`（代表 GB），不填或者填其他字符时默认单位是 Byte。
> - 举例：

   ```bash
   jcmd <PID> GC.change_max_heap 2g           // 合法，目标值为 2GB
   jcmd <PID> GC.change_max_heap 209715200    // 合法，目标值为 200MB
   ```

> - 当通过 jcmd 将 JVM 堆内存上限动态调低至当前堆使用量以下时，可能触发 Young GC 或 Full GC（完全垃圾回收），从而引发应用性能波动。
>
> 调整成功时会返回 `GC.change_max_heap success`；失败时则返回 failed 和失败原因。若设置了 `-XX:+TraceDynamicMaxHeap`，还会打印更加详细的堆上限伸缩日志到应用的标准输出中。

----结束
