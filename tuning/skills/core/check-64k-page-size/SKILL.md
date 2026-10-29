---
name: check-64k-page-size
description: Recommend 64K ARM kernel pages for database workloads.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [arm, performance, kernel, database, bigdata, tuning]
    category: core
    requires_toolsets: [file]
---

# Check 64K Page Size Skill

当分析数据库或大数据场景时，检查系统内核页是否为 64K。如果不是，推荐使用 ARM 64K 内核页以提升性能。

## 触发条件

当前目录存在 `check_64k_opt.txt` 时触发。技能内部根据检测结果自行判断是否需要输出建议。

## 前置条件

存在 `check_64k_opt.txt` 文件（由 `collect` 工具集生成），或可通过 `getconf PAGE_SIZE` 和 `/proc/self/smaps` 手动检测。

## 工作流

### 步骤 1: 判断架构

用 `terminal` 执行 `uname -m`。非 `aarch64` 架构则跳过（64K 页仅用于 ARM）。

### 步骤 2: 读取检测数据

如果当前目录存在 `check_64k_opt.txt`，用 `read_file` 读取，找到各方法的结论行.

### 步骤 3: 生成建议

- **已是 64K 内核** → 无需操作，记录确认信息
- **不是 64K 内核** → 推荐切换到 ARM 64K 内核页，说明以下收益：
  - 减少 TLB miss，提升内存访问密集型负载性能
  - 数据库场景（如 RocksDB）可受益于更大的页表覆盖范围
  - 大数据处理场景可降低页表开销

## 注意事项

- ARM 64K 内核需要硬件和内核同时支持，部分云实例可能不提供 64K 内核选项
- 切换内核页大小需要重启系统，建议在维护窗口操作
- 64K 页可能增加内存浪费（内部碎片），在内存受限场景需权衡
- 容器环境中页大小由宿主机内核决定，容器内无法独立切换
