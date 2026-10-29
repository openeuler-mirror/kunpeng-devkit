---
name: devkit-numafast-analysis
description: DevKit NUMA访问性能分析技能。专门分析devkit_numafast.txt数据文件，提取NUMA Score、跨NUMA访问流量、RMA占比、识别NUMA访问不均衡问题、生成NUMA绑定建议。当用户需要NUMA性能分析或跨NUMA访问优化时触发此技能。
---

# devkit-numafast-analysis — DevKit NUMA访问性能分析技能

本技能专门分析`devkit_numafast.txt`文件，提取NUMA Score、跨NUMA访问流量、RMA占比、识别NUMA访问不均衡问题、生成NUMA绑定建议。

---

## 适用场景

当用户提供`devkit_numafast.txt`数据文件，或需要：
- NUMA访问性能分析
- 跨NUMA流量分析
- NUMA Score评估
- NUMA绑定优化
- 内存访问本地化优化

---

## 数据文件

**输入文件**: `devkit_numafast.txt`

**文件格式示例**:
```
NUMAFAST ANALYZE SUMMARY REPORT
==========================================================================================
1. System's numa score : 1.00
   Note:
         score = (max cost - real cost) / (max cost - min cost)
         real cost = SUM(numa distance(i, j) * access percentage(i, j)), 0<=i,j<node number
         max cost = MAX(numa distance) , min cost = MIN(numa distance).  
         This score is best at 1 and worst at 0.
         Format: traffic | numa distance | access percentage.

              DST_0               DST_1          
SRC_0   0.00GB|10|0.00%     0.00GB|12|0.00%  
SRC_1   0.00GB|12|0.00%     0.32GB|10|100.00%

==========================================================================================
2. System node detail information of memory access traffic:
   Note:
         Aggregate traffic across NUMA nodes by source (SRC) node.
         RMA(Die): Access traffic across NUMA dies.
         RMA(Socket): Access traffic across NUMA sockets.
         LMA: Local access traffic on the NUMA node.
         %CPU: Number of occupied CPU cores.

 NID  RMA_Die  RMA_Skt      LMA    %RMA   MEM_all  MEM_free   %MEM      %CPU
   0   0.00GB   0.00GB   0.00GB    0.00   65.41GB   19.68GB  69.91    178.27
   1   0.00GB   0.00GB   0.32GB    0.00  197.12GB  140.85GB  28.55    200.11

==========================================================================================
3. Show top 1 processes which sorted by memory access:
    PID  SCORE  ACCESS  RMA_Die  RMA_Skt      LMA    %RMA  MIGRATED    %CPU    COMMAND
2964437   1.00 100.00%   0.00GB   0.00GB   0.32GB    0.00    0|2        --     pthread_mutex_l
==========================================================================================
```

---

## 分析流程

### Phase 1: 数据文件读取与验证

**目标**: 读取并验证numafast数据文件

**执行步骤**:
1. 检查`devkit_numafast.txt`文件是否存在
2. 读取文件内容
3. 验证文件格式是否正确
4. 提采集时间、系统信息、监控进程PID

**输出**: 文件验证状态、基础信息

---

### Phase 2: NUMA Score分析

**目标**: 提取并分析NUMA Score指标

**NUMA Score计算公式**:
```
score = (max cost - real cost) / (max cost - min cost)
real cost = SUM(numa distance(i, j) * access percentage(i, j))
max cost = MAX(numa distance)
min cost = MIN(numa distance)
```

**Score阈值判定**:
| Score值 | 性能评估 | 状态 | 说明 |
|---------|---------|------|------|
| 1.0 | Excellent | Optimal | 全本地访问，无跨NUMA流量 |
| 0.8-1.0 | Good | Good | 少量跨NUMA访问，影响较小 |
| 0.5-0.8 | Medium | Elevated | 跨NUMA访问较多，需优化 |
| < 0.5 | Poor | Critical | 跨NUMA访问严重，性能瓶颈 |

**Score影响因素**:
- Score = 1.0 → 全部本地访问(LMA)
- Score < 0.5 → 大量跨NUMA访问(RMA占比高)
- Score接近0 → 全部跨NUMA访问，最差情况

