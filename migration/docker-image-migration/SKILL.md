---
name: docker-image-migration
description: >-
  docker-image-migration Skill 主调度文件。用于将 x86_64 Docker 镜像迁移到 linux/arm64（鲲鹏）环境，覆盖有 Dockerfile 的直接迁移与无 Dockerfile 的镜像逆向重构两类场景。负责场景选择、启动门禁、受控并发、构建与运行验证、知识沉淀及中断恢复。不适用范围：Windows 容器迁移、非 Docker 场景（裸机或 VM）、仅需人工替换单行 `FROM` 的极简任务、history 完全不可读且镜像不可运行的场景。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit


---

# Docker 镜像 X86 到 Kunpeng 迁移主控 Skill

## Skill 说明

本 Skill 用于将 x86_64 Docker 镜像迁移到 linux/arm64（鲲鹏）平台，支持两种迁移路径：

- **有 Dockerfile 场景**：基于源码和 Dockerfile 重新构建 ARM64 镜像，适用于可访问源码和构建上下文的项目
- **无 Dockerfile 场景**：基于镜像逆向分析（manifest / history / layer）重构 ARM64 Dockerfile，适用于仅能访问镜像本身的场景

核心能力包括：启动门禁（环境 / 网络 / 配置校验）、受控并发执行、构建与运行验证、失败自动修复（知识库驱动）、知识沉淀及中断恢复。

## 核心原则

- **单一事实来源**：全局调度、告警和失败规则以 `SKILL.md` 为准；场景文件只定义该场景特有的阶段和动作

- **非侵入式探测**：不在 x86_64 机器上执行系统级变更（安装系统软件、修改系统配置、改写软件源等）；需要运行 x86_64 容器的采集/扫描操作统一通过工作目录中的 `ai-migration` 预编译二进制经 SSH 远程调用（`${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>`），**不用 `python3` 直接运行脚本**；需要系统级变更时必须先获得用户明确确认

- **系统环境变更确认**：任何对宿主机（ARM64 主控端或 x86_64 远程采集机）系统环境的变更操作，**执行前必须交互式请求用户确认，未确认前不得执行**。包括但不限于：

    - 安装或升级系统软件包（`apt-get install` / `yum install` / `dnf install` / `apk add` 等）
    - 安装或升级 Python / Java / Node.js 等语言运行时
    - 修改系统配置文件（如 `/etc/apt/sources.list`、Docker daemon 配置、环境变量等）
    - 添加或修改系统用户/用户组（如 `usermod -aG docker`）
    - 启停系统服务（如 `systemctl start docker`）
    - 修改文件权限或属主（如 `chmod`/`chown` 系统目录）

  确认时须向用户展示：① 拟执行的具体命令 ② 变更影响范围 ③ 不执行的后果。用户可选择：确认执行 / 拒绝并手动处理 / 跳过（接受相应功能受限）。
  **以下操作不视为系统环境变更，无需单独确认**：Docker 容器内操作（`docker run`/`docker build`/`docker cp` 等产生的容器内变更）、Skill 工作目录下的文件读写（报告、Dockerfile、采集产物等）。

- **有证据才判定**：所有失败判定都必须附证据，失败前必须先检索 `references/build_knowledge_reference.md`

## 全局执行红线

- **阶段记录与恢复**：若已存在该任务的完整阶段记录文件，则直接跳过；若仅有中间阶段记录，则从"最后一个完整阶段"之后继续；单任务超过 `WORKER_STALL_TIMEOUT_MIN` 仍无进展，标记为 `status=FAILED` 且 `failure_reason=STALLED`。
- **并发写入边界**：任务执行器（worker/子 Agent）只能写入本任务输出文件；汇总文件与知识库统一由主 Agent 串行写入，避免并发覆盖。

## 执行质量约束

- **warning 记录最小字段**：必须记录证据位置、影响、已执行动作、后续要求；无证据不得改写
- **失败前证据最小集**：必须记录失败命令与退出码、关键日志、尝试次数、检索章节、失败理由；无证据不得改写
- **流程性失败原因**（用于门禁阶段和执行中断判定，如超时、重试超限、无进展等）：
    - `TIMEOUT`（超时）
    - `EXCEEDED_ATTEMPTS`（重试次数超限）
    - `NO_ARM64_SUPPORT`（无 ARM64 支持，需提供 manifest 或同等平台证明）
    - `STALLED`（长时间无进展）
    - `ARCH_BLOCKED`（启动门禁判定当前环境不能执行 ARM64 构建；**仅限门禁阶段使用**，不得在场景阶段执行中使用）
