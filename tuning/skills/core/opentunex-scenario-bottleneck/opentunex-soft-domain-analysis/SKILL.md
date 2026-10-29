---
name: "opentunex-soft-domain-analysis"
description: "分域调度分析。检查SOFT_DOMAIN特性支持、分析NUMA拓扑与容器/进程部署场景，评估soft_domain调优的适用性。触发:NUMA节点>1、小配额多实例容器、跨NUMA调度抖动。"
---

# 分域调度分析

分析系统 NUMA 拓扑和容器/进程部署场景，检查内核 sched_features 中 SOFT_DOMAIN 特性支持状态，评估分域调度（soft_domain）调优的适用性。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-soft-domain-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-soft-domain-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行环境约束前置检查 → NUMA 拓扑检查 → 场景模式判定 | 分析结论 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-soft-domain-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-soft-domain-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-soft-domain-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `arch` | ARCH | 字符串：`"aarch64"` / `"x86_64"` / ... |
| `numa_nodes` | NUMA_NODES | 整数，NUMA 节点数量 |
| `cpu_per_numa` | CPU_PER_NUMA | 整数，每个 NUMA 节点的 CPU 数量 |
| `kernel_ver` | KERNEL_VER | 字符串，内核版本号 |
| `soft_domain_exist` | SOFT_DOMAIN_EXIST | `"存在"` / `"不存在"` |
| `soft_domain_enabled` | SOFT_DOMAIN_ENABLED | `"已启用"` / `"未启用"` |
| `sched_features_writable` | SCHED_FEATURES_WRITABLE | `"可写"` / `"不可写"` |
| `debugfs_mounted` | DEBUGFS_MOUNTED | `"已挂载"` / `"未挂载"` |
| `container_count` | CONTAINER_COUNT | 整数，容器数量 |
| `small_quota_instances` | SMALL_QUOTA_INSTANCES | 整数，小配额容器数量 |
| `container_quota_list` | CONTAINER_QUOTA_LIST | 数组，每个元素含 `name`（容器名）、`quota_cpus`（配额 CPU 数）、`is_small`（是否小配额） |
| `target_pid` | TARGET_PID | 整数或 `null` |
| `target_cpus_allowed` | TARGET_CPUS_ALLOWED | 字符串或 `"null"`，如 `"0-3,8-11"` |
| `target_cpu_affinity_span` | TARGET_CPU_AFFINITY_SPAN | 整数，CPU 亲和跨越的 NUMA 节点数（由脚本预计算） |
| `numa_cpu_map` | NUMA_CPU_MAP | `{"node0": [0,1,...], "node1": [2,3,...]}` |

> **注意**：`target_cpu_affinity_span` 已由脚本基于 `numa_cpu_map` 预计算，可直接用于决策逻辑 S3/S4 判定，无需再手动计算。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 从 `${DATA_DIR}/static_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| ARCH | 搜索 `Architecture:` 后的值（如 `aarch64`），位于 "--- System Info ---" 或 `uname -m` 输出节 | x86_64 |
| NUMA_NODES | 搜索 `--- NUMA Topology ---` 节中 `node X cpus:` 出现次数；若无，搜索 `NUMA node(s)` 后的数字 | 1 |
| CPU_PER_NUMA | 搜索 `--- NUMA Topology ---` 节中第一个 `node X cpus:` 的 CPU 编号个数；若无，用 `CPU(s)` / NUMA_NODES 估算 | 0 |
| KERNEL_VER | 搜索 `Kernel:` 或 `uname -r` 输出的内核版本号 | — |
| NUMA_CPU_MAP | 搜索 `--- NUMA Topology ---` 节，从 `numactl --hardware` 输出中解析 `node X cpus: Y Z ...` 行，建立 `NUMA节点 → [cpu列表]` 的映射 | 空映射 |

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| SOFT_DOMAIN_EXIST | 搜索 `=== 调度特性 ===` 节中 `SOFT_DOMAIN` 关键字：出现 `SOFT_DOMAIN` 词 → 存在；未出现 → 不存在 | 不存在 |
| SOFT_DOMAIN_ENABLED | 当 SOFT_DOMAIN 存在时：出现 `SOFT_DOMAIN` 且**不含** `NO_SOFT_DOMAIN` → 已启用；含 `NO_SOFT_DOMAIN` → 未启用 | 未启用 |
| SCHED_FEATURES_WRITABLE | 搜索 `sched_features 可写` 或类似描述（存在 `/sys/kernel/debug/sched/features` 且可写） | 不可写 |
| DEBUGFS_MOUNTED | 搜索 `debugfs` 挂载信息（通常含 `debugfs` 关键字），或确认 `/sys/kernel/debug/` 目录存在且 `/sys/kernel/debug/sched/features` 路径可访问 | 未挂载 |

#### 从 `${DATA_DIR}/docker_info.txt` 或 `${DATA_DIR}/container_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| CONTAINER_COUNT | 统计 `docker ps` 输出中容器行数（排除表头） | 0 |
| CONTAINER_QUOTA_LIST | 搜索每个容器的 CPU 配额：`docker inspect` 输出中 `NanoCpus`、`CpuQuota`/`CpuPeriod` 组 | — |
| SMALL_QUOTA_INSTANCES | 统计配额 CPU 数 ≤ CPU_PER_NUMA 的容器数量 | 0 |

