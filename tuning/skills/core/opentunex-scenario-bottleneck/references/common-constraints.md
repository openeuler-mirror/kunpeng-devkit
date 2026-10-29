# 场景分析子技能共享约束

所有 `opentunex-scenario-bottleneck` 下的子技能必须遵守以下共享约束。

## SB-01 执行约束

> **⚠️ 每次触发本技能都必须重新从头执行完整分析流程，不得引用历史数据或之前的回答。**
> - 即使系统状态未变化，也必须重新执行所有分析步骤
> - 不得跳过任何分析阶段，不得复用历史分析结果
> - 每次执行都必须创建新的时间戳批次目录，保存完整的分析过程数据
> - 这是强制性要求，无例外情况

## SB-02 数据目录约束

> **⚠️ 所有分析产出必须落入用户指定的工作目录 `WORK_DIR` 内，不得散落到 `/tmp` 或其他系统路径。**

分析数据文件通过协调器传入，位于 `${WORK_DIR}/` 根目录下（由用户一键采集脚本预置）。分析产物按以下路径写入：

| 路径 | 用途 |
|------|------|
| `${WORK_DIR}/` | 原始采集数据（用户一键采集脚本产出，只读） |
| `${WORK_DIR}/analysis/<skill_name>_collect/result.md` | 场景分析技能写入分析结果 |

## SB-03 禁止自行采集

子技能**禁止自行采集数据**，必须基于 `${WORK_DIR}/` 中已采集的数据进行分析。

## SB-04 数据缺失处理

当 `${WORK_DIR}/` 中缺少必要数据文件时，提示用户使用一键采集脚本补全数据，子技能不自行采集。

## SB-05 目录创建

目录由瓶颈分析域入口统一创建，本技能无需单独创建：
```bash
mkdir -p ${WORK_DIR}/analysis/<skill_name>_collect
```

## 子技能名称与目录映射

| 子技能 | 目录名 | collect 目录 |
|--------|--------|-------------|
| Docker算力统筹分析 | `opentunex-docker-coordination-burst-analysis` | `opentunex-docker-coordination-burst-analysis_collect` |
| 动态SMT分析 | `opentunex-dynamic-smt-analysis` | `opentunex-dynamic-smt-analysis_collect` |
| numa并行感知调度分析 | `opentunex-numa-sched-analysis` | `opentunex-numa-sched-analysis_collect` |
| 窃取任务调度分析 | `opentunex-stealtask-analysis` | `opentunex-stealtask-analysis_collect` |
| 网卡多路径瓶颈分析 | `opentunex-multi-net-path-analysis` | `opentunex-multi-net-path-analysis_collect` |
| 分域调度分析 | `opentunex-soft-domain-analysis` | `opentunex-soft-domain-analysis_collect` |
| BTB 适用性分析 | `opentunex-btb-analysis` | `opentunex-btb-analysis_collect` |