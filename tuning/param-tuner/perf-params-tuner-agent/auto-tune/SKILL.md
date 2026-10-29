---
name: auto-tune
description: 调优执行 + 进度监控子 skill。由perf-params-tuner-agent 主 skill 调用，不直接面向用户。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
---

# 自动调优与监控

> 本 skill 是 `perf-params-tuner-agent` 的子 skill，负责调优执行与进度监控。不直接由用户调用。

## 输入

由 orchestrator 传入：
- task YAML 路径（`task_{App}_System.yaml`）
- param YAML 路径（`param_{App}_System.yaml`）
- 或用户原始输入（从中提取模板路径）

## 执行流程

### 1. 确认模板文件

- 校验当前工作空间是否存在task/param 文件
- 如果不存在，返回主 skill 报错

### 2. 确认训练目录

- 校验训练目录`train_result`是否存在
- 如果存在，需要用户确认是否重新训练

### 3. 启动调优   

调用调优脚本，启动寻优训练：

```bash
python3 {skill_base_dir}/scripts/tuner_monitor.py \
  train_result \
  task_{App}_System.yaml \
  param_{App}_System.yaml \
```
注意：
  - 实时展示脚本执行进度，用户可以查看调优过程。

## 输出

- 训练目录路径
- 进度总结

## 设计原则

- **异常可见**：连续失败、性能骤降及时提示用户