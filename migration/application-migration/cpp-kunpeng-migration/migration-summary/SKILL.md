---
name: migration-summary
description: C/C++ 鲲鹏迁移的迁移总结报告生成子 Skill。作为 cpp-kunpeng-migration 阶段 6 被调用，或用户需要生成 C/C++ 鲲鹏迁移总结报告、统计阶段耗时、梳理修改清单或归档迁移成果时使用。负责汇总各阶段执行结果、耗时、修改文件及修改内容，并输出风险、遗留问题和后续建议。不负责环境检测、源码适配和编译修复。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
---

# 迁移报告总结功能描述

本阶段在编译验证成功后汇总整个迁移过程的关键信息，生成结构化总结报告。

**执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段6 子 Skill 调用。

**前置条件**：阶段 5 编译成功（编译成功后收尾 流程执行完成），或阶段 5 触发人工介入（人工介入报告 流程执行完成）。

**参数定义**：
- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <skill目录绝对路径>（主编排传入）

---
# 使用流程

## 1. 收集各阶段执行时长

读取 `$WORK_DIR/reports/timeline.log`（由主编排在各阶段边界记录），计算各阶段时长。

timeline.log 格式（每行一条）：
```
PHASE_1_START|2024-01-01 10:00:00
PHASE_1_END|2024-01-01 10:15:30
PHASE_2_START|2024-01-01 10:16:00
...
```

**时长计算**：对每个阶段，END 时间戳 - START 时间戳。若某阶段因人工介入未正常结束（记录了 `PHASE_X_ABORT`），标注"未完成"。

输出到报告的"各阶段执行时长"表格：

| 阶段 | 描述 | 开始时间 | 结束时间 | 时长 |
|------|------|---------|---------|------|
| 1 | 环境检测与准备 | <时间> | <时间> | <XX分XX秒> |
| 2 | 依赖分析与兼容性探测 | <时间> | <时间> | <XX分XX秒> |
| 3 | 用户确认与切换 | <时间> | <时间> | <XX分XX秒> |
| 4 | 源码迁移扫描与适配 | <时间> | <时间> | <XX分XX秒> |
| 5 | 编译验证循环 | <时间> | <时间> | <XX分XX秒> |
| **合计** | | | | <总时长> |

---

## 2. 收集所有修改文件及修改点描述

从以下来源汇总修改信息：

1. **git diff**：执行 `git -C $PROJECT_ROOT diff --stat` 和 `git -C $PROJECT_ROOT diff --name-only` 获取完整修改文件列表
2. **fix_history.txt**：读取阶段 5 每次修复的文件路径、修改范围、根因描述
3. **DevKit 扫描报告**：读取 `$WORK_DIR/reports/devkit-*/` 中的扫描结果，获取阶段 4 源码修改记录
4. **dependency-analysis 报告**：读取阶段 2 报告中的依赖切换记录（WORKSPACE、BUILD 等构建配置文件修改）

输出到报告的"修改文件清单"表格：

| 序号 | 文件路径 | 修改阶段 | 修改类型 | 修改点描述 |
|------|---------|---------|---------|-----------|
| 1 | src/util/simd.cpp | 4/5 | 源码适配 | 用 #if defined(__x86_64__) 包裹 AVX intrinsics，ARM 路径提供 NEON 替代 |
| 2 | BUILD | 4 | 构建配置 | 添加 select() 分支，ARM 配置段增加 aarch64 编译标志 |
| 3 | .bazelrc | 1/4 | 构建配置 | 新增 --config=linux_aarch64 配置段 |
| ... | | | | |

**修改类型枚举**：源码适配 / 构建配置 / 环境安装 / 依赖切换

---

## 3. 生成 patch 文件

将源码与构建配置的改动导出为 patch 文件，供归档与跨环境应用。二进制文件（如 `.so`/`.a`/`.o`/`.dll`/`.dylib`/`.exe`/`.bin` 及图片/压缩包等）不纳入 patch，改为在报告中说明（见 6.4）。

### 3.1. 识别二进制文件改动

