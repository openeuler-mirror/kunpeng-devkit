---
name: "opentunex-stealtask-analysis"
description: "窃取任务调度分析。检查CONFIG_SCHED_STEAL与STEAL特性支持、分析CPU负载与调度特征、评估调优适用性。触发:CPU高负载、负载不均衡、调度优化。"
---

# 窃取任务调度分析

分析系统CPU负载状态和调度特征，检查内核是否支持窃取任务（stealtask）特性，评估窃取任务调优的适用性。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-stealtask-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-stealtask-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行 S1→S6 判定 | 分析结论 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-stealtask-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-stealtask-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-stealtask-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `config_sched_steal` | CONFIG_SCHED_STEAL | `"已启用"` / `"未启用"` |
| `steal_support` | STEAL_SUPPORT | `"支持"` / `"不支持"` |
| `steal_enabled` | STEAL_ENABLED | `"已启用"` / `"未启用"` |
| `cmdline_steal_node_limit` | CMDLINE_STEAL_NODE_LIMIT | `"已配置"` / `"未配置"` |
| `steal_version` | STEAL_VERSION | `"旧版本"` / `"新版本"` / `"未知"`（通过 `sched_max_steal_count` sysctl 是否存在判断） |
| `cpu_usage` | CPU_USAGE | 数值百分比，如 `75.50` |
| `cpu_imbalance` | CPU_IMBALANCE | 数值百分比，如 `35.20`，max(核心使用率) − min(核心使用率)（由脚本预计算） |
| `cs_rate` | CS_RATE | 整数，vmstat cs 列平均值 |

> **注意**：`cpu_imbalance` 已由脚本基于各核心 mpstat Average 行预计算，可直接用于 S4/S5/S6 判定，无需再手动计算。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| CONFIG_SCHED_STEAL | 搜索 "CONFIG_SCHED_STEAL=y" → 已启用；否则搜索 "sched_steal_node_limit:" 看是否为 yes | 未启用 |
| STEAL_SUPPORT | 搜索 "STEAL" 关键字：出现 "STEAL" 或 "NO_STEAL" → 支持；均不出现 → 不支持 | 不支持 |
| STEAL_ENABLED | 搜索 sched_features 内容：出现 "STEAL" 且无 "NO_" 前缀 → 已启用 | 未启用 |
| CMDLINE_STEAL_NODE_LIMIT | 搜索 "sched_steal_node_limit:"：值为 yes → 已配置；否则 → 未配置 | 未配置 |
| STEAL_VERSION | 搜索 `sched_max_steal_count` sysctl 输出：能正常输出数值 → 旧版本；报错 "unknown key" 或无法访问 → 新版本 | 未知 |

#### 从 `${DATA_DIR}/global_bottleneck.txt` 读取（若缺数据则回退到 `${DATA_DIR}/cpu_detail_info.txt`）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| CPU_USAGE | 从 "各核心利用率 (mpstat)" 节中找 `Average: all` 行，100 − idle% = 使用率；若无，从 "/proc/stat 多采样" 节中取 `cpu ` 行计算 (delta_total − delta_idle) / delta_total × 100 | 0 |
| CPU_IMBALANCE | 从 mpstat 各核心 Average 行中，max(使用率) − min(使用率) | 0 |
| CS_RATE | vmstat 输出中 cs 列平均值 | 0 |

**阈值参数**：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| CPU_HIGH | 70% | CPU 高负载阈值 |
| CPU_LOW | 40% | CPU 低负载阈值 |
| IMBALANCE | 30% | 负载不均衡阈值 |

---

## 决策逻辑

按以下优先级依次判断，命中即输出：

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| S1 | CONFIG_SCHED_STEAL = 未启用 | 不适用 | 内核不支持 CONFIG_SCHED_STEAL |
| S2 | STEAL_ENABLED = 已启用 | 不适用 | STEAL 特性已启用 |
| S3 | CPU_USAGE < CPU_LOW | 收益有限 | CPU 负载较低 |
| S4 | CPU_USAGE ≥ CPU_HIGH 且 CPU_IMBALANCE ≥ IMBALANCE 且 !STEAL_ENABLED | **适用** | 高负载+不均衡，收益高 |
| S5 | CPU_USAGE ≥ CPU_LOW 且 CPU_IMBALANCE ≥ IMBALANCE 且 !STEAL_ENABLED | **适用** | 存在不均衡，有收益 |
| S6 | CPU_USAGE ≥ CPU_HIGH 但 CPU_IMBALANCE < IMBALANCE | 收益有限 | 负载已均衡 |

### 预期收益（仅当结论为"适用"时填充）

| 结论来源 | 预期收益 |
|---------|---------|
| S4（高负载+不均衡） | CPU资源利用率提升10%-20%，负载均衡速度提升30%-50% |
| S5（存在不均衡） | CPU资源利用率提升5%-15%，负载均衡速度提升15%-30% |

### 版本判定与启用方式（仅当结论为"适用"时填充）

> STEAL 特性在不同内核版本上有不同的启用方式。通过检查 `sched_max_steal_count` sysctl 是否可用来判断版本。

| 版本 | 判定方式 | 启用步骤 |
|------|---------|---------|
| 旧版本 | `sysctl kernel.sched_max_steal_count` 可输出数值 | ① 在 grub.cfg 中添加 `sched_steal_node_limit=<NUMA 节点数>` 启动项参数；② 重启宿主机；③ `echo STEAL > /sys/kernel/debug/sched/features` |
| 新版本（宿主机级别） | `sysctl kernel.sched_max_steal_count` 报错 `unknown key` | `echo STEAL > /sys/kernel/debug/sched/features`（无需额外参数，立即生效） |
| 新版本（容器级别 group_steal） | 同上 + 容器场景 | ① 在 grub.cfg 中添加 `group_steal` 启动项参数；② 重启宿主机；③ `echo STEAL > /sys/kernel/debug/sched/features`；④ `echo 1 > /sys/fs/cgroup/cpu/<cgroup>/cpu.steal_task` |

