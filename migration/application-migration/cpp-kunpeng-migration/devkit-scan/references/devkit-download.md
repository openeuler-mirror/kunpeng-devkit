# DevKit CLI 包下载与安装

> **做什么**：从华为云镜像站动态匹配并下载最新 DevKit CLI 包，解压验证后输出 `DEVKIT` 路径变量。
> **何时调用**：由 [SKILL.md](../SKILL.md) 4.1.1 节用户选择 `download` 时，经读取文件加载执行。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | `WORK_DIR` | 主 SKILL 全局初始化的工作目录（已含 reports/downloads/build/logs/devkit） |
| 输出 | `DEVKIT` | devkit 可执行文件绝对路径，供 4.1.2 起各步骤调用 |
| 输出 | `$WORK_DIR/reports/devkit_path.txt` | 持久化记录 `DEVKIT_BIN=<路径>`，便于跨阶段复用 |
| 失败 | — | 回到 4.1.1 提问，由用户重新决策（provide_path / 手动下载 / abort） |

## 下载源

`https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit/`

华为云镜像站归档目录，可直接 `wget` 拉取。不硬编码版本号，从目录列表动态匹配最新 `DevKit-CLI-*-Linux-Kunpeng.tar.gz`。

## 调用方式：优先执行脚本

agent **优先以脚本形式一次性调用** [devkit-download.sh](../scripts/devkit-download.sh)，不要逐段执行下方说明中的 bash 片段。脚本已内建参数校验、重试、完整性校验与语义化退出码。

```bash
WORK_DIR="<工作目录>" bash $SKILL_DIR/devkit-scan/scripts/devkit-download.sh
```

调用约定：

1. 通过执行 shell 命令在 `bash` 下运行；`WORK_DIR` 通过环境变量传入。
2. 捕获 stdout 末行形如 `DEVKIT=<路径>` 的输出，解析出 `DEVKIT` 变量。
3. 捕获进程退出码，按下表进行异常分支处理；只有退出码为 `0` 才视为成功。

## 退出码与异常状态处理

| 退出码 | 含义 | agent 处置 |
|--------|------|-----------|
| 0 | 成功 | 解析 stdout 的 `DEVKIT=...`，继续 4.1.2 |
| 1 | 参数/环境校验失败（`WORK_DIR` 未设置/非目录、缺少 curl/wget/tar/find/stat） | 检查 `WORK_DIR` 是否正确传递；补齐缺失命令后重试一次；仍失败则回到 4.1.1 提问 |
| 2 | 镜像站不可达或未匹配到 CLI 包 | 提示用户检查网络/代理；确认镜像站目录结构未变更；不可达时回到 4.1.1 提问，引导 provide_path / 手动下载 / abort |
| 3 | 下载失败或文件不完整（小于 1MB） | 脚本已内置 3 次重试 + 断点续传；失败后删除 `$WORK_DIR/downloads/DevKit-CLI-*.tar.gz` 让用户手动下载到该目录后重试，或回到 4.1.1 提问 |
| 4 | 解压失败 | 通常为下载包损坏。删除 `$DOWNLOAD_DIR/$CLI_PKG` 后重试一次；仍失败则回到 4.1.1 提问 |
| 5 | 解压后未找到 devkit 可执行文件 | 镜像站包结构可能变更。回到 4.1.1 提问，引导用户 provide_path 或 abort |
| 6 | `devkit --version` 验证失败 | 多为动态库缺失或架构不匹配。让用户检查 `LD_LIBRARY_PATH`、目标架构是否为 aarch64；无法解决则回到 4.1.1 提问 |
| 7 | 持久化路径写入失败 | 检查 `$WORK_DIR/reports/` 目录权限与磁盘空间后重试一次；仍失败则回退 4.1.1 提问 |

> 任何非 0 退出码均**不得**继续 4.1.2。agent 应先按上表尝试一次自愈重试，仍失败则**必须**回到 4.1.1 向用户提问让其决策（不得自行跳过）。

> **变量传播说明**：`DEVKIT` 在调用脚本的 shell 内通过 stdout 输出。若 4.1.2 起的步骤在另一 shell 执行，应从 `$WORK_DIR/reports/devkit_path.txt` 读取后重新 `export DEVKIT`。

## 失败处置

| 现象 | 处置 |
|------|------|
| 镜像站列不出 CLI 包 | 回到 4.1.1 提问，让用户手动提供路径或下载 |
| 下载不完整 | 脚本内置 `wget -c` 断点续传 + 3 次重试；仍失败则删除残文件重下 |
| 解压后结构异常 | 回到 4.1.1 提问，引导 provide_path / abort |
| `--version` 失败 | 检查 `LD_LIBRARY_PATH` 与目标架构（须 aarch64） |

> 若镜像站下载失败，agent 应**必须**向用户提问，提示用户手动下载安装包到 `$WORK_DIR/downloads/` 后继续。
