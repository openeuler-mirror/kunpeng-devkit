---
name: diag
description: 模板诊断与修改子 skill。由perf-params-tuner-agent 主 skill 调用，不直接面向用户。负责对生成的 task_xxx_System.yaml 和 param_xxx_System.yaml 进行格式校验（代码）、语义诊断（agent）和修改。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
---

# 模板诊断与修改

> 本 skill 是 `perf-params-tuner-agent` 的子 skill，负责模板诊断与修改。不直接由用户调用。

## 输入

由 orchestrator 传入：
- 用户原始输入（诊断需求或修改指令）
- 工作目录
- 待诊断的模板文件路径（用户提供或自动探测）

## 核心架构

```
格式校验（代码）          语义校验（agent）
     │                        │
     ▼                        ▼
validate_template.py     读取 env_info.jsonc
  ├─ YAML 语法            ├─ Task: run_test 可执行性
  ├─ 字段完整性           ├─ Param: 内核版本匹配
  ├─ ptype 规则           ├─ Param: 应用版本匹配
  ├─ 占位符检查           ├─ Param: 架构匹配
  ├─ 块标量格式           ├─ Param: 硬件上限匹配
  └─ 跨文件一致性         └─ Param: 参数依赖一致性
```

**格式问题全部由代码解决，agent 不判断格式问题。**
Agent 只在脚本输出的基础上补充语义级诊断。

## 模式识别

根据用户输入判断执行模式：

| 模式 | 关键词示例 | 说明 |
|------|-----------|------|
| **Mode 1: 诊断** | "检查"、"诊断"、"校验"、"看看有没有问题"、"是否正确" | 调脚本做格式校验 + agent 做语义诊断 |
| **Mode 2: 修改** | "修改"、"加上"、"改一下"、"改成"、"删除"、"增加" | 按用户指令修改模板文件 |
| **Mode 3: 语法校验** | 由 Mode 2 自动触发，或用户显式要求"语法检查" | 仅调脚本做格式校验 |

**规则：**
- Mode 2 执行完毕后**自动触发** Mode 3
- Mode 1 可独立执行，发现问题后可衔接 Mode 2 + Mode 3

---

## Mode 1: 诊断

### 1. 定位模板文件

1. **用户明确指定文件路径** → 直接使用
2. **用户提到文件名**（如"检查 task_Redis_System.yaml"）→ 在工作目录下查找
3. **用户未指定** → 自动探测工作目录下所有 `task_*.yaml` 和 `param_*.yaml` 文件
4. **未找到** → 返回提示，要求用户提供文件路径

### 2. 格式校验（代码完成）

调用验证脚本，一次性完成全部格式检查：

```bash
python3 {skill_base_dir}/scripts/validate_template.py \
  --task <task_yaml> --param <param_yaml> --summary
```

脚本自动检查（详见 `references/validation-rules.md` 第一层）：
- YAML 语法合法性
- 顶级字段完整性
- configs 子字段类型
- ptype 规则（immutable/uniform_int/uniform_float/categorical）
- suggestion 范围合法性
- 块标量格式（`|` vs 引号字符串）
- benchmark 包装器 5 要素
- 占位符保留/替换检查
- host_name 规则
- 参数名重复
- 可调参数数量限制
- 跨文件参数组一致性

解析 `--summary` 输出格式：`severity|rule_id|file_type|message`，按 severity 分类展示。

### 3. 语义诊断（agent 完成）

读取 `references/validation-rules.md` 第二层规则，在格式校验通过的基础上进行语义检查。

#### Task YAML 语义诊断：run_test 可执行性

读取 task YAML 内容，结合目标环境信息，检查：

**S1. 路径存在性**
- 提取所有命令中的路径引用（如 `/opt/redis/bin/redis-server`）
- 在目标节点执行 `test -e <path>` 或 `which <command>` 验证路径存在
- 路径不存在 → 🔴 错误，提示用户确认实际路径

**S2. 命令逻辑正确性**
- 检查 `set_up → round_set_up → run_test → round_tear_down → tear_down` 执行链逻辑自洽
- `round_set_up` 是否正确停止上一轮进程
- `run_test` 前置命令是否正确启动应用
- `run_test` 压测命令参数是否完整（如 redis-benchmark 需要 -p/-c/-n）
- `tear_down` 是否清理了临时文件

