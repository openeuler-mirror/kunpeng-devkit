# 中间件迁移

读取 `MIGRATION_PLAN_PATH` 指向的 `migration-plan.json` 的 `route.middleware`，逐项完成中间件迁移并输出原生汇总结果。

## 入口

`run_migration.sh` 等全部 `.sh` 脚本（含 `scripts/lib/common.sh`、`scripts/run_handoff.sh`）均部署在 DevKit 工具包内（预检按 plan 的 `migration_tools` 下载解包，完整路径见下方命令）；本仓库 `middleware-migration/` 只维护 `scripts/lib/*.py`、`config/`、`reference/`（见文末"本仓库维护文件"），运行前复制到包内对应位置：

```bash
MW_PKG_DIR="$MIGRATION_WORK_DIR/tools/unpacked/<devkit_id>/expanded/<devkit_pkg>/toolscript/migration-target-execution/middleware-migration"
REPO_MW_DIR="<执行skill的工作区根目录>/migration/system-migration/migration-target-execution/middleware-migration"  # 即当前skill检出的仓库根目录
cp "$REPO_MW_DIR"/scripts/lib/*.py "$MW_PKG_DIR/scripts/lib/"
cp -r "$REPO_MW_DIR"/config "$MW_PKG_DIR"/
cp -r "$REPO_MW_DIR"/reference "$MW_PKG_DIR"/
bash "$MW_PKG_DIR/scripts/run_migration.sh" "$MIGRATION_PLAN_PATH"
```

`<devkit_id>` 取自 plan（`migration_tools` 中声明 `ai-migration` 的 DevKit 包 `id`）；`<devkit_pkg>` 为该包解压后的顶层目录名（`ls "$MIGRATION_WORK_DIR/tools/unpacked/<devkit_id>/expanded/"` 取唯一顶层目录）；`MIGRATION_WORK_DIR` 由主 Skill 的 `python3 <migration-target-execution>/scripts/migration_plan.py work-dir --plan "$MIGRATION_PLAN_PATH"` 解析（返回 `<migration_work_dir>/<migration_id>`，与预检一致）。调用方只需传入 `migration-plan.json`，内部脚本完成解析、排序（JDK 优先）、安装、配置恢复、服务切换与验证、汇总。详细策略见 `config/middleware_registry.json`。

## 执行时序（必须遵守）

`run_migration.sh` 退出后，按退出码决定后续动作，**不得跳过任一步骤**：

| 退出码 | 含义 | 必须执行的后续动作 |
|---|---|---|
| 0 | 全部成功 | 流程结束 |
| 1 | 存在失败项且无 handoff、无阻塞 | 读 `batch_migration_summary.json` 排查，按需重试 |
| 2 | 冲突待确认或 License 阻塞 | 读 `middleware-action-required.json`，向用户确认后重跑 |
| 3 | 有 Agent 接管项 | **必须**执行 `run_handoff.sh` 补完（见下方"迁移失败与 Agent 接管"） |

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

### 迁移失败与 Agent 接管

迁移流程分两类：已登记中间件走专属脚本（`scripts/migrate_*.sh`，路径标记 `REGISTERED`），未登记中间件走通用兜底流程（`scripts/migrate_generic.sh`，路径标记 `GENERIC`）。任一流程未能完整完成（安装失败，或已安装但无法确定启动方式／未通过服务验证）时，脚本生成 `middleware-agent-handoff.json` 清单，交由 Agent 用自身能力在目标机补完迁移（安装/启动/验证）；Agent 接管后仍无法解决才报最终失败。License 阻塞（exit 20）与 `REGISTERED` 路径的 exit 10（成功带警告）不进接管清单。

Agent 接管**必须**遵守：不改动 `scripts/` 下脚本与 `config/` 下配置（迁移流程不修改、Agent 接管亦不修改），仅在目标机操作产物目录、systemd 服务与配置文件。

Agent **必须**调用 `scripts/run_handoff.sh` 补完接管项并汇总结果（完整命令由 `run_migration.sh` 退出码 3 时在 stderr 的 `[NEXT]` 指令给出，可先用 `--dry-run` 查看接管项摘要），不得将其视为可选步骤或自行手动处理接管项。`run_handoff.sh` 支持两种闭环模式，见下方第 4 条。

#### Agent 接管项处理规则（硬性约束，必须逐条遵守）

接管阶段只消费 `middleware-agent-handoff.json`、采集包配置制品和目标机现状三类信息。**禁止**为了"弄懂怎么迁移/怎么启动"而去阅读 `scripts/**` 与 `config/middleware_registry.json` 的实现源码；迁移逻辑与启动策略由脚本和清单承载，不属于 Agent 补完所需的推断材料。

按以下固定顺序执行，顺序不可颠倒，也不得跳过：

1. **只读 `middleware-agent-handoff.json` 的 `reason`、`exit_code`、`diagnostics` 定位根因**，按 `exit_code` 分流（诊断字段与分流动作详见 `reference/middleware_handoff_playbook.md`）。
2. **恢复配置只从采集包取**：按清单 `source_dir` 对应组件的采集制品恢复到目标部署目录（目录取自清单 `deploy_dir` 字段，勿自行推断）。**禁止**用 `find`/`glob` 重新搜索同名文件，禁止用目标机已存在文件反推配置。
3. **仅当第 1、2 步信息不足时才查目标机现状**，且只允许最小核对（系统包是否已装、服务状态、端口监听）。查完即修复并启动验证，不再追问无关信息。
4. **闭环必须经 `run_handoff.sh`**，二选一：
   - **直接操作模式**（推荐用于单 item 或需多轮观察的修复）：Agent 用自身能力在目标机操作（边做边观察边修），每完成一项立即调
     `run_handoff.sh record <handoff.json> <item-index> --exit-code <N> [--log <操作日志路径>] [--note "<一句话说明>"]`
     登记；全部登记完自动 finalize 生成 `middleware-agent-handoff-result.json`。操作日志建议把关键命令 `tee` 到 per-item 文件并作为 `--log` 引用，以便审计。
   - **脚本载体模式**（推荐用于多 item、批量同类修复或需可重放审计的危险操作）：产出单任务处理器脚本交
     `run_handoff.sh <handoff.json> <处理器脚本>` 执行，处理器脚本接收单项 JSON 路径为唯一参数，`exit 0` 视为成功。
   两种模式都禁止"操作后不登记就跳过汇总"；闭环以 `middleware-agent-handoff-result.json` 为准。

## 输出

以下路径均相对于 `MIGRATION_WORK_DIR`（即 `$MIGRATION_WORK_DIR/middleware/reports/...`）：

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

## 本仓库维护文件

```text
scripts/
└── lib/
    ├── transform_plan.py     # 将 migration-plan.json 转换为内部统一格式，含产品名标准化
    └── registry_query.py     # registry 查询工具，解析 middleware_registry.json
config/
└── middleware_registry.json  # 中间件登记与迁移策略
reference/
    ├── middleware_handoff_playbook.md  # Agent 接管项诊断与分流手册
    └── middleware_issues.md            # 已知问题与排查
tests/
└── verify_lib.py            # 仓库侧脚本离线验证（不复制进 DevKit 包）
```
