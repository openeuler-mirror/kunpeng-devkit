---
name: "opentunex-numa-sched-analysis"
description: "numa并行感知调度分析。检查PARAL特性支持、分析NUMA拓扑与跨节点访问率（PMU HHA优先，vmstat/numastat降级），评估调优适用性。触发:NUMA内存不均衡、跨NUMA访问率高、NUMA瓶颈。"
---

# NUMA 调度并行分析

分析系统NUMA拓扑和内存访问特征，检查内核sched_features中PARAL特性支持状态，评估numa并行感知调度调优的适用性。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-numa-sched-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-numa-sched-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行环境与特性前置检查 → 路径 A PMU HHA 判定（或降级到路径 B vmstat/numastat 判定） | 分析结论 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-numa-sched-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

NUMA 远程访问瓶颈的判定采用**双路径**：优先使用 PMU HHA 数据（精确），降级使用 vmstat/numastat 数据（近似）。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-numa-sched-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-numa-sched-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `hha_available` | HHA_DEVICE | `true` → 可用（路径 A 有效）；`false` → 不可用（降级到路径 B） |
| `ops_per_sec` | OPS_PER_SEC | 整数，HHA 每秒内存操作量 |
| `remote_ratio` | REMOTE_RATIO | 数值百分比，如 `8.50` |
| `pmu_path_applicable` | PMU_PATH | `true` → 使用 PMU 路径 A；`false` → 降级到路径 B（由脚本预计算） |
| `numa_hit` | NUMA_HIT | 整数，降级路径中 numastat 本地命中数 |
| `numa_miss` | NUMA_MISS | 整数，降级路径中 numastat 远程访问数 |
| `numa_foreign` | NUMA_FOREIGN | 整数，降级路径中 numastat 外部访问数 |
| `remote_access_ratio` | REMOTE_ACCESS_RATIO | 已计算的 `NUMA_MISS / (NUMA_HIT + NUMA_MISS) × 100`（由脚本预计算） |
| `numa_nodes` | NUMA_NODES | 整数，NUMA 节点数量 |
| `paral_support` | PARAL_SUPPORT | `"支持"` / `"不支持"` |
| `paral_enabled` | PARAL_ENABLED | `"已启用"` / `"未启用"` |
| `sched_util_low_pct` | SCHED_UTIL_LOW_PCT | 整数或 `null`（`null` 表示无法获取） |

> **注意**：`pmu_path_applicable` 和 `remote_access_ratio` 已由脚本预计算，可直接用于决策逻辑判定路径 A/B 和 NB2-NB4 阈值比较，无需再手动计算。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 路径 A：PMU HHA 数据（优先，从 `${DATA_DIR}/pmu_info.txt` 读取）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| HHA_DEVICE | 搜索 "HHA 设备检测" 节中是否有 `/sys/devices/hha*` 路径；搜索 "未检测到 HHA 设备" → 不可用 | 不可用 |
| OPS_PER_SEC | 搜索 `ops_per_sec=` 后的整数，位于 "速率与远程访问占比" 节 | 0 |
| REMOTE_RATIO | 搜索 `remote_ratio=` 后的百分比（如 `8.50%`），取数值部分，位于同一节 | 0 |

**阈值（与参考实现对齐）**：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| OPS_THRESHOLD | 2,000,000 | HHA 每秒内存操作量门槛（次/秒） |
| REMOTE_THRESHOLD | 5% | 远程内存访问占比门槛 |

#### 路径 B：vmstat/numastat 数据（降级，从 `${DATA_DIR}/memory_metrics_analysis.txt` 读取）

当 PMU 数据不可用（无 HHA 设备或 `pmu_info.txt` 中无有效 `ops_per_sec`）时使用此路径。

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NUMA_HIT | 搜索 `=== NUMA Statistics` 节中 `numa_hit` 行的数字（格式：`numa_hit 123456`） | 0 |
| NUMA_MISS | 同上节中 `numa_miss` 行的数字 | 0 |
| NUMA_FOREIGN | 同上节中 `numa_foreign` 行的数字 | 0 |

