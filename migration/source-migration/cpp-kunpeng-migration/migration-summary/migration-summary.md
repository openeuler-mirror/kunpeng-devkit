# 阶段 6：迁移报告总结

本阶段在编译验证成功后汇总整个迁移过程的关键信息，生成结构化总结报告。

**执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段6 子 Skill 调用。

**前置条件**：阶段 5 编译成功（编译成功后收尾 流程执行完成）。

**输入参数**：

本子 Skill 接收以下三个路径变量作为输入：

- `<项目绝对路径>` -> `PROJECT_ROOT`
- `<工作目录绝对路径>` -> `WORK_DIR`
- `<skill目录绝对路径>` -> `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

- `SKILL_DIR`：本 skill 自知（cpp-kunpeng-migration 目录 = 本子 skill 目录的上一层）。
- `PROJECT_ROOT`、`WORK_DIR`：主 agent 调用时由主 agent 传入；独立调用时优先从用户提示词取，未提供则向用户提问获取。

---
# 使用流程

## 1. 收集各阶段执行时长

读取 `$WORK_DIR/reports/timeline.log`（由主 agent 在各阶段边界记录），计算各阶段时长。

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

| 序号 | 文件路径 | 修改点描述（怎么改的） | 修改原因（x86->arm 为何要改） |
|------|---------|------|------|
| 1 | src/util/simd.cpp | 用 #if defined(__x86_64__) 包裹 AVX intrinsics，ARM 路径提供 NEON 替代 | 使用 x86 AVX intrinsics，鲲鹏不支持 AVX 指令集 |
| 2 | BUILD | 添加 select() 分支，ARM 配置段增加 aarch64 编译标志 | 需为 aarch64 单独配置编译标志与依赖分支 |
| 3 | .bazelrc | 新增 --config=linux_aarch64 配置段 | 需独立 aarch64 构建配置段 |
| ... | | | |

**合并去重**：修改文件清单需合并阶段 2（依赖切换）、阶段 4（DevKit 源码适配）、阶段 5（fix_history 修复）三个来源，按文件路径去重--同一文件在多阶段改动合并为一行。各列填充：
- `修改点描述`（怎么改的）：取自来源的修复操作--fix_history「修复操作」、DevKit 报告建议的修改方法、依赖分析报告的切换操作
- `修改原因`（x86->arm 为何要改）：取自来源的根因/问题描述--fix_history「错误根因」、DevKit 报告的问题描述（如「使用 x86 AVX intrinsics，鲲鹏不支持」）、依赖分析报告的冲突原因

---

## 3. 生成 patch 文件

将源码与构建配置的改动导出为 patch 文件，供归档与跨环境应用。二进制文件（如 `.so`/`.a`/`.o`/`.dll`/`.dylib`/`.exe`/`.bin` 及图片/压缩包等）不纳入 patch，改为在报告中说明（见报告模板「三、修改文件清单 -> 未包含在 patch 中的二进制文件改动」）。

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
  > $WORK_DIR/output/migration.patch
```

patch 文件保存到：`$WORK_DIR/output/migration.patch`

---

## 4. 收集编译产物与编译命令

供【产物】段"编译产物"和"编译命令与脚本"填充。

- **编译产物**：按构建系统取编译成功那次的产物目录
- **编译命令与脚本**：优先从上下文获取，上下文无则从最后一次编译成功的日志 `$WORK_DIR/logs/build_<成功次序>.log`

---

## 5. 收集重要提示与建议

从迁移过程中提取需要用户注意的重要信息：

### 提示来源

| 来源 | 提取内容 |
|------|---------|
| 阶段 1 环境报告 | 新安装/升级的工具及版本（如 Bazel 4.0.0、Blade 3.0）、Protobuf 版本对齐操作 |
| 阶段 2 依赖报告 | 需手动确认的依赖、无法自动探测 ARM 兼容性的私有库 |
| 阶段 3 用户决策 | 用户选择"跳过"的依赖及降级方案、用户确认切换的分支 |
| 阶段 4 DevKit 报告 | 仍有潜在风险但未修改的扫描项、需人工验证的适配点 |
| 阶段 5 编译日志 | x86 双架构兼容性验证提示、编译尝试次数 |
| `$WORK_DIR/kunpeng_confirmed.md` | 本次迁移新增登记的 ARM 适配依赖（供后续项目复用） |

### 报告中的提示格式

```
## 重要提示与建议

### 建议关注
- 建议在 x86 环境执行编译，验证迁移修改是否破坏原有 x86 兼容性
- <依赖名> 的 ARM 兼容性未完全验证，建议在生产环境部署前进行完整功能测试
- <文件名> 中的 <函数名> 使用标量退化替代 SIMD，性能可能下降，建议后续优化为 NEON 实现

### 本次迁移产出
- `$WORK_DIR/kunpeng_confirmed.md` 新增登记： <依赖名1>、<依赖名2>
- 编译尝试次数：<N> 次
- 最终编译状态：成功
```

---

## 6. 收集迁移过程摘要指标

