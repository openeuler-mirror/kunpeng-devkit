# DevKit NUMA访问性能分析技能

## 概述

本技能专门分析`devkit_numafast.txt`数据文件，提取NUMA Score、跨NUMA访问流量、RMA占比、识别NUMA访问不均衡问题、生成NUMA绑定建议。

## 适用场景

- NUMA访问性能分析
- 跨NUMA流量分析
- NUMA Score评估
- NUMA绑定优化
- 内存访问本地化优化

## 数据文件

**输入**: `devkit_numafast.txt`

**输出**: `numafast_analysis_report_YYYYMMDD_HHMMSS.md`

## 快速使用

```bash
# 1. 解压数据包
tar -xzf profiling_data_*.tar.gz

# 2. 进入数据目录
cd profiling_data_*

# 3. 调用技能
# 使用opencode CLI调用此技能
```

## 分析流程

1. **Phase 1**: 数据文件读取与验证
2. **Phase 2**: NUMA Score分析
3. **Phase 3**: 跨NUMA访问流量矩阵分析
4. **Phase 4**: RMA占比分析
5. **Phase 5**: 进程级NUMA访问分析
6. **Phase 6**: NUMA优化建议生成

## 关键阈值

| NUMA指标 | 正常范围 | Elevated阈值 | Critical阈值 |
|----------|---------|------------|-------------|
| NUMA Score | > 0.8 | < 0.8 | < 0.5 |
| 跨NUMA占比 | < 10% | > 30% | > 50% |
| RMA占比 | < 10% | > 30% | > 50% |
| 进程迁移次数 | < 5次 | > 10次 | > 20次 |
| 节点内存差异 | < 30% | > 50% | > 80% |
| 节点CPU差异 | < 30% | > 50% | > 80% |

## NUMA Score计算

```
score = (max cost - real cost) / (max cost - min cost)
real cost = SUM(numa distance(i, j) * access percentage(i, j))
max cost = MAX(numa distance)
min cost = MIN(numa distance)
```

**Score含义**:
- Score = 1.0 → 全本地访问（最优）
- Score = 0.0 → 全跨NUMA访问（最差）

## NUMA距离

| NUMA距离 | 访问类型 | 延迟差异 |
|---------|---------|---------|
| 10 | 本地访问 | 基准延迟 |
| 12 | 跨NUMA访问 | +20%延迟 |

## NUMA优化建议

```bash
# 禁用NUMA自动均衡
sysctl -w kernel.numa_balancing=0

# 绑定进程到NUMA节点
numactl --cpunodebind=0 --membind=0 <command>

# 启用zone reclaim
sysctl -w vm.zone_reclaim_mode=1
```

## 输出报告示例

```markdown
## NUMA Score评估

**NUMA Score**: 1.00 (Excellent)
**状态**: Optimal
**瓶颈级别**: None

## 跨NUMA访问流量矩阵

| SRC节点 | DST节点 | 流量(GB) | NUMA距离 | 占比(%) | 状态 |
|---------|---------|----------|----------|---------|------|
| Node0 | Node0 | 0.00 | 10 | 0.00 | Local |
| Node1 | Node1 | 0.32 | 10 | 100.00 | Local |

**跨NUMA流量**: 0.00 GB
**跨NUMA占比**: 0.00 %

## 进程级NUMA访问分析

| PID | SCORE | ACCESS | RMA(GB) | LMA(GB) | %RMA | 迁移次数 |
|-----|-------|--------|---------|---------|------|---------|
| 2964437 | 1.00 | 100.00% | 0.00 | 0.32 | 0.00 | 0|2 |
```

## 注意事项

1. NUMA Score=1.0表示全本地访问，Score=0表示全跨NUMA访问
2. Kunpeng-920本地距离10，跨NUMA距离12，延迟差异约20%
3. RMA占比高不一定有问题，需结合应用特性判断
4. 进程迁移开销大，需禁用NUMA自动均衡并绑定进程
5. 内存分布差异大时，需考虑数据分布策略

## 版本

- DevKit版本: 26.0.RC1
- 技能版本: 1.0
- 支持平台: Kunpeng-920