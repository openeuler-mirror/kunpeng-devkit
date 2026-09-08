---
name: "opentunex-multi-net-path-analysis"
description: "网卡多路径瓶颈分析。检查oenetcls内核模块支持、网卡ntuple硬件过滤能力、irqbalance状态、NUMA拓扑，评估multi_net_path_tune特性适用性与运行条件。触发:多网卡多NUMA环境、跨NUMA中断开销、网络密集型业务。"
---

# 网卡多路径瓶颈分析

分析主机多网卡多NUMA环境下的网络中断亲和性，检查 `oenetcls` 内核模块支持状态、网卡 ntuple 硬件过滤能力、irqbalance 状态及 NUMA 拓扑，评估 `multi_net_path_tune` 特性的适用性和运行条件。

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-multi-net-path-analysis_collect`。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-multi-net-path-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行阶段一→阶段二→阶段二点五→阶段三 | 分析结论 + 推荐参数 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-multi-net-path-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 数据读取

> **优先级**：本技能提供 `scripts/preanalysis.sh` 脚本对原始采集数据进行预处理。优先执行脚本生成 `preanalysis.json`，然后基于 JSON 进行分析。逐文件读取原始数据仅作为降级路径。

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-multi-net-path-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-multi-net-path-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `oenetcls.loaded` | OENETCLS_LOADED | `true` → 已加载；`false` → 未加载 |
| `oenetcls.available` | OENETCLS_AVAILABLE | `true` → 可用；`false` → 不可用 |
| `irqbalance` | IRQBALANCE_ACTIVE | `"active"` → 运行中；`"inactive"` → 未运行；`"unknown"` → 未知 |
| `numa_nodes` | NUMA_NODES | 整数，NUMA 节点数量 |
| `numa_cpu_map` | NUMA_CPU_MAP | `{"node0": [0,1,...], "node1": [2,3,...]}` |
| `interrupt_overview` | INTERRUPT_DISTRIBUTION | 字符串："集中在少数核心(≤2)" / "分布在N个核心" / "均匀分布在N个核心" / "无数据" |
| `apps.redis` | HAS_REDIS | `true` / `false` |
| `apps.nginx` | HAS_NGINX | `true` / `false` |
| `apps.mysql` | HAS_MYSQL | `true` / `false` |
| `target_app_pid` | TARGET_APP_PID | 整数或 `null` |
| `physical_nics` | NIC_LIST | 字符串数组，如 `["eth0", "eth1"]` |
| `physical_nics.length` | PHYSICAL_NIC_COUNT | 物理网卡数量 |
| `nic_details[].has_ntuple` | NIC_NTUPLE_MAP | `true` → 1（有 ntuple）；`false` → 0（无） |
| `nic_details[].ntuple_fixed` | NIC_NTUPLE_MAP | `"no"` → 2（可配置）；`"yes"` → 1（被 [fixed] 锁定）；`"N/A"` → 0（不适用） |
| `nic_details[].max_q` | NIC_QUEUES_MAP | 最大 Combined 队列数（或 RX+TX 之和） |
| `nic_details[].cur_q` | NIC_QUEUES_MAP | 当前 Combined 队列数（或 RX+TX 之和） |
| `nic_details[].rxpck` | NIC_TRAFFIC_MAP | 接收包速率（rxpck/s） |
| `nic_details[].rxkb` | NIC_TRAFFIC_MAP | 接收流量（rxkB/s） |
| `nic_details[].multi_path` | multi_path | `true` → yes（硬件支持多路径）；`false` → no |
| `nic_details[].recommend_enable` | recommend_enable | `true` → yes（建议使能）；`false` → no |
| `nic_details[].numa_span` | NIC_NUMA_SPAN | IRQ 涉及的 NUMA 节点数（由脚本预计算） |
| `nic_details[].numa_annotation` | NUMA 标注 | 如 "中断跨NUMA，多路径收益明确" / "单NUMA亲和"（由脚本预计算） |

> **注意**：`nic_details[].multi_path`、`nic_details[].recommend_enable`、`nic_details[].numa_span`、`nic_details[].numa_annotation` 已由脚本预计算，可直接用于决策逻辑，无需再逐个网卡分析 IRQ 亲和。

### 降级路径：逐文件读取（仅当 preanalysis.json 不可用时）

> 以下为逐文件读取原始采集数据的解析规则。仅在以下情况使用：
> - `preanalysis.json` 文件不存在
> - 脚本 `preanalysis.sh` 执行失败
> - 需要交叉验证 JSON 中的数据

#### 从 `${DATA_DIR}/kernel_config_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| OENETCLS_LOADED | 搜索 `--- oenetcls ---` 节：若紧随其后出现 `modinfo` 输出（含 `filename:`、`description:` 等字段）→ 模块存在；再搜索 `--- cpufreq_seep / oenetcls in /proc/modules ---` 节：若该节中出现 `oenetcls` 行（非 `(无匹配)`）→ 已加载；若仅 `modinfo` 有输出但 `/proc/modules` 无 → 存在但未加载 | 不存在 |
| OENETCLS_AVAILABLE | `modinfo oenetcls` 有输出 → 可用；无输出或 `modinfo: ERROR` → 不可用 | 不可用 |
| IRQBALANCE_ACTIVE | 搜索 `--- irqbalance ---` 节下一行的内容：若为 `active` → 运行中；若为 `inactive` 或其他 → 未运行 | unknown |

