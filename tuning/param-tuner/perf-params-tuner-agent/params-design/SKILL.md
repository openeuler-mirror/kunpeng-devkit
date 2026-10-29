---
name: params-design
description: >-
  技能定位：这是应用参数调优模板生成技能，由 perf-params-tuner-agent 主 skill 调用，不直接面向用户。
  能力描述：提供根据应用信息(app_info)和环境信息(env_info)自动生成应用参数调优模板(param_{App}_System.yaml)的能力。
  触发场景：在调优流程阶段3需要生成参数模板时触发。
  适用范围：适用于 Redis/MySQL/Spark/Kafka 等有内置参数参考文件的应用调优模板生成。
  不适用范围：不适用于任务模板(task yaml)生成、模板诊断与修改、调优执行与报告生成。
license: MulanPSL-2.0
compatibility:
  note: 环境采集阶段需要 bash 4+ 与 python3；远程节点采集需预配置 SSH 免密登录。
  bash: "4+"
  python3: "required"
  ssh: "required"
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - AskUserQuestion
---

# 通用应用参数调优模板设计

## 概述

本 Skill 用于根据**应用信息**和**环境信息**自动生成应用参数调优模板（`param.yaml`）。覆盖从用户输入提炼应用信息、匹配环境硬件、到生成结构化调优参数的完整流程。
严格按照流程执行，不能跳过任何步骤。

## 文件结构

```
/skills/params-design/
├── SKILL.md                    # 本说明文件
├── scripts/                    # 可执行代码
│   ├── remote_exec.sh           # 多节点环境信息采集与汇总脚本
│   └── collect_env.sh           # 单节点环境信息采集脚本
├── assets/                     # 模板、资源文件
│   ├── en.jsonc                 # 环境信息模板（占位符 {{key}} 格式）
│   ├── app_info_tpl.jsonc       # 应用信息模板（含字段注释说明）
│   └── param_tpl.yaml           # 参数模板格式定义（单参数字段结构）
└── references/                 # 长文档、参数参考库（按需加载）
    ├── param_System_base.yaml   # System 基础参数全量库（kernel/vm/net/io 等）
    ├── redis.md                 # Redis 参数参考（缓存/持久化/MQ 场景）
    ├── mysql.md                 # MySQL 参数参考（OLTP/OLAP/HTAP 场景）
    ├── spark.md                 # Spark 参数参考（Batch/Streaming/SQL/MLlib 场景）
    └── kafka.md                 # Kafka 参数参考（消息队列/事件流/日志收集 场景）
```

## 核心输入文件

| 文件 | 位置 | 作用 | 必需 |
|------|------|------|------|
| `app_info_tpl.jsonc` | assets/ | 应用信息模板（含字段注释说明） | 是 |
| `en.jsonc` | assets/ | 环境信息模板（占位符格式，供采集脚本使用） | 是 |
| `param_tpl.yaml` | assets/ | 参数模板格式定义（单参数字段结构） | 是 |
| `param_System_base.yaml` | references/ | System 基础参数全量库（供阶段二/三过滤） | 是 |
| `remote_exec.sh` | scripts/ | 多节点环境信息采集与汇总脚本 | 是 |
| `collect_env.sh` | scripts/ | 单节点环境信息采集脚本 | 是 |

## 输出文件

所有输出文件默认生成在**当前工作空间目录**（即执行脚本时的工作目录），可通过 `--output-dir` 参数指定其他目录。

| 文件 | 默认位置 | 说明 |
|------|---------|------|
| `app_info.jsonc` | 工作空间根目录 | 填充后的应用信息（保留模板注释） |
| `env_info.jsonc` | 工作空间根目录 | 环境硬件/系统信息（多节点采集汇总结果） |
| `param_{App}_System.yaml` | 工作空间根目录 | 最终调优参数模板（System + 应用两层） |
| `results/` | 工作空间根目录下 | 各节点采集原始结果（`<node_name>.jsonc`） |