---

### Phase 3: 跨NUMA访问流量矩阵分析

**目标**: 提取NUMA节点间的访问流量矩阵

**流量矩阵提取**:
```
              DST_0               DST_1          
SRC_0   0.00GB|10|0.00%     0.00GB|12|0.00%  
SRC_1   0.00GB|12|0.00%     0.32GB|10|100.00%
```

**矩阵解读**:
- **SRC_0 → DST_0**: Node0本地访问，流量0.00GB，距离10，占比0.00%
- **SRC_0 → DST_1**: Node0访问Node1，流量0.00GB，距离12，占比0.00%
- **SRC_1 → DST_0**: Node1访问Node0，流量0.00GB，距离12，占比0.00%
- **SRC_1 → DST_1**: Node1本地访问，流量0.32GB，距离10，占比100.00%

**NUMA距离定义**:
- 本地访问距离: 10 (本地NUMA节点)
- 跨NUMA访问距离: 12 (跨NUMA节点，延迟约+20%)

**跨NUMA流量计算**:
```
跨NUMA流量 = SRC_0→DST_1 + SRC_1→DST_0
本地流量 = SRC_0→DST_0 + SRC_1→DST_1
总流量 = 跨NUMA流量 + 本地流量
```

**跨NUMA占比阈值**:
| 跨NUMA占比 | 状态 | 瓶颈级别 | 说明 |
|-----------|------|---------|------|
| < 10% | Optimal | None | NUMA访问优化 |
| 10-30% | Elevated | Medium | 需NUMA绑定优化 |
| 30-50% | High | High | 严重影响性能 |
| > 50% | Critical | Critical | NUMA瓶颈 |

---

### Phase 4: RMA占比分析

**目标**: 提取各NUMA节点的RMA(Remote Memory Access)占比

**RMA指标提取**:
- **RMA_Die**: 跨Die访问流量(GB)
- **RMA_Skt**: 跨Socket访问流量(GB)
- **LMA**: 本地访问流量(GB)
- **%RMA**: RMA占总访问的比例

**NUMA节点RMA分析**:
```
 NID  RMA_Die  RMA_Skt      LMA    %RMA   MEM_all  MEM_free   %MEM      %CPU
   0   0.00GB   0.00GB   0.00GB    0.00   65.41GB   19.68GB  69.91    178.27
   1   0.00GB   0.00GB   0.32GB    0.00  197.12GB  140.85GB  28.55    200.11
```

**节点级RMA判定**:
| %RMA值 | 状态 | 瓶颈级别 | 说明 |
|--------|------|---------|------|
| < 10% | Local | None | 本地访问为主 |
| 10-30% | Elevated | Medium | 跨NUMA访问较多 |
| > 30% | Critical | Critical | 跨NUMA访问严重 |

**节点不均衡判定**:
- Node0 RMA vs Node1 RMA差异 > 20% → NUMA分布不均衡
- Node CPU利用率差异 > 30% → CPU绑定不均衡

---

### Phase 5: 进程级NUMA访问分析

**目标**: 提取进程级的NUMA访问和迁移信息

**进程指标提取**:
```
    PID  SCORE  ACCESS  RMA_Die  RMA_Skt      LMA    %RMA  MIGRATED    %CPU    COMMAND
2964437   1.00 100.00%   0.00GB   0.00GB   0.32GB    0.00    0|2        --     pthread_mutex_l
```

**进程级指标**:
- **PID**: 进程ID
- **SCORE**: 进程NUMA Score
- **ACCESS**: 占总流量比例
- **RMA_Die/Skt**: 进程跨NUMA流量
- **LMA**: 进程本地访问流量
- **%RMA**: 进程RMA占比
- **MIGRATED X|Y**: X=迁移次数，Y=线程数
- **%CPU**: CPU占用率

**进程迁移判定**:
| 迁移次数/线程数 | 状态 | 说明 |
|---------------|------|------|
| 0/N | Optimal | 无迁移，NUMA绑定良好 |
| 1-5/N | Elevated | 少量迁移，需关注 |
| > 10/N | Critical | 频繁迁移，需绑定 |

---