计算：`REMOTE_ACCESS_RATIO = NUMA_MISS / (NUMA_HIT + NUMA_MISS) × 100`

**降级路径阈值**（精度低于 PMU，使用更保守的阈值）：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| VMSTAT_REMOTE_HIGH | 30% | vmstat 远端访问率高阈值 |
| VMSTAT_REMOTE_LOW | 10% | vmstat 远端访问率低阈值 |

#### 从 `${DATA_DIR}/static_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NUMA_NODES | 搜索 `--- NUMA Topology ---` 节中 `node X cpus:` 出现次数；若无，搜索 `NUMA node` 出现次数 | 1 |

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| PARAL_SUPPORT | 搜索 `=== 调度特性 ===` 节中的 `PARAL` 关键字：出现 `PARAL: present` → 支持且已启用；出现 `PARAL: NOT present` → 需进一步检查 sched_features 原文是否含 `NO_PARAL`（含则支持但未启用，不含则不支持） | 不支持 |
| PARAL_ENABLED | 当 PARAL 存在时：`PARAL: present` → 已启用；sched_features 原文含 `PARAL` 且**不含** `NO_PARAL` → 已启用 | 未启用 |
| SCHED_UTIL_LOW_PCT | 在 `=== 特殊调度参数 ===` 节中，`sched_util_ratio` 行后紧跟一行：若为纯数字（如 `100`）→ 取该值；若为 `sched_util_low_pct: not exist` → 无法获取 | 无法获取 |

---

## 决策逻辑

按以下优先级依次判断，命中即输出。

### 环境与特性前置检查

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| N1 | NUMA_NODES ≤ 1 | 不适用 | 单NUMA节点无需调度并行 |
| N2 | PARAL_SUPPORT = 不支持 | 不适用 | 内核不支持 PARAL 特性 |
| N3 | PARAL_ENABLED = 已启用 | 不适用 | PARAL 特性已启用 |

### 路径 A：PMU HHA 判定（精确，命中即采用）

> **优先路径**：若使用 `preanalysis.json`，直接检查 `pmu_path_applicable` 字段：`true` → 进入 NA2-Na4 判定；`false` → 降级到路径 B。
>
> **降级路径**：若未使用 `preanalysis.json`，按 NA1 判断 `pmu_info.txt` 是否有效。

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| NA1 | `pmu_info.txt` 无有效数据 | 降级到路径 B | — |
| NA2 | OPS_PER_SEC ≤ OPS_THRESHOLD (200万) | 收益有限 | HHA 每秒操作量 {X} < 2,000,000，未达到远程瓶颈判定门槛 |
| NA3 | OPS_PER_SEC > OPS_THRESHOLD 且 REMOTE_RATIO ≤ REMOTE_THRESHOLD (5%) | 收益有限 | 操作速率达标 ({X}/s) 但远程访问占比 {X}% ≤ 5%，NUMA 本地性良好 |
| NA4 | OPS_PER_SEC > OPS_THRESHOLD 且 REMOTE_RATIO > REMOTE_THRESHOLD (5%) | **适用** | 操作速率 {X}/s > 2,000,000 且远程访问占比 {X}% > 5%，NUMA 内存访问存在瓶颈 |

### 路径 B：vmstat/numastat 判定（降级，仅当路径 A 不可用时使用）

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| NB1 | 无法获取 NUMA_HIT/NUMA_MISS 数据 | 收益有限 | 无法获取远端访问率数据 |
| NB2 | REMOTE_ACCESS_RATIO < VMSTAT_REMOTE_LOW (10%) | 收益有限 | vmstat 远端访问率 {X}% < 10%，NUMA 状态良好（注意：此为降级路径，精度低于 PMU） |
| NB3 | REMOTE_ACCESS_RATIO ≥ VMSTAT_REMOTE_HIGH (30%) | **适用** | vmstat 远端访问率 {X}% ≥ 30%，NUMA 瓶颈明显 |
| NB4 | REMOTE_ACCESS_RATIO ≥ VMSTAT_REMOTE_LOW (10%) | **适用** | vmstat 远端访问率 {X}% ≥ 10%，存在 NUMA 瓶颈（降级路径，建议在支持 HHA 的机型上使用 PMU 精确判定） |

