---
name: "opentunex-scenario-bottleneck"
description: "场景化瓶颈分析协调器。基于数据采集层提供的系统指标，全量调度所有场景分析技能并行执行并汇总结果。触发：瓶颈分析流程中场景化分析阶段。"
sub_agent_enabled: true
---

# opentunex-scenario-bottleneck — 场景化瓶颈分析协调器

> **⛔ 入口门：在执行 Phase 1 调度前，必须确认以下规则：**
>
> 1. **场景分析子技能必须尝试通过子智能体工具启动**——不得在当前上下文中直接读取子技能 SKILL.md 并内联执行
> 2. **在启动子智能体之前，不得预读取采集数据**——数据路径写入输入契约，由子智能体自行读取
> 3. **如果子智能体工具不可用或能力不足，才允许降级模式**，但必须标注 `execution_mode: "degraded"` 并记录降级原因

纯协调器，职责：

1. 全量调度所有场景分析技能：通过子智能体工具启动各场景分析子技能，传入数据目录路径，由子智能体在独立上下文中完成数据读取、阈值比较和结论输出
2. 汇总结果，保留各子技能原始结论术语

**不执行分析逻辑，不执行远程命令，不执行外部脚本。**

## 强制约束

> 本技能遵守 [瓶颈分析域约束](references/constraints-bottleneck.md) 中定义的所有执行约束和数据目录约定。

***

## 输入约定

本技能的数据来源是**数据采集层**。数据采集层提供的系统指标将传递给各场景分析技能使用。

### 数据路径优先级

数据读取按以下优先级依次尝试：

| 优先级   | 来源   | 路径                        | 说明                |
| ----- | ---- | ------------------------- | ----------------- |
| 1（最高） | 用户指定 | `${WORK_DIR}/`（用户提供的工作目录） | 用户通过输入直接指定的采集数据目录 |
| 2     | 默认   | `${WORK_DIR}/`            | 分析目录              |

### 路径解析流程

```
用户是否指定了数据目录？
  ├── 是 → 使用用户指定路径（WORK_DIR），检查路径是否存在
  │       ├── 存在 → 读取该目录下的数据
  │       └── 不存在 → 提示用户路径无效，终止流程
  └── 否 → 检查 ${WORK_DIR}/ 是否存在（由瓶颈分析域入口传入）
          ├── 存在 → 读取该目录下的数据
          └── 不存在 → 终止流程，提示用户先使用一键采集脚本生成数据
```

### 数据缺失处理

| 场景                       | 处理                     |
| ------------------------ | ---------------------- |
| 用户指定路径不存在                | 终止流程，提示用户检查路径是否正确      |
| `${WORK_DIR}/` 不存在且用户未指定 | 终止流程，提示用户先使用一键采集脚本生成数据 |

| 输入数据       | 必需 | 说明              |
| ---------- | -- | --------------- |
| 系统环境静态信息   | 是  | 硬件规格、软件版本、内核参数  |
| 全局资源瓶颈识别数据 | 是  | CPU/内存/IO/网络指标  |
| 高资源消耗进程列表  | 是  | Top CPU/内存/IO进程 |

协调器将采集数据传递给各场景分析技能，子技能仅做分析不做采集；

***

## Phase 1: 全量调度场景分析技能

**目标**：调度所有场景分析技能并行执行，不根据数据选择性跳过。

**设计原则**：场景分析技能自身包含完整的环境检查和适用性评估，协调器无需预判场景是否适用，应全量调度，由各技能自行输出结论。这确保：

- 不遗漏任何潜在的场景瓶颈
- 协调器逻辑与场景解耦，新增场景时无需修改调度逻辑
- 各技能原子化，可独立运行

### 二级子智能体调度声明

