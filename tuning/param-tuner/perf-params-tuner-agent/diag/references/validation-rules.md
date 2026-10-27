# 模板校验规则

> 校验分为两层：**格式校验**（代码完成）和 **语义校验**（agent 完成）。
> 格式问题由 `scripts/validate_template.py` 全权处理，agent 不再判断格式问题。

---

## 第一层：格式校验（代码完成）

由 `scripts/validate_template.py` 自动执行，agent 只需调用脚本并解析输出。

### Task YAML 格式规则

| 规则 ID | 级别 | 检查内容 |
|---------|------|---------|
| A1 | error | 顶级字段齐全（template_type/hosts_list/configs/assign_params/set_up/round_set_up/run_test/round_tear_down/tear_down） |
| A2 | error | configs 子字段齐全且类型正确（rounds:int, algorithm:str, random_initial_ratio:float, performance_info:str, tuning_direction:str, maximum_consecutive_failures:int） |
| A3 | error | assign_params 条目含 name/enable 字段 |
| B1 | error | template_type = "custom" |
| B2 | error | algorithm = "HPO" |
| B3 | error | tuning_direction ∈ {"high", "low"} |
| B4 | error/warn | rounds 为正整数；<10 警告，<30 建议 |
| B5 | error | random_initial_ratio ∈ [0, 1] |
| B6 | error | maximum_consecutive_failures 为正整数 |
| B7 | error | performance_info 非空 |
| C1 | error | 所有 cmd 使用 `\|` 块标量格式（检测引号字符串） |
| C2 | error | run_test 末项含 benchmark 包装器 5 要素（output 捕获/$?检查/result提取/空值检查/echo输出） |
| C3 | warn | 各段命令非空（set_up/round_set_up/run_test/round_tear_down/tear_down） |
| D1 | warn | 运行时占位符 `<kat_name>`/`<kat_value>`/`<kat_suffix>` 保留 |
| D2 | warn | 变量占位符 `{app_exe_path}` 等已替换（`{timestamp}` 除外） |
| D3 | info | 占位路径检测（`/path/`、`placeholder`） |
| E2 | warn | 远程模式下 run_test 末项 host_name 非空 |
| E3 | error | 远程模式下 run_test 末项 host_name 在 hosts_list 中有定义 |
| F1 | error | assign_params 至少一个 enable=True；应用参数组 enable=True 时 query/assign/backup/recover 命令非空 |

### Param YAML 格式规则

| 规则 ID | 级别 | 检查内容 |
|---------|------|---------|
| A1 | error | 顶级为 map，每组含 params 列表 |
| A2 | error | 每个参数含全部字段（name/ptype/upper/lower/suggestion/choices/enable/default/version） |
| B1 | error | ptype ∈ {immutable, uniform_int, uniform_float, categorical} |
| B2 | error | immutable: upper=0, lower=0, choices 单元素, suggestion=choices[0] |
| B3 | error | uniform_int/uniform_float: lower ≤ suggestion ≤ upper, choices 为空 |
| B4 | error | categorical: choices ≥ 2 元素, suggestion ∈ choices |
| C1 | error | suggestion 非空 |
| C2 | error | enable 为布尔值（非字符串） |
| C3 | error | version 为列表格式 |
| C4 | error/warn | 参数名组内不重复（error）；跨组重复（warn） |
| D2 | warn | 可调参数（enable=True 且非 immutable）≤ 10 |
| D4 | warn | choices 元素类型检查 |

### 跨文件格式规则

| 规则 ID | 级别 | 检查内容 |
|---------|------|---------|
| X1 | error | task assign_params 中应用参数组 name 在 param YAML 中有对应顶级 key |
| X2 | warn | param YAML 参数组在 task assign_params 中有对应条目；enable=True 的组在 param 中有定义 |
| X3 | info | task 中建议包含 System 参数组条目 |

### 脚本调用方式

```bash
# 完整校验（人类可读）
python3 {skill_base_dir}/scripts/validate_template.py --task <task_yaml> --param <param_yaml>

# 紧凑输出（供 agent 解析）
python3 {skill_base_dir}/scripts/validate_template.py --task <task_yaml> --param <param_yaml> --summary

# JSON 输出
python3 {skill_base_dir}/scripts/validate_template.py --task <task_yaml> --param <param_yaml> --json

# 仅校验 task 或 param
python3 {skill_base_dir}/scripts/validate_template.py --task <task_yaml>
python3 {skill_base_dir}/scripts/validate_template.py --param <param_yaml>
```

返回码：0=通过，1=有错误，2=仅有警告

---

## 第二层：语义校验（agent 完成）

格式校验通过后，agent 聚焦以下语义级问题。这些需要理解命令逻辑、环境上下文，代码无法自动判断。

### Task YAML 语义校验：run_test 脚本可执行性

**目标**：确认 task YAML 中的命令在实际环境中可以正确执行。

