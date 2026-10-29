---
name: "opentunex-docker-coordination-burst-analysis"
description: "Docker算力统筹适用性分析。分析宿主机CPU负载与容器CPU使用率，判断是否需要为CPU受限容器启用算力统筹（Coordination Burst）。当涉及容器性能、Docker CPU限流、容器CPU瓶颈、cfs_burst、容器CPU配额不足、宿主机有空闲算力等场景时，必须使用本技能。"
---

# Docker Coordination Burst 分析

分析宿主机 CPU 负载、内核 burst 支持能力以及各容器的 CPU 使用与软配额状态，判断是否需要为高负载容器启用 Docker Coordination Burst（CPU burst），并给出具体操作建议。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-docker-coordination-burst-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-docker-coordination-burst-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行 B1→B6 判定 | 分析结论 + 容器级明细 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-docker-coordination-burst-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-docker-coordination-burst-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-docker-coordination-burst-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `host_cpu_util` | HOST_CPU_UTIL | 数值百分比，如 `32.50`（由脚本基于 /proc/stat 多采样预计算） |
| `host_ncpus` | HOST_NCPUS | 整数，宿主机 CPU 数量 |
| `burst_support` | BURST_SUPPORT | `"支持"` / `"不支持"` |
| `container_count` | CONTAINER_COUNT | 整数，运行中容器数量 |
| `containers[].id` | — | 容器短 ID（前 12 位） |
| `containers[].full_id` | — | 容器完整 ID |
| `containers[].cpu_usage` | 容器使用率 | 百分比数值（由脚本基于首尾采样 cpuacct_usage 差值预计算） |
| `containers[].cpu_limit` | CPU 限制 | 核数（cfs_quota_us / cfs_period_us，回退 host_ncpus） |
| `containers[].soft_quota` | 软配额状态 | `"已启用"` / `"未启用"` |
| `containers[].classification` | 容器分类 | `"建议对象"` / `"已启用 burst"` / `"低负载"`（由脚本预计算） |

> **注意**：容器的 `cpu_usage` 和 `classification` 已由脚本基于首尾采样预计算，可直接用于 B4/B5/B6 判定，无需再手动解析 container_info.txt 的 SAMPLE 块。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 从 `${DATA_DIR}/cpu_detail_info.txt` 读取

| 指标              | 提取方法                                                                                         | 默认值 |
| --------------- | -------------------------------------------------------------------------------------------- | --- |
| HOST\_CPU\_UTIL | 从 "/proc/stat 多采样" 节中取相邻 `cpu `  行计算 (delta\_total − delta\_idle) / delta\_total × 100，多组取平均 | 0   |
| HOST\_NCPUS     | 搜索 "在线CPU数量" 行的数字；若无，搜索 "processor 数量" 行                                                     | 1   |

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标             | 提取方法                                                                                            | 默认值 |
| -------------- | ----------------------------------------------------------------------------------------------- | --- |
| BURST\_SUPPORT | 搜索 "Docker CPU Burst: yes" → 支持；搜索 "sched\_soft\_runtime\_ratio" 且值不为 "not exist" → 支持；其余 → 不支持 | 不支持 |

#### 从 `${DATA_DIR}/container_info.txt` 读取

从 "容器 CPU 多采样观测" 节中逐采样提取每个容器的数据。每个采样块格式：

```
=== SAMPLE <N> ===
=== TIMESTAMP <epoch> ===
--- CONTAINER ---
id=<full_container_id>
cfs_period_us=<value>
cfs_quota_us=<value>
cpuacct_usage=<value>
soft_quota=<0|1>
timestamp=<epoch>
--- END CONTAINER ---
```

**容器 CPU 使用率计算**：对每个容器，取首尾采样的 `cpuacct_usage` 差值除以时间间隔得实际用量。CPU 限制 = `cfs_quota_us / cfs_period_us`（若 cfs\_quota\_us > 0），否则为 HOST\_NCPUS。使用率 = 实际用量 / (CPU 限制 × 时间间隔) × 100。