供报告「四、迁移过程摘要」表填充。逐阶段从对应报告抽取关键结果，**无需重新执行检测**：

| 阶段 | 关键结果 | 数据来源 |
|------|---------|---------|
| 1 环境检测 | 识别的构建系统、安装/升级的工具及版本 | `$WORK_DIR/reports/environment_check_report.md` |
| 2 依赖分析 | 依赖总数、命中免检清单数、待确认数 | `$WORK_DIR/reports/dependency_analysis_<项目名>.md` + `stage_2_pending_items.md` + `stage_2_switch_list.md` |
| 3 用户确认 | 确认项数、切换依赖数 | `$WORK_DIR/reports/user_decisions.txt` + `stage_2_switch_list.md` |
| 4 源码迁移扫描 | 扫描问题数、已修复数、按类型分布 | `$WORK_DIR/reports/devkit_summary.json`（`categories` 字段）+ `source_changes.txt` |
| 5 编译验证 | 编译尝试次数、修复错误数、最终结果 | `$WORK_DIR/reports/fix_history.txt`（尝试次数=条目数）+ `build_summary.txt`（最终结果） |

> 若某来源文件缺失，可同时基于本次迁移上下文（各阶段已读报告与对话记录）补充，但不得编造数据；上下文也无法确认时再标注"未执行"。

---

## 7. 生成总结报告

将 1 ~ 5 的内容整合为一份完整的 Markdown 报告，保存到：

```
$WORK_DIR/output/migration_summary_report.md
```

**报告完整结构模板**见 [assets/migration_summary_report_template.md](assets/migration_summary_report_template.md)。生成报告时按该模板填充 1 ~ 6 的内容。

---

## 8. 输出要求（硬性约束）

报告生成后，必须按以下结构向用户输出最终回复。这是用户看到的迁移收尾信息，**不得省略关键段、不得自由发挥**；完整明细落报告文件，终端只给摘要 + 可执行要点 + 路径。

```
================ 鲲鹏迁移完成 ================
状态：<编译成功>   总耗时：<XX分XX秒>（6 个阶段）

【各阶段时长】
- 1 环境检测与准备：<XX分XX秒>
- 2 依赖分析与兼容性探测：<XX分XX秒>
- 3 用户确认与切换：<XX分XX秒>
- 4 源码迁移扫描与适配：<XX分XX秒>
- 5 编译验证循环：<XX分XX秒>

【产物】
- 总结报告：$WORK_DIR/output/migration_summary_report.md
- 迁移 patch：$WORK_DIR/output/migration.patch（源码+构建配置，排除二进制）
- 编译产物：编译成功那次的产物目录
- 编译命令与脚本：编译命令/脚本优先从上下文获取，如果没有从编译日志（$WORK_DIR/logs/build_<成功次序>.log）中取

【修改统计】
- 修改文件 <N> 个：源码文件 <N> / 构建配置文件 <N> / 其他 <N>
- 编译尝试 <N> 次，修复错误 <N> 处

【建议关注】
- 在 x86 环境编译，确认迁移是否破坏原有 x86 构建
- <依赖名> ARM 兼容性未完全验证，部署前建议完整功能测试
- <文件:函数> 标量退化替代 SIMD，性能可能下降，建议后续 NEON 优化
- 无则省略本段

【本次迁移产出】
- kunpeng_confirmed.md 新增登记：<依赖1>、<依赖2>（供后续项目复用，无则省略）
================================================
```

**填充说明**：
- 各段数据来源：各阶段时长←第1节；修改统计←第2节；建议关注/本次迁移产出←第5节；产物路径←各节产出（编译产物与编译命令←第4节）。
- 某阶段因人工介入未正常结束（`PHASE_X_ABORT`），【各阶段时长】对应行标注"未完成"。
- 「建议关注」中 x86 双架构兼容性验证放在首位（build-verify 第7节已提，收尾再强化--这是迁移后最易漏、代价最高的动作）。
- 各段无内容则省略该段，不留空壳。

---

## 9. 快速检查清单

阶段 6 完成后，确认以下所有项均已完成：

- [ ] timeline.log 已读取，各阶段时长已计算
- [ ] git diff 已执行，修改文件完整列表已获取
- [ ] fix_history.txt 已读取，修改点描述已汇总
- [ ] 重要提示与建议已从各阶段报告中提取
- [ ] 迁移过程摘要指标已从各阶段报告抽取（构建系统/依赖数/扫描问题数/编译次数等）
- [ ] patch 文件已生成（排除二进制文件），保存到 `$WORK_DIR/output/migration.patch`
- [ ] 二进制文件改动清单已记录到 `$WORK_DIR/reports/binary_changes.txt`
- [ ] 编译产物路径与编译命令/脚本已收集（编译产物按构建系统取成功那次；编译命令/脚本优先从上下文取，上下文无则从编译日志取）
- [ ] 总结报告已生成并保存到 `$WORK_DIR/output/migration_summary_report.md`
- [ ] 已按「输出要求」（第8节）向用户输出最终回复：状态 / 各阶段时长 / 产物 / 修改统计 / 建议关注 / 本次迁移产出
