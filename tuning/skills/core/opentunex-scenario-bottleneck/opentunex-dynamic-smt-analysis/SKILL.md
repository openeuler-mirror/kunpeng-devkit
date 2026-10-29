---
name: "opentunex-dynamic-smt-analysis"
description: "动态SMT适用性分析。分析CPU使用率与SMT超线程状态，评估是否需要启用动态SMT调优。当涉及超线程干扰、CPU利用率低、SMT超线程优化、dynamic_smt_tune、功耗优化、低负载场景优化时，必须使用本技能。"
---

# 动态 SMT 调优分析

分析系统 CPU 负载与 SMT 状态，评估是否需要启用动态 SMT 调优（`dynamic_smt_tune`）。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-dynamic-smt-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-dynamic-smt-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节执行判定 | 分析结论 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-dynamic-smt-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-dynamic-smt-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-dynamic-smt-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `cpu_usage` | CPU_USAGE | 数值百分比，如 `65.30`（由脚本基于 /proc/stat 多采样预计算） |
| `smt_active` | SMT_ACTIVE | `"已启用"` / `"未启用"` / `"未知"` |
| `sched_support` | SCHED_SUPPORT | `"支持"` / `"不支持"` / `"未知"`（KEEP_ON_CORE 特性） |

> **注意**：`cpu_usage` 已由脚本基于 /proc/stat 相邻采样预计算（多组取平均），可直接用于决策逻辑阈值比较，无需再手动计算。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 从 `${DATA_DIR}/cpu_detail_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| CPU_USAGE | 从 "/proc/stat 多采样" 节中取相邻 `cpu ` 行计算：(delta_total − delta_idle) / delta_total × 100，多组取平均 | 0 |
| SMT_ACTIVE | 搜索 "SMT active:" 行，值为 1 → 已启用，0 → 未禁用，unknown → 未知 | 未知 |

**CPU 使用率计算方法**：`cpu ` 行中字段顺序为 user, nice, system, idle, iowait, irq, softirq, steal。total = 前8个字段之和，idle_total = idle + iowait。相邻两个采样的 delta_total != 0 时 utilization = (delta_total − delta_idle) / delta_total × 100。

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| SCHED_SUPPORT | 搜索 "KEEP_ON_CORE": "present" → 支持；"NOT present" → 不支持；搜索 "NO_KEEP_ON_CORE" 也视为支持 | 未知 |

**阈值参数**：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| THRESHOLD | 80% | CPU 使用率高负载阈值 |

---

## 决策逻辑

```
IF CPU_USAGE ≥ THRESHOLD:
    结论 = "不需要启用动态 SMT"
    原因 = "CPU 使用率 {X}% ≥ {THRESHOLD}%，高负载下应保持最大并行能力"
ELSE:
    IF SMT_ACTIVE = 已启用 AND SCHED_SUPPORT = 支持:
        结论 = "建议启用 dynamic_smt_tune"
        原因 = "CPU 使用率 {X}% < {THRESHOLD}%，系统负载低，且 SMT 已启用、内核调度特性支持，满足动态 SMT 调优条件"
    ELSE:
        结论 = "不启用 dynamic_smt_tune"
        原因 = "CPU 使用率 {X}% < {THRESHOLD}%，但系统条件不满足：[逐条列出不满足的条件]"
```

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-dynamic-smt-analysis_collect/result.md`，格式如下：

```markdown
## 动态 SMT 调优分析结论

**结论**：{结论}

**原因**：{原因}

## 评估摘要

| 指标 | 观测值 | 阈值 | 状态 |
|------|--------|------|------|
| CPU 使用率 | {X}% | {THRESHOLD}% | {高负载/低负载} |
| SMT 启用状态 | {已启用/未禁用/未知} | 必须启用 | ✅/❌ |
| 调度特性支持 | {支持/不支持/未知} | 必须支持 | ✅/❌ |

## 建议

{根据结论填充具体的操作命令或说明}
```

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "dynamic_smt",
  "suggestion": "写入 sched_util_ratio=<threshold> 到 /proc/sys/kernel/sched_util_ratio，再向 sched_features 写入 KEEP_ON_CORE",
  "equivalence_class": "dynamic_smt",
  "activation_requirement": "immediate",
  "estimated_gain": {
    "primary_metric": "cpu_usage",
    "severity": "high",
    "description": "低负载场景下减少超线程干扰，提升单线程性能10%-25%"
  },
  "conflicts": [],
  "prerequisites": [],
  "synergy_with": [],
  "scenario_priority": 4,
  "source": "skill_output",
  "cross_skill_relations": {}
}
```

> **字段填充说明**：
> - `applicability`：分析结论为"建议启用"→ `"applicable"`；"不需要启用"（CPU 高负载等运行时条件）→ `"limited_benefit"`；"不启用"（环境条件不满足，如 SMT 未启用、内核不支持）→ `"not_applicable"`
> - 映射标准见 [统一映射表](../references/result-template.md#零子技能结论--结构化数据映射统一标准)
> - `estimated_gain.severity`：使用评估矩阵判定（瓶颈严重程度 × 建议匹配效能）→ `high` / `medium` / `low`
> - 若 applicability 为 `"not_applicable"`：`estimated_gain.severity` 设为 `"low"`，`suggestion` 填写不启用的原因描述
> - 若 applicability 为 `"limited_benefit"`：`estimated_gain.severity` 设为 `"low"`，正常参与融合流程
> - activation_requirement 字段保持当前模板中预设的值，无需修改。

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-dynamic-smt-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
