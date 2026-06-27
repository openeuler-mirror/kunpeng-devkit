# DevKit CLI 包下载与安装

> **做什么**：从华为云镜像站动态匹配并下载最新 DevKit CLI 包，解压验证后输出 `DEVKIT` 路径变量。
> **何时调用**：由 [sourcecode-devkit-scan.md](sourcecode-devkit-scan.md) D.1.1 节用户选择 `download` 时，经 `read_file` 加载执行。

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | `WORK_DIR` | 主 SKILL 全局初始化的工作目录（已含 reports/downloads/build/logs/devkit） |
| 输出 | `DEVKIT` | devkit 可执行文件绝对路径，供 D.1.2 起各步骤调用 |
| 输出 | `$WORK_DIR/reports/devkit_path.txt` | 持久化记录 `DEVKIT_BIN=<路径>`，便于跨阶段复用 |
| 失败 | — | 回到 D.1.1 提问，由用户重新决策（provide_path / 手动下载 / abort） |

## 下载源

`https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit/`

华为云镜像站归档目录，可直接 `wget` 拉取（无需登录鉴权）。不硬编码版本号，从目录列表动态匹配最新 `DevKit-CLI-*-Linux-Kunpeng.tar.gz`（正则要求 `Linux-Kunpeng` 后缀，自动排除 x86-64 包）。

## 执行步骤

```bash
# 1. 准备下载目录（WORK_DIR 已由主 SKILL 全局初始化，此处仅补建本阶段所需子目录）
DOWNLOAD_DIR="$WORK_DIR/downloads"
DEVKIT_DIR="$WORK_DIR/devkit"
mkdir -p "$WORK_DIR/reports" "$DOWNLOAD_DIR" "$DEVKIT_DIR"
cd "$DOWNLOAD_DIR"

# 2. 从华为云镜像站匹配最新 CLI 包
MIRROR_BASE="https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit"
CLI_PKG=$(curl -s "$MIRROR_BASE/" \
  | grep -oE 'DevKit-CLI-[0-9][^"]*Linux-Kunpeng\.tar\.gz' \
  | sort -V \
  | tail -1)

if [ -z "$CLI_PKG" ]; then
  echo "镜像站未匹配到 DevKit-CLI 包，请检查镜像站目录结构或网络" >&2
  exit 1   # 回到 D.1.1 提问，由用户决定 provide_path / 手动下载 / abort
fi

# 3. 下载（支持断点续传；失败即回退到 D.1.1 提问）
echo "匹配到最新 CLI 包：$CLI_PKG"
if ! wget -c "$MIRROR_BASE/$CLI_PKG" -O "$DOWNLOAD_DIR/$CLI_PKG"; then
  echo "下载失败：$MIRROR_BASE/$CLI_PKG" >&2
  exit 1
fi

# 4. 解压并定位 devkit 可执行文件（清理后重新解压，确保无残留）
rm -rf "$DEVKIT_DIR" && mkdir -p "$DEVKIT_DIR"
tar -xzf "$DOWNLOAD_DIR/$CLI_PKG" -C "$DEVKIT_DIR"
DEVKIT_BIN=$(find "$DEVKIT_DIR" -type f -name "devkit" | head -1)

if [ -z "$DEVKIT_BIN" ]; then
  echo "解压后未找到 devkit 可执行文件" >&2
  exit 1
fi

# 5. 验证可执行
export LD_LIBRARY_PATH="$(dirname "$DEVKIT_BIN")/lib:$(dirname "$DEVKIT_BIN")/../lib:${LD_LIBRARY_PATH:-}"
if ! "$DEVKIT_BIN" --version; then
  echo "devkit --version 验证失败" >&2
  exit 1
fi

# 6. 设置路径：将验证通过的路径赋值给 DEVKIT 变量，继续 D.1.2
DEVKIT="$DEVKIT_BIN"
echo "DEVKIT_BIN=$DEVKIT_BIN" > "$WORK_DIR/reports/devkit_path.txt"
```

> **变量传播说明**：`DEVKIT` 在本脚本内赋值。若 D.1.2 起的步骤在另一 shell 执行，应从 `$WORK_DIR/reports/devkit_path.txt` 读取后重新 `export DEVKIT`。

## 失败处置

| 现象 | 处置 |
|------|------|
| 镜像站列不出 CLI 包 | 回到 D.1.1 提问，让用户手动提供路径或下载 |
| 下载不完整 | `wget -c` 断点续传或重新下载 |

> 若镜像站下载失败，agent 应通过 `AskUserQuestion` 提示用户手动下载安装包到 `$WORK_DIR/downloads/` 后继续。
