---
name: task-design
description: >-
  技能定位：这是任务配置生成技能，由 perf-params-tuner-agent 主 skill 调用，不直接面向用户。
  能力描述：提供根据场景类型生成任务所需的配置文件(task_{App}_System.yaml)的能力。
  触发场景：在调优流程阶段2需要生成任务模板时触发。
  适用范围：适用于 KAT 内置场景（Redis/MySQL/PostgreSQL/openGauss/Vastbase/Kafka/Hive/Flink/Spark/Rocksdb）及自定义场景。
  不适用范围：不适用于参数模板(param yaml)生成、模板诊断与修改、调优执行与报告生成。
license: MulanPSL-2.0
compatibility:
  note: 变量探测与远程主机信息收集需要 bash 与 ssh；远程模式需预配置 SSH 免密登录。
  bash: "4+"
  ssh: "required"
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
allowed-tools:
  - Read
  - Bash
  - Write
  - AskUserQuestion
---

# 任务配置生成

> 本 skill 是 `perf-params-tuner-agent` 的子 skill，负责任务配置生成。不直接由用户调用。

## 输入

由 orchestrator 传入：
- 用户原始输入（自然语言描述的调优需求）

## 执行流程

### 1. 场景识别

读取 `references/shared/scenario-registry.md`，根据用户输入语义识别目标场景：

- **命中唯一场景** → 读取该场景的 `assets/scenarios/{name}/meta.yaml` → 进入内置场景流程
- **命中多个场景** → 列出候选项让用户选择 → 选定后进入内置场景流程
- **未命中任何场景** → 进入自定义场景流程

**注意：** 场景数据路径基于本 skill 的 base directory 推导：
```
{skill_base_dir}/assets/scenarios/{ScenarioName}/meta.yaml
{skill_base_dir}/assets/scenarios/{ScenarioName}/param_*.yaml
{skill_base_dir}/references/shared/scenario-registry.md
```

不依赖任何外部工具获取路径。

### 2. 按场景类型加载工作流

- **内置场景** → 读取 `references/gen/workflow-builtin.md` 并执行
- **自定义场景** → 读取 `references/gen/workflow-custom.md` 并执行

## 核心流程（提案先行 + 直接生成正式配置）

采用"提案先行"模式：先展示方案让用户确认，确认后直接生成正式调优配置（含合理轮数），不再先生成 1 轮测试配置。

1. **解析主机信息** → 从用户输入中提取主机列表（无则默认本机）
2. **探测变量** → 优先使用用户提供的值，否则按五级策略（用户提供 → env_var → 三级探测 → default → placeholder）自动赋值
3. **展示提案** → 向用户展示人类可读的调优方案
4. **确认生成** → 用户确认后，生成 YAML 文件并写入磁盘（直接生成正式配置，`rounds` 设为合理默认值，如 30）

**重要：在用户确认之前，不生成任何 YAML 文件。**

## 输出

- 调优方案提案（人类可读格式，用于确认前展示）
- 确认后：生成的 task YAML 文件 + 文件路径 + 下一步引导

## 设计原则

- **提案先行**：先展示方案让用户审查，确认后才生成文件
- **直接生成正式配置**：确认后直接生成含合理轮数的正式调优配置，无需先跑 1 轮测试
- **不阻断**：变量探测失败时填占位值继续，不向用户提问
- **不做校验**：模板校验由 `diag` 子 skill 负责