#### 从 `${DATA_DIR}/network_metrics_analysis.txt` 读取（网卡硬件能力）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NIC_NTUPLE_MAP | 对每张物理网卡，调用 `ethtool -k "$ifname"` 后使用 `grep -iE 'ntuple-filters\|ntuple'` 匹配输出行：若匹配到行（含 `ntuple-filters` 或 `ntuple` 关键字）→ `has_ntuple=1`；若该行中任意位置含 `[fixed]` 标记 → `ntuple_fixed=1`（硬件锁定不可变更），否则 `ntuple_fixed=2`（可配置）。若未匹配到 → `has_ntuple=0, ntuple_fixed=0`（N/A）。建立 `网卡名 → {has_ntuple, ntuple_fixed}` 映射 | 空映射 |
| NIC_QUEUES_MAP | 对每张物理网卡，解析其 `ethtool -l` 输出：从 `Pre-set maximums` 节取 `Combined:` 值作为 `max_q`；若 Combined 不存在或值为 0，取该节中 `RX:` + `TX:` 之和作为 `max_q`。从 `Current hardware settings` 节取 `Combined:` 值作为 `cur_q`；若 Combined 不存在或值为 0，取该节中 `RX:` + `TX:` 之和作为 `cur_q`。建立 `网卡名 → {max_q, cur_q}` 映射 | 空映射 |
| NIC_TRAFFIC_MAP | 从 `sar -n DEV` 输出或 `=== 网卡流量采集 ===` 节提取每张物理网卡的 `rxkB/s` 值：优先取 `Average:` / `平均:` 汇总行（列顺序 `IFACE rxpck/s ... rxkB/s`）；若无汇总行，取各时间戳采样行（注意 12h 制 AM/PM 会导致列号后移一位：`$2=="PM"\|$2=="AM"` 时 IFACE 在 $3、rxkB 在 $6，否则 IFACE 在 $2、rxkB 在 $5）的均值。若 sar 解析失败或输出为空，回落使用 `/proc/net/dev` 两次采样（间隔等同 sar 采集时长）计算速率差值。建立 `网卡名 → {rxpck, rxkB}` 映射 | 空映射 |
| PHYSICAL_NIC_COUNT | 从 `=== 接口详细状态 (/sys/class/net) ===` 节中统计物理网卡数量（排除 lo、docker*、veth*、br-*、virbr*、tun*、tap* 等虚拟接口）；若该节不可用，从 `ip -br link show` 输出中统计 | 0 |
| NIC_LIST | 提取所有物理网卡名称列表（过滤规则同 PHYSICAL_NIC_COUNT） | 空 |

#### 从 `${DATA_DIR}/static_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NUMA_NODES | 搜索 `--- NUMA Topology ---` 节中 `node X cpus:` 出现次数；若无，搜索 `available: X nodes` 中的数字 | 1 |

#### 从 `${DATA_DIR}/cpu_detail_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| INTERRUPT_DISTRIBUTION | 搜索 `=== /proc/interrupts ===` 节，提取 eth 相关网卡的中断行，观察中断在各 CPU 核心上的分布情况 | 无数据 |