**阈值参数**：

| 参数                   | 默认值 | 含义         |
| -------------------- | --- | ---------- |
| HOST\_THRESHOLD      | 45% | 宿主机负载高/低阈值 |
| CONTAINER\_THRESHOLD | 95% | 容器高负载阈值    |

---

## 决策逻辑

按以下优先级依次判断，命中即输出：

| 优先级 | 条件                                                                                  | 结论                                        |
| --- | ----------------------------------------------------------------------------------- | ----------------------------------------- |
| B1  | BURST\_SUPPORT = 不支持                                                                | 环境不支持 — 内核未提供 sched\_soft\_runtime\_ratio |
| B2  | 无运行中容器（采样中无 CONTAINER 块）                                                            | 无运行中的容器，无需启用                              |
| B3  | HOST\_CPU\_UTIL > HOST\_THRESHOLD                                                   | 不建议启用 — 宿主机负载高，不适合调度突发流量                  |
| B4  | HOST\_CPU\_UTIL ≤ HOST\_THRESHOLD 且存在 soft\_quota=0 且使用率 > CONTAINER\_THRESHOLD 的容器 | **建议启用** — 宿主机负载低，存在未启用 burst 的高负载容器      |
| B5  | HOST\_CPU\_UTIL ≤ HOST\_THRESHOLD 且所有高负载容器已启用 burst（soft\_quota=1）                  | 无需额外操作 — 已正确配置                            |
| B6  | HOST\_CPU\_UTIL ≤ HOST\_THRESHOLD 且所有容器使用率 ≤ CONTAINER\_THRESHOLD                   | 无需启用 — 无高负载容器                             |

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-docker-coordination-burst-analysis_collect/result.md`，格式如下：

```markdown
## Docker Coordination Burst 分析结论

**结论**：{结论}

**原因**：{原因}

## 评估摘要

| 指标 | 观测值 | 阈值 | 状态 |
|------|--------|------|------|
| 宿主机 CPU 使用率 | {X}% | {HOST_THRESHOLD}% | {高负载/低负载} |
| 内核 burst 支持 | {支持/不支持} | 必须支持 | ✅/❌ |
| 检测到容器数 | {N} | >0 | {有/无} |

## 容器级评估明细

| 容器 ID（短） | CPU 使用率 | CPU 限制（核） | 软配额 | 分类 |
|---------------|-----------|---------------|--------|------|
| {short_id} | {X}% | {limit} | {已启用/未启用} | {建议对象/已启用 burst/低负载} |
```

**注意**：当 B3 命中（不建议启用）时，仍应展示容器级评估明细，仅不输出建议操作。

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "docker_coordination_burst",
  "suggestion": "设置全局 sched_soft_runtime_ratio=20，对高负载容器写入 cpu.soft_quota=1",
  "equivalence_class": "docker_coordination_burst",
  "activation_requirement": "immediate",
  "estimated_gain": {
    "primary_metric": "container_cpu_throttle",
    "severity": "high",
    "description": "容器CPU限流现象减少50%-80%，突发请求响应延迟降低30%-50%"
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
> - `applicability`：分析结论为"建议启用"→ `"applicable"`；"不建议启用"（宿主机负载高等运行时条件）→ `"limited_benefit"`；"无需启用/环境不支持/无运行中容器"→ `"not_applicable"`
> - 映射标准见 [统一映射表](../references/result-template.md#零子技能结论--结构化数据映射统一标准)
> - `estimated_gain.severity`：使用评估矩阵判定（瓶颈严重程度 × 建议匹配效能）→ `high` / `medium` / `low`
> - 若 applicability 为 `"not_applicable"`：`estimated_gain.severity` 设为 `"low"`，`suggestion` 填写不适用/不支持的原因描述
> - 若 applicability 为 `"limited_benefit"`：`estimated_gain.severity` 设为 `"low"`，正常参与融合流程
> - activation_requirement 字段保持当前模板中预设的值，无需修改。

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-docker-coordination-burst-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
