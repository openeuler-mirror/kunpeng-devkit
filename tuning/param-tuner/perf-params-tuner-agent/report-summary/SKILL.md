---
name: report-summary
description: 报告摘要子 skill。由 perf-params-tuner-agent 主 skill 调用，不直接面向用户。读取自动调优训练结果（train.db），生成可视化 HTML 报告 + AI 分析。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
---

# 调优报告生成

> 本 skill 是 `perf-params-tuner-agent` 的子 skill，负责调优结果报告摘要。不直接由用户调用。  

## 输入

由 orchestrator 传入：
- 训练结果目录（含 `train.db` 和 `kat_run.log`）
- 或用户原始输入（从中提取训练目录路径）

## 执行流程

### 1. 确认训练目录

- 用户明确提供了目录 → 直接使用
- 用户未提供 → 向用户询问训练结果目录（perf-params-tuner-agent 执行时指定的目录）
- 校验目录存在且含 `train.db`，否则提示用户

### 2. 复用已有报告（若存在）

**报告命名规则**：报告默认命名为 `report_{YYYYMMDD_HHMMSS}.html`（时间戳取训练创建时间 `tune_info.created_at`，即本次调优数据的创建时间，已从 UTC 转为本地时区）。同一批调优数据对应唯一报告名，不同批次互不覆盖；即使训练后执行过 set/apply 等操作（会更新 train.db 修改时间），报告名也不会漂移。

**先检查训练目录下是否已存在对应本次数据的报告：**

- **存在 `report_{YYYYMMDD_HHMMSS}.html`（时间戳与 train.db 修改时间一致），且用户未明确要求重新生成** → **直接复用**：
  - 跳过生成步骤，直接输出该报告路径
  - 提示用户用浏览器打开即可，不再调用脚本覆盖
- **存在对应报告，但用户明确要求重新生成**（如"重新生成报告"、"更新报告"）→ 继续步骤3
- **不存在对应报告**（含旧批次 `report.html` 或时间戳不一致的报告）→ 继续步骤3，生成带本次时间戳的新报告

### 3. 生成 HTML 报告骨架

调用报告脚本生成自包含静态 HTML（含 KPI 卡片、收敛曲线、参数重要性、Top 10 表）。报告名默认绑定 `train.db` 修改时间戳，互不覆盖：

```bash
python3 {skill_base_dir}/scripts/report.py <训练目录>
```

输出：训练目录下的 `report_{YYYYMMDD_HHMMSS}.html`。

如用户需要旧式固定名（供其他工具引用），可显式指定：
```bash
python3 {skill_base_dir}/scripts/report.py <训练目录> -o report.html
```

### 4. 读取数据摘要

调用脚本的 `--summary` 模式，获取紧凑文本数据供 AI 分析参考：

```bash
python3 {skill_base_dir}/scripts/report.py <训练目录> --summary
```

输出示例：
```
调优结果摘要 — Redis
指标: requests per second | 方向: maximize
baseline: 584,112
最优: 874,182 (round 5)
提升幅度: +49.66%
每轮性能:
  round 1: 827,921  (+41.7%)
  ...
参数重要性 (Top 5):
  maxmemory-samples: 17.51%
  ...
```

### 5. 生成 AI 分析文字

基于摘要数据，用自然语言生成分析，包含：

1. **结果概览**：baseline → 最优，提升多少，最优出现在第几轮
2. **趋势解读**：性能是否稳定收敛、有无波动、阶段特征（随机探索期 vs 寻优期）
3. **关键参数**：哪些参数影响最大（依据参数重要性），给出取值倾向
4. **建议**：如需继续调优，建议如何调整（扩大重要参数范围、增加轮数、调整 random_initial_ratio 等）

### 6. 写入 AI 分析到报告

脚本提供 `--ai-note` 参数，将 AI 分析（markdown 文件）自动注入报告并**自动校验**：占位符清零、文件非空、关键 section 齐全：

```bash
# 将 analysis.md 的 AI 分析注入报告，并自动校验
python3 {skill_base_dir}/scripts/report.py <训练目录> --ai-note analysis.md
```

脚本会：
- 将 markdown 转简单 HTML（标题、列表、加粗、段落），替换 `<!-- AI_ANALYSIS -->` 占位符
- 注入后自动校验（`✅ 报告校验通过`，或 `⚠️ 报告校验发现缺失: ...`）
- 更新报告关键参数为完整解析结果（含截断参数名的匹配）

也可以分两步：先生成骨架，再注入 AI 分析：
```bash
python3 {skill_base_dir}/scripts/report.py <训练目录>          # 生成骨架（report_{timestamp}.html）
python3 {skill_base_dir}/scripts/report.py <训练目录> --ai-note analysis.md  # 注入同一文件
```

## 输出

- **复用场景**：返回与本次 train.db 时间戳匹配的已有报告路径 `{训练目录}/report_{YYYYMMDD_HHMMSS}.html`，并注明"复用已有报告，未重新生成"
- **生成场景**：返回新生成的报告路径 `{训练目录}/report_{YYYYMMDD_HHMMSS}.html`（时间戳绑定 train.db 修改时间，与本次调优数据对应）
- 关键结论摘要（应用、baseline、最优、提升幅度、Top 参数）
- 下一步引导：用浏览器打开报告

## 设计原则

- **脚本做数据与图表，AI 做分析**：脚本解析 train.db + kat_run.log 生成图表骨架，AI 只负责自然语言解读
- **自包含**：报告为单个静态 HTML，无外部依赖，离线可用
- **非破坏性**：只生成/修改训练目录下的 `report.html`，不触碰 train.db 和原始数据