- **技术性失败原因**：场景阶段执行中还可能产生技术性失败原因（如 `PROPRIETARY_X86_SO`、`VERSION_INCOMPATIBILITY` 等），完整枚举见 `references/build_knowledge_reference.md` 附录「failure_reason 枚举」。报告 `failure_reason` 字段从该完整枚举中取值。

***

## 整体流程

> **迁移场景选择** → **启动门禁检查** → **操作准备** → **注入任务上下文信息** → **场景阶段执行** → **报告生成与知识沉淀**

## 迁移场景选择

**信息不足时**：必须以交互方式提示用户按"最小输入清单"补齐信息；在信息补齐前，不得推测路径、凭据或镜像标签。

最小输入清单：

- 必填：待迁移镜像（可多镜像）与目标输出镜像名 + 镜像tag
- 可选：Registry / Git / 软件源访问凭据（仅在需要认证时提供）
- 场景必填（二选一）：
    - 有 Dockerfile 场景：Dockerfile 路径 + 构建上下文路径
    - 无 Dockerfile 场景：已采集产物路径（manifest/history/layer）；若未提供采集产物，需提供可访问源镜像以便自动采集

**信息充分时**：

- 存在可访问的 Dockerfile 和源码 → 读取 `references/dockerfile_migration.md`，执行 阶段 1–5
- 无 Dockerfile，且已提供采集产物或可访问源镜像（用于自动采集）→ 读取 `references/image_reconstruction.md`，执行 阶段 1–6

场景选择优先级：若同时提供 Dockerfile/源码与采集产物，默认优先走 `references/dockerfile_migration.md`；仅在 Dockerfile 不可访问或无法形成可用构建上下文时，转入 `references/image_reconstruction.md`。

***

## 启动门禁检查

所有门禁按顺序执行，每个门禁记录「输入、检查结果、后续决策」并注入任务上下文。任一门禁未通过时不得进入后续阶段。

### 1. 输入与配置

| 检查     | 通过条件                                                     | 未通过时                                                     |
| -------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| 任务输入 | 场景已在迁移场景选择中确定，输入信息齐备                     | 请求缺失信息，不推测路径或凭据                               |
| 配置文件 | `GIT_HOSTS`、`INTERNAL_REGISTRIES`、`WORKER_COUNT` 等不含未替换的 `<...>` | 按 `references/config_reference.md` 的参数说明补齐配置后重试 |
| 隔离模式 | `AIRGAP_MODE=true` 时已配置内网源                            | 停止公网访问动作并请求补充配置                               |

> 配置参数的完整说明见 `references/config_reference.md`。

### 2. Docker、架构与磁盘

检查 Docker CLI、daemon 和构建权限，生成 `DOCKER_CTX`。检查 `uname -m`、Buildx 和 binfmt/QEMU，生成 `ARCH_COMPAT`：

| 值         | 含义                                                         |
| ---------- | ------------------------------------------------------------ |
| `full`     | ARM64 原生环境                                               |
| `emulated` | x86_64 + Buildx + QEMU                                       |
| `noemu`    | x86_64 + Buildx，但未确认 QEMU；须执行一次最小 ARM64 探测构建验证，仅当探测构建成功后方可继续 |
| `blocked`  | 当前环境不能执行 ARM64 构建                                  |

`blocked` 时的处置：

- `dockerfile_migration + blocked`：经用户确认可只执行 阶段 1–3；状态标记为 `FAILED` 且 `failure_reason=ARCH_BLOCKED`，`notes` 中注明"架构受限，仅完成阶段 1–3 分析，未执行构建与验证"。不得写成迁移成功。
- `image_reconstruction + blocked`：停止本地重构构建，提示切换到可用的 ARM64 或模拟构建机；可在当前环境继续完成采集与分析（阶段 1–2），状态标记为 `FAILED` 且 `failure_reason=ARCH_BLOCKED`，`notes` 中注明"架构受限，仅完成阶段 1–2 采集分析，未执行重构构建"。不得写成迁移成功。