#### 从 `${DATA_DIR}/network_metrics_analysis.txt` 读取（IRQ 亲和分析）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NIC_IRQ_MAP | 遍历每个物理网卡的 `--- IRQ Affinity ---` 节：逐行解析 `IRQ X: <smp_affinity> (<desc>)`，建立 `网卡名 → [{irq, smp_affinity, cpu_list}]` 的映射关系 | 空映射 |
| IRQ_CPU_PARSING | 将 smp_affinity 十六进制掩码（如 `00000000,00000001` 或 `ff`）解析为 CPU 列表：长格式按逗号拆分为 32-bit 块，低位在前，每 bit 对应一个 CPU 编号；短格式（≤16 个 CPU）直接按单块解析 | — |

#### 从 `${DATA_DIR}/static_info.txt` 读取（NUMA CPU 映射）

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| NUMA_CPU_MAP | 搜索 `--- NUMA Topology ---` 节，从 `numactl --hardware` 输出中解析 `node X cpus: Y Z ...` 行，建立 `NUMA节点 → [cpu列表]` 的映射 | 空映射 |

#### 从 `${DATA_DIR}/process_detail_info.txt` 读取

| 指标 | 提取方法 | 默认值 |
|------|---------|--------|
| TARGET_PROCESSES | 搜索 `=== 关键进程检查 ===` 节，检查是否存在 `redis-server`、`nginx`、`mysql` 等目标业务进程（输出非 `未运行` 即为存在） | 无 |
| HAS_REDIS | `pgrep -a redis-server` 输出非空（非 `redis-server 未运行`）→ 存在 | false |
| HAS_NGINX | `pgrep -a nginx` 类似判断 | false |
| HAS_MYSQL | `pgrep -a mysql` 类似判断 | false |
| TARGET_APP_PID | 若目标进程存在，从 pgrep 输出中提取第一个 PID；如 `pgrep -a redis-server` 输出 `12345 /usr/bin/redis-server`，则 APP_PID=12345 | 无

---

## 决策逻辑

按以下优先级依次判断，命中即输出。

### 阶段一：基础可行性检查

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| M1 | OENETCLS_LOADED = 已加载 | **已启用** | oenetcls 模块已加载，multi_net_path_tune 特性可能已使能，无需重复操作 |
| M2 | OENETCLS_AVAILABLE = 不可用 | **不建议启用** | 内核不支持 oenetcls 模块，不具备运行条件 |
| M3 | NIC_NTUPLE_MAP 中没有任何网卡满足 `has_ntuple=1 且 ntuple_fixed=2`（即 ntuple 存在且未被 [fixed] 锁定） | **不建议启用** | 所有物理网卡的 ntuple 均不可配置（不存在或被硬件锁定），硬件过滤能力缺失 |
| M4 | IRQBALANCE_ACTIVE = active | **条件不满足** | irqbalance 正在运行，特性需接管中断亲和，须先停止 irqbalance |
| M5 | NUMA_NODES ≤ 1 | **不建议启用** | 系统仅 1 个 NUMA 节点，收益极小 |

### 阶段二：场景收益评估

> 仅当基础可行性检查全部通过（即未命中 M1-M5 中任何"不建议启用"或"条件不满足"结论）时，进入此阶段。

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| M6 | NUMA_NODES ≥ 2 且 PHYSICAL_NIC_COUNT ≥ 2 且 (HAS_REDIS 或 HAS_NGINX 或 HAS_MYSQL) | **建议启用（高收益）** | 多 NUMA（{N}节点）+ 多物理网卡（{M}张）+ 目标业务进程存在，满足典型高收益场景 |
| M7 | NUMA_NODES ≥ 2 且 PHYSICAL_NIC_COUNT ≥ 2 | **建议启用（中收益）** | 多 NUMA（{N}节点）+ 多物理网卡（{M}张），存在跨 NUMA 中断优化空间 |
| M8 | INTERRUPT_DISTRIBUTION 显示 eth 中断集中在少数核心 | **建议启用** | 中断分布不均，可能跨 NUMA，优化空间大 |
| M9 | 以上均不满足 | **收益有限** | 当前环境不具备显著收益条件，可保持现状观察 |

