---
name: devkit-turbostat-analysis
description: DevKit CPU频率与功耗散热分析技能。专门分析devkit_turbostat.txt数据文件，提取CPU频率、Uncore频率、功耗、温度、识别频率波动、降频、散热问题、生成功耗和散热优化建议。当用户需要CPU频率分析、功耗分析或散热优化时触发此技能。
---

# devkit-turbostat-analysis — DevKit CPU频率与功耗散热分析技能

本技能专门分析`devkit_turbostat.txt`文件，提取CPU频率、Uncore频率、功耗、温度、识别频率波动、降频、散热问题、生成功耗和散热优化建议。

---

## 适用场景

当用户提供`devkit_turbostat.txt`数据文件，或需要：
- CPU频率分析
- Uncore频率分析
- CPU功耗分析
- CPU温度分析
- 频率波动识别
- 降频问题诊断
- 散热问题诊断
- 功耗优化建议

---

## 数据文件

**输入文件**: `devkit_turbostat.txt`

**文件格式示例**:
```
CPU and Server Status Summary Report                    Time:2026/05/07 11:52:55
================================================================================

Per NUMA Frequency Table
--------------------------------------------------------------------------------
──────────────────────────────────────────────────────────
| NUMA ID | CPU Frequency (MHz) | Uncore Frequency (MHz) |
──────────────────────────────────────────────────────────
|       0 | N/A                 | N/A                    |
|       1 | N/A                 | N/A                    |
──────────────────────────────────────────────────────────

CPU Core Frequency Table
--------------------------------------------------------------------------------
────────────────────────────────────────────────────────────
| Logical ID | Physical ID | NUMA ID | Frequency (MHz) |
────────────────────────────────────────────────────────────
|          0 |           0 |       0 | N/A             |
|          1 |           1 |       0 | N/A             |
|          2 |           2 |       0 | N/A             |
...
|         127 |         127 |       1 | N/A             |
────────────────────────────────────────────────────────────

CPU Socket Power and Temperature Table (In-band)
--------------------------------------------------------------------------------
────────────────────────────────────────────────────────────────────────────────────────────────────────────
| CPU Socket ID | CPU Socket Power (W) | CPU Socket Die0 Temperature (C) | CPU Socket Die1 Temperature (C) |
────────────────────────────────────────────────────────────────────────────────────────────────────────────
|             0 | N/A                  | N/A                             | N/A                             |
|             1 | N/A                  | N/A                             | N/A                             |
────────────────────────────────────────────────────────────────────────────────────────────────────────────

CPU Socket Temperature Table (Out-of-band, '--bmc' required)
--------------------------------------------------------------------------------
──────────────────────────────────────────────────────────────────────────────────────
| CPU Socket ID | CPU Socket Temperature (C) | CPU Socket Mem Temperature (C) |
──────────────────────────────────────────────────────────────────────────────────────
|             0 | N/A                        | N/A                            |
|             1 | N/A                        | N/A                            |
──────────────────────────────────────────────────────────────────────────────────────

Server status Table (Out-of-band, '--bmc' required)
--------------------------------------------------------------------------------
Total Server Power (W): N/A
Total CPU Power (W): N/A
Total Memory Power (W): N/A
Inlet Temperature (C): N/A
Outlet Temperature (C): N/A
```

---

## 分析流程

### Phase 1: 数据文件读取与验证

**目标**: 读取并验证turbostat数据文件

**执行步骤**:
1. 检查`devkit_turbostat.txt`文件是否存在
2. 读取文件内容
3. 验证文件格式是否正确
4. 提取采集时间、CPU型号、数据来源（In-band/Out-of-band）

**输出**: 文件验证状态、基础信息、数据来源标识

**注意事项**:
- In-band数据: CPU频率、Socket功耗和温度（Linux内核采集）
- Out-of-band数据: CPU温度、内存温度、服务器功耗（BMC采集，需--bmc参数）
- N/A表示数据未采集或驱动不可用

---

### Phase 2: CPU频率分析

**目标**: 提取并分析CPU核心频率

**CPU频率指标**:
- **CPU Frequency (MHz)**: CPU核心当前频率
- **Base Frequency**: CPU基频（如2.6 GHz）
- **Maximum Frequency**: CPU最大频率

