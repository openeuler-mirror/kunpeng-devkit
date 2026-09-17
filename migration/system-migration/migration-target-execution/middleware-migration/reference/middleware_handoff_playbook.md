# Agent 接管诊断手册

`middleware-migration.md` 中 Agent 接管规则第 1 步"按 `exit_code` 分流"的实现细节。主文档保留规则骨架，本文件承载诊断字段与分流动作。

> 注意：本文 `exit_code` 均指 handoff 清单单项的 `exit_code` 字段（取值 1 / 10），与 `run_migration.sh` 的进程退出码（0 / 1 / 2 / 3）是两套不同的码。

## handoff 项 `exit_code` 字段分流

### exit_code=10（已安装并恢复配置，未通过启动验证）

安装已完成，直接补齐 systemd 服务注册、依赖顺序（如 `After=`/`Requires=`）与服务启动验证，不再排查"为什么没装"。

### exit_code=1（通用流程安装失败）

只用 `diagnostics` 以下字段定位根因：

| 字段 | 用途 |
|------|------|
| `diagnostics.service_journal` | `journalctl -u <svc>` 输出，查服务启动报错 |
| `diagnostics.service_status` | `systemctl status` 输出，查 Active/退出码 |
| `diagnostics.deploy_dir_listing` | 部署目录文件清单，查文件缺失/属主 |

常见根因：运行用户权限、日志/数据目录属主、端口占用、包缺失。

## 采集制品路径

按清单 `source_dir` 对应组件，从采集包以下路径恢复配置到目标部署目录：

- `details/artifacts/configs/...` — 主配置制品
- `configs/supplemental/...` — 补充配置制品

## 目标机最小核对命令

仅当第 1、2 步信息不足时才执行，查完即修复并启动验证：

| 核对项 | 命令 |
|--------|------|
| 系统仓库包是否已装 | `rpm -q <pkg>` |
| 当前服务状态 | `systemctl is-active/is-enabled <svc>` |
| 端口监听 | `ss -ltn` / `nc -z <host> <port>` |

## 闭环路径约定

闭环必须经 `run_handoff.sh`，二选一。两种模式都禁止"操作后不登记就跳过汇总"；闭环以 `middleware-agent-handoff-result.json` 为准。

### 直接操作模式（推荐：单 item 或需多轮观察）

- Agent 直接在目标机操作（边做边观察边修）
- 每完成一项立即登记：
  `run_handoff.sh record <handoff.json> <item-index> --exit-code <N> [--log <path>] [--note "<说明>"]`
- 失败项 `--exit-code` 非零，成功返回 0，不得静默跳过
- 建议把关键命令 `tee` 到 per-item 日志文件，作为 `--log` 引用以便审计
- 全部登记完自动 finalize；也可显式 `run_handoff.sh finalize <handoff.json>`
- `item-index` 可传数字（如 `0`）或规范名（如 `item-0000`），脚本自动归一化

### 脚本载体模式（推荐：多 item / 批量同类 / 危险操作需可重放）

- 每个接管项一个处理器分支
- 脚本需 `chmod +x`
- 失败项返回非 0，成功返回 0，不得静默跳过
- 交 `run_handoff.sh <handoff.json> <处理器脚本>` 执行
