# 中间件迁移

读取 `MIGRATION_PLAN_PATH` 指向的 `migration-plan.json` 的 `route.middleware`，逐项完成中间件迁移并输出原生汇总结果。

## 入口

```bash
bash middleware-migration/scripts/run_migration.sh "$MIGRATION_PLAN_PATH"
```

调用方只需传入 `migration-plan.json`，内部脚本完成解析、排序（JDK 优先）、安装、配置恢复、服务切换与验证、汇总。详细策略见 `config/middleware_registry.json`。

## 执行时序（必须遵守）

`run_migration.sh` 退出后，按退出码决定后续动作，**不得跳过任一步骤**：

| 退出码 | 含义 | 必须执行的后续动作 |
|---|---|---|
| 0 | 全部成功 | 流程结束 |
| 1 | 存在失败项且无 handoff、无阻塞 | 读 `batch_migration_summary.json` 排查，按需重试 |
| 2 | 冲突待确认或 License 阻塞 | 读 `middleware-action-required.json`，向用户确认后重跑 |
| 3 | 有 Agent 接管项 | **必须**执行 `run_handoff.sh` 补完（见下方"未登记中间件与 Agent 接管"） |

退出码 3 时 `run_migration.sh` 会在 stderr 打印 `[NEXT]` 指令与完整命令，直接照执行即可。生成 `middleware-agent-handoff.json` 不代表流程结束，只有 `run_handoff.sh` 产出的 `middleware-agent-handoff-result.json` 才标志闭环完成。

## 关键约束

### 部署目录

部署目录自动推导（策略见 registry 各条目 `deploy_dir_strategy`），具体路径由脚本写入接管清单与冲突清单的 `deploy_dir` 字段，Agent 直接读取、勿自行推断；可用 `DEPLOY_DIR_<TYPE>` 环境变量覆盖（设为 `skip` 跳过该中间件目录推导）。

### 冲突检测

迁移前检测两类冲突，检测到时**必须**通过运行环境的交互式提问工具向用户提问、阻塞等待真实答复后再继续（不得跳过、以纯文本代替或自行决定覆盖/跳过）。

- **目录冲突**：目标部署目录已存在**且非空**。`overwrite` = 删除现有目录后覆盖安装，`skip` = 跳过该迁移项。（目录存在但为空目录不算冲突，直接安装）
- **服务冲突**：目标环境已存在同名 systemd 服务。`overwrite` = 备份旧 service 文件后覆盖服务注册（**不删除原服务目录和配置文件**），`skip` = 跳过该迁移项。

### 依赖

Java 中间件优先复用已迁移的目标 Java 运行时；未就绪时按 registry 声明的依赖准备。计划内若所有 Java 中间件 JDK 需求版本一致，统一使用该版本避免冲突。

### 未登记中间件与 Agent 接管

未在 `config/middleware_registry.json` 登记的中间件走通用流程（`scripts/migrate_generic.sh`）：尽力安装（解压/编译）并恢复配置。通用流程未能完整完成（安装失败，或已安装但无法确定启动方式／未通过服务验证）时，脚本生成 `middleware-agent-handoff.json` 清单，交由 Agent 用自身能力在目标机补完迁移（安装/启动/验证）。

Agent 接管**必须**遵守：不改动 `scripts/` 下脚本与 `config/` 下配置（通用流程不修改、Agent 接管亦不修改），仅在目标机操作产物目录、systemd 服务与配置文件。

Agent **必须**调用 `scripts/run_handoff.sh <handoff.json> <单任务处理器脚本>` 逐项串行补完接管项并汇总结果（可先用 `--dry-run` 查看接管项摘要）。生成 `middleware-agent-handoff.json` 后，`run_migration.sh` 以退出码 3 退出并打印 `[NEXT]` 指令；agent 必须按指令执行 `run_handoff.sh`，不得将其视为可选步骤或自行手动处理接管项。

#### Agent 接管项处理规则（硬性约束，必须逐条遵守）

接管阶段只消费 `middleware-agent-handoff.json`、采集包配置制品和目标机现状三类信息。**禁止**为了"弄懂怎么迁移/怎么启动"而去阅读 `scripts/**` 与 `config/middleware_registry.json` 的实现源码；迁移逻辑与启动策略由脚本和清单承载，不属于 Agent 补完所需的推断材料。

按以下固定顺序执行，顺序不可颠倒，也不得跳过：

1. **只读 `middleware-agent-handoff.json` 的 `reason`、`exit_code`、`diagnostics` 定位根因**，按 `exit_code` 分流（诊断字段与分流动作详见 `reference/middleware_handoff_playbook.md`）。
2. **恢复配置只从采集包取**：按清单 `source_dir` 对应组件的采集制品恢复到目标部署目录（目录取自清单 `deploy_dir` 字段，勿自行推断）。**禁止**用 `find`/`glob` 重新搜索同名文件，禁止用目标机已存在文件反推配置。
3. **仅当第 1、2 步信息不足时才查目标机现状**，且只允许最小核对（系统包是否已装、服务状态、端口监听）。查完即修复并启动验证，不再追问无关信息。
4. **必须产出单任务处理器脚本**并交给 `run_handoff.sh <handoff.json> <处理器脚本>` 执行。**禁止**在调用 `run_handoff.sh` 之前手工修改 systemd 服务、部署目录或配置文件来绕过汇总闭环。

## 输出

```text
middleware/reports/batch_migration_summary.json
middleware/reports/batch_migration_summary.md   
```

批次状态：`SUCCEEDED`（全部成功）/ `SUCCEEDED_WITH_WARNINGS`（存在警告或跳过）/ `FAILED`（至少一项失败）/ `BLOCKED`（License 未就绪，或目录/服务冲突待用户确认）。

冲突待确认时输出：

```text
middleware/reports/middleware-action-required.json
```

通用流程未完成、需 Agent 接管时输出：

```text
middleware/reports/middleware-agent-handoff.json
```

Agent 执行 `run_handoff.sh` 补完后输出（标志闭环完成）：

```text
middleware/reports/middleware-agent-handoff-result.json
```

单项失败不阻止其他可执行项，批次最终状态和退出码反映整体结果。

## 脚本说明

```text
scripts/
├── run_migration.sh          # 批量迁移入口：解析 plan、排序(JDK优先)、逐项调度、冲突预检、汇总输出
├── init_context.sh           # 初始化 SKILL_DIR/RUN_ID 等运行环境
├── migrate_jdk.sh            # JDK/JRE 迁移：安装 Java 运行时，设置 JAVA_HOME
├── migrate_javamiddleware.sh # 通用 Java 中间件迁移(Tomcat/Resin/Nacos/RocketMQ)：依赖 JDK、配置 systemd、恢复配置
├── migrate_tongweb.sh        # TongWeb 迁移：专用安装、依赖 JDK、健康检查
├── migrate_besappserver.sh   # BES AppServer 迁移：专用安装、依赖 JDK、健康检查
├── migrate_package.sh        # 通用包迁移(Nginx/Redis/ES 等)：yum/apt/源码编译、配置恢复、systemd 注册
├── migrate_generic.sh        # 兜底通用迁移：未登记产品走此脚本，尽力安装与配置恢复
├── run_handoff.sh            # Agent 接管清单调度器：逐项串行调用单任务处理器并汇总结果
└── lib/
    ├── common.sh             # 公共函数：部署目录推导、依赖管理、服务启停、冲突处理、日志等
    ├── transform_plan.py     # 将 migration-plan.json 转换为内部统一格式，含产品名标准化
    └── registry_query.py     # registry 查询工具，解析 middleware_registry.json
```