| 子智能体                               | 技能定义路径                                                                              | 输入契约路径                                                                             | 约束文件                                              | 输出契约路径                                                                              | 分析报告路径                                                                           |
| ---------------------------------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| numa-sched-analysis                | opentunex-scenario-bottleneck/opentunex-numa-sched-analysis/SKILL.md                | \[analysis\_dir]/contracts/opentunex-numa-sched-analysis-input.yaml                | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-numa-sched-analysis-output.yaml                | \[analysis\_dir]/opentunex-numa-sched-analysis\_collect/result.md                |
| stealtask-analysis                 | opentunex-scenario-bottleneck/opentunex-stealtask-analysis/SKILL.md                 | \[analysis\_dir]/contracts/opentunex-stealtask-analysis-input.yaml                 | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-stealtask-analysis-output.yaml                 | \[analysis\_dir]/opentunex-stealtask-analysis\_collect/result.md                 |
| dynamic-smt-analysis               | opentunex-scenario-bottleneck/opentunex-dynamic-smt-analysis/SKILL.md               | \[analysis\_dir]/contracts/opentunex-dynamic-smt-analysis-input.yaml               | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-dynamic-smt-analysis-output.yaml               | \[analysis\_dir]/opentunex-dynamic-smt-analysis\_collect/result.md               |
| docker-coordination-burst-analysis | opentunex-scenario-bottleneck/opentunex-docker-coordination-burst-analysis/SKILL.md | \[analysis\_dir]/contracts/opentunex-docker-coordination-burst-analysis-input.yaml | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-docker-coordination-burst-analysis-output.yaml | \[analysis\_dir]/opentunex-docker-coordination-burst-analysis\_collect/result.md |
| soft-domain-analysis               | opentunex-scenario-bottleneck/opentunex-soft-domain-analysis/SKILL.md               | \[analysis\_dir]/contracts/opentunex-soft-domain-analysis-input.yaml               | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-soft-domain-analysis-output.yaml               | \[analysis\_dir]/opentunex-soft-domain-analysis\_collect/result.md               |
| multi-net-path-analysis            | opentunex-scenario-bottleneck/opentunex-multi-net-path-analysis/SKILL.md            | \[analysis\_dir]/contracts/opentunex-multi-net-path-analysis-input.yaml            | constraints-bottleneck.md + common-constraints.md | \[analysis\_dir]/contracts/opentunex-multi-net-path-analysis-output.yaml            | \[analysis\_dir]/opentunex-multi-net-path-analysis\_collect/result.md            |

**调度方式**：使用当前环境中可用的子智能体工具（如 sessions\_spawn+sessions\_yield、Task Tool、Agent Tool 等）启动上述子智能体。具体调用格式由运行时环境决定，本技能不限定。

**子智能体任务描述**（传入子智能体的指令）：

> 读取技能定义 \[技能定义路径]，读取输入契约 \[输入契约路径]，读取约束文件 \[约束文件路径]，执行技能定义中的步骤，写入输出契约 \[输出契约路径]，写入分析报告 \[分析报告路径]

**全量调度**：所有子智能体均需启动，不做选择性过滤。场景分析技能自身包含完整的环境检查和适用性评估，由各技能自行输出结论。

### 降级模式（仅在子智能体工具不可用时使用）

降级模式**不是首选执行路径**，仅在子智能体工具不可用或启动失败时使用：

降级执行时必须：

- 在输出契约中标注 `execution_mode: "degraded"` 并记录降级原因
- 逐个读取子技能的 SKILL.md，每次只加载一个，执行完毕后释放上下文再加载下一个
- 仍须遵守所有约束和契约输出要求

### 场景分析调度规则

**调度方式**：全量调度当前目录下所有 `opentunex-*` 前缀的子目录中的 SKILL.md。

**发现规则**：

- 扫描当前目录（`opentunex-scenario-bottleneck/`）下的子目录
- 匹配 `opentunex-*` 前缀的子目录即为场景分析技能
- 排除 `references/` 等非技能目录
- 每个子目录中的 SKILL.md 即为一个场景分析技能

**调度规则**：

