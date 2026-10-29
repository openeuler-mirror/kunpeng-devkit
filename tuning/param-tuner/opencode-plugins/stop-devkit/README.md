# stop-devkit-on-abort

opencode 服务器插件：ESC 停止当前任务时，同步终止运行中的 devkit 调优进程。

## 功能

- 监听 opencode 事件流中的 `MessageAbortedError`（对应 TUI 中按 ESC 中止任务）
- 检测到中止后立即 `pkill` 残留的 devkit 进程：`devkit kat`、`kat_python_cli`、`tuner_monitor.py`
- 避免 ESC 中止 agent 循环后，后台调优训练进程继续占用资源

## 部署

由 `install.sh` 自动复制到标准 auto-discovery 插件目录：

- 全局：`~/.config/opencode/plugins/stop-devkit-on-abort.js`
- 项目：`<project>/.opencode/plugins/stop-devkit-on-abort.js`

opencode 启动时自动加载，无需手动注册到 `opencode.json`。

## 匹配的进程模式

| 模式 | 目标 |
|------|------|
| `[d]evkit kat` | `devkit kat train/continue/set` 等子命令 |
| `[k]at_python_cli` | devkit 内部调优 CLI |
| `[t]uner_monitor.py` | 调优监控脚本 |

`[x]` 括号技巧避免 `pkill` 匹配到自身命令行。
