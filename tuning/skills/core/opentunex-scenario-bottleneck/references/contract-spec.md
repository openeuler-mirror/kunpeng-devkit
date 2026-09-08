# 子智能体契约文件规范 v1.0

## 概述

契约文件是子智能体与主智能体之间的标准化通信协议，替代上下文传递。每个子智能体将执行结果写入契约文件，主智能体读取契约文件获取结果。

## 文件格式

契约文件使用 YAML 格式，存放路径：`${WORK_DIR}/<domain>/contracts/<skill_name>.yaml`

> **路径适配**：`WORK_DIR` 默认值为 `/srv/opentunex/<YYYYMMDD_HHMMSS>`，用户可通过一键采集脚本或手动指定覆盖。下文所有路径中的 `${WORK_DIR}/` 均指工作目录根路径。

> **用户指定已有数据目录**：当用户提供了已有采集数据目录（如 `/root/profiling_data_aarch64_20260519_150038/`）时，`WORK_DIR` 为该动态目录路径，分析结果和调优产出将统一存放于该目录下。这种情况下不需要再进行采集，直接进行瓶颈分析和调优。

## 输入契约（主智能体 → 子智能体）

主智能体在启动子智能体前，将输入参数写入契约文件：

```yaml
contract_type: "input"
skill_name: "<skill-name>"
timestamp: "<YYYYMMDD_HHMMSS>"

input:
  batch_dir: "<批次目录路径>"
  target_host: "<目标主机IP>"
  data_dir: "<数据源目录路径>"
  fusion_report: "<融合报告路径>"
  extra_params: {}

constraints_file: "<约束文件路径>"
constraints_version: "<约束文件版本号>"
```

### 标准输入字段

| 字段 | 必需 | 说明 |
|------|------|------|
| batch_dir | 是 | 批次根目录路径 |
| target_host | 否 | 目标主机IP（远程执行场景） |
| data_dir | 否 | 数据源目录路径（分析/调优场景） |
| fusion_report | 否 | 融合报告路径（调优场景） |
| extra_params | 否 | 扩展字段，各子技能可自定义 |

### 扩展字段机制

子技能可在 `extra_params` 下增加域特有字段，例如：

```yaml
input:
  batch_dir: "${WORK_DIR}/20260521_143022"
  target_host: "192.168.1.100"
  extra_params:
    collect_dir: "cpu-collection_collect"
    vmstat_duration: 5
```

## 输出契约（子智能体 → 主智能体）

子智能体执行完成后，将结果写入契约文件：

```yaml
contract_type: "output"
skill_name: "<skill-name>"
timestamp: "<YYYYMMDD_HHMMSS>"
status: "success|partial|failed"

output:
  report_path: "<报告文件路径>"
  contract_path: "<契约文件自身路径>"
  summary: {}
  errors: []

constraints_acknowledged:
  - "<约束编号>: <约束描述>"
constraints_version: "<约束文件版本号>"
```

### status

| 值 | 含义 |
|---|------|
| success | 全部步骤执行成功 |
| partial | 部分步骤成功，部分降级或跳过 |
| failed | 执行失败，无法产出有效结果 |

### constraints_acknowledged

子智能体**必须**列出已遵守的所有约束编号及版本号。主智能体在读取输出契约时校验此字段，缺失约束确认时拒绝接受结果。

校验规则：
1. 输出契约中的 `constraints_acknowledged` 列表不得为空
2. 列表内容必须与约束文件中定义的约束编号一一对应
3. `constraints_version` 必须与输入契约中的版本号一致

## 契约文件路径约定

| 域 | 路径模板 |
|----|---------|
| 数据采集域 | `${WORK_DIR}/collect/contracts/<skill_name>-input.yaml` / `<skill_name>-output.yaml` |
| 瓶颈分析域 | `${WORK_DIR}/analysis/contracts/<skill_name>-input.yaml` / `<skill_name>-output.yaml` |
| 调优域 | `${WORK_DIR}/tuning/contracts/<skill_name>-input.yaml` / `<skill_name>-output.yaml` |

