---
name: devkit-kspect-analysis
description: DevKit系统静态配置分析技能。专门分析devkit_kspect.txt数据文件，提取系统静态配置(CPU、NUMA、内存、网卡、存储)、识别配置问题(内存插法、NUMA拓扑、网卡归属)、生成系统配置优化建议。当用户需要系统静态配置分析或硬件配置优化时触发此技能。
scripts:
  - parse_kspect.sh
---

# devkit-kspect-analysis — DevKit系统静态配置分析技能

本技能专门分析`devkit_kspect.txt`文件，提取系统静态配置(CPU、NUMA、内存、网卡、存储)、识别配置问题(内存插法、NUMA拓扑、网卡归属)、生成系统配置优化建议。

---

## 适用场景

当用户提供`devkit_kspect.txt`数据文件，或需要：
- 系统静态配置分析
- CPU配置检查
- NUMA拓扑分析
- 内存插法检查
- 网卡NUMA归属分析
- 存储配置分析
- BIOS配置检查

---

## 数据文件

**输入文件**: `devkit_kspect.txt`

**文件格式示例**:
```
System
================================================================================

Host
────────────────────────────────────────────────────────────────────────────────

 Host Name:           localhost.localdomain        
 Time:                Thu May 07 19:52:56 CST 2026 
 Runtime:             211 days,  9:34              
 Load Average:        5.66, 3.25, 2.45             
 Local IP:            100.102.199.151              



Product
────────────────────────────────────────────────────────────────────────────────

 Manufacturer:        Huawei                               
 Product Name:        TaiShan 200 (Model 2280)             
 Version:             To be filled by O.E.M.               
 Serial:              To be filled by O.E.M.               
 UUID:                e1c5d866-0018-8034-b211-d21d8a63b324 

```

**虚拟机场景文件格式示例**:
```
Product
────────────────────────────────────────────────────────────────────────────────

 Manufacturer:        QEMU                                 
 Product Name:        Standard PC (Q35 + ICH9, 2009)       
 Version:             pc-q35-6.2                           
 Serial:              Not Specified                        
 UUID:                12345678-1234-1234-1234-123456789abc 

Software
────────────────────────────────────────────────────────────────────────────────

 KVM Info:
   Hypervisor: KVM
   VM Type: HVM
   vCPU Count: 8
   Memory: 16GB
   
Note: 可通过virsh edit修改虚拟机XML配置实现NUMA绑定
``` 

CPU
================================================================================

CPU
────────────────────────────────────────────────────────────────────────────────

 CPU Model:                         HUAWEI Kunpeng 920 7260 
 Family:                            ARM                     
 Architecture:                      aarch64                 
 Model:                             0                       
 Stepping:                          0x1                     
 Base Frequency:                    2.6 GHz                 
 Maximum Frequency:                 2.6 GHz                 
 CPUs:                              128                     
 On-line CPU List:                  0-127                   
 Hyperthreading:                    1(disabled)             
 Cores per Socket:                  64                      
 Sockets:                           2                       
 NUMA Nodes:                        2                       
 NUMA CPU List:                     0-63 :: 64-127          
 L1d Cache:                         8 MiB (128 instances)   
 L1i Cache:                         8 MiB (128 instances)   
 L2 Cache:                          64 MiB (128 instances)  
 L3 Cache:                          256 MiB (4 instances)  
 Memory Channels:                   8                       

NUMA
================================================================================

NUMA Memory Table
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  NUMA    CPU Cores    MemTotal(GB)    MemFree(GB)    MemUsed(GB)    Socket    Hugepages(64kB|2048kB|32768kB|1048576kB)  
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
     0         0-63           62.38          18.96          43.42         0    0|0|0|0                                   
     1       64-127          187.99         134.38          53.61         1    0|0|0|0                                   
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

────────────────────────
  NUMA    Distance 0-1  
────────────────────────
     0    10-12         
     1    12-10         
────────────────────────

NUMA PCIe Table
──────────────────────────────────────────────────────
  PCIe Bus        Nvme Devices    NUMA    Net Devices  