**频率数据来源**:
- In-band: 从`/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`读取
- Kunpeng-920: cpufreq驱动可能不可用，频率显示N/A

**频率状态判定**:
| 频率状态 | 频率范围 | 性能评估 | 说明 |
|---------|---------|---------|------|
| Base Frequency | Base Frequency | Normal | 正常运行频率 |
| High Frequency | > Base Frequency | High Performance | Turbo Boost启用 |
| Low Frequency | < Base Frequency * 0.8 | Power Saving | 降频（节能或散热问题） |
| N/A | N/A | Unknown | 频率驱动不可用 |

**频率波动分析**:
- 频率波动范围 > 20% → 频率不稳定，需检查频率策略
- 频率持续低于基频 → 降频问题，散热或功耗限制
- 频率持续高于基频 → Turbo Boost启用，功耗增加

**CPU核心频率分布**:
- 频率一致性: 所有核心频率相近 → 负载均衡
- 频率不一致: 部分核心频率低 → 核心负载不均衡或降频

---

### Phase 3: Uncore频率分析

**目标**: 提取并分析Uncore频率（LLC频率）

**Uncore频率指标**:
- **Uncore Frequency (MHz)**: Uncore（Last Level Cache）频率
- Uncore包含L3 Cache、内存控制器、系统互连

**Uncore频率作用**:
- 影响L3 Cache访问速度
- 影响内存访问延迟
- 影响跨NUMA通信速度

**Uncore频率判定**:
| Uncore频率 | 性能评估 | 说明 |
|-----------|---------|------|
| Base Uncore Frequency | Normal | 正常运行 |
| High Uncore Frequency | High Performance | Uncore性能高，内存访问快 |
| Low Uncore Frequency | Power Saving | Uncore降频，内存访问延迟增加 |
| N/A | Unknown | Uncore频率监控不可用 |

**Uncore与CPU频率关系**:
- Uncore频率应接近CPU频率
- Uncore频率低 → 内存访问延迟增加，Memory Bound增加

---

### Phase 4: CPU功耗分析

**目标**: 提取并分析CPU Socket功耗

**功耗指标**:
- **CPU Socket Power (W)**: CPU Socket总功耗
- **Total CPU Power (W)**: 所有CPU总功耗（Out-of-band）
- **Total Server Power (W)**: 服务器总功耗（Out-of-band）
- **Total Memory Power (W)**: 内存总功耗（Out-of-band）

**功耗阈值判定**（Kunpeng-920参考）:
| 功耗值 | 状态 | 说明 |
|--------|------|------|
| < 100W | Low | 低负载或降频 |
| 100-150W | Normal | 正常功耗 |
| 150-200W | High | 高负载 |
| > 200W | Critical | 功耗过高，可能降频 |

**功耗分析**:
- 功耗低 + CPU频率低 → 降频问题
- 功耗高 + CPU频率低 → 散热限制降频
- 功耗波动大 → 负载波动大或频率策略不稳定

**Socket功耗对比**:
- Socket 0功耗 vs Socket 1功耗差异 > 30% → 负载不均衡
- Socket功耗均衡 → NUMA负载均衡

---

### Phase 5: CPU温度分析

**目标**: 提取并分析CPU温度

**温度指标**:
- **CPU Socket Die0 Temperature (C)**: CPU Die0温度（In-band）
- **CPU Socket Die1 Temperature (C)**: CPU Die1温度（In-band）
- **CPU Socket Temperature (C)**: CPU Socket温度（Out-of-band）
- **CPU Socket Mem Temperature (C)**: CPU附近内存温度（Out-of-band）
- **Inlet Temperature (C)**: 进风口温度（Out-of-band）
- **Outlet Temperature (C)**: 出风口温度（Out-of-band）

**温度阈值判定**:
| 温度值 | 状态 | 说明 |
|--------|------|------|
| < 60°C | Normal | 温度正常，散热良好 |
| 60-80°C | Elevated | 温度较高，需关注 |
| 80-90°C | High | 温度高，接近降频阈值 |
| > 90°C | Critical | 温度过高，可能降频或关机保护 |

**降频阈值**（参考）:
- Kunpeng-920降频阈值: ~95°C（需验证）
- Intel降频阈值: 100°C（PROCHOT）

