---
name: recommendation-template
description: 调优建议表格模板，定义标准的输出格式
---

# 调优建议表格模板

本文档定义调优建议的标准输出格式。

---

## 标准表格格式

### 简化表格（用于快速概览）

| 序号 | 瓶颈类型 | 严重程度 | 优化手段 | 预期效果 |
|-----|---------|---------|---------|---------|
| 1 | [类型] | [Critical/High/Medium/Low] | [参数名称] | [预期改善] |
| 2 | [类型] | [Critical/High/Medium/Low] | [参数名称] | [预期改善] |

### 完整表格（用于详细报告）

| 瓶颈描述 | 调优方案 | 关联的性能数据 | 关联的调优手段 | 具体的执行步骤 |
|---------|---------|--------------|-------------------|--------------|
| **[瓶颈名称]**<br><br>[详细描述瓶颈现象、位置、影响范围]<br><br>严重程度: [Critical/High/Medium/Low]<br>影响进程: [进程列表] | **调优方向**:<br>[概述调优方向]<br><br>**预期效果**:<br>[描述预期的性能改善]<br><br>**风险评估**:<br>[低/中/高] | **关键指标**:<br>- 指标1: 数值 (阈值, 状态)<br>- 指标2: 数值 (阈值, 状态)<br><br>**数据来源**:<br>- [文件名]: [行号范围]<br><br>**分析时间**: [时间戳] | **参数1**: [参数路径]<br>- 说明: [参数说明]<br>- 当前值: [值]<br>- 推荐值: [值]<br>- 调整命令: `sysctl -w ...`<br><br>**参数2**: [参数路径]<br>- 说明: [参数说明]<br>- 当前值: [值]<br>- 推荐值: [值]<br>- 调整命令: `sysctl -w ...` | **步骤1**: [操作描述]<br>```bash<br>command<br>```<br><br>**步骤2**: [操作描述]<br>```bash<br>command<br>```<br><br>**备注**: 脚本名称: [script_name.sh]<br>下载链接: [URL] |

---

## 表格字段详细说明

### 1. 瓶颈描述

**内容要求**:
- 瓶颈名称（加粗）
- 详细描述瓶颈现象
- 瓶颈位置（具体组件、进程、设备）
- 影响范围（哪些进程、资源受影响）
- 严重程度分级
- 影响进程列表

**示例**:
```
**CPU I/O等待过高**

系统CPU花费大量时间等待I/O完成，导致整体响应延迟增加。
主要影响: mysqld进程 (PID: 12345)
影响范围: 所有依赖磁盘I/O的查询操作

严重程度: High
影响进程: mysqld (PID: 12345), jbd2/sda1-8 (PID: 678)
```

### 2. 调优方案

**内容要求**:
- 调优方向概述
- 预期效果描述
- 风险评估（低/中/高）
- 时间估算（可选）

**示例**:
```
**调优方向**:
优化磁盘I/O调度策略，减少I/O等待时间

**预期效果**:
CPU iowait从35%降低到15%以下，查询延迟降低30%

**风险评估**: 低

**时间估算**: 立即生效（运行时调整）
```

### 3. 关联的性能数据

**内容要求**:
- 关键指标列表（指标名、数值、阈值、状态）
- 数据来源（文件名、行号）
- 分析时间戳
- 支撑证据

**示例**:
```
**关键指标**:
- %iowait: 35.2% (阈值: 20%, 状态: Critical)
- 磁盘util: 95.8% (阈值: 90%, 状态: Critical)
- await: 45.3ms (阈值: 20ms, 状态: High)

**数据来源**:
- global_bottleneck.txt: 第45-52行
- microarch_analysis.txt: 第78-82行

**分析时间**: 2026-04-27 11:07:23
```

### 4. 关联的需要调整的参数

**内容要求**:
- 参数名称和路径
- 参数说明
- 当前值
- 推荐值
- 调整命令
- 安全注意事项

**示例**:
```
**参数1**: /sys/block/sda/queue/scheduler
- 说明: I/O调度器选择
- 当前值: cfq
- 推荐值: mq-deadline
- 调整命令: echo mq-deadline > /sys/block/sda/queue/scheduler
- 安全注意: SSD设备建议使用none或mq-deadline

**参数2**: vm.dirty_ratio
- 说明: dirty page占比上限
- 当前值: 20
- 推荐值: 10
- 调整命令: sysctl -w vm.dirty_ratio=10
- 安全注意: 降低可能增加I/O频率
```

### 5. 具体的执行步骤

**内容要求**:
- 步骤编号和描述
- 具体命令（代码块）
- 验证命令
- 回滚命令
- 备注信息（脚本名称、下载链接）