## 工作流程

### 阶段零：环境信息采集

在生成调优参数前，需要先采集目标环境的硬件与系统信息。使用 `scripts/` 目录下的脚本完成采集。

#### 脚本说明

| 脚本 | 作用 | 依赖文件 |
|------|------|---------|
| `remote_exec.sh` | 多节点环境信息采集与汇总（入口脚本） | `collect_env.sh` + `en.jsonc` |
| `collect_env.sh` | 单节点环境信息采集（读取模板、替换占位符、输出结果） | `en.jsonc` |
| `en.jsonc` | 环境信息模板（`{{key}}` 占位符格式，保留注释） | - |

#### 采集流程

1. **将脚本部署到目标环境**：将 `scripts/` 下的 `remote_exec.sh`、`collect_env.sh` 与 `assets/` 下的 `en.jsonc` 复制到工作目录（三个文件放在同一目录，脚本按同目录解析模板）。
2. **执行采集**：

```bash
# 单节点（本机）- 输出到当前工作目录
bash remote_exec.sh

# 单节点（远程）- 输出到当前工作目录
bash remote_exec.sh --nodes "master,@192.168.1.1"

# 多节点混合（2远程 + 1本地），并行执行
bash remote_exec.sh --nodes "master,@192.168.1.1;worker,@192.168.1.2;default,@127.0.0.1" --parallel
```

3. **节点输入格式**：`"节点role,用户名@ip;节点role,用户名@ip"`
   - `role` 默认 `default`（可省略）
   - `用户名` 默认 `root`（可省略）
   - 根据 IP 自动判断本地/远程执行（`127.0.0.1`/`localhost`/`0.0.0.0`/本机IP → 本地）

   | 简写形式 | 等价完整形式 |
   |---------|------------|
   | `192.168.1.1` | `default,root@192.168.1.1` |
   | `root@192.168.1.1` | `default,root@192.168.1.1` |
   | `@192.168.1.1` | `default,root@192.168.1.1` |
   | `master,192.168.1.1` | `master,root@192.168.1.1` |
   | `master,@192.168.1.1` | `master,root@192.168.1.1` |
   | `worker,admin@192.168.1.2` | `worker,admin@192.168.1.2`（完整形式） |

4. **远程前置条件**：远程节点需预先配置 SSH 免密登录：
   ```bash
   ssh-keygen -t rsa -b 2048        # 生成密钥（已有可跳过）
   ssh-copy-id root@远程IP          # 分发公钥
   ```

5. **采集结果**（默认输出到当前工作目录）：
   - 单节点结果：`<输出目录>/results/<node_name>.jsonc`
   - 汇总结果：`<输出目录>/env_info.jsonc`（多节点合并，JSONC 格式保留注释）

6. **读取汇总结果** `env_info.jsonc`，提取关键硬件/系统维度供后续阶段使用。

7. **清理临时文件**：删除`results/`目录和`remote_exec.sh`、`collect_env.sh`、`en.jsonc` 文件。

### 阶段一：应用信息收集与生成

1. **读取模板** `assets/app_info_tpl.jsonc`，理解每个字段的含义和约束（注释中有枚举值说明）。
2. **分析用户输入**，从自然语言中提炼可推断的字段（如应用名称、场景类型）。
3. **识别缺失信息**，对照模板字段逐一检查，列出所有无法从用户输入推断的字段。
4. **向用户提问补全**，使用 `AskUserQuestion` 工具批量提问：
   - 版本类字段：给出当前 LTS 版本供选择，其他通过用户输入
   - 枚举类字段（部署模式等）：列出所有可选值
   - 数值类字段（节点数等）：给出常见取值范围
   - 场景类字段：支持多选，覆盖主要调优方向
5. **生成 `app_info.jsonc`**：以 `assets/app_info_tpl.jsonc` 为模板，替换字段值，**保留所有注释**。

