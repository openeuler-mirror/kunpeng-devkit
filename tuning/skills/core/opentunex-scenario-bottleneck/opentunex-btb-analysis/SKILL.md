---
name: "opentunex-btb-analysis"
description: "BTB(分支目标缓冲) / TidCMP 适用性分析。检查 CPU 型号是否为鲲鹏 920新型号、关键进程(redis/mysql)是否运行，评估禁用 TidCMP 消除线程分支预测记录隔离的适用性。触发:BTB、TidCMP、分支预测、920新型号、鲲鹏、redis、mysql、分支预测记录隔离。"
---

# BTB 适用性分析

分析 CPU 型号和关键进程运行状态，评估禁用 TidCMP（线程分支预测记录隔离）的适用性。

**分析原理**：鲲鹏 920新型号 处理器在启用 TidCMP 时会对线程的分支预测记录（BTB）进行隔离，这可能导致 redis/mysql 等关键业务的性能下降。禁用 TidCMP 可消除该隔离，提升支持服务（redis/mysql）的分支预测性能。

> **⚠️ 本调优方向不支持一键使能，需手工进入 BIOS 设置。**

## 强制约束

> 本技能遵守 [场景分析子技能共享约束](../references/common-constraints.md) 中定义的所有执行约束和数据目录约定。
>
> 本技能的数据目录名为 `opentunex-btb-analysis_collect`。

---

## 输入约定

本技能的数据来源是**数据采集层**。数据由协调器传入 `${DATA_DIR}` 变量，指向采集批次目录。本技能**禁止自行采集数据**。

---

## 执行流程

本技能的完整执行流程如下，**必须按顺序完成所有步骤，不得在中间步骤终止**：

| 步骤 | 操作 | 产出 |
|------|------|------|
| 1 | 执行 `scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-btb-analysis_collect` | `preanalysis.json` |
| 2 | 读取 `preanalysis.json`，按"字段→决策变量映射"表提取决策变量 | 决策变量值 |
| 3 | 按"决策逻辑"章节依次执行环境约束前置检查 → 场景模式判定 | 分析结论 |
| 4 | 按"产出"章节模板，将决策结果写入 `${WORK_DIR}/analysis/opentunex-btb-analysis_collect/result.md` | 完整分析报告（含结构化数据 JSON） |
| 5 | 按"契约输出"章节格式写入输出契约 YAML 文件 | 契约文件 |

> **注意**：步骤 1 仅完成数据预处理，步骤 2-5 必须继续执行。不得在生成 `preanalysis.json` 后终止流程。

---

## 数据读取

### 优先路径：预分析 JSON（推荐）

1. 执行预处理脚本生成 JSON：
   ```bash
   bash scripts/preanalysis.sh ${DATA_DIR} ${DATA_DIR}/opentunex-btb-analysis_collect
   ```
2. 读取生成的 JSON 文件：`${DATA_DIR}/opentunex-btb-analysis_collect/preanalysis.json`

#### preanalysis.json 字段 → 决策变量映射

| JSON 路径 | 决策变量 | 取值说明 |
|-----------|---------|---------|
| `is_kunpeng` | IS_KUNPENG | `true` / `false`（lscpu 输出含 "Kunpeng" 关键字） |
| `part_id` | PART_ID | 字符串，dmidecode -t processor 的 ID 字段，如 `"20 D0 1F 49 00 00 00 00"` |
| `is_920_new_model` | IS_920_NEW_MODEL | `true` / `false`（part_id 以 "20 D0" 开头即为 true） |
| `redis_running` | REDIS_RUNNING | `true` / `false` |
| `mysql_running` | MYSQL_RUNNING | `true` / `false` |

---

## 决策逻辑

按以下优先级依次判断，命中即输出。