#### S1. 路径存在性
检查所有命令中引用的路径在目标节点上是否存在：
- `set_up` 中的路径检查命令（如 `/path/redis/bin/redis-server`）
- `run_test` 中的应用启动命令路径
- `run_test` 中的压测工具路径
- `assign_cmd`/`backup_cmd`/`recover_cmd` 中的配置文件路径

**方法**：通过 SSH 在目标节点执行 `test -e <path>` 或 `which <command>` 验证。

#### S2. 命令逻辑正确性
检查命令链是否逻辑自洽：
- `set_up` → `round_set_up` → `run_test` → `round_tear_down` → `tear_down` 执行顺序合理
- `round_set_up` 是否正确停止了上一轮的进程
- `run_test` 前置命令是否正确启动了应用
- `run_test` 压测命令参数是否完整（如 redis-benchmark 需要 -p/-c/-n 等参数）
- `tear_down` 是否清理了 `set_up` 和 `round_set_up` 产生的临时文件

#### S3. 指标提取正确性
检查 benchmark 包装器中的提取命令能否正确提取指标：
- 提取命令（grep/awk/sed 管道）的输出格式与压测工具实际输出匹配
- 提取出的数值是浮点数（KAT 要求 run_test 回显为浮点数）
- 压测命令的输出中确实包含 `performance_info` 指定的指标名

**方法**：在目标节点手动执行一次压测命令，检查输出格式与提取命令的匹配性。

#### S4. 参数下发命令正确性
检查 `assign_cmd`/`query_cmd`/`backup_cmd`/`recover_cmd` 是否正确操作应用的配置：
- `query_cmd` 能正确查询当前参数值
- `assign_cmd` 能正确修改配置文件中的参数值（sed/grep 逻辑正确）
- `backup_cmd` 和 `recover_cmd` 配对，备份和恢复的文件路径一致
- `<kat_name>` 和 `<kat_value>` 占位符在命令中的位置正确

### Param YAML 语义校验：参数范围与环境匹配

**目标**：确认 param YAML 中的参数取值范围与当前运行环境匹配。

#### S5. 内核版本匹配
检查 System 参数的 `version` 范围是否覆盖当前内核版本：
- 读取 `env_info.jsonc` 获取内核版本（如 5.10）
- 遍历每个 System 参数的 `version` 字段：
  - `version: []` → 无限制，跳过
  - `version: [["4.0", "5.12"]]` → 当前内核必须在 [4.0, 5.12] 内
  - 当前内核不在范围内 → 标记为不匹配
- 不匹配的参数：建议排除或调整 version 范围

#### S6. 应用版本匹配
检查应用参数的 `version` 范围是否覆盖当前应用版本：
- 读取 `app_info.jsonc` 获取应用版本（如 Redis 6.2.23）
- 应用参数通常无 version 字段或为空，但应检查参数名在该版本中是否存在
- 如 Redis 7.0+ 将 `hash-max-ziplist-entries` 改为 `hash-max-listpack-entries`，需根据版本检查参数名是否正确

#### S7. 架构匹配
检查参数是否与当前 CPU 架构匹配：
- 读取 `env_info.jsonc` 获取 CPU 架构（aarch64/x86_64）
- 某些参数仅在特定架构上有效：
  - `kernel.sched_cluster` → 仅内核 5.0+ 且 ARM 架构
  - `transparent_hugepage_*` → x86 和 ARM 行为不同
  - `Kunpeng uarch` 参数组 → 仅鲲鹏 ARM 架构
- 架构不匹配的参数建议排除

#### S8. 硬件上限匹配
检查参数取值范围是否超出硬件物理限制：
- 内存相关参数：
  - `vm.min_free_kbytes` upper 不超过物理内存的 5%
  - `kernel.shmmax` upper 不超过物理内存总量
  - `vm.max_map_count` upper 考虑实际内存页数
- CPU 相关参数：
  - `io-threads`（Redis）不超过 CPU 核心数
  - `kernel.sched_nr_migrate` 不超过 CPU 核心数
  - `net.core.dev_weight` 考虑网卡队列数
- 存储相关参数：
  - `nr_requests` upper 考虑块设备队列深度
  - `read_ahead_kb` 考虑存储类型（SSD vs HDD）
- 网络相关参数：
  - `net.core.somaxconn` upper 考虑 conntrack 表大小
  - `net.ipv4.tcp_max_syn_backlog` 不超过 `net.core.somaxconn`

**方法**：从 `env_info.jsonc` 提取硬件规格（CPU 核心数、内存总量、存储类型、网卡信息），与参数 upper 值逐一比对。

#### S9. 参数间依赖一致性
检查参数之间的依赖关系是否自洽：
- 若参数 A 依赖参数 B 的状态（如 AOF 关闭后 appendfsync 无效），确保依赖参数的 enable 状态一致
- immutable 参数的固定值不与其他参数的取值范围矛盾
- 同一组中语义相关的参数（如 `tcp_rmem[0]/[1]/[2]` 三元组）范围不交叉