### 预期收益（仅当结论为"适用"时填充）

| 结论来源 | 预期收益 |
|---------|---------|
| NA4（PMU 精确判定） | 跨NUMA访问比例降低30%-50%，内存访问延迟降低15%-30% |
| NB3（vmstat 严重） | 跨NUMA访问比例降低30%-50%，内存访问延迟降低15%-30% |
| NB4（vmstat 存在） | 跨NUMA访问比例降低15%-30%，内存访问延迟降低10%-20% |

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-numa-sched-analysis_collect/result.md`，格式如下：

```markdown
# numa并行感知调度分析结果

## 1. 环境检查

| 检查项 | 结果 |
|--------|------|
| NUMA_NODES | {N} |
| PARAL_SUPPORT | {支持/不支持} |
| PARAL_STATUS | {已启用/未启用} |

## 2. NUMA 远端访问指标

| 指标 | 值 | 来源 |
|------|-----|------|
| OPS_PER_SEC | {值 或 "N/A（无HHA设备）"} | PMU HHA |
| REMOTE_RATIO | {X}% | {PMU HHA / vmstat 降级} |
| SCHED_UTIL_LOW_PCT | {值 或 无法获取} | /proc/sys/kernel |

## 3. 适用性评估

| 评估维度 | 结果 | 证据 |
|---------|------|------|
| NUMA拓扑 | ✅/❌ | {N}个NUMA节点 |
| PARAL特性支持 | ✅/❌ | PARAL: {present/NOT present/不支持} |
| PARAL当前状态 | {已启用/未启用} | — |
| 操作速率门槛 | ✅/❌ | {ops值}/s vs 2,000,000 |
| 远端访问占比 | ✅/❌ | {X}% vs {阈值}% |

**综合结论**: {适用/不适用/收益有限} — {原因}

**判定路径**: {PMU HHA 精确判定 / vmstat 降级判定}

**预期收益**: {量化收益}

**调优前提**: 仅适用于 aarch64 架构

**回滚参考**: SCHED_UTIL_LOW_PCT_ORIG={原始值}（如有）
```

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "numa_sched_paral",
  "suggestion": "向 sched_features 写入 PARAL 启用 NUMA 并行感知调度，并设置 sched_util_low_pct=100",
  "equivalence_class": "numa_sched_paral",
  "activation_requirement": "immediate",
  "estimated_gain": {
    "primary_metric": "numa_remote_ratio",
    "severity": "high",
    "description": "跨NUMA远程访问比例降低30%-50%，内存访问延迟降低15%-30%"
  },
  "conflicts": [],
  "prerequisites": [],
  "synergy_with": [],
  "scenario_priority": 7,
  "source": "skill_output",
  "cross_skill_relations": {}
}
```

> **字段填充说明**：
> - `applicability`：分析结论为"适用"→ `"applicable"`；"收益有限"→ `"limited_benefit"`；"不适用"→ `"not_applicable"`。映射标准见 [统一映射表](../references/result-template.md#零子技能结论--结构化数据映射统一标准)
> - `estimated_gain.severity`：使用评估矩阵判定（瓶颈严重程度 × 建议匹配效能）→ `high` / `medium` / `low`
> - 若 applicability 为 `"not_applicable"`：`estimated_gain.severity` 设为 `"low"`，`suggestion` 填写不适用/收益有限的原因描述
> - 若 applicability 为 `"limited_benefit"`：`estimated_gain.severity` 设为 `"low"`，正常参与融合流程
> - activation_requirement 字段保持当前模板中预设的值，无需修改。

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-numa-sched-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
