# 内置场景生成流程

## 前置条件

- 已从 `scenario-registry.md` 匹配到内置场景
- 已读取该场景的 `meta.yaml` 文件

---

## Step 1: 自动探测变量值

### 1a. 解析主机信息

从用户输入中提取主机信息：

- **用户未提及主机** → 默认单 host 本机模式，`hosts_list` 保持空值
- **用户提及主机**（如"在 host1(192.168.1.10) 和 host2(192.168.1.11) 上"）→ 解析为多 host 模式：
  - 应用主机列表：用户指定的所有主机
  - 压测主机：默认取应用主机列表的第一台，用户可调整
  - SSH 连接信息：默认 `username: root`、`port: 22`，用户可调整

### 1b. 探测变量值

对 `app_framework.vars` 中每个变量，按以下优先级自动赋值：

1. **用户直接提供**：若用户在输入中明确给出了变量值（如"redis 在 /opt/redis 下"）→ 直接使用，跳过探测
2. **环境变量检查**：若变量定义了 `env_var`（如 `JAVA_HOME`）→ 执行 `echo ${env_var}` → 非空则使用
3. **三级目标探测**：对变量的每个 `search_targets` 目标，执行统一搜索：
   - **L1 快速**：`which {target}` + `pgrep -a {target} | head -1`（从命令行中提取可执行文件路径）
   - **L2 常见目录**：`find /opt /usr/local /home /root /data /app -name {target} -type f`
   - **L3 全盘**：`find / -name {target} -type f -maxdepth 5`
   - 取第一个有效结果的**目录部分**作为变量值
4. **使用 `default` 值**：若探测全部失败且 meta.yaml 定义了 default → 使用该值
5. **填占位值**：若以上均失败 → 使用 `placeholder` 值，标记为 **[待确认]**

**重要：** 所有探测命令合并为单条 bash 命令执行，减少权限确认次数。

**规则：** 不因变量探测失败而阻断流程或向用户提问。所有探测失败的变量填占位值继续。

---

## Step 2: 展示调优方案（提案先行）

**不直接生成 YAML 文件**，先向用户展示人类可读的调优方案。

### 提案格式

```
📋 {app_name} 调优方案
━━━━━━━━━━━━━━━

[主机]（仅多 host 时显示）
  应用主机：
    - host1 (192.168.1.10) [root/22]
    - host2 (192.168.1.11) [root/22]
  压测主机：
    - host1 (192.168.1.10)

🔧 压测：
  工具：{native_benchmark}
  命令：{native_benchmark_command 简写}
  指标：{performance_info 中文描述}（{tuning_direction 中文：越高越好/越低越好}）

🔬 调优对象：
  本次将调优 {app_name} 的应用参数（如 {param_App_System.yaml 前排 3-5 个代表性参数名}）。
  默认调优应用参数；如需再加 System 系统参数或 Kunpeng 架构参数，告诉我即可。

⚙️ 直接生成正式调优配置（合理轮数，用户可调整）

🔄 执行流程：
  1. （用通俗语言描述 set_up 做了什么，不提 set_up 概念）
  2. （描述每轮循环的逻辑：停止旧进程 → 用新参数启动 → 压测 → 收集指标）
  3. （描述结束清理）

⚠️ 请确认以下信息是否正确：
  [检测值] {变量desc}：实际值
  [默认] {变量desc}：默认值
  [待确认] {变量desc}：占位值  ← 请确认是否正确

确认没问题后说"可以"，我会生成配置文件。
```

### 提案内容来源

| 提案段 | 数据来源 |
|--------|----------|
| 主机信息 | Step 1a 解析结果（仅多 host 时显示） |
| 压测工具/命令 | meta.yaml 的 `native_benchmark` / `native_benchmark_command` |
| 指标/方向 | meta.yaml 的 `performance_info` / `tuning_direction`（翻译为中文） |
| 执行流程 | meta.yaml 的 `cmd` 段（翻译为通俗语言，不使用 set_up/run_test 等术语） |
| 确认项 | Step 1b 探测结果，使用变量的 `desc` 字段展示（不暴露变量名） |

### 确认项标签规则

- `[检测值]`：三级探测成功返回了有效结果
- `[默认]`：探测失败，使用了 meta.yaml 的 default 值
- `[待确认]`：探测和 default 均无结果，使用了 placeholder 值，需用户重点关注

---

## Step 3: 处理确认前的修正

用户在确认提案时可能指出某些值不正确，按以下规则处理并**更新提案重新展示**（不生成 YAML）：

### 变量修正

| 指令示例 | 操作 |
|----------|------|
| "Redis 安装路径应该是 /usr/local/redis/bin" | 更新变量值，重新渲染所有引用该变量的命令 |
| "端口改成 6380" | 识别对应变量（app_port），更新值并重新渲染 |

### 压测命令调整

| 指令示例 | 操作 |
|----------|------|
| "换成自定义压测脚本 /opt/bench.sh" | 见下方"自定义压测命令处理" |

### 自定义压测命令处理

当用户提供自定义压测命令时：

