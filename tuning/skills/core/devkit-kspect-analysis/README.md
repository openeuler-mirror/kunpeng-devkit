# DevKit系统静态配置分析技能

## 概述

本技能专门分析`devkit_kspect.txt`数据文件，提取系统静态配置(CPU、NUMA、内存、网卡、存储)、识别配置问题(内存插法、NUMA拓扑、网卡归属)、生成系统配置优化建议。

## 适用场景

- 系统静态配置分析
- CPU配置检查
- NUMA拓扑分析
- 内存插法检查
- 网卡NUMA归属分析
- 存储配置分析
- BIOS配置检查

## 数据文件

**输入**: `devkit_kspect.txt`

**输出**: `kspect_analysis_report_YYYYMMDD_HHMMSS.md`

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
2. **Phase 2**: CPU配置分析
3. **Phase 3**: NUMA拓扑分析
4. **Phase 4**: 内存配置与插法分析
5. **Phase 5**: 网卡与存储配置分析
6. **Phase 6**: 系统配置优化建议生成

## 关键阈值

| 配置指标 | 推荐配置 | 问题配置 | 瓶颈级别 |
|----------|---------|---------|---------|
| NUMA内存差异 | < 30% | > 50% | Critical |
| 内存通道数 | 8 | < 4 | High |
| 巨页配置 | > 0 | 0 | Medium |
| NUMA Balancing | Disabled | Enabled | Medium |
| 内存速度 | 2666 MT/s | < 2666 MT/s | Low |
| Swap大小 | < MemTotal/10 | > MemTotal/2 | Medium |
| 网卡NUMA归属 | 单节点 | 多节点分散 | Low |

## CPU配置检查

| 配置项 | 推荐配置 | 说明 |
|--------|---------|------|
| Hyperthreading | Disabled | Kunpeng-920不支持超线程 |
| Memory Channels | 8 | 内存通道需充分利用 |
| L3 Cache | 256 MiB | 标准配置 |
| NUMA Nodes | 2 | 推荐2节点配置 |

## NUMA内存配置

| NUMA节点 | 推荐状态 | 问题状态 | 说明 |
|---------|---------|---------|------|
| MemTotal差异 | < 30% | > 50% | 内存分布不均衡 |
| Hugepages | > 0 | 0 | 未启用巨页 |
| NUMA Balancing | Disabled | Enabled | 导致进程迁移 |

## 内存插法分析

**警告示例**:
```
[WARNING] 当前的内存插入方法不是最佳的插入方法。
```

**推荐插法**:
- 均匀分布到各NUMA节点
- 每节点内存通道数相等
- 使用推荐插槽位置

## NUMA PCIe归属

| 设备类型 | NUMA归属 | 说明 |
|---------|---------|------|
| 网卡 | 单节点集中 | 与进程绑定一致 |
| NVMe | 与进程一致 | 减少跨NUMA访问 |

## 虚拟机场景NUMA配置

**虚拟机识别**:
- Product Name包含"Virtual Machine"、"VMware"、"KVM"、"QEMU"、"VirtualBox"等虚拟化标识
- 存在KVM Info或虚拟化相关字段

**NUMA优化策略优先级**:

| 场景 | XML配置可行 | 推荐方案 | 说明 |
|------|------------|---------|------|
| 虚拟机 | 是 | **使用virsh edit或libvirt XML配置** | 优先级最高，不推荐numactl |
| 虚拟机 | 否 | numactl绑定策略 | XML配置不可用时使用 |
| 物理机 | N/A | numactl绑定策略 | 标准方式 |

**XML配置方式判定**:
- `devkit_kspect.txt`中明确提到"可通过XML配置"、"virsh edit"、"libvirt"等关键词
- 文件中包含虚拟机NUMA绑定的配置建议

**XML配置示例**:
```xml
<!-- virsh edit <vm-name> -->
<vcpu placement='static'>8</vcpu>
<cputune>
  <vcpupin vcpu='0' cpuset='0-3'/>
  <vcpupin vcpu='1' cpuset='4-7'/>
</cputune>
<numatune>
  <memory mode='strict' nodeset='0'/>
  <memnode cellid='0' mode='strict' nodeset='0'/>
</numatune>
```

## 系统优化建议
根据上述提供的系统数据，提出对应的调优建议

**内存插法调整**（需物理操作）:
- 均匀分布内存条到各Socket
- 确保每Socket内存通道数相等
- 遵循推荐插槽位置

## 输出报告示例

```markdown
## CPU配置分析

**CPU型号**: HUAWEI Kunpeng 920 7260
**架构**: 鲲鹏
**核心数**: 128核（64核/Socket * 2 Socket）
**基频**: 2.6 GHz
**NUMA节点**: 2节点
**内存通道**: 8通道
**超线程**: Disabled

## NUMA拓扑分析

| NUMA节点 | CPU核心 | 总内存(GB) | 可用内存(GB) | Socket |
|---------|---------|----------|------------|--------|
| Node 0 | 0-63 | 62.38 | 18.96 | 0 |
| Node 1 | 64-127 | 187.99 | 134.38 | 1 |

**内存分布不均衡**: Node1内存187.99GB vs Node0内存62.38GB（差异200%）
**状态**: Imbalanced
**瓶颈级别**: Critical

## 内存插法分析

**内存插法警告**: 当前的内存插入方法不是最佳的插入方法。
**Socket 0**: 2条32GB内存（Channel 2, 3）
**Socket 1**: 6条32GB内存（Channel 0, 1, 2, 3, 6, 7）
**状态**: Imbalanced
```

## 注意事项

1. 内存插法不合理会导致NUMA内存分布不均衡，需物理调整
2. Kunpeng-920支持8通道内存，需确保所有通道使用
3. 巨页需静态配置，透明巨页性能不稳定
4. Kunpeng-920 NUMA迁移开销大，建议禁用自动均衡
5. 网卡归属NUMA节点影响网络延迟，需与进程绑定一致
6. 混用不同厂商内存可能导致性能不一致
7. BIOS部分配置需使用BMC信息（--bmc参数）
8. **虚拟机NUMA优化**: 虚拟机场景下，如果`devkit_kspect.txt`明确指出可通过XML配置解决NUMA问题，则优先使用virsh edit或libvirt XML配置，不推荐numactl方式

## 相关技能
- `tuning-recommendation-generator`: 综合调优建议

## 版本

- DevKit版本: 26.0.RC1
- 技能版本: 1.0
- 支持平台: Kunpeng-920