### 阶段二点五：网卡-应用精准匹配

> **目标**：从所有物理网卡中筛选出**需要开启多路径特性的网卡列表**，并确定**目标应用名**。
> 仅当阶段二结论为"建议启用"时执行此阶段。
>
> **优先路径**：若使用 `preanalysis.json`，`nic_details[].multi_path`、`nic_details[].recommend_enable`、`nic_details[].numa_span`、`nic_details[].numa_annotation` 已由脚本预计算，**可跳过 Step 2 和 Step 3**，直接根据 `recommend_enable` 字段筛选纳入/排除的网卡，进入 Step 4 输出推荐参数。
>
> **降级路径**：若未使用 `preanalysis.json`（即使用逐文件读取），需按以下 Step 1-4 完整执行。

#### Step 1: 确定目标应用

按优先级选取第一个存在的应用作为 APP_NAME：

| 优先级 | 条件 | APP_NAME 取值 |
|--------|------|---------------|
| A1 | HAS_REDIS = true | `redis-server` |
| A2 | HAS_NGINX = true | `nginx` |
| A3 | HAS_MYSQL = true | `mysql` |
| A4 | 以上均不存在 | 从 `ps -eo comm` 输出中选取 CPU 占用最高的非内核进程名（排除 kworker、ksoftirqd 等） |

#### Step 2: 逐网卡 IRQ 亲和分析

对 NIC_LIST 中每一张物理网卡，执行以下判断：

| 子步骤 | 操作 |
|--------|------|
| 2a | 从 NIC_IRQ_MAP 中取出该网卡的所有 IRQ 记录 |
| 2b | 对每条 IRQ 记录，将 `smp_affinity` 解析为 CPU 列表（参考 IRQ_CPU_PARSING 规则） |
| 2c | 对解析出的 CPU 列表，使用 NUMA_CPU_MAP 反查每个 CPU 所属的 NUMA 节点 |
| 2d | 统计该网卡 IRQ 涉及的不同 NUMA 节点数量 → `NIC_NUMA_SPAN` |
| 2e | 若 TARGET_APP_PID 可用：从 NUMA_CPU_MAP 推算出应用进程可能所在的 NUMA 节点（假设进程可运行在所有 CPU 上） |

#### Step 3: 网卡筛选规则

对每张物理网卡，分两级判定。

**第一级 — 硬件条件判定（决定 `multi_path`）**：

| 条件 | `multi_path` | 说明 |
|------|-------------|------|
| NIC_NTUPLE_MAP[nic].has_ntuple=1 且 NIC_NTUPLE_MAP[nic].ntuple_fixed=2 | `yes` | ntuple 存在且可配置（未被 [fixed] 锁定），具备多路径硬件基础 |
| 其他（has_ntuple=0 或 ntuple_fixed=0/1） | `no` | ntuple 不存在或被硬件锁定无法变更 |

**第二级 — 推荐使能判定（决定 `recommend_enable`）**：

仅当 `multi_path=yes` 时进入此级。需同时满足以下三项才判定为 `recommend_enable=yes`：

| 条件 | 阈值 | 说明 |
|------|------|------|
| 队列数达标 | NIC_QUEUES_MAP[nic].max_q > 1 | 最大 Combined 队列数（或 RX+TX 之和）须大于 1，反映网卡多队列能力 |
| 流量达标 | NIC_TRAFFIC_MAP[nic].rxkB > 2048 | 网卡接收流量（rxkB/s）须超过 2048 KB/s 门槛，低于此值开启多路径收益有限 |
| 流量数据缺失 | NIC_TRAFFIC_MAP 中无该网卡数据 | 若流量数据缺失，此单项视为通过（不因缺数据而排除） |

**汇总判定**：

| `multi_path` | `recommend_enable` | 判定 |
|-------------|-------------------|------|
| no | — | **排除** — 硬件不支持多路径 |
| yes | no | **排除** — 硬件支持但流量/队列条件不满足 |
| yes | yes | **纳入** — 建议使能多路径 |