**恢复方法**：

| 版本 | 恢复步骤 |
|------|---------|
| 旧版本 | ① 删除 grub.cfg 中的 `sched_steal_node_limit`；② 重启宿主机；③ `echo NO_STEAL > /sys/kernel/debug/sched/features` |
| 新版本（宿主机级别） | `echo NO_STEAL > /sys/kernel/debug/sched/features` |
| 新版本（容器级别） | ① 删除 grub.cfg 中的 `group_steal`；② 重启宿主机；③ `echo NO_STEAL > /sys/kernel/debug/sched/features`；④ `echo 0 > /sys/fs/cgroup/cpu/<cgroup>/cpu.steal_task` |

### 容器级 stealtask 触发条件（仅当结论为"适用"且有分析数据时判定）

> `group_steal` 是容器粒度的 steal_task 控制，仅在"存在运行中容器 且 需要差异化控制"时才推荐容器级别。

| 场景 | 判定条件 | 推荐模式 | 理由 |
|------|---------|---------|------|
| 宿主机级别 | 结论为"适用"且 `CONTAINER_COUNT = 0` 或无容器数据 | 宿主机模式（旧版本/新版本） | 无容器或无法获取容器信息，全体宿主机进程统一启用 steal |
| 容器级别 (group_steal) | 结论为"适用"且 `STEAL_VERSION = 新版本` 且 `CONTAINER_COUNT > 0` 且用户关注特定容器 | 容器模式（group_steal） | 仅对指定 cgroup 开启 steal_task，避免影响其他容器 |
| 宿主机级别（有容器，无差异化需求） | 结论为"适用"且 `CONTAINER_COUNT > 0` 但无需按容器区分 | 宿主机模式 | 所有进程（含容器内进程）统一使用 steal，简单高效 |

> **默认策略**：当 `CONTAINER_COUNT > 0` 且为**新版本**内核时，应同时输出宿主机和容器两种启用路径，由用户根据实际需求选择。旧版本内核不支持 `cpu.steal_task` cgroup 接口。

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-stealtask-analysis_collect/result.md`，格式如下：

```markdown
# 窃取任务调度分析结果

## 1. 环境检查

| 检查项 | 结果 |
|--------|------|
| CONFIG_SCHED_STEAL | {启用/未启用} |
| STEAL_SUPPORT | {支持/不支持} |
| STEAL_STATUS | {已启用/未启用} |
| CMDLINE_STEAL_NODE_LIMIT | {已配置/未配置} |
| STEAL_VERSION | {旧版本/新版本/未知} |

## 2. CPU负载与调度指标

| 指标 | 值 |
|------|-----|
| CPU_USAGE | {X}% |
| CPU_IMBALANCE | {X}% |
| CS_RATE | {X} |

## 3. 适用性评估

| 评估维度 | 结果 | 证据 |
|---------|------|------|
| 内核CONFIG支持 | ✅/❌ | CONFIG_SCHED_STEAL={y/n} |
| STEAL特性支持 | ✅/❌ | sched_features支持状态 |
| STEAL当前状态 | {已启用/未启用} | — |
| CPU负载水平 | {高/中/低} | 使用率 {X}% |
| 负载均衡度 | {均衡/不均衡} | 不均衡度 {X}% |

**综合结论**: {适用/不适用/收益有限} — {原因}

**预期收益**: {量化收益或无}

**调优前提**: 仅适用于 aarch64 架构

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "stealtask_steal",
  "suggestion": "根据内核版本选择启用方式：旧版本在 grub.cfg 添加 sched_steal_node_limit=<NUMA节点数> 并重启后 echo STEAL > sched_features；新版本直接 echo STEAL > sched_features 即可（容器场景需额外 grub.cfg 添加 group_steal 并重启后 echo 1 > cpu.steal_task）",
  "equivalence_class": "stealtask_steal",
  "activation_requirement": "{immediate / system_reboot}（根据 STEAL_VERSION 动态填充：新版本→immediate；旧版本或容器 group_steal 场景→system_reboot）",
  "estimated_gain": {
    "primary_metric": "cpu_imbalance",
    "severity": "high",
    "description": "CPU资源利用率提升10%-20%，负载均衡速度提升30%-50%"
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
> - `applicability`：分析结论为"适用"→ `"applicable"`；"收益有限"→ `"limited_benefit"`；"不适用"→ `"not_applicable"`。映射标准见 [统一映射表](../references/result-template.md#零子技能结论--结构化数据映射统一标准)
> - `activation_requirement`：根据 STEAL_VERSION 动态填充。新版本（宿主机级别）→ `"immediate"`；旧版本或容器 group_steal 场景（需修改 grub.cfg 并重启）→ `"system_reboot"`
> - `estimated_gain.severity`：使用评估矩阵判定（瓶颈严重程度 × 建议匹配效能）→ `high` / `medium` / `low`
> - 若 applicability 为 `"not_applicable"`：`estimated_gain.severity` 设为 `"low"`，`suggestion` 填写不适用/收益有限的原因描述
> - 若 applicability 为 `"limited_benefit"`：`estimated_gain.severity` 设为 `"low"`，正常参与融合流程
> - `activation_requirement`：根据 STEAL_VERSION 动态填充（见上方说明），无需手动修改模板。
```

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-stealtask-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