**示例**:
```
**步骤1**: 查看当前I/O调度器
```bash
cat /sys/block/sda/queue/scheduler
```

**步骤2**: 切换I/O调度器为mq-deadline
```bash
echo mq-deadline > /sys/block/sda/queue/scheduler
```

**步骤3**: 验证调整结果
```bash
cat /sys/block/sda/queue/scheduler
```

**步骤4**: 监控I/O性能
```bash
iostat -xz 5 10
```

**备注**: 
- 脚本名称: io_scheduler_tuning.sh
- 下载链接: https://example.com/scripts/io_scheduler_tuning.sh
```

---

## 表格优先级排序

调优建议表格应按以下优先级排序：

1. **Critical级别瓶颈**: 优先展示Critical级别的瓶颈
2. **根本原因瓶颈**: 如果多个瓶颈存在因果关系，优先展示根本原因
3. **High级别瓶颈**: 其次展示High级别瓶颈
4. **Medium/Low级别瓶颈**: 最后展示中低级别瓶颈

---

## 表格完整性检查

生成表格后，检查以下内容：

- [ ] 所有瓶颈都已包含在表格中
- [ ] 每个瓶颈都有对应的性能数据支撑
- [ ] 每个瓶颈都有明确的调优手段建议
- [ ] 每个瓶颈都有可执行的命令
- [ ] 所有参数都提供了安全注意事项
- [ ] 表格已保存到文件并输出给用户

---

## 示例完整表格

| 瓶颈描述 | 调优方案 | 关联的性能数据 | 关联的调优手段 | 具体的执行步骤 |
|---------|---------|--------------|-------------------|--------------|
| **磁盘I/O饱和**<br><br>磁盘sda利用率达到95.8%，I/O等待时间过长，严重影响系统响应速度。主要影响mysqld数据库进程的读写操作。<br><br>严重程度: **Critical**<br>影响进程: mysqld (PID: 12345), jbd2/sda1-8 (PID: 678) | **调优方向**:<br>优化I/O调度器，减少I/O等待延迟<br><br>**预期效果**:<br>磁盘util从95.8%降低到70%以下，I/O等待时间从45ms降低到20ms以内<br><br>**风险评估**: 低<br><br>**时间估算**: 立即生效 | **关键指标**:<br>- %util: 95.8% (阈值: 90%, 状态: Critical)<br>- await: 45.3ms (阈值: 20ms, 状态: High)<br>- %iowait: 35.2% (阈值: 20%, 状态: Critical)<br><br>**数据来源**:<br>- global_bottleneck.txt: 第45-52行<br><br>**分析时间**: 2026-04-27 11:07:23 | **参数1**: /sys/block/sda/queue/scheduler<br>- 说明: I/O调度器<br>- 当前值: cfq<br>- 推荐值: mq-deadline<br>- 调整命令: `echo mq-deadline > /sys/block/sda/queue/scheduler`<br><br>**参数2**: vm.dirty_ratio<br>- 说明: dirty page占比上限<br>- 当前值: 20<br>- 推荐值: 10<br>- 调整命令: `sysctl -w vm.dirty_ratio=10` | **步骤1**: 查看当前I/O调度器<br>```bash<br>cat /sys/block/sda/queue/scheduler<br>```<br><br>**步骤2**: 切换I/O调度器<br>```bash<br>echo mq-deadline > /sys/block/sda/queue/scheduler<br>```<br><br>**步骤3**: 调整dirty_ratio<br>```bash<br>sysctl -w vm.dirty_ratio=10<br>```<br><br>**步骤4**: 监控效果<br>```bash<br>iostat -xz 5 10<br>```<br><br>**备注**: 脚本名称: io_tuning.sh<br>下载链接: https://example.com/scripts/io_tuning.sh |

---

## 报告头部信息

每个调优建议报告应包含以下头部信息：

```markdown
# 系统调优建议报告

**生成时间**: YYYY-MM-DD HH:MM:SS
**系统环境**: 
- CPU: [型号, 核心数, NUMA配置]
- 内存: [总大小, NUMA分布]
- 磁盘: [设备列表, 类型, 调度器]
- 网络: [网卡列表, 配置]
- 操作系统: [发行版, 内核版本]

**主要瓶颈**: [Primary Bottleneck名称]
**瓶颈数量**: [Critical: N, High: M, Medium: K, Low: L]

**分析数据来源**:
- static_info.txt
- global_bottleneck.txt
- top_processes.txt
- hotspot_analysis.txt
- microarch_analysis.txt
- [其他数据文件]
```

---

## 注意事项

1. **表格宽度**: 表格可能很宽，建议在Markdown阅读器中横向滚动查看
2. **代码块**: 执行步骤中的命令使用代码块格式，便于复制
3. **链接**: 所有脚本都应提供下载链接（如果适用）
4. **版本**: 在报告头部注明分析工具和技能版本
5. **安全**: 所有参数调整都应包含安全注意事项