1. **格式校验**（纯 LLM，不执行命令）：判断是否为常见压测工具（redis-benchmark、sysbench、pgbench、mysqlslap、fio、ab、wrk、ycsb 等）。若是，检查命令拼写、常用参数是否完整、参数语法是否正确。发现问题时提示用户修正后再继续。
2. **对比 native 命令**：将用户命令与 meta.yaml 的 `native_benchmark_command` 比较
3. **若使用相同工具**（如都是 redis-benchmark，只是参数不同）→ 复用 `native_benchmark_extract`，提示"已自动匹配指标提取命令"
4. **若完全不同** → 需要收集：
   - 让用户提供一次执行的回显示例
   - LLM 从回显中推断 `extract_cmd`（管道命令）并展示给用户确认
   - 确认调优方向："指标是越高越好还是越低越好？（默认：越高越好）"
   - 更新提案中的 extract_cmd 和 tuning_direction
5. **自定义命令同样使用 benchmark 包装器模板**，将用户的命令和提取命令分别填入 `NATIVE_BENCHMARK_COMMAND` 和 `NATIVE_BENCHMARK_EXTRACT` 位置

---

## Step 4: 确认后生成 YAML 文件

用户确认方案无误后（如说"可以"、"确认"、"没问题"），生成 task YAML 文件。

直接生成正式调优配置，`rounds` 设为合理默认值（默认 30，用户可要求调整）。不在确认后先生成 1 轮测试配置。

### 模板结构规范

以 `assets/scenarios/Custom/task_Custom_System.yaml` 为标准结构：

```yaml
template_type:
    "custom"
hosts_list:
    -
        name:
            ""
        ip:
            ""
        username:
            ""
        port:
            "22"
configs:
    rounds:
        30
    maximum_consecutive_failures:
        10
    algorithm:
        "HPO"
    random_initial_ratio:
        0.5
    performance_info:
        "{meta.yaml 的 performance_info}"
    tuning_direction:
        "{meta.yaml 的 tuning_direction}"
assign_params:
    -
        name:
            "{app_name}"
        enable:
            True
        query_cmd:
            -
                cmd: |
                    {meta.yaml param_group.command_templates.query}
                host_name:
                    []
        assign_cmd:
            -
                cmd: |
                    {meta.yaml param_group.command_templates.assign}
                host_name:
                    []
        backup_cmd:
            -
                cmd: |
                    {meta.yaml param_group.command_templates.backup}
                host_name:
                    []
        recover_cmd:
            -
                cmd: |
                    {meta.yaml param_group.command_templates.recover}
                host_name:
                    []
        execute_after_assign:
            -
                cmd: |
                    {meta.yaml param_group.command_templates.execute_after_assign}
                host_name:
                    []
        vars:
            []
set_up:
    -
        cmd: |
            {meta.yaml cmd.set_up[0]}
        host_name:
            []
    -
        cmd: |
            {meta.yaml cmd.set_up[1]}
        host_name:
            []
round_set_up:
    -
        cmd: |
            {meta.yaml cmd.round_set_up}
        host_name:
            []
run_test:
    -
        cmd: |
            {meta.yaml cmd.run_test 前置项（如应用启动）}
        host_name:
            []
    -
        cmd: |
            {benchmark 包装器（见下方）}
        host_name:
            [""]
round_tear_down:
    -
        cmd: |
            {meta.yaml cmd.round_tear_down}
        host_name:
            []
tear_down:
    -
        cmd: |
            {meta.yaml cmd.tear_down}
        host_name:
            []
```

### Benchmark 包装器模板

run_test 最后一项必须使用以下包装器，确保错误处理和指标提取：

```bash
output=$( { {NATIVE_BENCHMARK_COMMAND} 2>&1; } )
if [ $? -ne 0 ]; then
  echo "Benchmark command failed with non-zero exit code"
  echo "$output"
  exit 1
fi
result=$(echo "$output" | {NATIVE_BENCHMARK_EXTRACT})
if [ -z "$result" ]; then
  echo "Failed to extract metric from benchmark output"
  echo "$output"
  exit 1
fi
echo "$result"
```

其中：
- `{NATIVE_BENCHMARK_COMMAND}` → meta.yaml 的 `native_benchmark_command`
- `{NATIVE_BENCHMARK_EXTRACT}` → meta.yaml 的 `native_benchmark_extract`

### 变量替换规则（生成时执行）

- `{timestamp}` → 替换为当前时间戳（格式：`yyyyMMddHHmmss`）
- `{app_exe_path}`、`{app_config_path}` 等花括号变量 → 替换为 Step 1 探测到的值
- `<kat_name>`、`<kat_value>`、`<kat_suffix>` → **保留原样，不得替换**（运行时占位符）

### 格式规范

- 命令统一使用 `|` 块标量（YAML block scalar），不使用双引号字符串
- **本机模式（默认）：** `hosts_list` 保持空值，一般命令 `host_name: []`，run_test 末项 `host_name: [""]`
- **远程模式（单机或多机）：** `hosts_list` 填写主机信息，一般命令 `host_name: []`（所有主机执行），run_test 末项 `host_name: ["压测主机名"]`（仅压测主机执行并捕获指标）
### 远程模式模板生成规则

当用户指定了远程主机时（无论单机还是多机）：

1. `hosts_list` 填充主机信息，默认 `username: root`、`port: 22`
2. 所有生命周期命令（set_up、round_set_up、run_test 前置项、round_tear_down、tear_down）使用 `host_name: []`
3. run_test 最后一项（benchmark）使用 `host_name: ["压测主机名"]`
4. 多机时：压测主机默认取应用主机列表的第一台，用户可调整
5. 压测命令可能需要调整目标地址（如 redis-benchmark 加 `-h {应用主机IP}`），具体取决于应用场景

### 文件输出

- task 文件命名：`task_{app_name}_System.yaml`
- 写入目录：用户指定路径，或当前工作目录
