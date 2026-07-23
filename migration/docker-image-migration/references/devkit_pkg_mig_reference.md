## 1. 可用性检查与安装决策

先做工具定位（由 Skill 自动执行），不要让用户手动查下载路径：

```bash
# 1) 优先查 PATH
DEVKIT_BIN="$(command -v devkit 2>/dev/null || true)"

# 2) PATH 未命中时，自动查常见安装目录
if [ -z "$DEVKIT_BIN" ]; then
  DEVKIT_BIN="$(find /opt /usr/local -maxdepth 8 -type f -name devkit 2>/dev/null | head -1)"
fi

# 3) 对候选路径做版本校验
[ -n "$DEVKIT_BIN" ] && "$DEVKIT_BIN" --version
```

判定规则：

- 找到可执行 `devkit` 且 `--version` 成功：直接进入第 2 节扫描。
- 未找到或版本校验失败：不得跳过扫描，必须先给出安装决策。

建议使用以下决策模板：

```text
question: "未在系统中检测到 DevKit，如何继续 pkg-mig 扫描？"
options:
  - id: download
    label: "由 Skill 自动下载安装 DevKit"
  - id: provide_path
    label: "我知道路径，手动提供 DevKit 安装路径"
  - id: abort
    label: "中止当前扫描"
```

按决策执行：

- `provide_path`：使用用户提供路径再次执行 `--version`；失败则回到决策步骤。
- `download`：仅在用户明确授权后执行 1.1 的自动安装流程，并记录下载来源、版本、校验结果与安装日志。
- `abort`：终止当前扫描流程，并在报告中写明中止原因与影响范围。

安装约束：

- 只在 `aarch64` 主机执行安装；x86 主机不执行安装动作。
- 安装前必须确认来源可信；若组织要求校验和/签名，先校验再安装。
- 安装属于有副作用操作，必须在报告中记录版本、命令、结果与失败证据。

### 1.1 自动下载安装方式（`download` 分支）

下载源参考（不硬编码版本）：

- `https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit/`
- 动态匹配最新 `DevKit-CLI-*-Linux-Kunpeng.tar.gz`

推荐方式：优先执行脚本，不要手动拆步骤。脚本负责参数校验、重试、完整性检查、解压和 `--version` 验证。

```bash
WORK_DIR="<WORK_DIR>" \
  bash $SKILL_DIR/source-migration-scan/scripts/devkit-download.sh
```

执行约定：

1. 在 `bash` 中执行，`WORK_DIR` 通过环境变量传入。
2. 读取 stdout 末行 `DEVKIT=<path>` 作为 `DEVKIT` 可执行路径。
3. 仅当退出码为 `0` 才继续；非 `0` 必须先处理异常，不得直接进入扫描。

退出码处置（对齐参考实现）：

- `0`：成功，继续第 2 节扫描。
- `1`：环境或参数异常（如 `WORK_DIR`/依赖命令缺失），修复后重试一次。
- `2`：镜像站不可达或未匹配到 CLI 包，回到决策步骤（`provide_path` / `download` / `abort`）。
- `3`：下载失败或文件不完整，清理残文件后重试；仍失败回到决策步骤。
- `4`：解压失败，删除损坏包后重试一次；仍失败回到决策步骤。
- `5`：包结构异常（未找到 `devkit`），回到决策步骤。
- `6`：`devkit --version` 验证失败，检查架构与动态库；仍失败回到决策步骤。
- `7`：写入路径文件失败，检查权限和磁盘后重试。

变量传播：若后续步骤在新 shell 执行，需从 `$WORK_DIR/reports/devkit_path.txt` 重新读取并 `export DEVKIT`。

自动安装成功后，回到第 1 节执行“版本校验通过 → 进入第 2 节扫描”。

规范文件名为 `devkit_pkg_mig_reference.md`；旧拼写文件仅作为兼容跳转保留。

## 2. 结构化扫描

```bash
mkdir -p /tmp/pkg_mig_reports
devkit porting pkg-mig \
  -i <JAR_WAR_ARCHIVE_or_DIR> \
  -t openeuler22.03 \
  -r json \
  -l 3 \
  -o /tmp/pkg_mig_reports
```

| 参数 | 含义 |
|---|---|
| `-i` | 单个 JAR/WAR/EAR、目录或 `.zip`/`.tar.gz` 归档 |
| `-t` | 目标操作系统；示例使用 `openeuler22.03`，实际任务应与目标环境一致 |
| `-r json` | 输出 JSON，供 Agent 解析 |
| `-l 3` | 使用当前流程约定的报告等级，减少非关键输出 |
| `-o` | 报告输出目录 |

Agent 解析 `dependency_packages → porting_level → bin_detail_info`，至少读取 `is_aarch64`、`path_ext`、`type`、`libname` 和可用的 `so_info`。

## 3. DevKit 不可用时的 fallback

fallback 只提供 ELF/JAR 初筛，不等价于 DevKit 完整报告。结果必须保留 `file` 或归档列表证据。

```bash
# 扫描目录中的 ELF/静态库；使用括号避免 find -o 优先级歧义
find <resource_path> -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.a' \) \
  -exec file {} + | grep -Ev 'ARM aarch64|symbolic link|ASCII|directory'

# 检查 Java 归档内的 native 文件和平台目录
unzip -l <path>.jar | grep -Ei '\.(so|dll|dylib)(\.|$)|linux|x86_64|aarch64|arm64'
```

| 证据 | 初筛结论 |
|---|---|
| `x86-64`、`x86_64`、`80386` | 存在 x86 native 依赖，需要替换、重编译或失败判定 |
| `ARM aarch64` | 文件架构与 ARM64 一致，仍需构建和运行验证 |
| 未发现 native 文件 | 记录“手动初筛未发现”，不得写成 DevKit 判定“已兼容” |

## 4. 报告字段与决策

JSON 关键结构示例：

```json
{
  "dependency_packages": {
    "<jar-name>": [
      {
        "porting_level": {
          "5": {
            "amount": 1,
            "bin_detail_info": [
              {
                "is_aarch64": false,
                "path_ext": ["eclipse.so"],
                "type": "JAR",
                "libname": "libname.jar"
              }
            ]
          }
        }
      }
    ]
  }
}
```

| `is_aarch64` | `path_ext` | 处理 |
|---|---|---|
| `true` | 任意 | 工具判定兼容；保存报告并继续运行验证 |
| `false` | 含 native 路径 | 按功能影响选择 ARM64 替代、源码重编译或失败 |
| 缺失/无法解析 | 任意 | 标记待确认；不得推断兼容 |

常见结果文本仅作为辅助，不替代 JSON 字段：

| 中文 | English | 使用方式 |
|---|---|---|
| `可兼容` | `Adaptable for Compatibility` | 保留工具证据并继续验证 |
| `待确认` | `To Be Confirmed` | 需要进一步检查 native 文件 |
| `已兼容` | `Compatible` | 仍需构建与运行验证 |
| `不兼容` | `Incompatible` | 进入替换、重编译或失败分支 