- **全量调度**：所有发现的场景分析技能均通过 Task Tool 并行启动子智能体
- **子智能体执行**：每个子智能体独立读取自身 SKILL.md，根据其中定义的数据读取方法和决策矩阵完成分析判断，无需执行外部脚本
- 每个子技能自身完整，在其 SKILL.md 中定义了：数据读取（从哪个报告文件提取哪些指标）→ 决策逻辑（条件→结论映射）→ 产出模板
- **结论术语**：各子技能使用各自的结论术语输出，协调器汇总时保留原始结论

### 错误处理与容错机制

| 异常场景             | 处理策略                       |
| ---------------- | -------------------------- |
| 未发现任何场景分析技能      | 输出"无可用场景分析技能"结论，终止流程       |
| 单个子技能执行失败        | 标记为"执行失败"，记录错误原因，继续执行其他子技能 |
| 子技能执行超时（默认 300s） | 标记为"超时"，继续执行其他子技能          |
| 子技能输出格式异常        | 标记为"结果解析失败"，保留原始输出供人工检查    |
| 所有子技能均失败         | 输出"所有场景分析均失败"结论，列出各子技能失败原因 |

### 子技能执行状态

每个子技能执行后应记录以下状态：

| 状态            | 说明             |
| ------------- | -------------- |
| `success`     | 执行成功，结果已汇总     |
| `failed`      | 执行失败，记录错误原因    |
| `timeout`     | 执行超时（超过 300 秒） |
| `parse_error` | 执行完成但结果无法解析    |

***

## Phase 2: 结果融合

> **目标**：在所有子技能完成分析后，提取各报告的 `## 结构化数据` 区块，按 [references/fusion-rules.md](references/fusion-rules.md) 规则进行等价组聚合、组内择优、冲突消解、依赖检查、策略过滤，最终输出一份统一的融合报告。

**输出模板**：[references/output-template.md](references/output-template.md)

### 2.1 前置条件

启动前必须确认：