### Phase 6: NUMA优化建议生成

**目标**: 生成结构化的NUMA优化报告和建议

**报告结构**:

```markdown
# NUMA访问性能分析报告

**采集时间**: YYYY/MM/DD HH:MM:SS
**分析时间**: YYYY-MM-DD HH:MM:SS
**CPU型号**: Kunpeng-920
**NUMA节点**: 2节点
**监控进程**: PID [进程号]

## 1. NUMA Score评估

**NUMA Score**: [值] ([性能评估])
**状态**: [Optimal/Good/Elevated/Critical]
**瓶颈级别**: [None/Low/Medium/Critical]

**Score计算**:
- real cost = [计算过程]
- max cost = 12, min cost = 10
- score = (12 - real cost) / (12 - 10)

**评估**: NUMA访问优化程度评估

## 2. 跨NUMA访问流量矩阵

### 2.1 NUMA节点间流量分布

| SRC节点 | DST节点 | 流量(GB) | NUMA距离 | 占比(%) | 状态 |
|---------|---------|----------|----------|---------|------|
| Node0 | Node0 | XX | 10 | XX | Local |
| Node0 | Node1 | XX | 12 | XX | Remote |
| Node1 | Node0 | XX | 12 | XX | Remote |
| Node1 | Node1 | XX | 10 | XX | Local |

**跨NUMA流量**: XX GB
**本地流量**: XX GB
**跨NUMA占比**: XX %

**状态**: [Optimal/Elevated/Critical]
**瓶颈级别**: [None/Medium/Critical]

### 2.2 NUMA访问拓扑图

Node0 → Node0: XX GB (本地)
Node0 → Node1: XX GB (跨NUMA, 距离12)
Node1 → Node0: XX GB (跨NUMA, 距离12)
Node1 → Node1: XX GB (本地)

## 3. NUMA节点RMA占比分析

### 3.1 节点级RMA指标

| NUMA节点 | RMA_Die(GB) | RMA_Skt(GB) | LMA(GB) | %RMA | 状态 |
|---------|------------|------------|---------|------|------|
| Node0 | XX | XX | XX | XX | [状态] |
| Node1 | XX | XX | XX | XX | [状态] |

**节点RMA对比**: Node0 RMA XX% vs Node1 RMA XX%
**不均衡度**: XX %
**状态**: [Balanced/Imbalanced]

### 3.2 节点内存与CPU分布

| NUMA节点 | 总内存(GB) | 可用内存(GB) | 内存利用率(%) | CPU占用(%) |
|---------|----------|------------|-------------|-----------|
| Node0 | XX | XX | XX | XX |
| Node1 | XX | XX | XX | XX |

**内存分布**: Node0 XX GB vs Node1 XX GB
**CPU分布**: Node0 XX% vs Node1 XX%

## 4. 进程级NUMA访问分析

### 4.1 Top进程NUMA访问详情

| PID | SCORE | ACCESS | RMA(GB) | LMA(GB) | %RMA | 迁移次数 | CPU占用 |
|-----|-------|--------|---------|---------|------|---------|---------|
| XX | XX | XX% | XX | XX | XX | XX|N | XX% |

**进程NUMA Score**: [值]
**进程迁移**: XX次 / N线程

### 4.2 进程NUMA访问问题识别

**问题进程**: [PID]
**问题描述**: RMA占比高/迁移频繁/跨NUMA访问

## 5. NUMA瓶颈根本原因分析

### 5.1 NUMA Score低（< 0.8）

**根本原因**:
- 进程未绑定本地NUMA节点
- 数据分布跨NUMA节点
- NUMA自动均衡导致跨节点访问
- 内存分配策略不合理

**影响**:
- 内存访问延迟增加20%+（距离12 vs 10）
- 降低IPC和整体性能
- 增加DDR带宽压力

**证据链**:
- NUMA Score [值]
- 跨NUMA占比 [值]
- RMA占比 [值]

### 5.2 进程NUMA迁移频繁（> 10次）

**根本原因**:
- NUMA自动均衡启用(kernel.numa_balancing=1)
- 进程未绑定CPU和内存
- 调度器跨NUMA调度
- 内存压力触发迁移

**影响**:
- 进程迁移开销大（TLB刷新、缓存冷启动）
- 降低进程性能
- 增加NUMA不稳定性

## 6. NUMA优化建议索引

> **重要**: 具体调优建议由 `tuning-recommendation-generator` 技能统一生成，避免重复。
> 本节仅提供优化方向索引，供调优建议生成器引用。

### 索引1: NUMA绑定优化

**适用场景**: 跨NUMA占比 > 10% 或 NUMA Score < 0.7

**优化方向索引**:
- NUMA自动均衡配置（kernel.numa_balancing）
- 进程NUMA绑定策略（numactl）
- zone_reclaim配置（慎用，见注意事项）

**参数索引**: 参考 `parameter-database.md` NUMA参数

### 索引2: 进程绑定优化

**适用场景**: 进程迁移 > 5次/线程

**优化方向索引**:
- CPU核心绑定（taskset）
- 进程级NUMA绑定（numactl）
- 精细化绑核策略

### 索引3: 内存分配策略优化

**适用场景**: RMA占比 > 30%

**优化方向索引**:
- 应用级NUMA策略（MySQL/Redis/Java）
- 系统级内存策略

### 索引4: NUMA拓扑优化

**适用场景**: 多节点不均衡

**优化方向索引**:
- NUMA拓扑检查
- 内存插法检查（参考kspect分析）
- 网卡NUMA归属检查（参考kspect分析）

## 7. 注意事项

> **zone_reclaim_mode 慎用说明**:
> `vm.zone_reclaim_mode=1` 可能导致性能下降，优先回收本地内存可能阻塞其他操作。
> 仅在NUMA内存极度不均衡且跨NUMA访问严重影响性能时慎用，否则保持默认值0。

> **NUMA Balancing 配置建议**:
> - 高负载场景且进程已绑定: 建议禁用 `kernel.numa_balancing=0`
> - 未绑定进程且需NUMA优化: 建议启用 `kernel.numa_balancing=1`
> - 根据应用特性选择，避免进程频繁迁移

**详细参数说明**: 参考 `tuning-recommendation-generator/references/parameter-database.md`

**当前NUMA拓扑**:

Node0:
- CPU核心: 0-63
- 内存: XX GB
- 本地访问流量: XX GB
- 跨NUMA访问流量: XX GB
- RMA占比: XX%
- CPU占用: XX%
- 状态: [分析结果]

Node1:
- CPU核心: 64-127
- 内存: XX GB
- 本地访问流量: XX GB
- 跨NUMA访问流量: XX GB
- RMA占比: XX%
- CPU占用: XX%
- 状态: [分析结果]

**NUMA距离矩阵**:
```
      Node0  Node1