──────────────────────────────────────────────────────
  0000:7d:00.0    --                 0    enp125s0f0   
  0000:7d:00.1    --                 0    enp125s0f1   
  0000:7d:00.2    --                 0    enp125s0f2   
  0000:7d:00.3    --                 0    enp125s0f3   

Memory
================================================================================

OS Memory Info
───────────────────────────────────────────────────────────────────────────────

 Installed Memory Count:           8                       
 Installed Memory Size:            256 GB (8*32 GB)        
 Installed Memory Type:            8*DDR4                  
 Installed Memory Speed:           8*2666 MT/s [2666 MT/s] 
 Kernel Memory Page Size:          4096                    
 Populated Memory Channels:        8                       
 MemTotal:                         250.37 GB               
 MemAvailable:                     240.25 GB               
 MemFree:                          153.37 GB               
 Buffers:                          3.19 GB                 
 Cached:                           82.39 GB                 
 SwapTotal:                        4.00 GB                 
 SwapUsed:                         0.01 GB                 
 SwapFree:                         3.99 GB                 
 SwapCached:                       0.00 GB                 
 HugePages Total:                  0                       
 Hugepagesize:                     2048 kB                 
 Transparent Huge Pages:           always                  
 Automatic NUMA Balancing:         Enabled                 

DIMM Table
───────────────────────────────────────────────────────────────────────────────
[WARNING] 当前的内存插入方法不是最佳的插入方法。
──────────────────────────────────────────────────────────────────────────────────────────────────────────
  Bank Locator    Manufacturer(x)     Size    Data Width    Type        Speed    Configured Speed    Rank  
──────────────────────────────────────────────────────────────────────────────────────────────────────────
  0|2|0           Micron             32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  0|3|0           Micron             32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|0|0           Micron             32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|1|0           Hynix              32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|2|0           Hynix              32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|3|0           Hynix              32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|6|0           Hynix              32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
  1|7|0           Hynix              32 GB    64 bits       DDR4    2666 MT/s           2666 MT/s       2  
──────────────────────────────────────────────────────────────────────────────────────────────────────────

───────────────────────────────────────
  Bank Locator    Recommended Slots(x)  
───────────────────────────────────────
  0|2|0           Rec.(√)               
  0|3|0           Rec.(√)               
  1|0|0           Rec.(√)               
  1|1|0           Rec.(√)               
  1|2|0           Rec.(√)               
  1|3|0           Rec.(√)               
  1|6|0           Rec.(√)               
  1|7|0           Rec.(√)               