- 所有子技能已执行完毕（Phase 1 完成）
- 每个成功子技能已生成 `[analysis_dir]/<skill_name>_collect/result.md`
- 每个成功报告末尾包含 `## 结构化数据` 区块（JSON 格式，符合 [融合数据格式](references/fusion-rules.md#一结构化数据字段定义)）

### 2.2 融合执行

按 [references/fusion-rules.md](references/fusion-rules.md) 的 10 步流程执行：

1. **提取叙述性字段**（优先于融合步骤 1）：扫描每个成功子技能 result.md 的分析结论区块，按 [references/result-template.md](references/result-template.md) 规则提取 **综合结论**、**预期收益**、**建议操作**，填充融合报告"场景分析汇总"表的基础数据
2. **收集与标准化**：扫描每个成功子技能报告的 `## 结构化数据` 区块，提取 JSON 数据；补齐默认字段（`conflicts`→`[]`、`scenario_priority`→`0`、`source`→`"skill_output"`）；将 `applicability` 为 `not_applicable` 的建议直接归入 excluded（场景不适用）；将来源为 `llm_knowledge` 的临时建议归入 supplementary；构建全局冲突图和依赖图
3. **等价组划分**：按 `equivalence_class` 字段分组
4. **组内择优排序**：按 `scenario_priority` → `severity` → `activation_requirement` → `source` 四级排序
5. **构建初始选中集 S**：取每组排名第一的建议
6. **冲突消解**：按组内择优相同排序键消解冲突，从备选递补
7. **依赖检查**：检查 `prerequisites`，级联移除依赖不满足的建议
8. **会话策略过滤**：应用可选的 `no_reboot`、`min_gain_severity` 等策略
9. **生成扩展方案**：从各替代组的剩余备选及原本被排除但不引入新冲突的建议中，选取无冲突、依赖满足的增强建议
10. **编排执行顺序**：按依赖拓扑 + 生效成本排序
11. **输出融合报告**：按 [references/output-template.md](references/output-template.md) 格式输出

### 2.3 融合报告产出

融合报告写入 `${WORK_DIR}/analysis/opentunex-scenario-bottleneck_collect/result.md`，严格遵循 [references/output-template.md](references/output-template.md) 格式输出，10 个模块的字段来源如下：

#### 字段映射表（result.md → 融合报告 "场景分析汇总"）

| 融合报告列 | 数据来源                               | 提取规则                                                                                     |
| ------------------ | ---------------------------------- | ---------------------------------------------------------------------------------------- |
| **ID**             | 协调器分配                              | 按 S-001, S-002, ... 编号                                                                   |
| **场景**             | 子技能 name 字段                        | 取 SKILL.md 头部的 `name` 或目录名                                                               |
| **状态**             | Phase 1 执行状态                       | `success` / `failed` / `timeout` / `parse_error`                                         |
| **适用性**            | 结构化数据 `applicability`              | `applicable`→"适用"、`limited_benefit`→"收益有限"、`not_applicable`→"不适用"                        |
| **严重度**            | 结构化数据 `estimated_gain.severity`    | 按 fusion-rules.md §1.12 映射：`high`→P1-High、`medium`→P2-Medium、`low`→P3-Low                |
| **关键发现**           | result.md 叙述性分析                    | 提取 **综合结论** 行中 `—` 之后的瓶颈现象描述（降级：使用结构化数据 `estimated_gain.primary_metric` + `description`） |
| **预期收益**           | 结构化数据 `estimated_gain.description` | 直接引用（降级：result.md **预期收益** 行）                                                            |
| **建议调优方向**         | 结构化数据 `suggestion`                 | 直接引用（降级：result.md **建议操作** 行）                                                            |

#### 报告包含的 10 个模块

- 融合概览（输入技能数、提取建议数、等价组数、采纳/排除数）
- 场景分析汇总表（按上述字段映射填充）
- 主推荐方案（primary\_plan）：融合后保留的最终调优建议集合
- 等价组详情（每组内排序结果与采纳/备选说明）
- 被排除项：冲突消解/依赖检查/策略过滤中被排除的建议及原因
- 跨技能协同关系：`synergy_with` 字段的协同增强标记
- 扩展方案（extended\_plan）
- 执行顺序（implementation\_order）：按依赖拓扑和生效方式排序
- 实施建议（风险提示 + supplementary）
- 异常与遗漏（执行异常 + 未覆盖方向）

***

## 操作说明

- 纯协调器，不执行分析逻辑，不执行远程命令
- 全量调度所有场景分析技能，不做选择性过滤
- 数据来源是数据采集层，将采集数据传递给各技能
- 通过目录结构动态发现场景分析技能，新增场景时只需在 `opentunex-scenario-bottleneck/` 下创建新的 `opentunex-*` 子目录即可，无需修改本协调器
- 单个子技能失败不影响其他子技能执行，所有结果（含失败）均汇总到报告中
- 各子技能使用各自的结论术语输出，协调器汇总时保留原始结论，由融合阶段统一映射（映射标准见 [references/result-template.md 第零节](references/result-template.md#零子技能结论--结构化数据映射统一标准)）
- 严重度分级使用统一术语：P0-Critical / P1-High / P2-Medium / P3-Low
- Phase 2 融合阶段从各子技能报告的 `## 结构化数据` 区块提取 JSON 数据，按 fusion-rules.md 规则进行等价组聚合与融合

***

## 契约输出

输出契约格式参见 [contract-spec.md](references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-scenario-bottleneck"
input:
  analysis_dir: "${WORK_DIR}/analysis"
  data_dir: "${WORK_DIR}/"
  work_dir: "${WORK_DIR}/"
output:
  report_path: "${WORK_DIR}/analysis/opentunex-scenario-bottleneck_collect/result.md"
  sub_reports: "${WORK_DIR}/analysis/"
constraints_acknowledged: [B-01~B-08, SB-01~SB-05]
```

