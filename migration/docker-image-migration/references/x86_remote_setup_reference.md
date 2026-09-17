# x86_64 远程采集机环境准备参考

本文档是 SKILL.md「操作准备 > x86_64 远程采集机准备」的详细操作参考，包含环境检查、自动配置、工具包定位与验证的完整步骤。

- 工具定位与命令前缀约定见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「通用约定」
- ARM64 + 远程 x86_64 拆分采集流程见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「拆分采集流程」
- 远程采集配置参数（`X86_HOST`、`X86_AI_MIGRATION_DIR`）见 [config_reference.md](references/config_reference.md) 第 8 节

## 目录

- [触发条件](#触发条件)
- [脚本目录结构](#脚本目录结构)
- [环境检查与自动配置](#环境检查与自动配置)
- [工具包验证](#工具包验证)
- [重试上限](#重试上限)

---

## 触发条件

仅当以下条件**同时满足**时，才需要 x86_64 采集机并执行本节：

1. 当前机器为 ARM64（`uname -m` = `aarch64` 或 `arm64`）
2. 迁移场景需要采集 x86_64 镜像的 manifest + history、采集 layer 或执行 layout 扫描（无 Dockerfile 场景的采集阶段，或有 Dockerfile 场景需从 x86 镜像提取资源时）。ARM64 机器无法 `docker pull` / `docker history` x86_64 镜像，manifest + history 的本地采集（`collect-x86`）须在 x86_64 采集机执行
3. 用户已提供 x86_64 采集机的 SSH 地址

若当前机器为 x86_64（可直接本地采集），或无需远程采集，**跳过本节**。

---

## 脚本目录结构

x86 工具包（`DevKit-AI-Migration-Tool-<version>-Linux-x86-64`）优先复用 x86_64 采集机上 DevKit 安装目录 `/opt/huawei/devkit` 下的工具包；无则放置在工作目录中。`ai-migration` 是 PyInstaller 打包的**预编译可执行文件**，镜像采集相关的 `docker_image_migration` 代码（含 `x86_remote_collector/`、`.sh` 内层脚本）已**嵌入二进制内部的 `_internal/`**。所有操作通过 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用，**禁止** 用 `python3` 直接运行脚本。

```text
<AI_MIGRATION_DIR>/            ← 优先 /opt/huawei/devkit/DevKit-AI-Migration-Tool-<version>-Linux-x86-64；无则 <工作目录>/DevKit-AI-Migration-Tool-<version>-Linux-x86-64
  ai-migration                 ← 统一入口可执行文件
  _internal/                   ← Python 运行时 + 嵌入的 docker_image_migration 包（含 x86_remote_collector/、.sh 内层脚本）
  modules/                     ← 模块
  subcommand/                  ← 外部子命令（source-migration 等）
  toolscript/                  ← 工具脚本
```

> x86 工具包为预编译可执行文件（PyInstaller 打包），自带 Python 运行时，不依赖系统 Python3。采集所需代码已随二进制嵌入 `_internal/`，运行时由 `ai-migration` 自动加载（调用方式与 python3 禁令见上方「脚本目录结构」）。

---

## 环境检查与自动配置

> 以下检查按顺序执行。每步失败时遵循两个原则：
>
> - **可自动修复**：生成修复命令，经用户确认后通过 SSH 自动执行
> - **不可自动修复**：输出明确诊断信息和手动修复指引，暂停等待用户处理
>
> ⚠️ **系统环境变更确认原则**（遵照 SKILL.md「核心原则 — 系统环境变更确认」）：所有对 x86_64 采集机宿主机环境的变更（安装/升级软件、修改配置、启停服务、修改用户组等），**执行前必须交互式请求用户确认，未确认前不得执行**。确认时须展示：① 拟执行的具体命令 ② 变更影响范围 ③ 不执行的后果。

### 步骤 1：SSH 连通性检查

```bash
ssh -o ConnectTimeout=10 <user>@<host> "echo OK"
```

| 结果                           | 处置                                                         |
| ------------------------------ | ------------------------------------------------------------ |
| ✓ OK                           | 继续步骤 2                                                   |
| ✗ Connection refused / Timeout | 提示用户检查：目标机 SSH 服务是否启动（`sudo systemctl status sshd`）、防火墙规则、IP/端口是否正确；不可自动修复，暂停等待用户处理 |
| ✗ Permission denied            | 提示用户检查：SSH 密钥是否已部署（`ssh-copy-id`）或密码是否正确；不可自动修复，暂停等待用户处理 |
| ✗ Host key verification failed | 提示用户确认是否信任该主机指纹，确认后执行 `ssh-keyscan <host> >> ~/.ssh/known_hosts` 并重试 |

### 步骤 2：x86 工具包定位检查

> x86 工具包（`DevKit-AI-Migration-Tool-<version>-Linux-x86-64`）优先在 x86_64 采集机的 **DevKit 安装目录 `/opt/huawei/devkit`** 下定位（经 RPM 安装的 DevKit 会把工具包解压到此）；若不存在，再在**工作目录**下定位；仍无则按步骤 2.1 下载或获取工具包到工作目录。

```bash
# 1. 优先检查 DevKit 安装目录
ssh <user>@<host> "ls /opt/huawei/devkit/DevKit-AI-Migration-Tool-*-Linux-x86-64/ai-migration"

# 2. 工作目录下定位
ssh <user>@<host> "ls <工作目录>/DevKit-AI-Migration-Tool-*-Linux-x86-64/ai-migration"
```

> `<工作目录>` 为 x86_64 采集机上本次迁移的工作目录（与采集产物输出目录同级）。若用户已指定工具包实际安装路径，可直接用该路径替代上述定位路径。

| 结果     | 处置                                                         |
| -------- | ------------------------------------------------------------ |
| ✓ 已找到 | 记录 `AI_MIGRATION_DIR`（x86_64 采集机上工具包目录的绝对路径），继续步骤 3 |
| ✗ 未找到 | 进入步骤 2.1 获取工具包到工作目录后重新定位                  |

### 步骤 2.1：获取 x86 工具包到工作目录

> 仅当步骤 2 在 `/opt/huawei/devkit` 和工作目录均未定位到工具包时执行本步。获取到的工具包放置在**工作目录**下（解压后即用，不写入系统目录）。
>
> ⚠️ **系统环境变更**：下载工具包需占用磁盘与网络带宽，须经用户确认后方可执行（遵照 SKILL.md「系统环境变更确认」原则，须展示：① 拟执行的具体命令 ② 变更影响范围 ③ 不执行的后果）。

获取优先级依次为：

1. **本机下载**：x86_64 采集机网络正常时，从华为云镜像下载并解压到工作目录（版本号 `${AI_MIGRATION_TOOL_VERSION}`、下载基址 `${AI_MIGRATION_TOOL_DOWNLOAD_BASE}` 在 `config_reference.md` §9 集中维护）

   ```bash
   # 下载地址（文件名形如 DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz）
   ssh <user>@<host> "cd <工作目录> && \
     curl -LO ${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz && \
     tar -xzf DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz"
   ```

2. **从另一台机器下载后传输**：x86_64 采集机网络不可用时，由网络正常的 **ARM64 主控端**（或反之）下载 x86 工具包，再 scp 传到 x86_64 采集机工作目录

   ```bash
   # 在网络正常的机器（如 ARM64 主控端）下载
   cd <ARM64 工作目录>
   curl -LO ${AI_MIGRATION_TOOL_DOWNLOAD_BASE}/Kunpeng%20DevKit%20${AI_MIGRATION_TOOL_VERSION}/DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz
   # 传输到 x86_64 采集机并解压
   scp DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz <user>@<host>:<工作目录>/
   ssh <user>@<host> "cd <工作目录> && tar -xzf DevKit-AI-Migration-Tool-${AI_MIGRATION_TOOL_VERSION}-Linux-x86-64.tar.gz"
   ```

3. **请求用户上传或提供路径**：两台机器网络均不可用、且 `/opt/huawei/devkit` 与工作目录下均无工具包时，**必须暂停并交互式请求用户**二选一：

   - 用户上传 x86 工具包到 x86_64 采集机工作目录（或 ARM64 主控端工作目录后由 Skill 传输过去），Skill 解压并重新定位；
   - 用户提供工具包已有路径，Skill 校验该路径下 `ai-migration` 可执行后记录为 `AI_MIGRATION_DIR`。

   未得到用户确认前不得继续执行。

> 默认按 `${AI_MIGRATION_TOOL_VERSION}`（见 `config_reference.md` §9）下载；若该版本直链失效（如版本目录调整），可在 DevKit 下载门户 `https://kunpeng-community.rnd.huawei.com/zh/developer/devkit/downloadNew` 手动查找对应架构与版本的工具包，下载后按本步骤放到工作目录，并在任务记录中留存实际下载的文件名与版本。

获取完成后回到步骤 2 重新定位。

### 步骤 3：Docker 检查

```bash
ssh <user>@<host> "docker info >/dev/null 2>&1 && echo OK"
```

| 结果                                        | 处置                               |
| ------------------------------------------- | ---------------------------------- |
| ✓ OK                                        | 继续步骤 4                         |
| ✗ docker: command not found                 | Docker 未安装 → 按步骤 3.1 处理    |
| ✗ Cannot connect to the Docker daemon       | Daemon 未运行 → 按步骤 3.2 处理    |
| ✗ Permission denied while trying to connect | 权限不足 → 按步骤 3.3 处理         |
| ✗ 其他错误                                  | 输出完整错误信息，暂停等待用户处理 |

### 步骤 3.1：Docker 未安装

> ⚠️ **系统环境变更**：Docker 安装涉及添加仓库 GPG 密钥、修改包源等系统级变更，**不自动执行**。即使后续增加自动安装能力，也必须经用户确认后方可执行。

根据检测到的发行版，生成安装指引供用户手动执行：

| 发行版                       | 安装指引                                                     |
| ---------------------------- | ------------------------------------------------------------ |
| Debian / Ubuntu              | `curl -fsSL https://get.docker.com \| sudo sh` 或参考 [Docker 官方 APT 安装文档](https://docs.docker.com/engine/install/ubuntu/) |
| RHEL / CentOS / Rocky / Alma | `sudo yum install -y yum-utils && sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && sudo yum install -y docker-ce docker-ce-cli containerd.io && sudo systemctl start docker` |
| Fedora                       | `sudo dnf install -y dnf-plugins-core && sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo && sudo dnf install -y docker-ce docker-ce-cli containerd.io && sudo systemctl start docker` |
| Alpine                       | `sudo apk add docker && sudo rc-service docker start`        |
| 其他                         | 指向官方文档 https://docs.docker.com/engine/install/         |

输出指引后暂停，等待用户确认已安装，然后重新检查。

### 步骤 3.2：Docker Daemon 未运行

> ⚠️ **系统环境变更**：启动 Docker 服务属于系统服务变更，须经用户确认后方可执行。

询问用户是否自动启动：

```bash
sudo systemctl start docker
```

- 用户确认 → 通过 SSH 执行 → 重新检查
- 用户拒绝 → 提示手动启动（`sudo systemctl start docker` 或 `sudo dockerd &`），暂停等待确认

### 步骤 3.3：Docker 权限不足

> ⚠️ **系统环境变更**：修改用户组属于系统用户配置变更，须经用户确认后方可执行。

当前用户不在 `docker` 组。询问用户是否自动修复：

```bash
sudo usermod -aG docker $USER
```

> 此命令执行后需**重新登录 SSH 会话**才能生效。

- 用户确认 → 通过 SSH 执行 → 断开并重新建立 SSH 连接 → 重新检查
- 用户拒绝 → 提示在命令前加 `sudo` 或手动加入 docker 组（`sudo usermod -aG docker $USER`），暂停等待确认

### 步骤 4：Docker 运行能力验证

```bash
ssh <user>@<host> "docker run --rm hello-world >/dev/null 2>&1 && echo OK"
```

| 结果                   | 处置                                                         |
| ---------------------- | ------------------------------------------------------------ |
| ✓ OK                   | 继续步骤 5                                                   |
| ✗ 拉取失败（网络问题） | 提示配置 Docker 镜像加速器或检查网络；若为离线环境（`AIRGAP_MODE=true`），提示用户手动加载镜像；暂停等待用户处理 |
| ✗ 其他运行错误         | 输出完整错误信息，暂停等待用户处理                           |

### 步骤 5：磁盘空间检查（/tmp 可用 ≥ 2 GB）

```bash
ssh <user>@<host> "df -m /tmp | tail -1 | awk '{print \$4}'"
```

| 结果               | 处置                                                         |
| ------------------ | ------------------------------------------------------------ |
| ✓ 可用 ≥ 2048 MB   | 继续步骤 6                                                   |
| ⚠ 可用 500–2048 MB | 警告：磁盘空间偏低，大镜像采集可能失败。询问用户是否继续或指定其他传输路径 |
| ✗ 可用 < 500 MB    | 建议清理 `/tmp` 或将 x86 工具包安装到其他路径（见 [config_reference.md](references/config_reference.md) 第 8 节）。暂停等待用户处理 |

### 步骤 6：目标镜像存在性检查

对每个待采集镜像逐一检查：

```bash
ssh <user>@<host> "docker image inspect <image> >/dev/null 2>&1 && echo OK"
```

| 结果             | 处置                                                         |
| ---------------- | ------------------------------------------------------------ |
| ✓ 镜像已存在本地 | 继续步骤 7                                                   |
| ✗ 镜像不存在     | 询问用户是否自动拉取：`docker pull <image>`                  |
|                  | - 用户确认 → 通过 SSH 执行拉取（超时 600s）→ 重新检查；拉取失败时检查网络/认证，交互提示 |
|                  | - 用户拒绝 → 暂停等待用户手动处理（如自行 `docker load`、配置 Registry 等） |

---

## 工具包验证

### 步骤 7：验证工具包子命令可执行

```bash
# 验证主流程采集子命令（collect-x86 采 manifest+history）与 env（采 layer）
ssh <user>@<host> "${AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 --help"
ssh <user>@<host> "${AI_MIGRATION_DIR}/ai-migration image-migration env --help"
```

> x86_64 采集机的工具包目录在此文档记为 `${AI_MIGRATION_DIR}`；在拆分采集流程文档中亦作 `${X86_AI_MIGRATION_DIR}`（与 ARM64 主控端的 `${AI_MIGRATION_DIR}` 区分），二者指同一个 x86 工具包目录。

| 结果                   | 处置                                                         |
| ---------------------- | ------------------------------------------------------------ |
| ✓ 成功（输出帮助信息） | 记录 `AI_MIGRATION_DIR`（x86_64 采集机上的工具包安装目录）到任务上下文，后续采集通过 SSH 远程调用 |
| ✗ 命令未找到           | 返回步骤 2.1 获取 x86 工具包                                 |
| ✗ Permission denied    | 执行 `ssh <user>@<host> "chmod +x ${AI_MIGRATION_DIR}/ai-migration"` 后重新验证 |
| ✗ 其他错误             | 输出完整错误信息，暂停等待用户处理                           |

> 远程清理时只删除采集输出文件（如 `/tmp/layer_<project>.json`、`/tmp/layout_<project>.json`），**不要删除工具包目录**，后续 `layout`（阶段 1.7）和 `docker cp`（阶段 3）仍需使用。

---

## 重试上限

| 步骤                            | 最大重试次数 | 超限处置                                                     |
| ------------------------------- | ------------ | ------------------------------------------------------------ |
| 步骤 2.1（x86 工具包下载/获取） | 2            | 标记该任务为 `status=FAILED`、`failure_reason=EXCEEDED_ATTEMPTS`，继续处理其余任务 |
| 步骤 3.1（Docker 安装）         | 2            | 同上                                                         |
| 步骤 6（镜像拉取）              | 1（每镜像）  | 同上                                                         |

---

## 环境检查结果结构

步骤 1–7 完成后，生成 `x86_env` 记录到 TASK_CTX：

```yaml
x86_env:
   ssh_ok: true | false
   ai_migration_ok: true | false
   ai_migration_dir: "<AI_MIGRATION_DIR>"  # x86_64 采集机上工具包安装目录，不可用时为 ""
   docker_ok: true | false
   docker_version: "<version>"  # 如 "24.0.7"，不可用时为 ""
   docker_daemon_running: true | false
   docker_run_ok: true | false   # docker run --rm hello-world 是否成功
   disk_free_mb: <int>           # /tmp 可用空间 MB
   target_images_available: ["<image>:<tag>", ...]  # 本地已存在的目标镜像
   target_images_missing: ["<image>:<tag>", ...]    # 本地不存在的目标镜像
   check_passed: true | false    # 所有阻断性检查是否通过（允许有非阻断性警告）；true 表示可继续执行远程采集
   auto_fixed: ["<item>", ...]   # 经自动修复后通过的项目，如 ["docker_daemon"]
   warnings: ["<item>", ...]    # 非阻断性警告，如 ["disk_space_low"]
```