───────────────────────────────────────
```

---

## 分析流程

### Phase 1: 数据文件读取与验证

**目标**: 读取并验证kspect数据文件，并预先解析数据

**执行步骤**:
1. 检查`devkit_kspect.txt`文件是否存在
2. 用 `skill_view(name='devkit-kspect-analysis', file_path='scripts/parse_kspect.sh')` 获取 `parse_kspect.sh` 脚本内容，确认脚本中的绝对路径（`skill_view` 返回的 `resolved_path` 字段即为脚本在技能目录中的绝对路径）
3. 将脚本内容写入工作目录（或直接使用绝对路径），用 `terminal` 执行 `bash <脚本绝对路径> devkit_kspect.txt` 解析数据，获取过滤后的结构化输出
4. 读取解析后的输出内容进行分析
5. 提取采集时间、系统信息、健康度检查

**parse_kspect.sh 获取与执行方式**（三选一，推荐方式A）:

- **方式A（推荐）: 通过 skill_view 获取绝对路径直接执行**
  ```
  # 1. skill_view 返回脚本内容及其 resolved_path（如 /home/user/.hermes/skills/core/devkit-kspect-analysis/scripts/parse_kspect.sh）
  # 2. 直接用绝对路径执行：
  bash /home/user/.hermes/skills/core/devkit-kspect-analysis/scripts/parse_kspect.sh <devkit_kspect.txt的绝对路径>
  ```

- **方式B: 通过 skill_view 获取脚本内容，写入临时文件后执行**
  ```
  # 1. skill_view 返回脚本内容
  # 2. write_file 写入临时文件 /tmp/parse_kspect.sh
  # 3. terminal 执行：bash /tmp/parse_kspect.sh <devkit_kspect.txt的绝对路径>
  ```

- **方式C: 将脚本复制到数据目录后执行**
  ```
  # 1. terminal: cp <脚本绝对路径> <数据目录>/parse_kspect.sh
  # 2. terminal: cd <数据目录> && bash parse_kspect.sh devkit_kspect.txt
  ```

**⚠️ 重要**: 不要使用相对路径（如 `script/parse_kspect.sh` 或 `scripts/parse_kspect.sh`），因为执行工作目录可能与技能目录不一致。始终使用通过 `skill_view` 获取的绝对路径，或先将脚本写入/复制到已知路径。

**parse_kspect.sh 说明**: 从原始 kspect 数据中自动提取 CPU、NUMA、Memory、Network、Storage、Software、OS、BIOS 等关键段，过滤无关内容（如 Health Report、性能指标表等）。输出约30KB（原始131KB的23%），大幅减少后续读取和分析的数据量。

**输出**: 文件验证状态、基础信息、解析后的结构化数据

---

### Phase 2: CPU配置分析

**目标**: 提取并分析CPU静态配置

**CPU配置指标**:
- **CPU Model**: CPU型号（如Kunpeng 920 7260）
- **Architecture**: 架构（aarch64）
- **Base/Max Frequency**: 基频/最大频率
- **CPUs**: CPU核心数
- **Cores per Socket**: 每Socket核心数
- **Sockets**: Socket数量
- **NUMA Nodes**: NUMA节点数
- **NUMA CPU List**: NUMA节点CPU分布
- **Cache**: L1d/L1i/L2/L3缓存配置
- **Memory Channels**: 内存通道数
- **Hyperthreading**: 超线程状态（enabled/disabled）

**CPU配置判定**:
| 配置项 | 推荐配置 | 问题配置 | 说明 |
|--------|---------|---------|------|
| Hyperthreading | Disabled | Enabled | Kunpeng-920不支持超线程，如显示Enabled可能配置错误 |
| Memory Channels | 8 | < 8 | 内存通道未充分利用，带宽降低 |
| L3 Cache | 256 MiB | < 256 MiB | L3缓存未配置或不均衡 |
| NUMA Nodes | 2 | > 2 | NUMA节点过多，复杂度增加 |

**CPU核心分布分析**:
- CPU 0-63 → NUMA Node 0
- CPU 64-127 → NUMA Node 1
- 每NUMA节点64核心，分布均衡

---

### Phase 3: NUMA拓扑分析

**目标**: 提取并分析NUMA拓扑配置

**NUMA Memory Table指标**:
- **NUMA节点ID**: NUMA节点编号
- **CPU Cores**: 节点CPU核心范围
- **MemTotal**: 节点总内存（GB）
- **MemFree**: 节点可用内存（GB）
- **MemUsed**: 节点已用内存（GB）
- **Socket**: 节点归属Socket
- **Hugepages**: 巨页配置（64kB|2048kB|32768kB|1048576kB）

**NUMA Distance矩阵**:
```
  NUMA    Distance 0-1  
     0    10-12         
     1    12-10         