**配额 CPU 数计算规则**：
- `NanoCpus` 存在：`quota_cpus = NanoCpus / 1e9`
- `CpuQuota`/`CpuPeriod` 存在：`quota_cpus = CpuQuota / CpuPeriod`
- `cpuset` 存在：`quota_cpus = cpuset 指定的 CPU 数`
- 无任何配额信息：`quota_cpus = ∞`（视为不受限，不计入小配额）

#### 从 `${DATA_DIR}/top_processes.txt` 或 `${DATA_DIR}/process_info.txt` 读取（process 模式）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| TARGET_PID | 用户指定的目标进程 PID，或从进程中搜索用户关注的关键进程 | — |
| TARGET_CPUS_ALLOWED | 搜索目标进程的 `Cpus_allowed_list` | — |
| TARGET_CPU_AFFINITY_SPAN | 统计 `Cpus_allowed_list` 跨越的 NUMA 节点数 | 1 |

### 用户输入

| 输入项 | 必需 | 说明 |
|--------|------|------|
| USER_FOCUS_CONTAINERS | 否 | 用户关注的容器名称模式（如 `redis*`、`mysql*`） |
| USER_FOCUS_PROCESSES | 否 | 用户关注的进程名（如 `mysqld`、`redis-server`） |
| LATENCY_SENSITIVE | 否 | 用户是否明确标注为尾延迟敏感型业务（默认 `false`） |

---

## 决策逻辑

按以下优先级依次判断，命中即输出。

### 环境约束前置检查

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| E1 | ARCH ≠ aarch64 | 不适用 | 非 aarch64 架构，soft_domain 仅适用于 aarch64 |
| E2 | SOFT_DOMAIN_EXIST = 不存在 | 不适用 | 内核调度特性中未包含 SOFT_DOMAIN |
| E3 | DEBUGFS_MOUNTED = 未挂载 或 SCHED_FEATURES_WRITABLE = 不可写 | 不适用 | 无法通过 debugfs 修改 sched_features |
| E4 | SOFT_DOMAIN_ENABLED = 已启用 | 不适用 | SOFT_DOMAIN 已启用，无需再调优 |

### NUMA 拓扑检查

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| N1 | NUMA_NODES ≤ 1 | 不适用 | 单 NUMA 节点无跨节点调度问题 |
| N2 | CPU_PER_NUMA ≤ 0 | 收益有限 | 无法确定每节点 CPU 数，不足以评估小配额场景 |

### 场景模式判定

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| S1 | CONTAINER_COUNT > 0 且 SMALL_QUOTA_INSTANCES ≤ 0 | 收益有限 | 容器存在但无小配额实例，跨 NUMA 调度影响有限 |
| S2 | CONTAINER_COUNT > 0 且 SMALL_QUOTA_INSTANCES ≥ 2 | **适用（容器模式）** | 存在 {N} 个小配额多实例容器运行在 {M} NUMA 节点上，跨 NUMA 调度可能导致性能抖动 |
| S3 | CONTAINER_COUNT = 0 且 TARGET_PID 有值 且 TARGET_CPU_AFFINITY_SPAN > 1 | **适用（进程模式）** | 目标进程跨越 {N} 个 NUMA 节点运行，存在跨 NUMA 调度可能 |
| S4 | CONTAINER_COUNT = 0 且 TARGET_PID 有值 且 TARGET_CPU_AFFINITY_SPAN ≤ 1 | 收益有限 | 目标进程仅运行在单 NUMA 节点，无跨节点调度问题 |
| S5 | CONTAINER_COUNT = 0 且 TARGET_PID 无值 | 收益有限 | 无容器且未指定目标进程，缺少场景触发条件 |

### 收益评估（仅当结论为"适用"时填充）

