# AI Migration Tool 定位与 DevKit CLI 获取

> **范围**：本文件描述阶段 4 扫描前如何获取 AI Migration Tool，以及工具就绪后如何通过其 `source-migration` 子命令获取 DevKit CLI、汇总报告和安装 KSL。Agent 不直接调用本目录下的 shell 脚本，也不使用 `python3` 调用工具包内部实现。

## 1. 两层工具的职责

源码迁移扫描涉及两个不同的工具：

| 工具 | 作用 | 典型路径/变量 |
|------|------|---------------|
| AI Migration Tool | 统一命令入口，封装 `source-migration` 的下载、报告汇总、摘要读取和 KSL 安装 | `${AI_MIGRATION_DIR}/ai-migration` |
| DevKit CLI | 实际执行 `porting src-mig` 源码扫描 | `DEVKIT`，由 `source-migration download` 输出并写入 `reports/devkit_path.txt` |

`source-migration download` **不能用于引导获取 AI Migration Tool 本身**：调用该命令前必须先定位或获取包含 `ai-migration` 的工具包。

## 2. 本地定位优先

按以下顺序查找 `ai-migration`，匹配任意已安装版本，不受下载版本配置限制：

1. 用户明确提供的 `AI_MIGRATION_DIR`，要求 `${AI_MIGRATION_DIR}/ai-migration` 存在；如缺少执行位，先尝试 `chmod +x` 后再验证。
2. Kunpeng DevKit 安装目录：`/opt/huawei/devkit/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration`。
3. 本次迁移工作目录：`$WORK_DIR/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration`。

示例检查命令：

```bash
AI_MIGRATION_BIN=""
if [[ -n "${AI_MIGRATION_DIR:-}" && -f "$AI_MIGRATION_DIR/ai-migration" ]]; then
  AI_MIGRATION_BIN="$AI_MIGRATION_DIR/ai-migration"
else
  AI_MIGRATION_BIN=$(find /opt/huawei/devkit -maxdepth 3 -type f \
    -path '*/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration' 2>/dev/null | head -1 || true)
  if [[ -z "$AI_MIGRATION_BIN" ]]; then
    AI_MIGRATION_BIN=$(find "$WORK_DIR" -maxdepth 3 -type f \
      -path '*/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration' 2>/dev/null | head -1 || true)
  fi
  [[ -n "$AI_MIGRATION_BIN" ]] && AI_MIGRATION_DIR=$(dirname "$AI_MIGRATION_BIN")
fi
```

定位成功后先验证，再写入工作目录持久化文件：

```bash
[[ -n "${AI_MIGRATION_DIR:-}" && -f "$AI_MIGRATION_DIR/ai-migration" ]] || exit 1
chmod +x "$AI_MIGRATION_DIR/ai-migration" 2>/dev/null || true
"${AI_MIGRATION_DIR}/ai-migration" source-migration --help
mkdir -p "$WORK_DIR/reports"
printf 'AI_MIGRATION_DIR=%q\nAI_MIGRATION_BIN=%q\n' \
  "$AI_MIGRATION_DIR" "$AI_MIGRATION_DIR/ai-migration" \
  > "$WORK_DIR/reports/ai_migration_path.txt"
```

验证失败不得继续阶段 4，应重新定位或请求用户提供可用工具包。

## 3. 本地找不到时的下载配置

本地定位失败后，先按默认配置自动尝试一次直链下载（下载命令自身的重试不计为多次决策），不先等待用户确认。配置名和默认值与 Docker 镜像迁移 `references/config_reference.md` 第 9 节保持一致。源码迁移不依赖 Docker Skill 文件本身，值由任务上下文或同名环境变量提供，环境变量未提供时使用以下默认值：

```bash
AI_MIGRATION_TOOL_VERSION="${AI_MIGRATION_TOOL_VERSION:-26.2.T5}"
AI_MIGRATION_TOOL_DOWNLOAD_BASE="${AI_MIGRATION_TOOL_DOWNLOAD_BASE:-https://kunpeng-repo.obs.cn-north-4.myhuaweicloud.com/Kunpeng%20DevKit}"
```

ARM64/Kunpeng 工具包 URL：

```text
${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-Kunpeng.tar.gz
```

规则：

- `AI_MIGRATION_TOOL_VERSION` 只用于拼装下载 URL；本地定位仍使用 `*` 通配。
- 先自动尝试配置版本直链；若直链、解压或校验失败，停止自动流程并向用户说明失败原因和影响，取得用户选择后再重试直链，或到 DevKit 下载门户手动选择对应架构与版本，下载后放入 `$WORK_DIR/downloads/`。
- 记录最终实际下载的文件名和版本，不要把“配置版本”误记为“实际版本”。
- 默认直链失败后，必须先取得用户选择，不能静默反复下载或跳过扫描。

下载、解压示例：

```bash
mkdir -p "$WORK_DIR/downloads"
ARCHIVE="DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-Kunpeng.tar.gz"
URL="${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/${ARCHIVE}"
TARGET="$WORK_DIR/downloads/$ARCHIVE"
curl -fL --retry 3 --connect-timeout 30 -o "$TARGET" "$URL" || exit 1
EXTRACT_ROOT="$WORK_DIR/${ARCHIVE%.tar.gz}"
tar -xzf "$WORK_DIR/downloads/$ARCHIVE" -C "$WORK_DIR"
AI_MIGRATION_BIN=$(find "$EXTRACT_ROOT" -maxdepth 3 -type f \
  -path '*/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration' | head -1 || true)
if [[ -z "$AI_MIGRATION_BIN" ]]; then
  AI_MIGRATION_BIN=$(find "$WORK_DIR" -maxdepth 3 -type f \
    -path '*/DevKit-AI-Migration-Tool-*-Linux-Kunpeng/ai-migration' | head -1 || true)
fi
[[ -n "$AI_MIGRATION_BIN" ]] || exit 1
AI_MIGRATION_DIR=$(dirname "$AI_MIGRATION_BIN")
chmod +x "$AI_MIGRATION_DIR/ai-migration" 2>/dev/null || true
"$AI_MIGRATION_DIR/ai-migration" source-migration --help
export AI_MIGRATION_DIR
mkdir -p "$WORK_DIR/reports"
printf 'AI_MIGRATION_DIR=%q\nAI_MIGRATION_BIN=%q\n' \
  "$AI_MIGRATION_DIR" "$AI_MIGRATION_BIN" \
  > "$WORK_DIR/reports/ai_migration_path.txt"
```