**温度分析**:
- Die温度高 → CPU核心散热压力大
- Socket温度高 → CPU整体散热压力大
- Mem温度高 → 内存散热压力大
- Inlet温度高 → 环境温度高，散热效率低
- Outlet温度高 → 散热系统效率低

**温度波动分析**:
- 温度波动 > 10°C → 散热不稳定
- 温度持续上升 → 散热系统异常

---

### Phase 6: 功耗和散热优化建议生成

**目标**: 生成结构化的功耗和散热优化报告

**报告结构**:

```markdown
# CPU频率与功耗散热分析报告

**采集时间**: YYYY/MM/DD HH:MM:SS
**分析时间**: YYYY-MM-DD HH:MM:SS
**CPU型号**: Kunpeng-920
**数据来源**: [In-band/Out-of-band/Both]
**基频**: 2.6 GHz

## 1. CPU频率分析

### 1.1 NUMA节点频率

| NUMA节点 | CPU频率(MHz) | Uncore频率(MHz) | 状态 |
|---------|------------|----------------|------|
| Node 0 | XX | XX | [状态] |
| Node 1 | XX | XX | [状态] |

**频率评估**: [Normal/Low/High/Unknown]

### 1.2 CPU核心频率分布

| CPU核心范围 | 频率(MHz) | 状态 | 说明 |
|-----------|----------|------|------|
| CPU 0-63 | XX | [状态] | Node0核心频率 |
| CPU 64-127 | XX | [状态] | Node1核心频率 |

**频率一致性**: [Consistent/Inconsistent]
**频率波动范围**: XX MHz

**评估**:
- 频率正常 → CPU性能稳定
- 频率低 → 降频问题，散热或功耗限制
- 频率波动大 → 频率策略不稳定

### 1.3 频率波动分析

**频率分布统计**:
- 最高频率: XX MHz
- 最低频率: XX MHz
- 平均频率: XX MHz
- 频率波动范围: XX MHz (XX%)

**状态**: [Stable/Unstable]
**瓶颈级别**: [None/Medium/High]

**问题识别**:
- 频率波动 > 20% → 频率策略不稳定
- 部分核心频率异常 → 核心散热不均衡
- 频率持续低于基频 → 降频问题

## 2. Uncore频率分析

### 2.1 Uncore频率评估

**Uncore频率**: XX MHz
**状态**: [Normal/Low/High/Unknown]

**Uncore性能影响**:
- Uncore频率低 → L3 Cache访问延迟增加
- Uncore频率低 → 内存访问延迟增加
- Uncore频率低 → Memory Bound增加

### 2.2 Uncore与CPU频率对比

**CPU频率**: XX MHz
**Uncore频率**: XX MHz
**比率**: Uncore频率 / CPU频率 = XX

**评估**:
- 比率接近1 → Uncore与CPU同步
- 比率 < 0.8 → Uncore降频，内存性能降低

## 3. CPU功耗分析

### 3.1 Socket功耗

| Socket ID | 功耗(W) | 状态 | 说明 |
|----------|---------|------|------|
| Socket 0 | XX | [状态] | Node0功耗 |
| Socket 1 | XX | [状态] | Node1功耗 |

**总CPU功耗**: XX W
**状态**: [Low/Normal/High/Critical]

**功耗对比**: Socket 0 XX W vs Socket 1 XX W
**功耗差异**: XX %
**状态**: [Balanced/Imbalanced]

### 3.2 服务器功耗（Out-of-band）

**服务器总功耗**: XX W
**CPU总功耗**: XX W
**内存总功耗**: XX W

**功耗分布**:
- CPU功耗占比: XX %
- 内存功耗占比: XX %

**评估**: 功耗分布合理

### 3.3 功耗波动分析

**功耗波动范围**: XX W
**状态**: [Stable/Unstable]

**问题识别**:
- 功耗波动大 → 负载波动大
- 功耗持续高 → 高负载或散热限制

## 4. CPU温度分析

### 4.1 CPU Die温度（In-band）

| Socket ID | Die0温度(°C) | Die1温度(°C) | 状态 |
|----------|------------|------------|------|
| Socket 0 | XX | XX | [状态] |
| Socket 1 | XX | XX | [状态] |

**最高温度**: XX °C
**平均温度**: XX °C
**状态**: [Normal/Elevated/High/Critical]

**降频风险评估**:
- 温度 < 80°C → 无降频风险
- 温度 80-90°C → 降频风险Medium
- 温度 > 90°C → 降频风险High，可能降频保护

### 4.2 CPU Socket温度（Out-of-band）

| Socket ID | Socket温度(°C) | Mem温度(°C) | 状态 |
|----------|--------------|------------|------|
| Socket 0 | XX | XX | [状态] |
| Socket 1 | XX | XX | [状态] |

**评估**: Socket温度和内存温度分布

### 4.3 服务器散热温度（Out-of-band）

**进风口温度**: XX °C
**出风口温度**: XX °C
**温差**: XX °C

**散热效率评估**:
- 温差 > 20°C → 散热效率正常
- 温差 < 10°C → 散热效率低，需检查风扇

**环境温度评估**:
- 进风口温度 < 25°C → 环境温度正常
- 进风口温度 > 30°C → 环境温度高，散热压力大

### 4.4 温度波动分析

**温度波动范围**: XX °C
**状态**: [Stable/Unstable]

**问题识别**:
- 温度波动大 → 散热不稳定
- 温度持续上升 → 散热系统异常
- 温度接近降频阈值 → 降频风险高

## 5. 功耗和散热问题汇总

### 问题1: CPU降频问题（Critical）

**问题描述**:
- CPU频率持续低于基频（XX MHz < 2600 MHz）
- 降频幅度: XX %

**根本原因**:
- CPU温度过高（XX °C），触发降频保护
- 功耗限制（XX W），触发功耗降频
- 散热系统效率低

**影响**:
- CPU性能降低XX %
- IPC降低
- 应用延迟增加

**证据链**:
- CPU频率 XX MHz (Low)
- CPU温度 XX °C (High/Critical)
- 功耗 XX W (High)

### 问题2: CPU温度过高（High）

**问题描述**:
- CPU温度XX °C，接近降频阈值
- 散热压力大

**根本原因**:
- 环境温度高（进风口XX °C）
- 散热系统效率低（温差XX °C）
- CPU负载高，功耗高
- 机箱风道不合理

**影响**:
- 降频风险高
- CPU性能不稳定
- 系统稳定性降低

### 问题3: 散热系统效率低（Medium）

**问题描述**:
- 进风口出风口温差XX °C（< 10°C）
- 散热效率低

**根本原因**:
- 风扇转速低
- 风道阻塞
- 机箱通风不合理
- 环境温度高

**影响**:
- CPU温度高
- 降频风险增加

### 问题4: 功耗波动大（Medium）

**问题描述**:
- 功耗波动范围XX W（> 30%）
- 功耗不稳定

**根本原因**:
- 负载波动大
- 频率策略不稳定
- Turbo Boost频繁开关

**影响**:
- 功耗不稳定
- 频率波动
- 性能波动

### 问题5: Uncore频率低（Low）

**问题描述**:
- Uncore频率XX MHz（低于CPU频率）
- Uncore降频

**根本原因**:
- Uncore功耗限制
- Uncore散热限制
- 频率策略不合理

**影响**:
- L3 Cache访问延迟增加
- 内存访问延迟增加
- Memory Bound增加

## 6. 功耗和散热优化建议

### 建议1: 散热系统优化（Critical）

**优化方案**:

**环境温度控制**:
- 降低机房温度至22-25°C
- 增加空调制冷能力
- 避免阳光直射服务器

**机箱散热优化**:
- 检查风扇转速，确保风扇正常工作
- 清理机箱内部灰尘，疏通风道
- 检查机箱通风孔是否阻塞
- 增加辅助风扇（如有空间）

**服务器布局优化**:
- 增加服务器间距，提高散热空间
- 避免服务器密集堆叠
- 机柜通风优化

**预期效果**: CPU温度降低5-10°C，降频风险降低

### 建议2: CPU频率策略优化（High）

**优化方案（根据实际提取数据进行调整）**:

**启用performance频率策略**:
```bash
cpupower frequency-set -g performance
```

**设置频率范围**:
```bash
cpupower frequency-set -d 2600MHz -u 2600MHz  # 固定频率
```

**禁用cpu boost**（如散热压力大）:
```bash
echo 0 > /sys/devices/system/cpu/cpufreq/boost
```

**预期效果**: 频率稳定，性能稳定

### 建议3: 功耗管理优化（Medium）

**优化方案（根据实际提取数据进行调整）**:

**功耗限制配置**（适用于功耗敏感场景）:
```bash
# 设置功耗限制（需BMC支持）
ipmitool raw 0x2e 0xc8 0x00 0x00 0x00 [功耗值]
```

**功耗策略**:
- 低负载场景: 启用powersave策略，降低功耗
- 高负载场景: 启用performance策略，提高性能
- 混合场景: 启用ondemand策略，动态调整

**预期效果**: 功耗稳定，根据场景优化功耗-性能平衡

### 建议4: CPU核心绑定优化（Low）

**优化方案**:

**减少核心竞争，降低功耗波动**:
```bash
# 绑定进程到部分核心，其他核心idle
taskset -c 0-31 <command>  # 只使用32核，其他96核idle
```

**NUMA绑定**:
```bash
numactl --cpunodebind=0 --membind=0 <command>
```

**预期效果**: 降低功耗波动，提高核心利用率

### 建议5: Uncore频率优化（Low）

**优化方案**:

**提高Uncore频率**（需BIOS支持）:
- BIOS中配置Uncore频率策略
- 设置Uncore频率为高性能模式

**预期效果**: L3 Cache和内存访问延迟降低

## 7. 执行步骤

### 步骤1: 检查当前频率和温度状态
```bash
devkit tuner turbostat -d 5
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
```

### 步骤2: 检查频率策略
```bash
cpupower frequency-info
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### 步骤3: 设置频率策略
```bash
cpupower frequency-set -g performance
```