| 结论来源 | 适用场景 | 预期收益 |
|---------|---------|---------|
| S2（容器模式） | 多实例小配额容器 + 多 NUMA | 减少跨 NUMA 调度开销，降低尾延迟抖动 30%-50%；提高容器内 CPU 亲和性和缓存命中率 |
| S3（进程模式） | 单进程跨 NUMA + 多 NUMA | 减少跨 NUMA 调度开销，降低内存访问延迟 10%-20% |

### 特殊建议（仅当结论为"适用"时追加）

| 条件 | 建议 |
|------|------|
| LATENCY_SENSITIVE = true | 尾延迟敏感业务强烈建议启用 soft_domain，优先在低负载时段操作 |
| sched_features 含 `NO_SOFT_DOMAIN` | 需通过 debugfs 移除 `NO_SOFT_DOMAIN`：`echo SOFT_DOMAIN > /sys/kernel/debug/sched/features` |

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-soft-domain-analysis_collect/result.md`，格式如下：

```markdown
# 分域调度分析结果

## 1. 环境检查

| 检查项 | 结果 |
|--------|------|
| ARCH | {aarch64/x86_64/...} |
| KERNEL_VER | {内核版本} |
| SOFT_DOMAIN_EXIST | {存在/不存在} |
| SOFT_DOMAIN_ENABLED | {已启用/未启用} |
| DEBUGFS_MOUNTED | {已挂载/未挂载} |
| SCHED_FEATURES_WRITABLE | {可写/不可写} |

## 2. NUMA 拓扑

| 指标 | 值 |
|------|-----|
| NUMA_NODES | {N} |
| CPU_PER_NUMA | {N} |

## 3. 场景特征

| 指标 | 值 |
|------|-----|
| CONTAINER_COUNT | {N} |
| SMALL_QUOTA_INSTANCES | {N} |
| TARGET_PID | {PID 或 "未指定"} |
| TARGET_CPU_AFFINITY_SPAN | {N} |
| LATENCY_SENSITIVE | {true/false} |

### 容器配额详情（如适用）

| 容器名 | 配额 CPU 数 | 小配额判定 |
|--------|-----------|-----------|
| {容器名} | {N} | ✅/❌ |

## 4. 适用性评估

| 评估维度 | 结果 | 证据 |
|---------|------|------|
| aarch64架构 | ✅/❌ | ARCH={值} |
| SOFT_DOMAIN特性存在 | ✅/❌ | sched_features 含/不含 SOFT_DOMAIN |
| SOFT_DOMAIN当前状态 | {已启用/未启用} | — |
| debugfs可写 | ✅/❌ | — |
| 多NUMA节点 | ✅/❌ | {N}个NUMA节点 |
| 小配额多实例 | ✅/❌ | {N}个容器配额≤{每节点CPU数} |
| 跨NUMA亲和性 | ✅/❌ | Cpus_allowed_list 跨越 {N} 个NUMA节点 |

**综合结论**: {适用/不适用/收益有限} — {原因}

**适用场景**: {容器模式/进程模式}

**预期收益**: {量化收益}

**建议操作**:
{操作步骤}

**调优前提**: 仅适用于 aarch64 架构，需 debugfs 可写

**回滚参考**: SOFT_DOMAIN_ORIG={NO_SOFT_DOMAIN 或 SOFT_DOMAIN}（记录原始状态）

## 5. 调优参数推荐

> 以下参数可直接传递给调优技能 `opentunex-soft-domain-tuning`。

| 参数 | 填充规则 | 示例 |
|------|---------|------|
| RECOMMENDED_MODE | 适用场景为"容器模式" → `docker`；"进程模式" → `process` | `docker` |
| RECOMMENDED_WHITELIST | 容器模式：从小配额容器列表中提取容器名，用 `\|` 拼接（如 `container-a\|container-b`）；进程模式：提取目标进程名（如 `mysqld`） | `mysql-ks\|redis-ks` |

> **输出格式**：在报告末尾以独立段落输出，供调优技能解析：
>
> ```
> **RECOMMENDED_MODE**: docker
> **RECOMMENDED_WHITELIST**: mysql-ks|redis-ks
> ```

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "soft_domain",
  "suggestion": "写入 SOFT_DOMAIN 到 sched_features 总开关，对目标容器或进程 cgroup 写入 cpu.soft_domain_nr_cpu=<配额核数> 和 cpu.soft_domain=<NUMA编号>",
  "equivalence_class": "soft_domain",
  "activation_requirement": "immediate",
  "estimated_gain": {
    "primary_metric": "tail_latency_jitter",
    "severity": "high",
    "description": "减少跨NUMA调度开销，降低尾延迟抖动30%-50%；提高容器内CPU亲和性和缓存命中率"
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
```

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-soft-domain-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