### 环境约束前置检查

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| E0 | IS_KUNPENG = false（CPU 不是鲲鹏） | 不适用 | 本特性仅鲲鹏平台支持，非鲲鹏平台不适用 |
| E1 | IS_920_NEW_MODEL = false（CPU 型号不是 920新型号） | 不适用 | 当前 CPU 型号不在 TidCMP 优化支持的 CPU 型号列表中，仅鲲鹏 920新型号 适用 |
| E2 | REDIS_RUNNING = false 且 MYSQL_RUNNING = false | 不适用 | 未检测到 redis 或 mysql 关键进程运行，禁用 TidCMP 无收益 |

### 场景模式判定

| 优先级 | 条件 | 结论 | 原因 |
|--------|------|------|------|
| S1 | IS_920_NEW_MODEL = true 且 (REDIS_RUNNING = true 或 MYSQL_RUNNING = true) | **适用** | 鲲鹏 920新型号 + redis/mysql 关键进程运行中 → 禁用 TidCMP 可消除线程分支预测记录隔离，提升关键业务性能 |

---

## 产出

将分析结果写入 `${WORK_DIR}/analysis/opentunex-btb-analysis_collect/result.md`，格式如下：

```markdown
# BTB 适用性分析结果

## 1. 环境检查

| 检查项 | 结果 |
|--------|------|
| IS_KUNPENG | {true/false} |
| PART_ID | {dmidecode processor ID，如 "20 D0 1F 49 00 00 00 00"} |
| IS_920_NEW_MODEL | {true/false} |

## 2. 关键进程信息

| 指标 | 值 |
|------|-----|
| REDIS_RUNNING | {true/false} |
| MYSQL_RUNNING | {true/false} |

### 关键进程列表（如存在）

| 进程名 | PID | 说明 |
|--------|-----|------|
| {name} | {PID} | redis/mysql 关键进程 |

## 3. 适用性评估

| 评估维度 | 结果 | 证据 |
|---------|------|------|
| CPU 型号为 920新型号 | ✅/❌ | PART_ID={值}，以"20 D0"开头={是/否} |
| redis/mysql 运行中 | ✅/❌ | 检测到 {N} 个关键进程 |

**综合结论**: {适用/不适用} — {原因}

**建议操作**:
1. 进入服务器 BIOS 设置
2. 导航至 `Advanced → Power And Performance Configuration → CPU PM Control → TidCMP`
3. 将 TidCMP 设置为 `Disabled`
4. 保存并退出 BIOS，重启服务器

> **注意**：本调优方向不支持一键使能，需手工进入 BIOS 设置并重启服务器。

## 4. 结构化数据

> 以下 JSON 数据供融合器（Phase 2）自动提取，用于等价组聚合和融合分析。请将分析结论映射为此格式并写入 result.md。

```json
{
  "applicability": "applicable",
  "id": "btb_tidcmp",
  "suggestion": "鲲鹏 920新型号 处理器 + redis/mysql 关键进程运行中，推荐禁用 TidCMP 消除线程分支预测记录隔离：进入 BIOS → Advanced → Power And Performance Configuration → CPU PM Control → TidCMP → Disabled",
  "equivalence_class": "btb_tidcmp",
  "activation_requirement": "host_reboot",
  "estimated_gain": {
    "primary_metric": "branch_prediction",
    "severity": "low",
    "description": "消除线程分支预测记录隔离，提升 redis/mysql 等支持服务的分支预测性能"
  },
  "conflicts": [],
  "prerequisites": [],
  "synergy_with": [],
  "scenario_priority": 7,
  "source": "skill_output",
  "cross_skill_relations": {
    "conflicts_with": [],
    "depends_on": []
  }
}
```
```

> **适用性结论 → JSON applicability 映射**：适用 → `"applicable"`；不适用 → `"not_applicable"`。

---

## 契约输出

输出契约格式参见 [contract-spec.md](../references/contract-spec.md)，本技能特有字段：

```yaml
skill_name: "opentunex-btb-analysis"
input:
  data_dir: "[actual DATA_DIR]"
output:
  result_path: "[actual result_path]"
constraints_acknowledged: [SB-01~SB-05]
```