### 步骤4: 检查散热系统
```bash
# 检查风扇状态（需BMC）
ipmitool sensor list | grep -i fan

# 检查温度（需BMC）
ipmitool sensor list | grep -i temp
```

### 步骤5: 环境温度优化
- 降低机房温度至22-25°C
- 清理机箱灰尘
- 检查风道

### 步骤6: 监控频率和温度变化
```bash
devkit tuner turbostat -d 10
```

### 步骤7: 验证优化效果
- 目标: CPU频率稳定在2600 MHz
- 目标: CPU温度降低至< 80°C
- 目标: 功耗波动降低至< 20%

## 8. 功耗温度时序图

**采集时段1**:
- CPU频率: XX MHz
- CPU温度: XX °C
- 功耗: XX W

**采集时段2**:
- CPU频率: XX MHz
- CPU温度: XX °C
- 功耗: XX W

**趋势分析**: [频率/温度/功耗趋势描述]

## 9. BMC数据采集说明

**Out-of-band数据采集**（需BMC支持）:
```bash
devkit tuner turbostat -d 5 --bmc [BMC_IP] --bmc-user [用户] --bmc-password [密码]
```

**BMC数据包括**:
- CPU Socket温度
- 内存温度
- 服务器总功耗
- CPU总功耗
- 内存功耗
- 进风口/出风口温度
- 风扇转速

**BMC数据优势**:
- 更准确的温度数据
- 更全面的功耗数据
- 散热系统状态

**注意事项**:
- BMC连接需IPMI工具支持
- BMC密码需妥善保管
- BMC数据采集需服务器BMC支持
```

---

## 输出文件

**报告文件名**: `turbostat_analysis_report_YYYYMMDD_HHMMSS.md`
**保存位置**: 当前工作目录或profiling数据包目录

---

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

---

## 注意事项

1. **频率驱动**: Kunpeng-920 cpufreq驱动可能不可用，频率显示N/A，需使用其他方式监控
2. **降频阈值**: Kunpeng-920降频阈值约95°C（需实际验证）
3. **BMC数据**: Out-of-band数据需BMC连接，使用--bmc参数
4. **Turbo Boost**: Kunpeng-920不支持Turbo Boost，频率固定
5. **功耗数据**: In-band功耗数据可能不准确，建议使用BMC数据
6. **散热系统**: 温度高需检查环境温度、风扇转速、风道
7. **频率策略**: performance策略固定频率，powersave策略降频节能
8. **数据采集**: turbostat数据需多次采集观察趋势，单次采集可能不准确