> **目录说明**：`${WORK_DIR}` 本身已包含时间戳（如 `/srv/opentunex/20260527_143052/`），本次所有采集、分析、调优操作均在此目录内完成，各域直接读写其子目录，无需 `latest` 符号链接。

## 子智能体启动协议

### 启动模板

```
启动子智能体执行 [skill_name]：
- 加载技能定义：[skill_path]/SKILL.md
- 读取输入契约：[contract_input_path]
- 读取约束文件：[constraints_path]
- 执行技能定义中的步骤
- 写入输出契约：[contract_output_path]
- 写入报告：[report_path]
```

### 跨平台适配原则

本技能体系采用**声明式调度**：SKILL.md 定义 WHAT（调度什么子智能体、传什么参数、期望什么输出），运行时环境根据自身可用的工具决定 HOW（具体调用格式）。

**调度声明要素**（每个 SKILL.md 中定义）：
1. **子智能体列表**：需要启动哪些子智能体
2. **技能定义路径**：子智能体的 SKILL.md 位置
3. **输入契约路径**：传入子智能体的输入数据位置
4. **约束文件路径**：子智能体必须遵守的约束文件
5. **输出契约路径**：子智能体执行结果的输出位置
6. **任务描述**：传入子智能体的执行指令

**运行时适配**：LLM 根据当前环境可用的工具自行选择调用方式：

| 可用工具 | 调用方式 | 等待方式 |
|---------|---------|---------|
| sessions_spawn + sessions_yield | `sessions_spawn(task="...")` | `sessions_yield()` |
| Task Tool | `Task(description:"...", query:"...", subagent_type:"search")` | 同一轮多个 Task 自动并行 |
| Agent Tool | `Agent(prompt="...")` | 等待返回 |
| 无子智能体工具 | 降级顺序执行 | 串行执行 |

### 降级模式（仅在子智能体工具不可用时使用）

降级模式**不是首选执行路径**，仅在子智能体工具不可用或启动失败时使用：

1. **触发条件**：当前环境无任何子智能体工具可用，或子智能体启动返回错误
2. **执行方式**：主智能体逐个读取子 skill 的 SKILL.md，每次只加载一个，执行完毕后释放上下文再加载下一个
3. **契约文件处理**：降级模式下仍写入契约文件，主智能体在所有子技能执行完毕后统一读取
4. **约束校验**：降级模式下约束校验不变，子技能执行前读取约束文件，执行后写入 constraints_acknowledged
5. **错误处理**：单个子技能失败时标注失败项，继续执行其他子技能
6. **并行退化**：原本可并行的子技能改为顺序执行，总耗时增加但功能不受影响
7. **降级标注**：必须在输出契约中标注 `execution_mode: "degraded"` 并记录降级原因

## 嵌套深度限制

最大嵌套深度为 2 级：入口 → 一级子智能体 → 二级子智能体。

二级子智能体的契约由一级子智能体管理：
- 一级子智能体创建二级契约目录
- 二级子智能体将输出写入一级子智能体指定的路径
- 一级子智能体汇总二级结果后，写入自身的输出契约

## 子智能体超时机制

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 子智能体超时 | 300 秒 | 单个子智能体的最大执行时间 |
| 重试次数 | 1 次 | 超时或失败后的最大重试次数 |
| 重试间隔 | 10 秒 | 重试前的等待时间 |
| 全局失败阈值 | 50% | 超过此比例的子智能体失败时中止整个流程 |

超时处理流程：
1. 子智能体超过 300 秒未完成 → 标记为 timed_out
2. 自动重试 1 次（间隔 10 秒）
3. 重试仍失败 → 标记为 failed，在输出契约中记录错误信息
4. 累计失败率 > 50% → 中止流程，通知用户

## 三级加载系统

技能采用三级渐进式加载：

| 级别 | 内容 | 加载时机 | 大小建议 |
|------|------|---------|---------|
| L1 - 元数据 | frontmatter（name, description） | 始终在上下文中 | <100 词 |
| L2 - 主体 | SKILL.md 正文（调度逻辑、执行步骤） | 技能触发时 | <500 行 |
| L3 - 参考资源 | references/ 目录下的文件 | 按需加载 | 单文件 <200 行 |