```

**NUMA距离解读**:
- 本地访问: 距离10
- 跨NUMA访问: 距离12（延迟+20%）

**NUMA拓扑判定**:
| 配置项 | 推荐配置 | 问题配置 | 说明 |
|--------|---------|---------|------|
| MemTotal差异 | < 30% | > 50% | 节点内存分布不均衡 |
| Hugepages | > 0 | 0 | 未启用巨页，TLB命中率低 |
| NUMA Distance | 10-12 | > 12 | NUMA距离过大，延迟高 |
| NUMA Balancing | Disabled | Enabled | NUMA自动均衡导致进程迁移 |

**NUMA PCIe归属分析**:
- **PCIe Bus**: PCIe总线地址
- **Nvme Devices**: NVMe设备归属NUMA
- **Net Devices**: 网卡归属NUMA

**网卡NUMA归属判定**:
- 网卡归属NUMA Node 0 → 进程绑定Node0可减少网络延迟
- 网卡归属NUMA Node 1 → 进程绑定Node1可减少网络延迟
- 网卡归属跨NUMA → 需调整网卡位置或进程绑定

**虚拟机场景NUMA配置判定**:

虚拟机场景识别方法：
1. 检查`Product Name`字段是否包含虚拟化标识（如"Virtual Machine", "VMware", "KVM", "QEMU", "VirtualBox"等）
2. 检查`System Information`或`KVM Info`段是否存在虚拟化特征

虚拟机NUMA配置优化策略优先级：
1. **XML配置方式（优先）**: 如果`devkit_kspect.txt`中明确提到可通过虚拟机XML配置解决NUMA问题（如virsh编辑、libvirt XML配置vcpu、内存绑定等），则优先推荐XML配置方式
2. **numactl方式（备选）**: 仅在无法通过XML配置解决或XML配置方式不可用时，才推荐使用numactl绑定策略

XML配置方式适用场景：
- 虚拟机可以通过virsh edit或libvirt XML配置vCPU和内存的NUMA绑定
- 文件中明确标注了"可通过XML配置"或"virsh edit"等提示
- 虚拟机支持vCPU和内存的NUMA亲和性配置

判定流程：
```
if (虚拟机场景) {
    if (devkit_kspect.txt中明确提到"可通过XML配置"或"virsh"关键字) {
        推荐方案 = "使用虚拟机XML配置NUMA绑定"
        不推荐numactl方式
    } else {
        推荐方案 = "numactl绑定策略"
    }
} else {
    推荐方案 = "numactl绑定策略"
}
```

---

### Phase 4: 内存配置与插法分析

**目标**: 提取并分析内存配置和插法

**OS Memory Info指标**:
- **Installed Memory Count**: 内存条数
- **Installed Memory Size**: 总内存容量（GB）
- **Installed Memory Type**: 内存类型（DDR4）
- **Installed Memory Speed**: 内存速度（MT/s）
- **Kernel Memory Page Size**: 页面大小（4KB）
- **Populated Memory Channels**: 内存通道数
- **HugePages Total**: 巨页数量
- **Transparent Huge Pages**: 透明巨页状态
- **Automatic NUMA Balancing**: NUMA自动均衡状态

**内存配置判定**:
| 配置项 | 推荐配置 | 问题配置 | 说明 |
|--------|---------|---------|------|
| Memory Channels | 8 | < 8 | 内存通道未满，带宽降低 |
| Memory Speed | 按CPU型号+DPC分档判定 | < 额定最高速率 | 详见下方分档表 |
| HugePages | > 0 | 0 | 未启用巨页 |
| NUMA Balancing | Disabled | Enabled | 导致进程迁移 |
| Swap | < MemTotal | > MemTotal | Swap过大 |

**内存速率按CPU型号+DPC分档判定**:

| CPU型号 | 内存通道/CPU | 1DPC额定最高 | 2DPC额定最高 |
|---------|------------|------------|------------|
| 920 7260/7265 | 8 | DDR4 3200 MT/s | DDR4 2933 MT/s |
| 920 5240/5250 | 8 | DDR4 2933 MT/s | DDR4 2666 MT/s |
| 920 5220/5225 | 4 | DDR4 2933 MT/s | DDR4 2666 MT/s |
| 920 7270Z/7280Z/7285Z | 8 | DDR5 4800 MT/s | DDR5 4400 MT/s |
| 920 5253Z/5235Z/5252Z | 4 | DDR5 4800 MT/s | DDR5 4400 MT/s |

**CPU型号识别方法**: 读取static_info.txt中的CPU Model字段
**DPC识别方法**: 统计DIMM Table中同一Channel的Slot数量
- 每个Channel只有1条记录 → 1DPC
- 每个Channel有2条记录 → 2DPC

**DDR降速排查方向**（当实际速率 < 额定最高时）:
1. 检查BIOS中Memory Frequency是否设置为Auto
2. 检查内存条是否混插（不同速率的DIMM会降速到最低公共速率）
3. 检查内存Rank配置（2Rank可能限制最高速率）
4. 检查CPU型号是否支持该速率（7260/7265才支持3200，5240/5250最高2933）

**内存插法分析**（DIMM Table）:
- **Bank Locator**: 内存插槽位置（Socket|Channel|Slot）
- **Manufacturer**: 内存厂商
- **Size**: 内存容量
- **Speed/Configured Speed**: 内存速度
- **Recommended Slots**: 推荐插法标记（Rec.(√)表示推荐且已用）

**内存插法判定**:
```
[WARNING] 当前的内存插入方法不是最佳的插入方法。
```

**内存插法问题识别**:
- 内存未均匀分布到各NUMA节点
- 内存通道未全部使用
- 插槽位置不符合推荐插法
- 内存速度不一致

---

### Phase 5: 网卡与存储配置分析

**目标**: 提取网卡和存储设备配置

**网卡配置指标**:
- **IFACE**: 网卡接口名（如enp125s0f0）
- **NUMA归属**: 网卡归属NUMA节点
- **PCIe Bus**: 网卡PCIe地址

**网卡配置判定**:
| 配置项 | 推荐配置 | 问题配置 | 说明 |
|--------|---------|---------|------|
| NUMA归属 | 与进程绑定一致 | 不一致 | 网卡跨NUMA访问 |
| PCIe Bus | 单NUMA归属 | 多NUMA归属 | 网卡分布不合理 |

**存储配置指标**:
- **Nvme Devices**: NVMe设备归属NUMA
- **PCIe Bus**: 存储设备PCIe地址

**存储配置判定**:
| 配置项 | 推荐配置 | 问题配置 | 说明 |
|--------|---------|---------|------|
| NUMA归属 | 与进程绑定一致 | 不一致 | 存储跨NUMA访问 |

---

### Phase 6: 系统配置优化建议生成

> **重要**: 具体调优建议由 `tuning-recommendation-generator` 技能统一生成，避免重复。
> 本技能聚焦静态配置问题识别，输出配置问题报告供调优建议生成器引用。

**配置问题识别输出**:
- 内存插法问题（WARNING标记）
- 内存通道未满（Populated Memory Channels < 8）
- NUMA内存分布不均衡（节点差异 > 50%）
- 巨页未启用（HugePages Total = 0）
- NUMA自动均衡状态
- 网卡NUMA归属问题
- 网卡归属与进程绑定不一致

## 注意事项

> **NUMA Balancing 配置建议**:
> - 高负载场景且进程已绑定: 建议禁用 `kernel.numa_balancing=0`
> - 未绑定进程且需NUMA优化: 建议启用 `kernel.numa_balancing=1`
> - 根据应用特性选择，避免进程频繁迁移

> **zone_reclaim_mode 慎用说明**:
> `vm.zone_reclaim_mode=1` 可能导致性能下降。
> 仅在NUMA内存极度不均衡时慎用，否则保持默认值0。

> **虚拟机NUMA配置优先级**:
> - 虚拟机场景下，优先使用XML配置方式（virsh edit或libvirt XML）进行NUMA绑定
> - 如果`devkit_kspect.txt`中明确提到可通过XML配置解决NUMA问题，则不推荐numactl方式
> - XML配置方式可以实现虚拟机级别的vCPU和内存NUMA亲和性，效果优于宿主机上的numactl

1. **内存插法**: 内存插法不合理会导致NUMA内存分布不均衡，需物理调整
2. **内存通道**: Kunpeng-920支持8通道内存，需确保所有通道使用
3. **巨页配置**: 巨页需静态配置，透明巨页性能不稳定
4. **网卡NUMA归属**: 网卡归属NUMA节点影响网络延迟，需与进程绑定一致
5. **内存厂商**: 混用不同厂商内存可能导致性能不一致
6. **BIOS配置**: BIOS部分配置需使用BMC信息（--bmc参数）
7. **虚拟机NUMA优化**: 虚拟机场景优先使用XML配置NUMA绑定，避免与numactl方式冲突
