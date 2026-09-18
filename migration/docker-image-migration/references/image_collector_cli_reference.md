# image-migration 命令参考

本文档定义 `./ai-migration image-migration` 各子命令的参数、输出格式与字段说明。

- 采集流程与执行环境选择见 [image_reconstruction.md](references/image_reconstruction.md) 阶段 1.4
- x86_64 远程采集机环境准备见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)
- 采集边界、环境依赖与 Registry 读取优先级见本文「采集边界」「环境依赖」「Registry 读取优先级与 history 采集来源」节

## 目录

- [工具定位](#工具定位)
- [脚本能力与执行位置分类](#脚本能力与执行位置分类)
- [采集边界](#采集边界)
- [环境依赖](#环境依赖)
- [通用约定](#通用约定)
- [1. collect-x86 / collect 子命令 — 镜像 manifest/history 采集](#1-collect-x86--collect-子命令--镜像-manifesthistory-采集)
- [2. analyze 子命令 — 采集结果分析与打包](#2-analyze-子命令--采集结果分析与打包)
- [3. env 模块 — 容器环境信息采集（x86_64 采集机独立运行）](#3-env-模块--容器环境信息采集x86_64-采集机独立运行)
- [4. Registry 读取优先级与 history 采集来源](#4-registry-读取优先级与-history-采集来源)
- [5. diff 子命令 — 业务镜像与基础镜像环境差异分析](#5-diff-子命令--业务镜像与基础镜像环境差异分析)
- [6. ARM64 + 远程 x86_64 拆分采集流程](#6-arm64--远程-x86_64-拆分采集流程)
- [子命令速查表](#子命令速查表)

---

## 工具定位

> **所有采集/分析命令执行前必须完成本步**，否则命令将因找不到可执行文件而失败。

`ai-migration` 是镜像采集与分析的**预编译可执行文件**（非 Python 脚本），所有子命令通过 `ai-migration image-migration <subcommand>` 调用。ARM 工具包（`DevKit-AI-Migration-Tool-<version>-Linux-Kunpeng`）和 x86 工具包（`...-Linux-x86-64`）在 **ARM64 主控端**和 **x86_64 采集机**上的定位顺序为：优先检查 DevKit 安装目录 `/opt/huawei/devkit`（经 RPM 安装的 DevKit 会把工具包解压到此），无则放置在**工作目录**中，采集相关代码已随二进制嵌入 `_internal/`。**不存在** 可直接运行的 `collect.py`、`analyze.py` 等 Python 脚本文件，禁止尝试用 `python3` 直接运行任何采集/分析/扫描命令。

按以下顺序定位工具包目录（在对应机器上执行）：

```bash
# 1. 优先检查 DevKit 安装目录（经 RPM 安装的 DevKit 会把工具包解压到此）
ls /opt/huawei/devkit/DevKit-AI-Migration-Tool-*/ai-migration

# 2. 工作目录下定位
ls <工作目录>/DevKit-AI-Migration-Tool-*/ai-migration
```

定位成功后，将 `AI_MIGRATION_DIR` 记录到 `TASK_CTX`（工具包目录的绝对路径），后续所有命令中的 `./ai-migration` 替换为 `${AI_MIGRATION_DIR}/ai-migration`。`/opt/huawei/devkit` 与工作目录均无工具包时，按以下优先级获取工具包到工作目录：

1. **本机下载**：本机网络正常时，从 `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}` 下载对应架构工具包（ARM64 用 `DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-Kunpeng`，x86_64 用 `...-Linux-x86-64`）并解压到工作目录。版本号与下载基址在 `config_reference.md` §9 集中维护；
2. **从另一台机器下载后传输**：本机网络不可用时，由网络正常的另一台机器下载后 scp 传到本机工作目录；
3. **请求用户上传或提供路径**：两台机器网络均不可用、且 `/opt/huawei/devkit` 与工作目录均无工具包时，**暂停并交互式请求用户**上传工具包或提供已有路径，未确认前不得继续执行。

> x86_64 采集机的工具包获取详细步骤见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md) 步骤 2/2.1。下载属系统环境变更，执行前须按 SKILL.md「系统环境变更确认」原则请求用户确认。

---

## 脚本能力与执行位置分类

| 脚本能力                                       | 需要运行 x86_64 容器                                        | 执行位置      | 调用方式                                       |
| ---------------------------------------------- | ----------------------------------------------------------- | ------------- | ---------------------------------------------- |
| manifest + history 采集（x86_64 镜像，主流程） | 否（Registry 元数据 + 本地 docker history，后者需本地镜像） | x86_64 采集机 | `./ai-migration image-migration collect-x86`   |
| manifest + history 采集（registry 备选）       | 否（Registry 元数据查询，跨架构可用）                       | ARM64 主控端  | `./ai-migration image-migration collect`       |
| layer 采集（env 模块）                         | **是**（`docker run` 运行目标容器）                         | x86_64 采集机 | `./ai-migration image-migration env`           |
| inspect 扫描（layout 模块）                    | **是**（`docker run` 运行目标容器）                         | x86_64 采集机 | `./ai-migration image-migration layout`        |
| 分析（analyze 模块）                           | 否（纯 Python JSON 处理）                                   | ARM64 主控端  | `./ai-migration image-migration analyze`       |
| diff 分析                                      | 否（纯 Python JSON/XLSX 处理）                              | ARM64 主控端  | `./ai-migration image-migration diff`          |
| 镜像名映射（get-safe-name）                    | 否（纯 Python 文件名处理）                                  | x86_64 采集机 | `./ai-migration image-migration get-safe-name` |

> **⚠️ 关键区分 — ARM64 主控端 vs x86_64 远程采集机**：
>
> - **ARM64 主控端**：`analyze` / `diff` 统一通过 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用；`collect` 仅在 registry 可达、仅需 manifest+registry history 时作为备选用。
> - **x86_64 远程采集机**：`collect-x86`（manifest + history）、`env`（layer 采集）、`layout`（inspect 扫描）、`get-safe-name`（镜像名映射）统一通过 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用。
>
> 两端均**禁止** 用 `python3` 直接运行采集/分析脚本（禁令见上方「工具定位」，不存在可直接运行的 `.py`）。
>
> **主流程**：x86→ARM 迁移的目标镜像是 x86_64 镜像，manifest + history + layer 全部在 x86_64 采集机采集（`collect-x86` 采 manifest+history，`env` 采 layer），ARM64 主控端只做 `analyze`/`diff`。ARM64 端 `collect` 仅在 registry 可达、仅需 registry 元数据时作为备选。

---

## 采集边界

| 数据文件        | 主要用途                                 | 是否可能触发 `docker pull`                                   | ARM64 主机上的默认行为                                       |
| --------------- | ---------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `manifest.json` | 记录镜像架构、OS、基础配置、layer digest | 通常不会；buildx/skopeo/manifest inspect 从 registry 读取；仅在策略 D 兜底下读本地信息 | 正常尝试采集                                                 |
| `history.json`  | 记录可见构建层和历史命令                 | 通常不会；**仅来自 registry 元数据**（buildx/skopeo，跨架构可用），不依赖本地镜像 | 正常尝试采集（registry 可查即可）                            |
| `layer.json`    | 记录容器内包、运行时、文件和环境信息     | 可能会；通常需要先拉取镜像并运行容器                         | `collect` 不采集 layer；须通过 `ai-migration image-migration env` 在 x86_64 采集机执行后回传 |
| `diff.json`     | 记录业务镜像相对基础镜像的差异           | 不会单独触发 pull（依赖已有采集结果）                        | 由 `analyze` 子命令生成；若缺少 `layer.json`，通常不生成     |

说明：`collect`/`collect-x86` 子命令返回成功不代表每个文件都成功生成。自动化调用方必须读取 `_collect_summary.json` 与各镜像的 `_status.json` 判定真实结果，不能只看命令退出码或压缩包是否存在。

## 环境依赖

### ARM64 主控端

| 依赖                      | 要求                                                         |
| ------------------------- | ------------------------------------------------------------ |
| Docker CLI/daemon         | 必需；Registry 认证复用 `docker login` 凭据                  |
| `ai-migration` 可执行文件 | 必需；统一命令入口，子命令格式 `./ai-migration image-migration <subcommand>` |
| Docker Buildx             | 建议安装；优先获取 manifest 与 history                       |
| `skopeo`                  | 可选的 Registry 读取备选                                     |
| `openpyxl`                | 仅 `diff` 子命令需要                                         |

### x86_64 采集机（仅远程采集时需要）

完整的环境要求表和自动配置流程见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)。

需要 `layer.json` 时，须在可运行源镜像的 x86_64 主机通过 `ai-migration image-migration env` 执行。

---

## 通用约定

| 约定项       | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| 命令前缀     | 文档中 `./ai-migration image-migration` 为简写，执行前须替换为 `${AI_MIGRATION_DIR}/ai-migration image-migration`；定位方法见上方「工具定位」 |
| 可执行文件   | `ai-migration`（统一入口），子命令格式 `ai-migration image-migration <subcommand>` |
| Docker 依赖  | `collect` / `diff` 均需 Docker CLI / daemon 可用             |
| 日志输出     | 所有日志输出到 stderr，结果 JSON 输出到文件或 stdout         |
| 镜像列表格式 | 每行一个镜像名，`#` 开头为注释，空行忽略                     |
| 安全文件名   | 镜像名中的 `:` `/` `\` 空格及 `<>                            |

---

## 1. collect-x86 / collect 子命令 — 镜像 manifest/history 采集

manifest + history 有两个采集子命令，按目标镜像架构选择：

| 子命令        | 执行位置                    | 适用场景                            | history 来源                                                 |
| ------------- | --------------------------- | ----------------------------------- | ------------------------------------------------------------ |
| `collect-x86` | **x86_64 采集机**（主流程） | 目标镜像是 x86_64 镜像              | registry 元数据 + 本地 `docker history`（策略 D 在 x86 上对 x86 镜像可用，history 完整） |
| `collect`     | ARM64 主控端（备选）        | registry 可达、仅需 registry 元数据 | registry 元数据（buildx/skopeo，跨架构可用，不依赖本地镜像） |

> x86→ARM 迁移的目标镜像通常为 x86_64 镜像，**主流程用 `collect-x86` 在 x86_64 采集机采集 manifest + history**；`env` 也在同一台 x86_64 机器采集 layer，故 manifest+history+layer 全在 x86 采集机完成，ARM64 主控端只做 `analyze`。ARM64 端 `collect` 仅在 registry 可达、仅需 registry 元数据时作为备选。

### 1a. collect-x86（x86_64 采集机，主流程）

**命令**：`${AI_MIGRATION_DIR}/ai-migration image-migration collect-x86`（在 x86_64 采集机上执行）

**作用**：在 x86_64 采集机上采集 x86_64 镜像的 manifest + history。ARM64 机器无法 `docker pull` / `docker history` x86_64 镜像（架构不匹配），而 x86_64 采集机上策略 D（`docker image inspect` + `docker history`）天然可用，history 采集完整。

**参数**：

| 参数                       | 必填         | 类型          | 默认值            | 说明                                                         |
| -------------------------- | ------------ | ------------- | ----------------- | ------------------------------------------------------------ |
| `--mode`                   | 是           | enum          | —                 | `base`=基础镜像，`biz`=业务镜像                              |
| `images` / `--images-file` | 是（二选一） | string / path | —                 | 位置参数镜像名（可多个）/ 镜像列表文件                       |
| `--output`                 | 否           | path          | `./collector_out` | 输出根目录                                                   |
| `--workers`                | 否           | positive_int  | `4`               | 并发数                                                       |
| `--skip-docker`            | 否           | flag          | —                 | 跳过需本地 Docker daemon 的策略，仅用 skopeo（Docker daemon 不可用时） |

> **镜像输入与 `layout` 对齐**：`images` 为位置参数（可指定多个），`--images-file` 读取列表文件（每行一个，`#` 注释）。与 ARM `collect` 的 `--image`/`--list` 不同，二者不通用。

**输出结构**（与 ARM `collect` 一致，供 `analyze` 消费）：每个镜像一个子目录，含 `manifest.json` / `history.json` / `_status.json`，根目录 `_collect_summary.json`。

### 1b. collect（ARM64 主控端，备选）

**命令**：`./ai-migration image-migration collect`

**作用**：在 ARM64 主控端采集 manifest + history。**history 仅来自 registry 元数据**（buildx/skopeo，跨架构可用，不依赖本地镜像）；本地兜底策略（`docker image inspect`）只返回 manifest，不提供 history。

### collect 通用参数（ARM 备选版）

| 参数                 | 必填         | 类型          | 默认值            | 说明                            |
| -------------------- | ------------ | ------------- | ----------------- | ------------------------------- |
| `--mode`             | 是           | enum          | —                 | `base`=基础镜像，`biz`=业务镜像 |
| `--image` / `--list` | 是（二选一） | string / path | —                 | 单镜像名 / 镜像列表文件         |
| `--output`           | 否           | path          | `./collector_out` | 输出根目录                      |
| `--workers`          | 否           | positive_int  | `4`               | 并发数                          |

### 退出码与结果判定（两个子命令一致）

| 退出码 | 含义                                                         |
| ------ | ------------------------------------------------------------ |
| `0`    | 全部镜像至少获得了 manifest（但个别镜像可能缺少 history 或 layer） |
| `1`    | 全部镜像采集失败（无任何镜像获得 manifest）                  |
| `2`    | 部分镜像采集失败（有镜像未获得 manifest）                    |

> **重要**：退出码为 `0` 不代表每个镜像、每项数据都采集成功。必须读取 `_collect_summary.json` 与各镜像的 `_status.json` 判定真实结果，不能只看退出码。

`_status.json` 示例：

```json
{
  "image": "registry.example.com/team/app:v1",
  "safe_name": "registry.example.com_team_app_v1",
  "got_layer": false,
  "got_history": true,
  "got_manifest": true
}
```

> `safe_name` 字段即该镜像产物子目录名，Skill 可直接读取此字段定位 `manifest.json` / `history.json` / `layer.json`，无需自行实现镜像名到安全文件名的映射。

### 架构限制

ARM64（aarch64）主控端的 `collect` 只能采 registry 元数据（manifest + registry history），无法采 x86_64 镜像的本地 history（架构不匹配）。对 x86_64 镜像需完整 history 时，用 x86_64 采集机的 `collect-x86`。layer 采集须在 x86_64 采集机上通过 `ai-migration image-migration env` 执行后回传。

---

## 2. analyze 子命令 — 采集结果分析与打包

**命令**：`./ai-migration image-migration analyze`

**作用**：对 `collect-x86`/`collect` 采集的 manifest/history/layer 数据执行分析与打包。本命令运行在 ARM64 主控端，在采集产物（manifest/history 来自 x86_64 采集机的 `collect-x86`，layer 来自 `env`）回传后调用。

**典型流程（主流程，x86_64 采集机采集）**：

1. x86_64 采集机 `collect-x86` 采集 manifest + history
2. x86_64 采集机 `env` 采集 layer.json，manifest/history/layer 一并 scp 回传 ARM64
3. ARM64 端 `analyze` 分析 + 打包

完整拆分采集流程见下方 [6. ARM64 + 远程 x86_64 拆分采集流程](#6-arm64--远程-x86_64-拆分采集流程)。

### 参数

| 参数                 | 必填 | 类型          | 默认值 | 说明                                                         |
| -------------------- | ---- | ------------- | ------ | ------------------------------------------------------------ |
| `--mode`             | 是   | enum          | —      | `base`=建立基础镜像索引，`biz`=差异分析                      |
| `--output`           | 是   | path          | —      | `collect` 的输出目录（必须已存在）                           |
| `--base-output`      | 否   | path          | —      | biz 模式：基础镜像结果目录（用于 diff）                      |
| `--image` / `--list` | 否   | string / path | —      | 用于汇总的镜像名（未指定则自动从输出目录扫描 `_status.json`） |

### analyze 行为

1. **刷新 `_status.json`**：根据 `layer.json` 实际存在情况更新 `got_layer`（若 `layer.json` 已回传，`got_layer` 更新为 `true`）
2. **运行 Analyzer**：`run_base`（生成 `_base_index.json`）或 `run_biz`（生成 `diff.json`）
3. **写 `_collect_summary.json`**：包含更新后的采集状态和分析结果
4. **打包 tar.gz**

### 退出码与结果判定

| 退出码 | 含义                     |
| ------ | ------------------------ |
| `0`    | 命令正常结束             |
| `1`    | 输出目录不存在或分析失败 |

---

## 3. env 子命令 — 容器环境信息采集（x86_64 采集机运行）

**命令**：`./ai-migration image-migration env`

**作用**：采集容器内环境变量 / OS / 系统包 / 多语言运行时等 14 大类环境信息，输出为 `layer.json`。

**调用方式**：在 x86_64 采集机上运行。

```bash
# x86_64 采集机上运行
${AI_MIGRATION_DIR}/ai-migration image-migration env --image <image> --output /tmp/layer.json
${AI_MIGRATION_DIR}/ai-migration image-migration env --image <image> --output /tmp/layer.json --timeout 300
```

> env 模块的默认单容器超时为 120 秒，可通过 `--timeout` 参数控制。

### 参数

| 参数            | 必填 | 类型         | 默认值 | 说明                                                |
| --------------- | ---- | ------------ | ------ | --------------------------------------------------- |
| `--image, -i`   | 是   | string       | —      | Docker 镜像名                                       |
| `--output, -o`  | 否   | path         | stdout | 输出 JSON 文件路径（默认写 stdout）                 |
| `--timeout, -t` | 否   | positive_int | `120`  | 单容器超时秒数                                      |
| `--memory, -m`  | 否   | string       | `512m` | 容器内存限制（如 `1g`, `2g`），大镜像可增大避免 OOM |
| `--pretty, -p`  | 否   | flag         | —      | 输出缩进格式化 JSON                                 |

> **已知限制**：多行值（含换行的 ENV）会被截断为第一行，受影响的变量在 `layer.json` 的 `image_env` 中表现为值不完整，分析时需注意。输出 JSON 中包含 `_env_truncation_warning` 字段标记此限制。

### 退出码

| 退出码 | 含义                                                         |
| ------ | ------------------------------------------------------------ |
| `0`    | 采集成功，状态为 `ok`                                        |
| `1`    | 采集失败（容器运行失败、超时、OOM 等）                       |
| `2`    | 部分成功（容器运行成功但 JSON 解析失败，输出文件包含 `parse_error` 和部分原始数据） |

### 采集内容（14 大类）

| 类别      | 主要字段                                             |
| --------- | ---------------------------------------------------- |
| 环境变量  | `image_env`（过滤掉 PWD/OLDPWD/SHLVL 等）            |
| OS 信息   | `os.name`, `os.version`, `os.id`, `os.pretty_name`   |
| 系统包    | `packages.manager`（dpkg/rpm/apk）, `packages.list`  |
| C/C++     | `c_cpp.gcc`, `gxx`, `clang`, `cmake`, `libc_type`    |
| Go        | `go.version`, `goroot`, `go_mod`, `cgo_enabled`      |
| Java      | `java.java_version`, `maven`, `gradle`, `build_file` |
| Python    | `python.python3`, `pip`, `installed_packages`        |
| Ruby      | `ruby.ruby`, `gem`, `bundler`, `gemfile`             |
| Rust      | `rust.rustc`, `cargo`, `cargo_toml`                  |
| Node.js   | `nodejs.node`, `npm`, `yarn`, `package_file`         |
| 源码信息  | `source_code.repo_url`, `commit_id`, `github_url`    |
| PHP       | `php.php`, `composer`, `project_file`                |
| .NET/C#   | `.net.dotnet`, `nuget`, `project_file`               |
| 其他语言  | `other_languages`（perl/lua/swift/erlang/...）       |
| 构建工具  | `build_tools`（make/cmake/protoc/bazel/...）         |
| 关键 C 库 | `c_libs`（libssl/libsqlite3/zlib/...）               |

---

## 4. Registry 读取优先级与 history 采集来源

manifest / history 按以下顺序尝试：

1. `docker buildx imagetools inspect --format '{{json .}}'`（manifest + history，来自 registry 元数据）；
2. `skopeo inspect docker://<image>`（manifest + history，来自 registry 元数据）；
3. `docker manifest inspect <image>`，只保证 manifest；
4. `docker image inspect`（本地兜底，**仅 manifest**）。

> **history 采集来源**：`history.json` 仅由策略 1/2 从 registry 元数据提取（跨架构可用，不需本地镜像）；本地兜底策略 4 只返回 manifest。因此当镜像只能走策略 4（registry 不可达、仅本地有镜像）时不生成 `history.json`，`_status.json` 的 `got_history=false`。`analyze`/`diff` 用 `load_json` 读 `history.json`，文件缺失返回 `None` 并安全跳过，不影响 manifest 分析与打包。
>
> `collect-x86` 在 x86_64 采集机上策略 D 可读取本地 `docker history`（x86 对 x86_64 镜像可用，history 完整），这是 `collect-x86` 相对 ARM 端 `collect` 的增量；ARM 端 `collect` 的 history 仅来自 registry 元数据。

layer 采集独立于上述顺序：在 x86_64 主机上，镜像不在本地时会先尝试 `docker pull`。

**调用方式**：history 采集由 `collect`/`collect-x86` 子命令自动完成，**无独立 history 子命令入口**。如需采集构建历史，请直接使用对应子命令。

---

## 5. diff 子命令 — 业务镜像与基础镜像环境差异分析

**命令**：`./ai-migration image-migration diff`

**作用**：基于 XLSX 表格中记录的基础/业务镜像关系，读取 `collect` 产出的 `layer.json`，从业务镜像中减去基础镜像已有的内容，输出按语言分类的结构化差异结果。适用于基础/业务镜像关系已在 XLSX 表格中人工标注的场景；大多数迁移流程只需使用 `analyze --mode biz` 即可获取差异结果。

**前置条件**：

- 业务镜像与基础镜像已通过 `collect` 子命令完成采集
- XLSX 表格已按指定列格式准备
- `openpyxl` 已安装

### 参数

| 参数                | 必填   | 默认值                                                    | 说明                                                      |
| ------------------- | ------ | --------------------------------------------------------- | --------------------------------------------------------- |
| `--xlsx / -x`       | 否     | `$XLSX_FILE` 或 `./image_analysis_table.xlsx`             | XLSX 表格路径                                             |
| `--json-dir / -j`   | **是** | `$JSON_INPUT_DIR`                                         | `collect` 产出目录（布局 `<dir>/<safe_name>/layer.json`） |
| `--output-dir / -o` | 否     | `$OUTPUT_DIR` 或 `./diff_env_out`                         | 输出目录                                                  |
| `--registry-prefix` | 否     | `$REGISTRY_PREFIX` 或 `registry.example.com/custom_prod/` | 内部仓库前缀                                              |

> `--json-dir`（或环境变量 `JSON_INPUT_DIR`）为必填项，未指定时命令将报错退出。

### XLSX 表格列格式

| 列名             | 说明                            |
| ---------------- | ------------------------------- |
| `是否为基础镜像` | 值为"是"或"否"                  |
| `容器名称`       | 容器名（用于基础镜像索引 key）  |
| `基础镜像`       | 基础镜像名（"否"行需填写）      |
| `语言类型`       | 语言分类（如 Python/Java/Go）   |
| `原版镜像名称`   | 镜像全名（与 collect 输入一致） |
| `GitHub URL`     | 代码仓库地址                    |
| `备注`           | 补充说明                        |

### 输出结构

```text
<output-dir>/
  <language>/
    <safe_image_name>.json
```

### 示例

```bash
# 使用默认 xlsx 路径和环境变量指定 json-dir
export JSON_INPUT_DIR=./collector_out
./ai-migration image-migration diff

# 显式指定所有参数
./ai-migration image-migration diff \
  --xlsx ./image_analysis_table.xlsx \
  --json-dir ./collector_out \
  --output-dir ./diff_env_out \
  --registry-prefix registry.example.com/custom_prod/
```

> `diff` 依赖 `openpyxl`，调用前请确保环境已安装该依赖。若未安装，须按 SKILL.md「系统环境变更确认」原则请求用户确认后方可执行 `pip3 install openpyxl`，不得自行静默安装。

---

## 6. ARM64 + 远程 x86_64 拆分采集流程

ARM64 + 远程 x86_64 采集机环境下采用"采集→回传→分析"的流程：manifest + history + layer 全部在 x86_64 采集机采集，回传 ARM64 后 `analyze`。

> **按需优化**：`collect-x86` 与 ARM 端 `collect` 的策略 A/B（buildx/skopeo）都从 registry 元数据采 manifest + history，**内容等价**；`collect-x86` 的增量价值仅在 registry 不可达、镜像仅本地可用时（策略 D）补采本地 `docker history`。因此：
>
> - 默认（下方流程）用 `collect-x86` 一次采全，避免 ARM/x86 各采一半再合并的复杂度。
> - 若 ARM 端 buildx/skopeo 已能返回完整 history、且无需本地 history（如只需 manifest + registry history 即可推进迁移），可省略步骤 1 的 `collect-x86` 跨机采集，直接在 ARM64 主控端用 `collect` 采集 manifest + registry history（更轻、不触发 x86 的 `docker pull`），仅步骤 2 的 layer 仍须在 x86 采集。
> - 判定依据：先在 ARM 端 `collect` 试采，若 `_status.json` 的 `got_history=true` 且后续阶段不依赖本地 history，即满足省略条件；若 `got_history=false` 且迁移需要 history，再回退到 `collect-x86`。

> 远程采集机环境准备（SSH/Docker 检查、工具包定位）见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)。
> 下例中 `${X86_AI_MIGRATION_DIR}` 为 x86_64 采集机上的工具包目录，`${AI_MIGRATION_DIR}` 为 ARM64 主控端的工具包目录。

```bash
# ── 步骤 1：x86_64 采集机采集 manifest + history（collect-x86，目标镜像须先 docker pull 到 x86 本地） ──
ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
  --mode base <image> --output /tmp/collect_<project>"
# 回传 manifest + history 采集产物到 ARM64 主控端
scp -r <user>@<host>:/tmp/collect_<project> \
  arm_builds_<date>/analysis/<project>
# 清理远程临时产物（不删除工具包目录）
ssh <user>@<host> "rm -rf /tmp/collect_<project>"

# ── 步骤 2：x86_64 采集机采集 layer ──
ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration env \
  --image <image> --output /tmp/layer_<project>.json"
# 回传 layer 采集产物到 ARM64 主控端
scp <user>@<host>:/tmp/layer_<project>.json \
  arm_builds_<date>/analysis/<project>/<safe_image_name>/layer.json
# 清理远程临时产物
ssh <user>@<host> "rm -f /tmp/layer_<project>.json"

# ── 步骤 3：ARM64 端分析 + 打包（刷新 _status.json，运行 Analyzer，写汇总和打包） ──
${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
  --mode base --output arm_builds_<date>/analysis/<project>

# ── inspect 扫描（按需触发，见 references/image_reconstruction.md 1.7） ──
ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration layout \
  <image> --mode full --depth 3 --output /tmp/layout_<project>.json --pretty"

# 回传 inspect 结果
scp <user>@<host>:/tmp/layout_<project>.json \
  arm_builds_<date>/analysis/<project>/<safe_image_name>/layout.json

# 清理远程临时产物
ssh <user>@<host> "rm -f /tmp/layout_<project>.json"
```

> 远程清理时只删除采集输出文件（如 `/tmp/layer_<project>.json`、`/tmp/layout_<project>.json`），**不要删除脚本目录**，后续 `inspect`（阶段 1.7）和 `docker cp`（阶段 3）仍需使用。

---

## 子命令速查表

| 子命令          | 命令                                                         | 核心用途                                                     | 执行位置      | Skill 阶段                                                   |
| --------------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------- | ------------------------------------------------------------ |
| `collect-x86`   | `${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 --mode <base\|biz> <image> --output <dir>` | x86_64 镜像 manifest+history 采集（含本地 history，**主流程**） | x86_64 采集机 | image_reconstruction 阶段 1.4                                |
| `collect`       | `./ai-migration image-migration collect --mode <base\|biz> --image <image> --output <dir>` | manifest+registry history 采集（registry 备选）              | ARM64 主控端  | image_reconstruction 阶段 1.4（备选）                        |
| `analyze`       | `./ai-migration image-migration analyze --mode <base\|biz> --output <dir>` | 采集结果分析（索引/diff）+ 打包                              | ARM64 主控端  | image_reconstruction 阶段 1.4（采集回传后执行）              |
| `diff`          | `./ai-migration image-migration diff --xlsx <xlsx> --json-dir <dir>` | 基于 XLSX 表格的业务镜像与基础镜像环境差异分析               | ARM64 主控端  | 按需调用（XLSX 驱动场景）；大多数场景使用 `analyze --mode biz` 内置 diff 即可 |
| `env`           | `./ai-migration image-migration env --image <image> --output <file>` | 容器环境信息采集（14 大类）                                  | x86_64 采集机 | x86_64 远程采集 layer.json                                   |
| `layout`        | `./ai-migration image-migration layout <image> --mode <rebuild\|normal\|full> ...` | 镜像内部结构精细扫描                                         | x86_64 采集机 | image_reconstruction 阶段 1.7                                |
| `get-safe-name` | `./ai-migration image-migration get-safe-name --scan-dir <dir>` | 镜像名→安全文件名映射                                        | x86_64 采集机 | 批量采集时辅助获取 safe_name                                 |

> **history 采集**：`collect-x86`（x86_64 采集机，主流程）的 history 来自 registry 元数据 + 本地 `docker history`（x86 对 x86 镜像可用，完整）；ARM 端 `collect` 的 history 仅来自 registry 元数据。**无独立 history 子命令**。详见上方第 4 节。

> **layout 模块前置条件**：目标镜像**必须已存在于本地**（`docker image inspect <image>` 可查到）。layout 模块不会自动拉取镜像。如果镜像不在本地，需先 `docker pull <image>` 后再执行 layout。