**S3. 指标提取正确性**
- benchmark 包装器中的提取命令（grep/awk/sed 管道）输出格式与压测工具实际输出匹配
- 提取结果为浮点数（KAT 要求 run_test 回显为浮点数）
- 压测命令输出中包含 `performance_info` 指定的指标名
- **方法**：在目标节点手动执行一次压测命令，检查输出格式

**S4. 参数下发命令正确性**
- `query_cmd` 能正确查询当前参数值
- `assign_cmd` 的 sed/grep 逻辑能正确修改配置文件
- `backup_cmd` 和 `recover_cmd` 路径配对一致
- `<kat_name>` / `<kat_value>` 占位符位置正确

#### Param YAML 语义诊断：参数范围与环境匹配

读取 param YAML 和 `env_info.jsonc`（若存在），检查参数范围是否与环境匹配：

**S5. 内核版本匹配**
- 从 `env_info.jsonc` 获取内核版本（如 5.10）
- 遍历 System 参数的 `version` 字段
- 当前内核不在 version 范围内 → 🔴 错误，建议排除该参数
- **方法**：读取工作目录或 `params-design/references/param_System_base.yaml` 交叉验证

**S6. 应用版本匹配**
- 从 `app_info.jsonc` 获取应用版本（如 Redis 6.2.23）
- 检查应用参数名在该版本中是否存在（如 Redis 7.0+ 参数名变更）
- 参数名在当前版本不存在 → 🟡 警告

**S7. 架构匹配**
- 从 `env_info.jsonc` 获取 CPU 架构（aarch64/x86_64）
- 检查参数是否仅在特定架构有效（如 `kernel.sched_cluster` 仅 ARM）
- `Kunpeng uarch` 参数组仅在鲲鹏 ARM 架构有效
- 架构不匹配 → 🟡 警告，建议排除

**S8. 硬件上限匹配**
- 从 `env_info.jsonc` 提取硬件规格：
  - CPU 核心数 → 检查 `io-threads`、`kernel.sched_nr_migrate` 等不超过核心数
  - 物理内存总量 → 检查 `vm.min_free_kbytes` upper ≤ 内存 5%、`kernel.shmmax` upper ≤ 内存总量
  - 存储类型（SSD/HDD） → 检查 `read_ahead_kb`、`nr_requests` 范围是否合理
  - 网卡信息 → 检查 `net.core.somaxconn`、`tcp_max_syn_backlog` 范围
- 参数 upper 超出硬件物理限制 → 🔴 错误，建议调整范围

**S9. 参数间依赖一致性**
- 检查依赖参数的 enable 状态一致（如 AOF 关闭后 appendfsync 应为 immutable 或 enable=False）
- immutable 参数的固定值不与其他参数范围矛盾
- 语义相关参数组（如 `tcp_rmem[0]/[1]/[2]`）范围不交叉

### 4. 生成诊断报告

合并格式校验结果和语义诊断结果：

```
📋 模板诊断报告
━━━━━━━━━━━━━━━

── 格式校验（脚本） ──
文件：task_Redis_System.yaml
  [PASS] 格式校验通过

文件：param_Redis_System.yaml
  [ERROR] [B3] [Redis] params[0] suggestion=0 不在 [1073741824, 8589934592] 范围内
  [WARN]  [D2] [System] 可调参数 12 个，超过 10 个上限

── 语义诊断（agent） ──
Task YAML — run_test 可执行性：
  [ERROR] [S1] 路径 /path/redis/bin/redis-server 不存在（占位路径未替换）
  [WARN]  [S3] 提取命令 grep -oP '\d+\.\d+(?=\s+requests per second)' 可能无法匹配 redis-benchmark 的实际输出格式

Param YAML — 参数环境匹配：
  [ERROR] [S5] 参数 kernel.sched_cluster version=[["5.0","latest"]] 但当前内核 4.19 不在范围
  [ERROR] [S8] 参数 io-threads upper=64 超出 CPU 核心数 32
  [WARN]  [S6] 参数 hash-max-ziplist-entries 在 Redis 7.0+ 中已更名为 hash-max-listpack-entries

━━━━━━━━━━━━━━━
汇总：4 错误 / 3 警告
```