Node0  10     12
Node1  12     10
```
```

---

## 输出文件

**报告文件名**: `numafast_analysis_report_YYYYMMDD_HHMMSS.md`
**保存位置**: 当前工作目录或profiling数据包目录

---

## 关键阈值

> **统一阈值参考**: `tuning-recommendation-generator/references/benchmark-thresholds.md`

| NUMA指标 | 正常范围 | Elevated阈值 | Critical阈值 |
|----------|---------|------------|-------------|
| NUMA Score | > 0.7 | < 0.7 | < 0.5 |
| 跨NUMA占比 | < 10% | > 30% | > 50% |
| RMA占比 | < 10% | > 30% | > 50% |
| 进程迁移次数 | < 5次 | > 10次 | > 20次 |
| 节点内存差异 | < 30% | > 50% | > 80% |

**NUMA距离基准**: Kunpeng-920本地距离10，跨NUMA距离12（延迟+20%）

---

## 注意事项

1. **NUMA Score**: Score=1.0表示全本地访问，Score=0表示全跨NUMA访问
2. **NUMA距离**: Kunpeng-920本地距离10，跨NUMA距离12，延迟差异约20%
3. **RMA占比**: RMA占比高不一定有问题，需结合应用特性判断
4. **进程迁移**: 进程迁移开销大，需禁用NUMA自动均衡并绑定进程
5. **内存分布**: Node内存容量差异大时，需考虑数据分布策略