若当前机器无法联网，可由另一台机器下载后传输到 `$WORK_DIR/downloads/` 并在本机解压；两台机器都无法联网且本地没有工具包时，必须请求用户提供工具包路径或文件，不能跳过扫描。

## 4. `source-migration` 调用约定

工具包就绪后，所有源码迁移命令统一使用：

```bash
"${AI_MIGRATION_DIR}/ai-migration" source-migration <subcommand> [参数]
```

| 子命令 | 完整调用 | 参数含义 | 主要输出 |
|--------|----------|----------|----------|
| `download` | `"${AI_MIGRATION_DIR}/ai-migration" source-migration download --work-dir "$WORK_DIR"` | `--work-dir <DIR>`：工作目录，注入脚本的 `WORK_DIR`；CLI 未传时为 `./output` | 下载并验证 DevKit CLI；stdout 输出 `DEVKIT=<路径>`；写入 `$WORK_DIR/reports/devkit_path.txt`（文件键为 `DEVKIT_BIN`） |
| `scan` | `"${AI_MIGRATION_DIR}/ai-migration" source-migration scan "$DEVKIT_REPORT_DIR" --work-dir "$WORK_DIR"` | `$DEVKIT_REPORT_DIR`：DevKit 扫描报告目录，注入脚本的 `DEVKIT_REPORT_DIR`；`--work-dir/-w <DIR>`：摘要 JSON 和日志的工作目录，注入 `WORK_DIR`，未传时为 `./output` | `$DEVKIT_REPORT_DIR/summary.txt`、`$WORK_DIR/reports/devkit_summary.json`；无 CSV 或仅有 HTML 时返回 2 |
| `read-summary` | `"${AI_MIGRATION_DIR}/ai-migration" source-migration read-summary <FIELD> [CATEGORY] --work-dir "$WORK_DIR"` | `<FIELD>`：`rule_categories` / `categories` / `rule_detail_sample` / `all` / `has_rule` / `has`；`CATEGORY` 仅 `has` 使用；`--work-dir/-w <DIR>`：读取 JSON 所在工作目录，注入脚本的 `WORK_DIR`，未传时为 `./output` | 按字段输出摘要；`has_rule`/`has` 用 stdout 和退出码表达判断结果 |
| `install-ksl` | `"${AI_MIGRATION_DIR}/ai-migration" source-migration install-ksl --work-dir "$WORK_DIR"` | `--work-dir <DIR>`：工作目录，注入脚本的 `WORK_DIR`；CLI 未传时为 `./output` | stdout 输出 `KSL_INCLUDE`、`KSL_LIB`；写入 `$WORK_DIR/reports/ksl_path.txt` |

参数边界：`download`、`install-ksl` 不接受位置参数；`scan` 必须传报告目录；`read-summary` 必须传字段名，字段为 `has` 时还必须传类别名。AI Migration Tool 会把命令参数转换为内部脚本所需的环境变量/参数，Agent 不应绕过命令直接运行脚本。

`download` 成功后必须在后续扫描 shell 中显式恢复 DevKit 路径和动态库环境：

```bash
source "$WORK_DIR/reports/devkit_path.txt"
DEVKIT="${DEVKIT_BIN:-}"
[[ -n "$DEVKIT" && -f "$DEVKIT" ]] || exit 1
export DEVKIT
DEVKIT_BIN_DIR="$(cd "$(dirname "$DEVKIT")" && pwd)"
export LD_LIBRARY_PATH="${DEVKIT_BIN_DIR}/lib:${DEVKIT_BIN_DIR}/../lib:${LD_LIBRARY_PATH:-}"
```

`source-migration download` 是独立子进程；它内部设置的 `LD_LIBRARY_PATH` 不会自动传播到后续的 `porting src-mig` 命令。

## 5. 退出码与失败处理

- `download`：`0` 成功；`1` 参数/依赖校验；`2` 镜像站不可达或未匹配；`3` 下载失败/不完整；`4` 解压失败；`5` 未找到 `devkit`；`6` `devkit --version` 失败；`7` 路径写入失败。
- `scan`：`0` 成功；`1` 报告目录校验失败；`2` 没有 CSV，或仅有 HTML 报告；`3` CSV 表头不兼容；`4` JSON 输出失败。
- `read-summary`：`0` 成功；`1` 参数或 JSON 文件错误；`2` 字段无效；`11` Rule 类别为空；`12` 未找到指定类别；`13` awk 降级解析时 JSON 格式损坏。
- `install-ksl`：`0` 成功；`1` 环境校验；`2` 下载失败/不完整；`3` 解压失败；`4` 未找到 RPM；`5` RPM 安装失败；`6` 安装验证失败；`7` 路径写入失败。

任何非 0 退出码均不得继续后续阶段。先按错误含义检查路径、依赖、网络或权限并重试一次；仍失败则回到阶段 4 的工具获取/用户决策流程。
