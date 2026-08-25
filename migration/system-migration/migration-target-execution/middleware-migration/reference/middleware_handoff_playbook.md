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

## 单任务处理器脚本约定

- 每个接管项一个处理器分支
- 脚本需 `chmod +x`
- 失败项返回非 0，成功返回 0，不得静默跳过
- 交 `run_handoff.sh <handoff.json> <处理器脚本>` 执行
