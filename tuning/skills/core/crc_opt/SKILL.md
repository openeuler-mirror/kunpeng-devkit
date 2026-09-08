---
name: crc_opt
description: Suggest ARM CRC32 build flag from binary CRC analysis data.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [crc, arm, optimization, compilation, performance, rocksdb]
    category: core
    requires_toolsets: [file]
---

# CRC Optimization Skill

当应用是以下项目或依赖以下项目时，crc优化是可能有效的，否则无需执行该skill的剩下流程：
- rocksdb
- MMKV
- google/crc32c
- ICRAR/crc32c
- Rust crc-32c
- Btrfs/ext4/Ceph
- LevelDB
- Zlib/Gzip/PNG

## 触发条件

当前目录存在 `check_arm_crc32.txt` 时触发。技能内部根据检测结果自行判断是否需要输出建议。

## 工作流

### 步骤 1: 读取 `check_arm_crc32.txt`

用 `read_file` 读取 `check_arm_crc32.txt`，分析每行记录：

- 被检查的 ELF 文件路径
- 是否检测到 CRC32 指令
- 排除系统动态库（`/usr/lib/`、`/lib/`、`/lib64/` 等路径下的文件）

### 步骤 2: 判断 CPU 是否支持 CRC

读取 `/proc/cpuinfo`，检查是否包含 `crc` 标志。

### 步骤 3: 提示用户

- 已使用 CRC32 指令 → 无需操作
- 未使用且 CPU 不支持 → 无需操作
- **未使用但 CPU 支持** → 提示用户在编译选项中添加 `-march=armv8-a+crc`，说明该选项可使 GCC/Clang 自动生成硬件 CRC 指令，提升 rocksdb 等 crc32c 密集场景的性能

## 验证

提示用户编译后可用 `objdump -d <binary> | grep crc32` 验证。
