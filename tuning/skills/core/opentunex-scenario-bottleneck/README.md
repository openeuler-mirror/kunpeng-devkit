# opentunex-scenario-bottleneck

场景化瓶颈分析协调器。基于数据采集层提供的系统指标，全量调度所有场景分析技能并行执行并汇总结果。

## 总体功能

协调调度四个场景分析子技能并行执行：

1. **Docker算力统筹分析** - 识别CPU受限容器，评估burst适用性
2. **动态SMT分析** - 评估低负载场景下的动态SMT调优适用性
3. **numa并行感知调度分析** - 分析NUMA拓扑与跨节点访问，评估调度并行调优
4. **窃取任务调度分析** - 分析CPU负载不均衡，评估窃取任务调优

**Scope**: 纯协调器，不执行分析逻辑，不执行远程命令。

## 前置依赖

### 必需依赖

- **数据采集层** - 提供系统指标数据（CPU、内存、内核配置、容器信息等）
- Python 3.6+

### 工具依赖（子技能按需使用）

- `numactl` - NUMA拓扑分析
- `mpstat` (sysstat) - CPU使用率分析
- `vmstat` - 调度特征分析
- `lscpu` - CPU信息

## 用法

### 自然语言输入示例

```
对当前系统进行场景化瓶颈分析
```

```
容器CPU使用率高，帮我分析是否需要启用burst
```

```
系统负载不均衡，检查NUMA和窃取任务调优是否适用
```

### 输出示例

```markdown
### 场景分析报告

| ID | 场景 | 适用性 | 关键发现 | 预期收益 | 建议调优方向 |
|----|------|--------|---------|---------|------------|
| S-001 | Docker算力统筹 | 适用 | 3个容器CPU>95%，宿主机负载低 | 容器CPU突发能力提升 | 启用CPU burst |
| S-002 | 动态SMT | 不适用 | CPU使用率85%，高负载 | 无 | 保持全并行能力 |
| S-003 | numa并行感知调度 | 收益有限 | 远端访问率8%，NUMA状态良好 | 有限 | 持续监控 |
| S-004 | 窃取任务调度 | 适用 | CPU不均衡度35%，STEAL未启用 | CPU利用率提升10-20% | 启用窃取任务调度 |
```

## 目录结构

```
opentunex-scenario-bottleneck/
├── SKILL.md                                          # 协调器入口
├── DESIGN.md                                         # 设计文档
├── README.md                                         # 本文件
├── references/
│   └── skill-mapping.md                              # 场景映射参考
├── opentunex-docker-coordination-burst-analysis/
│   ├── SKILL.md                                      # Docker burst 分析
│   └── scripts/
│       └── analyze_burst.py                          # 分析脚本
├── opentunex-dynamic-smt-analysis/
│   ├── SKILL.md                                      # 动态SMT分析
│   └── scripts/
│       └── analyze_smt.py                            # 分析脚本
├── opentunex-numa-sched-analysis/
│   ├── SKILL.md                                      # NUMA分析
│   └── scripts/
│       └── analyze_numa.py                           # 分析脚本
└── opentunex-stealtask-analysis/
    ├── SKILL.md                                      # 窃取任务分析
    └── scripts/
        └── analyze_stealtask.py                      # 分析脚本
```