### 5. 提供修复建议

对每个错误项给出具体修复建议，提示用户是否需要通过 Mode 2 修复。

---

## Mode 2: 修改

### 1. 解析修改指令

| 修改类型 | 指令示例 | 操作 |
|----------|----------|------|
| 添加参数 | "加上 maxmemory 参数" | 在 param YAML 对应组中添加参数条目 |
| 删除参数 | "删掉 vm.swappiness" | 从 param YAML 中移除参数 |
| 修改范围 | "把 maxmemory 范围改成 1GB 到 8GB" | 修改 param YAML 参数的 upper/lower |
| 修改建议值 | "maxmemory 建议值改成 4GB" | 修改 param YAML 参数的 suggestion |
| 修改轮数 | "改成 100 轮" | 修改 task YAML configs.rounds |
| 修改命令 | "压测命令改成..." | 修改 task YAML run_test |
| 修改路径 | "Redis 路径改成 /usr/local/redis" | 替换 task YAML 中对应变量值 |
| 启用/禁用 | "启用 System 参数" | 修改 task YAML assign_params 中 enable |

### 2. 执行修改

**修改原则：**
- 先读取目标文件，理解当前结构
- 按修改指令定位目标位置
- 执行最小化修改，不影响其他部分
- 修改后保持 YAML 格式一致性（缩进、注释保留、块标量格式）
- **修改前向用户展示变更摘要，确认后执行**

**变更摘要格式（按文件分组，逐条列出全部变更点）：**

```
📝 修改摘要
━━━━━━━━━━━━━━━
文件：param_Redis_System.yaml
  + 添加参数：maxmemory (uniform_int, lower=1073741824, upper=8589934592, suggestion=4294967296)
  ~ 修改参数：tcp-backlog upper 511 → 65535
文件：task_Redis_System.yaml
  ~ 修改：configs.rounds 30 → 100
确认执行？(yes/no)
```

**变更清单要求：**
- 按文件分组展示，标明每个文件的变更处数
- 每条变更必须包含四要素：变更类型（新增/修改/删除）、字段位置、变更前值、变更后值
- 新增项需给出完整新增内容；删除项需给出被删除内容的完整原值
- 同一修改涉及多文件联动时（如同一参数在 param YAML 的范围与 task YAML 的引用处均变化），两个文件的清单中都必须列出对应变更
- 禁止使用"等其他若干处"之类的模糊表述，所有变更点必须逐条列全，不得省略或合并

### 3. 写入文件并触发 Mode 3

用户确认后写入文件。写入完成后向用户输出最终变更清单（按文件分组的逐条变更记录，格式同修改摘要），再自动调用脚本做格式校验。

---

## Mode 3: 语法校验

仅调用脚本执行格式校验（与 Mode 1 步骤 2 相同）：

```bash
python3 {skill_base_dir}/scripts/validate_template.py \
  --task <task_yaml> --param <param_yaml> --summary
```

输出校验结果：
- `PASS` — 格式校验通过
- 发现问题 — 列出问题，提示修复方式

---

## 输出

- **Mode 1**：格式校验结果 + 语义诊断报告（含 S1-S9 检查项）
- **Mode 2**：修改记录（按文件分组逐条列出变更点：文件名、变更类型、字段位置、变更前后值）
- **Mode 3**：格式校验结果（通过/问题列表）
- 下一步引导：根据结果提示用户可继续的操作

## 设计原则

- **格式交给代码**：所有格式/结构问题由 `validate_template.py` 自动检查，agent 不判断格式问题
- **agent 聚焦语义**：agent 只做需要理解命令逻辑和环境上下文的语义级诊断
- **只读优先**：Mode 1 不修改任何文件，仅报告
- **确认后修改**：Mode 2 在用户确认变更摘要后才写入文件
- **修改即校验**：Mode 2 完成后自动触发 Mode 3
- **最小化修改**：只改用户要求的，不连带修改其他部分
- **保留格式**：修改后保持 YAML 缩进、注释、块标量格式