用 git 的二进制检测能力精确识别工作区中的二进制改动（基于内容而非扩展名）：

```bash
# 列出所有改动文件及其 numstat（二进制文件显示 -\t-\t<路径>）
git -C $PROJECT_ROOT diff --numstat HEAD > $WORK_DIR/reports/binary_changes.txt

# 提取二进制文件清单（numstat 第一、二字段为 - 的行）
grep $'^-\t-' $WORK_DIR/reports/binary_changes.txt | cut -f3 > $WORK_DIR/reports/binary_files.txt
```

若 `binary_files.txt` 中存在扩展名清单外的二进制文件，在报告中标注"未识别类型"。

### 3.2. 生成 patch

用 pathspec exclude 排除二进制文件，生成纯净的源码 + 构建配置 patch：

```bash
git -C $PROJECT_ROOT diff HEAD \
  -- ':!*.so' ':!*.a' ':!*.o' ':!*.dll' ':!*.dylib' ':!*.exe' ':!*.bin' \
  -- ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.gif' ':!*.bmp' ':!*.zip' ':!*.tar' ':!*.gz' ':!*.tgz' \
  > $WORK_DIR/reports/migration.patch
```

patch 文件保存到：`$WORK_DIR/reports/migration.patch`

---

## 4. 收集重要提示与建议

从迁移过程中提取需要用户注意的重要信息：

### 提示来源

| 来源 | 提取内容 |
|------|---------|
| 阶段 1 环境报告 | 新安装/升级的工具及版本（如 Bazel 4.0.0、Blade 3.0）、Protobuf 版本对齐操作 |
| 阶段 2 依赖报告 | 需手动确认的依赖、无法自动探测 ARM 兼容性的私有库 |
| 阶段 3 用户决策 | 用户选择"跳过"的依赖及降级方案、用户确认切换的分支 |
| 阶段 4 DevKit 报告 | 仍有潜在风险但未修改的扫描项、需人工验证的适配点 |
| 阶段 5 编译日志 | x86 双架构兼容性验证提示、编译尝试次数、人工介入记录（如有） |
| `$WORK_DIR/kunpeng_confirmed.md` | 本次迁移新增登记的 ARM 适配依赖（供后续项目复用） |

### 报告中的提示格式

```
## 重要提示与建议

### 必须执行
- [ ] x86 双架构兼容性验证：在 x86 环境执行编译，确认迁移修改未破坏原有 x86 编译
- [ ] <其他必须用户手动执行的步骤>

### 建议关注
- <依赖名> 的 ARM 兼容性未完全验证，建议在生产环境部署前进行完整功能测试
- <文件名> 中的 <函数名> 使用标量退化替代 SIMD，性能可能下降，建议后续优化为 NEON 实现

### 本次迁移产出
- `$WORK_DIR/kunpeng_confirmed.md` 新增登记： <依赖名1>、<依赖名2>
- 编译尝试次数：<N> 次
- 最终编译状态：成功 / 人工介入
```

---

## 5. 生成总结报告

将 1 ~ 4 的内容整合为一份完整的 Markdown 报告，保存到：

```
$WORK_DIR/reports/migration_summary_report.md
```

**报告完整结构模板**见 [assets/migration_summary_report_template.md](assets/migration_summary_report_template.md)。生成报告时按该模板填充 1 ~ 4 的内容。

---

## 6. 快速检查清单

阶段 6 完成后，确认以下所有项均已完成：

- [ ] timeline.log 已读取，各阶段时长已计算
- [ ] git diff 已执行，修改文件完整列表已获取
- [ ] fix_history.txt 已读取，修改点描述已汇总
- [ ] 重要提示与建议已从各阶段报告中提取
- [ ] patch 文件已生成（排除二进制文件），保存到 `$WORK_DIR/reports/migration.patch`
- [ ] 二进制文件改动清单已记录到 `$WORK_DIR/reports/binary_changes.txt`
- [ ] 总结报告已生成并保存到 `$WORK_DIR/reports/migration_summary_report.md`
- [ ] 报告中的"必须执行"项已向用户醒目提示
