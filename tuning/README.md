# Kunpeng DevKit 调优 Skill 集

---

## 目录

- [简介](#简介)
- [Skill 分类概览](#skill-分类概览)
- [使用步骤](#使用步骤)

---

## 简介

本 Skill 集面向鲲鹏平台，提供从**系统级瓶颈识别**到**应用级优化落地**的全链路调优能力。Skill 包含如下调优场景：

- **核心调优 (core)**：系统静态配置分析、微架构瓶颈诊断、NUMA 访问分析、伪共享检测、CPU 频率/功耗分析、场景化瓶颈分析、CRC/64K 页检测等，共 16 个 Skill
- **Java 调优 (java)**：面向鲲鹏+ BishengJDK 的 8 条实战优化规则，覆盖 fastutil 容器替换、ITLB miss 降低、分代 ZGC、NUMA-aware 分配、KAE 加解密/压缩加速等

---

## Skill 分类概览

### 核心调优 (core)

| Skill | 说明 |
|------|------|
| `tuning-recommendation-generator` | 顶层协调器，按数据文件存在情况自动调度子 Skill，汇总生成最终调优报告 |
| `opentunex-scenario-bottleneck` | 二级协调器，全量调度 7 个场景分析子技能 |
| `devkit-kspect-analysis` | 系统静态配置分析（CPU、NUMA、内存插法、BIOS 等） |
| `devkit-topdown-analysis` | Top-down 微架构瓶颈诊断（Frontend/Backend Bound 等） |
| `devkit-turbostat-analysis` | CPU 频率/功耗/散热分析 |
| `devkit-numafast-analysis` | NUMA 访问性能分析 |
| `false-sharing-analysis` | 伪共享检测与修复（独立触发） |
| `crc_opt` | CRC32 编译优化 |
| `check-64k-page-size` | 64K 内核页检测 |
| `opentunex-stealtask-analysis` | 窃取任务调度分析 |
| `opentunex-soft-domain-analysis` | 分域调度分析 |
| `opentunex-numa-sched-analysis` | NUMA 并行感知调度分析 |
| `opentunex-multi-net-path-analysis` | 网卡多路径分析 |
| `opentunex-dynamic-smt-analysis` | 动态 SMT 分析 |
| `opentunex-docker-coordination-burst-analysis` | Docker 算力统筹分析 |
| `opentunex-btb-analysis` | BTB/TidCMP 分析 |

### Java 调优 (java)

| Skill | 说明 |
|-------|------|
| `kunpeng-java-tuning` | 面向鲲鹏+ BishengJDK 的 8 条实战优化规则 |

---

## 使用步骤

### 步骤一：安装依赖工具

在目标服务器上安装采集所需的第三方工具。

```bash
# 安装系统工具（以 openEuler 为例）
yum install -y sysstat perf iotop ethtool strace numactl

# 安装 DevKit 工具（devkit、kspect、ksys）及 async-profiler
cd tuning/collect
bash check_install.sh --install
```

### 步骤二：使用脚本执行采集

使用 `server_data_collect.sh` 执行采集。

采集完成后会生成打包文件（默认命名 `profiling_data_aarch64_<时间戳>.tar.gz`），包含性能数据文件。

### 步骤三：触发 Skill 分析

对话指引agent读取性能数据文件，触发 Skill 进行调优分析

```text
读取 profiling_data_aarch64_<时间戳>.tar.gz 中的性能数据文件，给出调优建议
```

```text
请使用 tuning-recommendation-generator 技能，分析当前目录下的性能数据，生成系统调优建议报告。
```

也可以针对特定问题单独触发专项 Skill，例如：

```text
帮我分析 devkit_topdown.txt，看看 Frontend/Backend Bound 瓶颈在哪里
```

---
