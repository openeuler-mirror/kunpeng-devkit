# 自定义场景生成流程

> 本文件由 `gen/SKILL.md` 在未匹配到任何内置场景时读取并执行。

## 适用场景

用户没有特定应用，或应用不在内置列表中（如 Nginx、MongoDB、自研应用等）。

---

## Step 1: 收集基本信息

与内置场景不同，自定义场景没有 meta.yaml 提供预定义数据。需要向用户收集以下信息：

1. **应用名称** — 用于模板命名和参数组标识
2. **性能测试命令 + 输出示例** — 用于生成 run_test 末项和 extract_cmd
3. **性能数字位置** — 输出结果中哪个数字代表性能
4. **调优方向** — 越高越好（默认）还是越低越好

**提问方式：** 一次性询问，不逐个追问：

```
📋 我需要了解以下信息来帮你配置：
1. 你要调优的应用叫什么？（如 Nginx、MongoDB）
2. 你用什么命令做性能测试？给我一条示例命令和它的输出结果
3. 输出结果中哪个数字代表性能？（比如"15000 requests/sec"中的 15000）
4. 这个数字是越高越好还是越低越好？（一般越高越好）

请直接告诉我，或者描述你的调优需求，我来帮你整理。
```

---

## Step 2: 展示调优方案（提案先行）

收集到基本信息后，展示提案。**不直接生成 YAML 文件。**

**压测命令格式校验**（纯 LLM，不执行命令）：判断用户提供的压测命令是否为常见压测工具（redis-benchmark、sysbench、pgbench、mysqlslap、fio、ab、wrk、ycsb 等）。若是，检查命令拼写、常用参数是否完整、参数语法是否正确。发现问题时提示用户修正后再继续。

### 提案格式

```
📋 {app_name} 调优方案（自定义场景）
━━━━━━━━━━━━━━━

🔧 压测：
  命令：{用户提供的压测命令}
  指标：{用户描述的指标}（{越高越好/越低越好}）

⚙️ 直接生成正式调优配置（合理轮数，用户可调整）

🔄 执行流程：
  1. 环境初始化
  2. 每轮：准备环境 → 应用新配置 → 执行压测 → 收集指标
  3. 结束：清理临时文件

💡 生成后你可以随时告诉我应用参数，比如"加上 {app_name} 参数：参数A（范围 1-100）、参数B（选项 x/y/z）"，我帮你加入调优。

⚠️ 请确认以下信息是否正确：
  {已检测到的变量，使用 desc 描述}
  {待确认的变量}  ← 请确认是否正确

确认没问题后说"可以"，我会生成配置文件。
```

### 默认策略

| 配置项 | 默认值 |
|--------|--------|
| 参数组 | System base 参数（从 `param_System_base.yaml` 加载） |
| 参数状态 | 保留 param 文件原始 enable 值 |
| 轮数 | 30（直接生成正式配置，用户可要求调整） |

---

## Step 3: 处理确认前的修正和补充

用户在确认提案时可能修正值或补充信息，按以下规则处理并**更新提案重新展示**（不生成 YAML）：

### 压测命令补充/修改

当用户修改压测命令时，需要收集以下三项信息（一次性询问）：

1. **格式校验**（纯 LLM，不执行命令）：判断是否为常见压测工具（redis-benchmark、sysbench、pgbench、mysqlslap、fio、ab、wrk、ycsb 等）。若是，检查命令拼写、常用参数是否完整、参数语法是否正确。发现问题时提示用户修正。
2. **压测命令及其输出示例** — 用于理解输出格式
3. **性能数字位置** — 输出结果中哪个数字代表性能
4. **调优方向** — 越高越好（默认）还是越低越好

根据以上信息生成 `extract_cmd` 和 `tuning_direction`，压测命令同样使用 benchmark 包装器模板（参见 `workflow-builtin.md` Step 4）。

### 生命周期命令补充

当用户提供生命周期命令时，更新提案中执行流程描述。

### 变量修正

与内置场景相同（参见 `workflow-builtin.md` Step 3）。

---

## Step 4: 确认后生成 YAML 文件

用户确认方案无误后，生成 task 和 param 两个 YAML 文件。

### 模板结构规范

与内置场景相同（参见 `workflow-builtin.md` Step 4 的模板结构规范），区别在于：
- `assign_params` 第一个条目为 System 参数组（而非应用参数组）
- 生命周期命令来自用户提供的命令（而非 meta.yaml）

### 格式规范

与内置场景相同：
- 命令使用 `|` 块标量
- 本机模式：`host_name` 一般用 `[]`，run_test 末项用 `[""]`
- 远程模式（单机或多机）：`host_name` 一般用 `[]`，run_test 末项用 `["压测主机名"]`
- 每个 assign_params 条目包含 `vars: []`

### 远程模式处理

与内置场景相同（参见 `workflow-builtin.md` Step 1a 和 Step 4 的远程模式规则）。

### 变量替换规则（生成时执行）

- `{timestamp}` → 替换为当前时间戳（格式：`yyyyMMddHHmmss`）
- `<kat_name>`、`<kat_value>`、`<kat_suffix>` → **保留原样，不得替换**

### 文件输出

- task 文件命名：`task_{app_name}_System.yaml`
- param 文件命名：`param_{app_name}_System.yaml`
- 写入目录：用户指定路径，或当前工作目录

---

## 参考：自定义业务参数（生成后添加）

当用户要求添加自定义业务参数时（如"加上 Nginx 参数：worker_connections（范围 512-8192）"），按以下规则处理，追加到已生成的配置中。

### 参数类型

根据用户描述的参数，选择对应的 ptype：
- 范围型 → `uniform_int` 或 `uniform_float`
- 选项型 → `categorical`
- 固定值 → `immutable`

### 默认 assign_cmd 模板

若用户未指定参数下发方式，使用以下通用 sed 模板：

```bash
output=$(cat {config_file} | grep -wn "^<kat_name>" | grep -vE '^[0-9]+:#' | awk -F ":" '{print $1}'); if [ -z "$output" ]; then echo "<kat_name> = <kat_value>" >> {config_file}; else line_nums=($output); for line_num in "${line_nums[@]}"; do if [ -n "$line_num" ]; then sed -i "${line_num}c <kat_name> = <kat_value>" {config_file}; fi; done; fi
```