对每个独立任务检查可用磁盘空间；低于 `MIN_DISK_SPACE_GB` 时按 `references/build_knowledge_reference.md` 23 节清理并复查。

### 3. Registry 与镜像源

使用 `curl` 或 Docker manifest 命令探测端点，生成 `NETWORK_CTX`：

| 响应                                              | 判定                                                         |
| ------------------------------------------------- | ------------------------------------------------------------ |
| `200` 或 `401`                                    | 可达（`401` 表示需要认证）                                   |
| `301/302`                                         | 继续验证跳转目标                                             |
| `manifest unknown` / `not found` / `name unknown` | 镜像不存在：必须暂停并交互提示用户确认镜像名和 tag，或提供替代镜像；未确认前不得继续迁移 |
| 超时 / 连接失败 / 持续 `5xx`                      | 不可达                                                       |

探测对象：Docker Hub、`INTERNAL_REGISTRIES` 以及配置中的备用镜像站。

```yaml
NETWORK_CTX:
  dockerhub_official: reachable | unreachable
  dockerhub_web: reachable | unreachable
  internal_registries: {"<registry>": reachable | unreachable}
  primary_mirror: "<url>" | null
  mirrors_checked: []
```

> 不要把镜像站路径拼接规则当作通用事实；只有在目标镜像站已验证支持该路径时才改写镜像名。

### 4. 软件包源

仅探测 Dockerfile 或采集结果实际使用的软件源，记录三种状态：`2xx/3xx`（可达）、`401/403`（受限）、不可达。遇到未列出的源时同样按此三种状态记录。

```yaml
NETWORK_CTX.package_sources:
  ubuntu: reachable | restricted | unreachable | not_used
  debian: reachable | restricted | unreachable | not_used
  ubuntu_ports: reachable | restricted | unreachable | not_used
  pypi: reachable | restricted | unreachable | not_used
  npm: reachable | restricted | unreachable | not_used
  maven: reachable | restricted | unreachable | not_used
```

> 官方源经重试仍不可达时，才按 `references/config_reference.md` 的已配置备用源替换；在执行记录中保留原始源、探测证据和替换结果。

### 5. 构建容器网络与代理

> **为什么单独探测**：宿主机和 Docker daemon 用宿主机网络栈解析 DNS，因此 `docker pull` / `docker manifest inspect` 可能正常；但 `docker build` 的 `RUN` 步骤（`pip install` / `npm install` / `apt-get`）运行在独立的容器网络命名空间，DNS 解析器（daemon.json 的 `dns`）在该命名空间的网络路径上未必可达，会导致 `Errno -3 Temporary failure in name resolution`，而 `docker pull` 仍成功。本探测用于在门禁阶段就确定构建时该用哪种网络模式与代理，避免在阶段 4/5 才发现构建容器无法出网。

**第 1 步：探测默认 bridge 网络的 DNS 是否可用**。用一个任意基础镜像（优先复用任务已 pull 的镜像，避免额外拉取）在默认网络下解析一个外部域名：

```bash
# 复用已有镜像，不指定 --network（即默认 bridge），尝试解析域名
docker run --rm <ANY_LOCAL_IMAGE> \
  sh -c 'getent hosts mirrors.aliyun.com >/dev/null 2>&1 || nslookup mirrors.aliyun.com >/dev/null 2>&1' \
  && echo BRIDGE_DNS_OK || echo BRIDGE_DNS_FAIL
```

> 选用镜像必须自带 `getent` 或 `nslookup`（Debian/Ubuntu/Alpine 均可）。若解析成功记 `BRIDGE_DNS_OK`，无需额外处理。

**第 2 步：DNS 失败时确认 `--network=host` 可恢复出网**（构建命令支持，宿主机网络已验证可达）：

```bash
docker run --rm --network=host <ANY_LOCAL_IMAGE> \
  sh -c 'getent hosts mirrors.aliyun.com >/dev/null 2>&1 || nslookup mirrors.aliyun.com >/dev/null 2>&1' \
  && echo HOST_NET_OK || echo HOST_NET_FAIL
```

