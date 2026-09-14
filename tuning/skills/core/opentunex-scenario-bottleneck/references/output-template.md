---
name: output-template
description: 场景分析融合报告输出模板
---

# 场景分析融合报告

```markdown
# 场景分析融合报告

> 生成时间：<YYYY-MM-DD HH:MM:SS>
> 协调器：opentunex-scenario-bottleneck
> 融合规则：references/fusion-rules.md
> 数据来源：各子技能 result.md 的 `## 结构化数据` 区块

---

## 1. 融合概览

| 指标 | 数值 |
|------|------|
| 输入子技能数 | {N} |
| 成功执行数 | {M} |
| 提取建议总数 | {T} |
| 等价组数量 | {G} |
| 最终采纳建议数 | {K} |
| 被排除建议数 | {E} |

---

## 2. 场景分析汇总

| ID | 场景 | 状态 | 适用性 | 严重度 | 关键发现 | 预期收益 | 建议调优方向 |
|----|------|------|--------|--------|---------|---------|-------------|
| S-001 | [场景名] | success | 适用 | P0-Critical/P1-High/P2-Medium/P3-Low | [具体瓶颈发现] | [量化收益] | [调优方向] |
| S-002 | [场景名] | success | 收益有限 | P3-Low | [具体发现] | [量化收益] | [调优方向（若适用）] |
| S-003 | [场景名] | success | 不适用 | — | [原因] | — | — |
| S-004 | [场景名] | failed | — | — | 执行失败: [错误原因] | — | — |

> 严重度分级：P0-Critical（立即处理）→ P1-High（优先处理）→ P2-Medium（排期处理）→ P3-Low（观察/收益有限）。仅"不适用"和"执行失败"的场景严重度栏为"—"。

---

## 3. 主推荐方案 (primary_plan)

> 以下为经过等价组聚合、冲突消解、依赖检查和策略过滤后保留的最终调优建议，按优先级排序。

| 优先级 | 建议 ID | 等价类 | 调优操作 | 生效方式 | 预期收益 | 协同关系 |
|--------|--------|--------|---------|---------|---------|---------|
| {1} | {id} | {equivalence_class} | {suggestion} | {activation_requirement} | {estimated_gain.severity}: {estimated_gain.description} | {synergy_with} |
| {2} | {id} | {equivalence_class} | {suggestion} | {activation_requirement} | {estimated_gain.severity}: {estimated_gain.description} | — |

### 3.1 各建议详细说明

#### {id}

| 字段 | 值 |
|------|-----|
| 建议 ID | {id} |
| 等价类 | {equivalence_class} |
| 调优操作 | {suggestion} |
| 生效方式 | {activation_requirement} |
| 预期指标 | {estimated_gain.primary_metric} |
| 收益等级 | {estimated_gain.severity} |
| 收益说明 | {estimated_gain.description} |
| 场景优先级 | {scenario_priority} |
| 来源 | {source} |
| 前置依赖 | {prerequisites 或 无} |
| 冲突项 | {conflicts 或 无} |
| 协同增强 | {synergy_with 或 无} |

---

## 4. 等价组详情

> 每个等价组展示组内所有建议的排序结果，排名第一的已入选主推荐方案。若等价组仅含单一建议则直接入选。

{若所有等价组均为单成员，输出：}
> 当前所有分析场景各自独立，无等价替代方案，所有适用建议均直接入选主推荐方案。

### 等价组：{equivalence_class_name}

| 排名 | 建议 ID | severity | scenario_priority | 是否采纳 | 说明 |
|------|--------|----------|------------------|---------|------|
| 1 | {id} | {high/medium/low} | {N} | ✅ 主推荐 | 择优入选 |
| 2 | {id} | {medium/low} | {M} | ❌ 备选 | 组内 severity/scenario_priority 较低 |

---

## 5. 被排除项

{若无被排除项，输出：}
> 当前无被排除的建议。

### 5.1 冲突消解排除

| 建议 ID | 冲突对象 | 排除原因 | 得分对比 |
|--------|---------|---------|---------|
| {id} | {conflict_with_id} | 与已入选建议冲突 | severity={X} priority={Y} vs severity={A} priority={B} |

### 5.2 依赖检查排除

| 建议 ID | 前置依赖 | 排除原因 |
|--------|---------|---------|
| {id} | {prerequisite_id} | 前置依赖不满足（已被排除或未入选） |

### 5.3 策略过滤排除

| 建议 ID | 过滤条件 | 排除原因 |
|--------|---------|---------|
| {id} | {策略条件} | 不满足策略要求 |

---

## 6. 跨技能协同关系

> 标记各建议之间的协同增强关系，供调优阶段参考。

{若无协同关系，输出：}
> 当前建议之间无已声明的协同增强关系。

| 建议 ID | 协同建议 ID | 协同说明 |
|--------|-----------|---------|
| {id} | {synergy_id} | 同时实施可获得叠加优化效果 |

---

## 7. 扩展方案 (extended_plan)

> 在 primary_plan 之外可额外实施的增强建议。这些建议无冲突、依赖已满足，建议在条件允许时一并执行。

{若无扩展方案，输出：}
> 当前无扩展方案。

| 建议 ID | 等价类 | 建议内容 | 选取理由 |
|--------|--------|---------|---------|
| {id} | {equivalence_class} | {suggestion} | 与主方案协同/低风险增强 |

---

## 8. 执行顺序 (implementation_order)

> 按依赖拓扑和生效成本排序。同级内按 `scenario_priority` 降序排列。

| 阶段 | 建议 ID | 生效方式 | scenario_priority | 前置依赖 | 说明 |
|------|--------|---------|------------------|---------|------|
| 第1阶段 | {id} | immediate | 无 | 立即生效，无需停机 |
| 第2阶段 | {id} | service_reload | 无 | 需reload服务 |
| 第3阶段 | {id} | business_restart | {id} | 需重启业务 |
| 第4阶段 | {id} | system_reboot | {id} | 需重启系统，请计划维护窗口 |

---

## 9. 实施建议

### 9.1 风险提示

- 标注所有 `activation_requirement` 为 `system_reboot` 的建议，需计划维护窗口
- 标注所有 `activation_requirement` 为 `business_restart` 的建议，评估业务影响
- 标注存在 `conflicts` 的建议，确认调优范围不重叠

### 9.2 补充参考 (supplementary)

> 来源为 `llm_knowledge` 且未参与核心融合流程的参考建议（若有）：

| 建议 ID | 建议内容 | 来源 | 排除原因 |
|--------|---------|------|---------|
| {id} | {suggestion} | llm_knowledge | 未经验证，仅供参考 |

---

## 10. 异常与遗漏

### 10.1 执行异常

| 场景ID | 异常类型 | 详情 | 影响 |
|--------|---------|------|------|
| S-00X | timeout | 执行超过 300s | 该场景结果缺失，可能遗漏瓶颈 |
| S-00Y | parse_error | 结果格式异常 | 保留原始输出供人工检查 |

### 10.2 未覆盖方向

> 以下可能存在的瓶颈方向未被任何场景技能覆盖，建议人工评估：

| 未覆盖方向 | 原因 | 建议 |
|-----------|------|------|
| [方向描述] | 无对应分析技能 | 建议补充对应场景技能或手工排查 |
```