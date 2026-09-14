# DevKit CPU频率与功耗散热分析技能

## 概述

本技能专门分析`devkit_turbostat.txt`数据文件，提取CPU频率、Uncore频率、功耗、温度、识别频率波动、降频、散热问题、生成功耗和散热优化建议。

## 适用场景

- CPU频率分析
- Uncore频率分析
- CPU功耗分析
- CPU温度分析
- 频率波动识别
- 降频问题诊断
- 散热问题诊断
- 功耗优化建议

## 数据文件

**输入**: `devkit_turbostat.txt`

**输出**: `turbostat_analysis_report_YYYYMMDD_HHMMSS.md`

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
2. **Phase 2**: CPU频率分析
3. **Phase 3**: Uncore频率分析
4. **Phase 4**: CPU功耗分析
5. **Phase 5**: CPU温度分析
6. **Phase 6**: 功耗和散热优化建议生成

## 关键阈值

| 频率/温度/功耗指标 | 正常范围 | Elevated阈值 | Critical阈值 |
|------------------|---------|------------|-------------|
| CPU频率 | Base Frequency | < Base * 0.8 | < Base * 0.6 |
| Uncore频率 | CPU频率 | < CPU * 0.8 | < CPU * 0.6 |
| 频率波动范围 | < 10% | > 20% | > 30% |
| CPU温度 | < 60°C | > 80°C | > 90°C |
| Socket功耗 | < 150W | > 200W | > 250W |
| 功耗波动范围 | < 20% | > 30% | > 50% |
| 进风口温度 | < 25°C | > 30°C | > 35°C |
| 进出风口温差 | > 20°C | < 15°C | < 10°C |
| Socket功耗差异 | < 30% | > 50% | > 80% |

## 频率状态判定

| 频率状态 | 频率范围 | 性能评估 | 说明 |
|---------|---------|---------|------|
| Base Frequency | Base Frequency | Normal | 正常运行频率 |
| High Frequency | > Base Frequency | High Performance | Turbo Boost启用 |
| Low Frequency | < Base * 0.8 | Power Saving | 降频（节能或散热问题） |
| N/A | N/A | Unknown | 频率驱动不可用 |

## CPU温度判定

| 温度值 | 状态 | 说明 |
|--------|------|------|
| < 60°C | Normal | 温度正常，散热良好 |
| 60-80°C | Elevated | 温度较高，需关注 |
| 80-90°C | High | 温度高，接近降频阈值 |
| > 90°C | Critical | 温度过高，可能降频或关机 |

**Kunpeng-920降频阈值**: ~95°C

## 功耗阈值

| 功耗值 | 状态 | 说明 |
|--------|------|------|
| < 100W | Low | 低负载或降频 |
| 100-150W | Normal | 正常功耗 |
| 150-200W | High | 高负载 |
| > 200W | Critical | 功耗过高，可能降频 |

## 数据来源说明

| 数据类型 | 来源 | 说明 |
|---------|------|------|
| CPU频率 | In-band | Linux内核采集 |
| Socket功耗/温度 | In-band | 内核驱动采集 |
| CPU温度/内存温度 | Out-of-band | BMC采集（需--bmc参数） |
| 服务器功耗 | Out-of-band | BMC采集 |

## 频率策略优化

```bash
# 启用performance策略
cpupower frequency-set -g performance

# 固定频率
cpupower frequency-set -d 2600MHz -u 2600MHz

# 禁用Turbo Boost
echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
```

## 散热优化建议

**环境温度控制**:
- 降低机房温度至22-25°C
- 增加空调制冷能力

**机箱散热优化**:
- 检查风扇转速
- 清理机箱内部灰尘
- 疏通风道

## 输出报告示例

```markdown
## CPU频率分析

| NUMA节点 | CPU频率(MHz) | Uncore频率(MHz) | 状态 |
|---------|------------|----------------|------|
| Node 0 | 2600 | 2600 | Normal |
| Node 1 | 2600 | 2600 | Normal |

**频率评估**: Normal

## CPU功耗分析

| Socket ID | 功耗(W) | 状态 |
|----------|---------|------|
| Socket 0 | 120 | Normal |
| Socket 1 | 130 | Normal |

**总CPU功耗**: 250 W

## CPU温度分析

| Socket ID | Die0温度(°C) | Die1温度(°C) | 状态 |
|----------|------------|------------|------|
| Socket 0 | 55 | 58 | Normal |
| Socket 1 | 60 | 62 | Elevated |

**最高温度**: 62 °C
**降频风险**: None
```

## 注意事项

1. Kunpeng-920 cpufreq驱动可能不可用，频率显示N/A
2. Kunpeng-920降频阈值约95°C（需实际验证）
3. Out-of-band数据需BMC连接，使用--bmc参数
4. Kunpeng-920不支持Turbo Boost，频率固定
5. In-band功耗数据可能不准确，建议使用BMC数据
6. 温度高需检查环境温度、风扇转速、风道
7. performance策略固定频率，powersave策略降频节能
8. turbostat数据需多次采集观察趋势

## BMC数据采集

```bash
devkit tuner turbostat -d 5 --bmc [BMC_IP] --bmc-user [用户] --bmc-password [密码]
```

**BMC数据包括**:
- CPU Socket温度
- 内存温度
- 服务器总功耗
- 进风口/出风口温度
- 风扇转速

## 相关技能

- `devkit-ksys-analysis`: 结合IPC和MPKI验证频率影响
- `devkit-topdown-analysis`: 结合微架构瓶颈验证散热影响
- `devkit-kspect-analysis`: 结合CPU配置检查频率策略
- `application-optimization`: 高负载应用频率优化
- `tuning-recommendation-generator`: 综合调优建议

## 版本

- DevKit版本: 26.0.RC1
- 技能版本: 1.0
- 支持平台: Kunpeng-920