- `HOST_NET_OK` → `BUILD_NET_MODE=host`，构建命令注入 `--network=host`。
- `HOST_NET_FAIL` → 宿主机 netns 也无法解析，说明环境整体断网；转「第 3 步代理探测」或按 `EXTERNAL_SERVICE` 暂停并交互提示用户。

**第 3 步：探测是否需要走代理**。仅当上述任一网络模式下「能解析域名但连接被重置/超时」、或宿主机本身只能经代理出网时执行：

```bash
# 检查宿主机是否已配置出网代理（不向用户暴露明文密码）
env | grep -iE '^(http_proxy|https_proxy|no_proxy)='
# 用探测到的代理验证连通性（代理地址需用户确认；daemon.json 的 http-proxy 只作用于 docker daemon，不注入构建容器）
curl -sS -x <proxy_url> -o /dev/null -w '%{http_code}' --max-time 10 https://mirrors.aliyun.com/pypi/simple/
```

- 探测到可用代理 → 记录 `BUILD_PROXY=<proxy_url>` 与 `BUILD_NO_PROXY`，构建时通过 `--build-arg HTTP_PROXY/HTTPS_PROXY/NO_PROXY` 注入；**代理地址必须经用户确认后方可使用**。
- 无可用代理且断网 → 暂停并交互提示用户："构建容器无法出网（DNS 解析失败且宿主机网络/代理均不可用），请提供可达的代理或修复容器网络后继续；若无法修复网络，可选择离线依赖兜底（见下）。" 未确认前不得继续。
- **离线依赖兜底（用户确认网络无法修复时启用）**：当所有网络模式与代理均不可达、且用户明确选择继续时，跳过构建容器内联网，改为在**网络可达的环境**（宿主机若可达，或具备网络的 x86_64/ARM64 机器）预下载全部依赖到构建上下文，构建时 `COPY` 注入：
    - Python：在目标架构环境 `pip download -d <build_context>/wheels -r requirements.txt`（须带 `--platform aarch64 --only-binary=:all:` 或在原生 ARM64 机执行，确保 wheel 架构匹配），Dockerfile 改 `pip install --no-index --find-links=./wheels -r requirements.txt`。
    - Node.js：在目标架构/Node 版本匹配的环境 `npm install`（见 `build_knowledge_reference.md` §8 npm 407 方案 A），`COPY node_modules` 注入。
    - 系统包（apt/yum）：优先从官方 ARM64 镜像 `docker cp` 提取 `.deb`/`.rpm` 后 `dpkg -i`/`rpm -i`，或换用已含所需包的 ARM64 基础镜像。
    - **必须标注 `WARN-OFFLINE-DEPS`**：`impact` 写明"构建容器无法出网，依赖以离线方式注入，未在构建时联网验证最新版本/完整性"，`action_required` 写明"生产部署前须在网络可达环境重新联网安装以获取最新安全补丁，或确认离线依赖版本经安全审核"。此为降级方案，不得标记为标准构建路径。

生成 `BUILD_NET_CTX`，按下表取值：

| 探测结果                          | `BUILD_NET_MODE` | `BUILD_NET_ARG`      | `BUILD_PROXY` | 说明                                   |
| --------------------------------- | ---------------- | -------------------- | ------------- | -------------------------------------- |
| `BRIDGE_DNS_OK`                   | `bridge`         | _（不传 --network）_ | 探测值或空    | 默认 bridge 网络可用，最简方案         |
| `BRIDGE_DNS_FAIL` + `HOST_NET_OK` | `host`           | `--network=host`     | 探测值或空    | 共享宿主机网络栈绕开 bridge DNS 不可达 |
| 上述任一 + 需代理                 | 同上             | 同上                 | `<proxy_url>` | 额外 `--build-arg` 注入代理            |

```yaml
BUILD_NET_CTX:
  build_net_mode: bridge | host        # 构建容器网络模式
  build_net_arg: "--network=host" | "" # 拼入 docker build 的实际参数（bridge 时为空串）
  build_proxy: "<proxy_url>" | null    # 出网代理，需用户确认；null 表示直连
  build_no_proxy: "<no_proxy>" | null  # 代理例外清单
  probe_evidence:                      # 探测证据，写入报告
    bridge_dns: ok | fail
    host_net: ok | fail | skipped
```