#### app_info_tpl.jsonc 字段说明

```jsonc
{
    "application": {
        "name": "应用名称（如 Redis/Spark/MySQL）",
        "version": "应用版本（细化到开源版本最小粒度，如 6.2.23 而非 6.X）",
        "deployment": {
            "mode": "部署模式：standalone / cluster / active-active / active-standby",
            "nodeCount": "节点数量"
        }
    },
    "scenario": {
        "name": "场景名称（如 缓存Cache / OLTP / Batch / Streaming）",
        "description": "场景描述（从用户输入的调优场景提炼）"
    }
}
```

#### 提问规则

- 版本号：**禁止接受 6.X 等粗粒度版本**，需细化到最小发布版本；给出当前 LTS 版本作为选项
- 部署模式：standalone / cluster / active-active / active-standby 四选一
- 调优方向：支持多选（吞吐量/性能、内存优化、延迟优化、持久化/可靠性等）
- 每次最多 4 个问题，单轮完成所有缺失字段收集

### 阶段二：环境信息分析

1. **读取阶段零采集生成的 `env_info.jsonc`**，提取关键硬件/系统维度：

| 维度 | 关键字段 | 影响调优方向 |
|------|---------|-------------|
| CPU | architecture / cores / threadsPerCore / frequencyMHz / cache | 调度器粒度、IO线程数、并发模型 |
| 内存 | totalGB / type | maxmemory范围、overcommit、碎片整理 |
| 存储 | device / type(SSD/HDD) / capacityGB | 持久化策略、fsync频率、压缩 |
| 网络 | interfaces / bandwidthMbps / latencyMs | TCP backlog、连接队列、TIME_WAIT |
| 系统 | os.name/version/kernel | 内核参数版本范围、特性可用性 |
| 容器 | containerRuntime / orchestrator | 资源限制、命名空间隔离 |

2. **匹配应用版本与内核版本**，确定参数的 `version` 范围：
   - System 参数：根据 `kernel` 版本设定上下限（如 kernel 5.10 → version: [["4.0","5.12"]]）
   - 应用参数：根据 `app_info.version` 设定上下限（如 Redis 6.2 → version: [["6.2","7.2"]]）

