# 场景分析技能映射参考

根据症状/关键词导航到对应的场景化分析子技能。所有子技能通过 `opentunex-scenario-bottleneck` 协调器全量调度并行执行，各子技能自行判断适用性。

## 映射表

| 症状/关键词 | 子技能 | 技能目录 |
|------------|--------|---------|
| 容器CPU配额不足、宿主机有空闲算力、Docker突发、容器CPU限流、cfs_burst | opentunex-docker-coordination-burst-analysis | `opentunex-docker-coordination-burst-analysis/` |
| CPU使用率低、超线程干扰、低负载场景、SMT超线程优化、功耗优化 | opentunex-dynamic-smt-analysis | `opentunex-dynamic-smt-analysis/` |
| NUMA内存不均衡、跨NUMA访问率高、NUMA瓶颈 | opentunex-numa-sched-analysis | `opentunex-numa-sched-analysis/` |
| CPU高负载、负载不均衡、调度优化 | opentunex-stealtask-analysis | `opentunex-stealtask-analysis/` |
| 多网卡多NUMA环境、跨NUMA中断开销、oenetcls、ntuple、网络中断亲和、multi_net_path_
| 多NUMA节点、小配额多实例容器、跨NUMA调度抖动、尾延迟敏感、soft_domain | opentunex-soft-domain-analysis | `opentunex-soft-domain-analysis/` |
| BTB、TidCMP、分支预测、鲲鹏、分支预测记录隔离 | opentunex-btb-analysis | `opentunex-btb-analysis/` |

## 技能发现机制

协调器通过扫描当前目录下的子目录动态发现场景分析技能。新增场景时只需在 `opentunex-scenario-bottleneck/` 下创建新的 `opentunex-<name>/` 子目录并包含 `SKILL.md` 即可，无需修改协调器逻辑。