> **传递约定**：下游场景阶段执行 `docker build` 时，统一用 `${BUILD_NET_ARG}` 注入网络参数、用 `${BUILD_PROXY_ARGS}` 注入代理 build-arg（见 `references/build_knowledge_reference.md` §20 模板），不在场景文件中重复探测或硬编码。代理值含敏感信息时仅在 `BUILD_NET_CTX` 中记录一次，日志中可脱敏。

***

## 操作准备

门禁全部通过后，按本节完成工具定位和远程采集机准备，为场景阶段执行建立操作条件。

### 工具定位

> **所有采集/分析命令执行前必须完成本步**，否则命令将因找不到可执行文件而失败。

定位 `ai-migration` 工具包目录，将 `AI_MIGRATION_DIR` 记录到 `TASK_CTX`。工具包按「**DevKit 安装目录（`/opt/huawei/devkit`）→ 工作目录 → 本机下载 → 从另一台机器下载后传输 → 请求用户上传或提供路径**」的优先级定位与获取：先检查 DevKit 产品安装目录 `/opt/huawei/devkit` 下是否已存在工具包（经 RPM 安装的 DevKit 会把工具包解压到此），有则直接复用；无则在**工作目录**中定位；仍无则从 `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}` 下载对应架构工具包（ARM/x86，版本号取 `${AI_MIGRATION_TOOL_VERSION}`）到工作目录。版本号与下载基址在 `references/config_reference.md` §9 集中维护。ARM64 主控端和 x86_64 采集机均需完成工具包定位；`/opt/huawei/devkit` 与工作目录均无工具包、且两台机器网络均不可用时，必须暂停并交互式请求用户上传工具包或提供已有路径，未确认前不得继续执行。

> ⚠️ **所有机器禁止直接 `python3` 调用采集/分析脚本**：
>
> - ARM64 主控端和 x86_64 采集机的所有操作均统一通过 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用。**不存在** 可直接运行的 `collect.py`、`analyze.py` 等 Python 脚本，**禁止** 尝试 `python3 xxx.py` 或类似命令。

> 详细定位与获取步骤、脚本能力与执行位置分类表见 `references/image_collector_cli_reference.md`「工具定位」与「脚本能力与执行位置分类」。下载工具包属系统环境变更，执行前须按本节「系统环境变更确认」原则请求用户确认。

### x86_64 远程采集机准备

**触发条件**：仅当以下条件同时满足时执行：

1. 当前机器为 ARM64（`uname -m` = `aarch64` 或 `arm64`）
2. 迁移场景需要采集 x86_64 镜像的 manifest + history、采集 layer 或执行 inspect（ARM64 机器无法 `docker pull`/`docker history` x86_64 镜像，manifest + history 本地采集须在 x86_64 采集机执行）
3. 用户已提供 x86_64 采集机的 SSH 地址

若当前机器为 x86_64，或无需远程采集，**跳过本节**。

> x86_64 采集机需定位 x86 工具包（包含 `ai-migration` 可执行文件 + `x86_remote_collector/`），优先复用 `/opt/huawei/devkit` 安装目录，无则工作目录，仍无则下载/获取并验证后所有操作通过 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用。
>
> 环境检查（SSH/Docker/磁盘/镜像存在性）、工具包定位与获取（工作目录定位 / 下载 / 跨机传输 / 请求用户）、验证的完整步骤见 `references/x86_remote_setup_reference.md`。
>
> ARM64 + 远程 x86_64 拆分采集流程的完整命令序列见 `references/image_collector_cli_reference.md`「拆分采集流程」。

> 远程清理时只删除采集输出文件（如 `/tmp/layer_<project>.json`），**不要删除工具包目录**，后续 inspect 和 docker cp 仍需使用。

***

## 注入任务上下文信息

门禁检查与操作准备完成后，多 Agent 模式下，主 Agent 在下发任务时必须同时下发：TASK_CTX、核心原则、全局执行红线、执行质量约束；子 Agent 在进入场景阶段前必须先读取并确认这些规则，未确认前不得开始执行，执行过程中不得违背。