3. **读取 `references/param_System_base.yaml`**（System 基础参数全量库），按以下规则过滤出当前环境适用的 System 参数候选集：

   **过滤条件一：内核版本匹配**
   - 提取 `env_info.jsonc` 中的 `kernel` 版本（如 5.10）
   - 遍历 `param_System_base.yaml` 中每个参数的 `version` 字段：
     - `version` 为 `[]`（空数组）→ 表示无版本限制，**保留**
     - `version` 为 `[["4.0","latest"]]` → 内核版本 ≥ 4.0 即匹配，**保留**
     - `version` 为 `[["4.0","5.12"]]` → 内核版本在 [4.0, 5.12] 区间内才匹配，**保留**；否则**排除**
     - `version` 为 `[["5.0","latest"]]` → 内核版本 ≥ 5.0 才匹配，**保留**；否则**排除**
   - **版本比较规则**：以主版本号.次版本号比较（如 5.10 > 5.0，5.10 < 5.12），`latest` 表示无上限

   **过滤条件二：应用适配性筛选**
   - 根据 `app_info.jsonc` 中的 `application.name`，从候选集中筛选与该应用相关的 System 参数：
     - Redis/MySQL/Kafka 等数据库/缓存类 → 保留内存管理(vm.*)、网络栈(net.*)、IO 调度、文件系统参数
     - Spark 计算类 → 保留调度器(kernel.sched_*)、内存管理(vm.*)、网络栈(net.*)参数
     - 具体应用关联的 System 参数参见各应用参考文件（`references/<应用>.md`）中的 System 参数建议
   - 排除与应用场景无关的参数（如 Redis 单机缓存场景无需 `kernel.numa_balancing`，除非部署模式为 cluster）

   **过滤条件三：场景相关性筛选**
   - 根据 `app_info.jsonc` 中的 `scenario.name` 和调优方向，进一步筛选候选集：
     - 吞吐量/性能方向 → 保留网络栈、IO 调度、调度器参数
     - 内存优化方向 → 保留 vm.swappiness / vm.dirty_ratio / vm.overcommit_memory / vm.max_map_count / transparent_hugepage 参数
     - 延迟优化方向 → 保留网络栈低延迟参数（tcp_fin_timeout / tcp_tw_reuse / scheduler / nr_requests）
     - 持久化/可靠性方向 → 保留 vm.dirty_ratio / vm.dirty_background_ratio / vm.dirty_writeback_centisecs / IO 调度参数
   - 被排除的参数不进入最终输出

   **过滤条件四：TOP-N 影响力筛选**
   - 在过滤条件一~三筛选后的候选集中，排除所有 `immutable` 类型的参数（immutable 参数单独处理，不占用 TOP-N 名额）
   - 按调优场景下参数对性能的**影响权重**从高到低排序，仅保留 TOP 参数
   - **最多不超过 10 个**可调参数（`immutable` 参数不计入此限制）
   - 影响权重判断依据：参数对场景核心指标的直接影响程度（如吞吐量场景中 `net.core.somaxconn` 权重高于 `vm.stat_interval`）

   **常见场景 TOP 参数参考**（供排序参考，实际以应用+硬件+场景综合判断）：

   | 调优方向 | TOP 参数（示例，按权重降序） |
   |---------|---------------------------|
   | 吞吐量/性能 | net.core.somaxconn, net.ipv4.tcp_max_syn_backlog, net.ipv4.tcp_congestion_control, vm.swappiness, scheduler, nr_requests, read_ahead_kb, net.core.rmem_max, net.core.wmem_max, net.ipv4.tcp_tw_reuse |
   | 内存优化 | vm.swappiness, vm.dirty_ratio, vm.dirty_background_ratio, vm.overcommit_memory, vm.max_map_count, transparent_hugepage_mode, vm.min_free_kbytes, vm.watermark_scale_factor, vm.vfs_cache_pressure, vm.zone_reclaim_mode |
   | 延迟优化 | net.ipv4.tcp_fin_timeout, net.ipv4.tcp_tw_reuse, scheduler, nr_requests, net.ipv4.tcp_keepalive_intvl, net.core.busy_read, net.ipv4.tcp_slow_start_after_idle, net.ipv4.tcp_syn_retries, net.core.somaxconn, transparent_hugepage_khugepaged_defrag |
   | 持久化/可靠性 | vm.dirty_ratio, vm.dirty_background_ratio, vm.dirty_writeback_centisecs, vm.dirty_expire_centisecs, scheduler, nr_requests, read_ahead_kb, queue_depth, vm.swappiness, vm.overcommit_memory |

   **过滤结果**：得到适用于当前环境的 System 参数候选集（可调参数 ≤ 10 个 + immutable 参数），进入阶段三进行 suggestion/default 填充

### 阶段三：参数模板生成

1. **读取 `assets/param_tpl.yaml`**，理解单参数字段结构：

```yaml
- name: "参数名称"
  ptype: "immutable|uniform_int|uniform_float|categorical"  # 参数类型
  upper: 0          # 最大值（uniform_int/uniform_float 生效，含边界）
  lower: 0          # 最小值（uniform_int/uniform_float 生效，含边界）
  suggestion: ""    # 建议值（当前场景下的推荐值）
  choices: []       # 可选值（仅 categorical 和 immutable 生效，yaml 格式列表）
  enable: True      # 是否启用
  default: ""       # 默认值
  version:          # 版本范围 [下限, 上限]
    - - "4.0"
      - "5.12"
```

2. **ptype 类型说明**：