> **IRQ/NUMA 亲和补充分析**（与上述硬件判定并行，不改变 `recommend_enable` 结论，仅提供补充佐证）：
>
> 当 `recommend_enable=yes` 且 NIC_IRQ_MAP 有数据时，额外标注：
> - `NIC_NUMA_SPAN ≥ 2`：标注"中断跨 NUMA，多路径收益明确"
> - `NIC_NUMA_SPAN = 1 且 NUMA_NODES ≥ 2 且存在其他网卡在别的 NUMA 节点`：标注"多网卡分属不同 NUMA，整体存在跨 NUMA 优化空间"
> - `NIC_NUMA_SPAN = 1 且仅 1 个 NUMA 节点`：标注"单 NUMA 环境，当前亲和已较优"

#### Step 4: 输出推荐参数

汇总 Step 3 中所有判定为"纳入"的网卡：

| 输出参数 | 格式 | 示例 |
|----------|------|------|
| RECOMMENDED_IFNAMES | 以 `#` 拼接的网卡名 | `eth0#eth1#eth2` |
| RECOMMENDED_APPNAME | 目标应用进程名；若 Step 1 无法确定 → 留空表示全局使能 | `redis-server` 或 空 |
| RECOMMENDED_NIC_COUNT | 推荐网卡数量 | `3` |
| EXCLUDED_NIC_LIST | 被排除的网卡、原因及具体数值 | `eth2: has_ntuple=0(R1级), eth3: max_q=1/rxkB=456(R2级)` |

### 阶段三：中断亲和深度评估（补充判断）

> 当中断分布数据可用时，进行深度评估。本阶段结果用于**补充佐证**阶段二点五的推荐。

| 条件 | 补充说明 |
|------|---------|
| eth 中断集中在 ≤2 个 CPU 核心 | 中断处理瓶颈明显，启用后可分散到各 NUMA 节点本地处理 |
| eth 中断所在 CPU 与目标业务进程 CPU 不在同一 NUMA 节点 | 跨 NUMA 中断开销显著，强烈推荐启用 |
| eth 中断已均匀分布在多个 NUMA 节点 | 当前中断亲和已较优，收益可能有限 |

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-multi-net-path-analysis_collect/result.md`，格式如下：

```markdown
# 网卡多路径瓶颈分析结果

## 1. 环境检查

| 检查项 | 结果 |
|--------|------|
| oenetcls 模块 | {已加载 / 可用未加载 / 不可用} |
| 物理网卡数量 | {N} |
| ntuple 可配置网卡数 | {has_ntuple=1 且 ntuple_fixed=2 的数量}/{N} |
| irqbalance 状态 | {active / inactive / unknown} |
| NUMA 节点数 | {N} |
| 目标业务进程 | {redis-server: 存在/不存在, nginx: 存在/不存在, mysql: 存在/不存在} |

## 2. 关键指标

| 指标 | 值 | 说明 |
|------|-----|------|
| 物理网卡列表 | {eth0, eth1, ...} | — |
| ntuple 详情（per-NIC） | {eth0: has_ntuple=1, ntuple_fixed=2, eth1: has_ntuple=1, ntuple_fixed=1, ...} | ntuple_fixed=0:N/A, 1:被[fixed]锁定, 2:可配置 |
| 网卡队列（per-NIC） | {eth0: max_q/cur_q=8/8, eth1: 4/4, ...} | ethtool -l 输出：Combined（或 RX+TX）最大/当前值 |
| 网卡流量（rxkB/s） | {eth0: 3456.78, eth1: 1234.56, ...} | sar -n DEV 采样均值 |
| 中断分布 | {集中/均匀/无数据} | /proc/interrupts |
| 跨 NUMA 中断风险 | {是/否/无法判断} | — |

## 3. 适用性评估

| 评估维度 | 结果 | 证据 |
|---------|------|------|
| 内核模块支持 | ✅/❌ | oenetcls: {状态} |
| 硬件过滤能力 | ✅/❌ | ntuple可配置: {M}/{N} |
| irqbalance 停止 | ✅/❌ | irqbalance: {状态} |
| 多 NUMA 环境 | ✅/❌ | {N} 个 NUMA 节点 |
| 多网卡环境 | ✅/❌ | {N} 张物理网卡 |
| 目标应用存在 | ✅/❌ | {进程列表} |