```yaml
TASK_CTX:
  config_path: references/config_reference.md
  ai_migration_dir: "<AI_MIGRATION_DIR>"  # ai-migration 安装目录的绝对路径（ARM64 主控端）
  x86_ai_migration_dir: "<X86_AI_MIGRATION_DIR>"  # x86_64 采集机上 ai-migration 安装目录的绝对路径，仅远程采集时存在
  x86_host: "<user>@<host>"  # x86_64 采集机 SSH 地址，仅远程采集时存在
  x86_env: {}  # x86_64 采集机环境检查结果，仅远程采集时存在；字段结构见 references/x86_remote_setup_reference.md「环境检查结果结构」
  network_ctx: "<NETWORK_CTX>"
  build_net_ctx: "<BUILD_NET_CTX>"  # 构建容器网络模式与代理，决定 docker build 的 --network 与代理 build-arg
  docker_ctx:
    docker_available: true | false
    docker_privileged: true | false
    buildkit_enabled: true | false
    arch_compat: full | emulated | noemu | blocked
  collected_data: {}  # 仅 image_reconstruction 使用
  report_dir: "<REPORT_DIR>"
```

***

## 场景阶段执行

1. 按选定场景文件的阶段顺序执行，不跨阶段写最终结论
2. 每个阶段完成后写阶段记录文件，并输出统一日志：`[{worker_id}] 阶段 {阶段} DONE target={target} elapsed={seconds}s`
3. 调度模式：
    - `WORKER_COUNT = 1`：主 Agent 串行执行所有镜像任务
    - `WORKER_COUNT >= 2`：主 Agent 启动 `WORKER_COUNT` 数量的子 Agent 并发执行，每个子 Agent 按主 Skill 的执行步骤独立完成各自分配的容器镜像迁移，并且只能写入各自任务的输出文件；汇总文件由主 Agent 在所有子 Agent 完成后串行写入
    - 当平台不支持子 Agent 时，退化为单会话顺序执行，不改变阶段顺序和阶段记录格式
4. 告警处理、重试、超时、失败判定和会话恢复统一遵守 `SKILL.md`
5. 失败判定遵循"有证据才判定"（见核心原则）；`NO_ARM64_SUPPORT` 需提供 manifest 或同等平台证明

***

## 报告生成与知识沉淀

1. **阶段内记录证据**：每个阶段完成后，记录关键命令、输出路径、失败重试信息

2. **单项目报告落盘**：任务结束立即写 `build_reports/<project>.json`，不得延后到批次结束

3. **状态一致性自检**：

    - `status=SUCCESS` 必须满足 `build_status=success` 且 `test_status ∈ {pass, skip}`（`skip` 时必须在 `notes` 中说明跳过原因和剩余风险）
    - `status=SUCCESS` 必须包含真实启动验证结果 `startup_status=ok`（即不覆盖 ENTRYPOINT/CMD 后容器仍存活）；`startup_status` 缺失或为 `crash` 时不得标记 SUCCESS
    - `status=FAILED` 必须包含 `failure_reason`（从流程性失败原因或技术性失败原因枚举中取值），并在 `notes` 写清失败证据与边界
    - `test_status` 取值：`pass`（验证通过）、`fail`（验证失败）、`skip`（跳过验证，须说明原因）
    - `startup_status` 取值：`ok`（真实启动验证通过）、`crash`（启动崩溃，按 `references/build_knowledge_reference.md` 第 21 节层次 0 崩溃处理流程修复）、`skip`（跳过启动验证，须说明原因）

4. **批次汇总与知识沉淀**

    - 全部项目完成后再写 `build_reports/_summary.json`，主 Agent 统一汇总
    - 知识沉淀条件：修复同时满足以下三项时进入知识沉淀流程——(1) `status=SUCCESS`；(2) 修复方式在 `references/build_knowledge_reference.md` 中无已有记录（即 NOVEL）；(3) 具备复用价值（适用于同类型镜像或通用构建场景）
    - 未经用户确认，不直接改写知识库

> 报告字段结构以场景模板为准：`templates/dockerfile_migration_report_template.md` 与 `templates/image_reconstruction_report_template.md`。