| ptype | 适用场景 | 生效字段 |
|-------|---------|---------|
| `immutable` | 当前场景下有唯一确定取值、无调优空间 | suggestion（固定值） |
| `uniform_int` | 整数范围调优 | upper / lower / suggestion |
| `uniform_float` | 浮点数范围调优 | upper / lower / suggestion |
| `categorical` | 枚举值选择 | choices / suggestion |

3. **生成两层参数**：

**System 层（内核/系统参数）— 基于阶段二过滤结果填充**：
- 取阶段二过滤后的 System 参数候选集（可调参数 ≤ 10 个 + immutable 参数，已通过四重过滤）
- 对候选集中每个参数进行填充：
  - `enable`：从 `False` 改为 `True`（base 文件中默认全为 `False`，过滤后需启用）
  - `suggestion`：根据硬件规格 + 应用场景综合判断，填充推荐值
  - `default`：填充参数的系统默认值
  - `version`：保留 base 文件中的原始版本范围（已通过版本匹配过滤）
  - `upper`/`lower`/`choices`：保留 base 文件中的原始值，无需修改
- 对候选集中符合 immutable 判定条件的参数，按 immutable 规则处理（见步骤 5），这些参数不占用 10 个可调参数的名额
- **不在候选集中的参数不输出**

**应用层（以应用类型决定具体参数）**：
- 根据应用名称（Redis/MySQL/Spark/Kafka 等）生成该应用特有的调优参数
- 根据场景类型（缓存/OLTP/批处理/流处理）调整参数方向
- 根据硬件规格调整参数取值范围

4. **参数取值规则**：
   - `suggestion`：当前场景下的最佳推荐值，基于硬件规格+应用场景综合判断
   - `upper`/`lower`：合理调优范围，suggestion 必须在 [lower, upper] 区间内
   - `default`：参数的系统/应用默认值
   - 数值参数需做单位换算（如内存 GB→MB→bytes，缓存 KB→MB）

5. **immutable 判定规则**：

将以下参数标记为 `immutable`（当前场景一定无需调优）：

| 判定条件 | 示例 |
|---------|------|
| 应用运行的硬性要求，其他值会导致功能异常 | Redis 的 vm.overcommit_memory=1（fork 需要） |
| 依赖参数已关闭/固定，子参数不生效 | AOF 关闭后 appendfsync / auto-aof-rewrite-* 不生效 |
| 数据安全/完整性要求，应始终开启 | rdbchecksum=yes / rdbcompression=yes |
| 自适应机制，无理由关闭 | dynamic-hz=yes |
| 场景特性决定，无调优空间 | 缓存场景 stop-writes-on-bgsave-error=no（数据可丢失） |
| 标准协议行为，非应用调优焦点 | tcp_timestamps=1 |

**immutable 参数处理**：
- `ptype` 设为 `"immutable"`
- `upper` / `lower` 设为 `0`
- `choices` 设置为固定值，如  - "yes"
- `suggestion` 设为固定值
- `enable` 保持 `True`

### 阶段四：输出与验证

1. **生成 `param.yaml`**，结构为：
```yaml
System:
  params:
    - name: "..."
      # ... 参数字段
Redis:  # 应用名称作为 key
  params:
    - name: "..."
      # ... 参数字段
```

2. **验证清单**：
- [ ] 每个参数包含完整字段（name/ptype/upper/lower/suggestion/choices/enable/default/version）
- [ ] uniform_int/uniform_float 参数的 suggestion 在 [lower, upper] 范围内
- [ ] categorical 参数的 suggestion 在 choices 列表中
- [ ] immutable 参数的 upper=0, lower=0, choices=[]
- [ ] version 范围与实际环境/应用版本匹配
- [ ] 参数分组有注释说明（用 # 分隔不同类别）
- [ ] app_info.jsonc 保留了模板注释

## 应用参数参考（按需加载）

参数参考文件按应用类型独立存放于 `references/` 目录，根据 `app_info.jsonc` 中的 `application.name` **按需加载**对应文件。System 基础参数全量库存放于 `references/param_System_base.yaml`，在阶段二统一加载并过滤。