**综合结论**: {已启用 / 建议启用（高收益）/ 建议启用（中收益）/ 不建议启用 / 收益有限 / 条件不满足} — {原因}

**判定路径**: {基础可行性 / 场景收益 / 网卡-应用精准匹配 / 中断亲和深度评估}

**预期收益**: {量化收益描述}
- 高收益场景：中断处理延迟降低 20%-40%，跨 NUMA 内存访问减少，网络吞吐提升 10%-25%
- 中收益场景：中断分布优化，跨 NUMA 中断开销降低

**启用前提**:
1. oenetcls 模块可用且未加载
2. 至少 1 张物理网卡支持 ntuple
3. irqbalance 已停止（`systemctl stop irqbalance`）
4. ≥2 个 NUMA 节点

**回滚参考**: 卸载 oenetcls 模块，重启 irqbalance 服务即可回滚

## 4. 调优参数推荐

> 以下参数可直接传递给调优技能 `opentunex-multi-net-path-tuning` 的 `apply` 操作。

| 参数 | 值 | 说明 |
|------|-----|------|
| ifnames | `{eth0#eth1}` | 以 `#` 拼接的推荐网卡列表 |
| appname | `{redis-server}` | 目标应用进程名 |

## 5. 网卡级分析详情

| 网卡 | ntuple | ntuple_fixed | queues(max/cur) | rxkB/s | multi_path | recommend_enable | NUMA 跨度 | 判定 | 原因 |
|------|--------|-------------|-----------------|--------|------------|-----------------|---------|------|------|
| eth0 | yes | 2 | 8/8 | 3456 | yes | yes | node0,node1(span=2) | ✅ 纳入 | ntuple可配+流量达标+跨NUMA |
| eth1 | yes | 2 | 4/4 | 2567 | yes | yes | node1(span=1) | ✅ 纳入 | ntuple可配+流量达标 |
| eth2 | no | 0(N/A) | — | — | no | — | — | ❌ 排除 | has_ntuple=0 |
| eth3 | yes | 1([fixed]) | — | — | no | — | — | ❌ 排除 | ntuple被硬件锁定 |
| eth5 | yes | 2 | 1/1 | 890 | yes | no | — | ❌ 排除 | max_q=1/rxkB=890(流量不达标) |

## 6. 目标应用详情

| 项目 | 值 |
|------|-----|
| 应用名 | {redis-server} |
| 进程 PID | {12345} |
| 选取依据 | {A1: 检测到 redis-server 进程} |

## 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "multi_net_path",
  "suggestion": "停止 irqbalance 服务，加载 oenetcls 内核模块接管网卡中断亲和",
  "equivalence_class": "multi_net_path",
  "activation_requirement": "immediate",
  "estimated_gain": {
    "primary_metric": "network_latency",
    "severity": "high",
    "description": "中断处理延迟降低20%-40%，跨NUMA内存访问减少，网络吞吐提升10%-25%"
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
> - `applicability`：分析结论为"建议启用"→ `"applicable"`；"不建议启用/收益有限"（运行时条件）→ `"limited_benefit"`；"已启用/条件不满足"（环境约束）→ `"not_applicable"`
> - 映射标准见 [统一映射表](../references/result-template.md#零子技能结论--结构化数据映射统一标准)
> - `estimated_gain.severity`：使用评估矩阵判定（瓶颈严重程度 × 建议匹配效能）→ `high` / `medium` / `low`
> - `scenario_priority`：可识别目标关键进程时设为 10，否则为 7
> - 若 applicability 为 `"not_applicable"`：`estimated_gain.severity` 设为 `"low"`，`suggestion` 填写不启用/已启用/收益有限的原因描述
> - 若 applicability 为 `"limited_benefit"`：`estimated_gain.severity` 设为 `"low"`，正常参与融合流程
> - activation_requirement 字段保持当前模板中预设的值，无需修改。
```

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-multi-net-path-analysis"
input:
  analysis_dir: "[actual analysis_dir]"
  data_dir: "[actual data_dir]"
  collect_dir: "[actual collect_dir]"
output:
  analysis_report_path: "[actual analysis_report_path]"
constraints_acknowledged: [SB-01~SB-05]
