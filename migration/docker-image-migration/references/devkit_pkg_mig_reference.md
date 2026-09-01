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
- 未找到或版本校验失败：不得跳过扫描，也不得直接进入第 3 节 fallback，必须先完成可用性留档并按主机架构分支处置。

**可用性结论必须留档**（写入阶段记录，fallback 与报告均需引用）：

```text
DEVKIT_CHECK_HOST_ARCH=$(uname -m)
DEVKIT_BIN=<可执行路径> | not_found
not_found 时必须写明原因：x86_64 主机禁止安装 / 未部署 / 版本校验失败
```

主机架构分支：

- `aarch64` 主机未找到：使用以下决策模板让用户选择，不得自行假定。
- `x86_64` 主机未找到：安装约束禁止在 x86 主机安装，**不进入安装决策**；记录 `DEVKIT_BIN=not_found（x86_64 主机，安装约束禁止）` 后直接进入第 3 节 fallback，并在报告标注“手动初筛，建议在 aarch64 主机补扫 pkg-mig”。用户主动提供可用路径时，`--version` 校验通过可直接进入第 2 节。

决策模板（仅 aarch64 主机）：

```text
question: "未在系统中检测到 DevKit，如何继续 pkg-mig 扫描？"
options:
  - id: provide_path
    label: "我知道路径，手动提供 DevKit 安装路径"
  - id: abort
    label: "中止当前扫描"
```

按决策执行：

- `provide_path`：使用用户提供路径再次执行 `--version`；失败则回到决策步骤。
- `abort`：终止当前扫描流程，并在报告中写明中止原因与影响范围。

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

对 1.4 命中的每个归档/JAR/RPM 候选分别执行并记录 JSON 输出路径；JSON 路径必须回填到决策表与报告的 `evidence_source`（如 `devkit-pkg-mig:/tmp/pkg_mig_reports/<name>.json`），不得只记录结论文本。

## 3. DevKit 不可用时的 fallback

**进入条件**：仅当第 1 节可用性检查已留档（`DEVKIT_BIN=not_found + 原因`），或工具执行失败（记录失败命令与退出码）时，才允许使用本节；不得未经检查直接进入。

fallback 只提供 ELF/JAR 初筛，不等价于 DevKit 完整报告，三条硬性要求：

1. 归档必须**先解压**，再对解压出的 `.so` / `.a` / ELF 逐个执行 `file`；`file` 输出是唯一判定证据。
2. `unzip -l` / `tar -t` 列表以及文件名、路径、目录名中的架构关键词**只能用于定位候选，不得单独作为兼容/不兼容结论**。
3. 结果必须保留证据，报告中标注“手动初筛”，并注明“建议在 aarch64 主机补扫 pkg-mig”。

```bash
# 1) 定位候选：目录中的 ELF/静态库（使用括号避免 find -o 优先级歧义）
find <resource_path> -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.a' \) \
  -exec file {} + | grep -Ev 'ARM aarch64|symbolic link|ASCII|directory'

# 2) 定位候选：归档内的 native 文件和平台目录（仅筛选，不作判定）
unzip -l <path>.jar | grep -Ei '\.(so|dll|dylib)(\.|$)|linux|x86_64|aarch64|arm64'

# 3) 解压后逐个 file，输出才可作为判定证据
mkdir -p /tmp/pkg_extract
unzip -o -j <path>.jar '<上一步定位到的 native 路径>' -d /tmp/pkg_extract   # JAR/ZIP
tar -xzf <path>.tar.gz -C /tmp/pkg_extract                                # tar.gz
rpm2cpio <pkg>.rpm | cpio -idmv -D /tmp/pkg_extract                       # RPM
find /tmp/pkg_extract -type f -exec file {} +
```

| 证据 | 初筛结论 |
|---|---|
| `file` 输出含 `x86-64`、`x86_64`、`80386` | 存在 x86 native 依赖，需要替换、重编译或失败判定 |
| `file` 输出含 `ARM aarch64` | 文件架构与 ARM64 一致，仍需构建和运行验证 |
| 仅路径/文件名关键词命中（无 `file` 输出） | **不构成证据**；必须解压后 `file` 或在 aarch64 主机补扫 pkg-mig |
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

处理动作回写决策表与报告时，必须引用来源 JSON 路径（`evidence_source`），不得只写结论文本。

常见结果文本仅作为辅助，不替代 JSON 字段：

| 中文 | English | 使用方式 |
|---|---|---|
| `可兼容` | `Adaptable for Compatibility` | 保留工具证据并继续验证 |
| `待确认` | `To Be Confirmed` | 需要进一步检查 native 文件 |
| `已兼容` | `Compatible` | 仍需构建与运行验证 |
| `不兼容` | `Incompatible` | 进入替换、重编译或失败分支 