### 参考文件索引

| 类型 | 参考文件 | 版本范围 | 涵盖场景 |
|------|---------|---------|---------|
| System 基础 | `references/param_System_base.yaml` | kernel 4.0 ~ latest | 调度器/内存/网络/IO/大页/电源 |
| Redis | `references/redis.md` | 6.2 ~ 7.2 | 缓存 / 持久化 / 消息队列 |
| MySQL | `references/mysql.md` | 5.7 ~ 8.0 | OLTP / OLAP / HTAP |
| Spark | `references/spark.md` | 3.0 ~ 3.5 | Batch / Streaming / SQL / MLlib |
| Kafka | `references/kafka.md` | 2.8 ~ 3.6 | 消息队列 / 事件流 / 日志收集 |

### 加载规则

1. **阶段一**生成 `app_info.jsonc` 后，读取 `application.name` 字段
2. 在 `references/` 目录中查找 `<应用名称>.md` 文件
3. 若文件存在 → 加载该文件，获取该应用的参数清单、场景适配表、immutable 判定参考
4. 若文件不存在 → 提示用户该应用暂无内置参考，需要根据应用官方文档手动补充参数清单
5. 加载后结合 `scenario.name` 匹配对应场景，选择该场景下的调优方向
6. **阶段二**读取 `references/param_System_base.yaml`（System 基础参数全量库），按内核版本 + 应用适配 + 场景相关性三重过滤（详见阶段二步骤 3），得到 System 参数候选集

### 参考文件结构

每个参考文件包含以下标准结构：

| 章节 | 说明 |
|------|------|
| **场景适配** | 列出该应用的常见场景、调优方向、关键差异 |
| **参数清单** | 按功能分类的参数表格（参数名 / ptype / 说明 / default / 建议范围） |
| **immutable 判定参考** | 该应用在特定场景下的 immutable 参数及判定原因 |

## 注意事项

- **版本粒度**：应用版本必须细化到开源版本最小粒度（如 6.2.23 而非 6.X），提问时给出 LTS 版本供选择
- **注释保留**：生成 app_info.jsonc 时必须保留 `assets/app_info_tpl.jsonc` 中的所有注释
- **单位换算**：硬件信息中的单位需要正确换算（如内存 GB→bytes 用于 maxmemory 参数，CPU L3 缓存 KB→MB）
- **版本范围**：参数的 version 字段需与实际环境匹配，不要超出内核/应用支持范围
- **System 参数过滤**：System 参数从 `references/param_System_base.yaml` 过滤得出，不手动编写；过滤条件依次为内核版本匹配→应用适配性→场景相关性→TOP-N 影响力筛选（可调参数 ≤ 10），被过滤掉的参数不输出；immutable 参数不占用 10 个名额
- **场景适配**：相同应用在不同场景下参数方向不同（如 Redis 缓存场景关闭 AOF，持久化场景开启 AOF）
- **immutable 谨慎**：只有"当前场景一定无需调优"的参数才标记 immutable，有调优空间的保留可调状态
- **环境采集前置**：阶段零的环境采集必须在阶段二之前完成；若 `env_info.jsonc` 已存在可跳过采集
- **输出目录**：所有生成文件默认输出到当前工作目录（PWD），可通过 `--output-dir` 参数指定其他目录；`app_info.jsonc` 和 `param.yaml` 由 AI 助手直接写入工作空间
- **SSH 免密**：远程节点采集需预先配置 SSH 免密登录，否则 `remote_exec.sh` 会报错退出
- **脚本兼容性**：`collect_env.sh` 使用 `set -eu`（非 `pipefail`），若以 sh 执行会自动切换到 bash
- **内存类型检测**：`collect_env.sh` 中 dmidecode 解析使用 `^[[:space:]]*Type:` 模式，避免匹配错误纠正字段
