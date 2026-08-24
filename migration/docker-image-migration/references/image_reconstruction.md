## 无 Dockerfile 场景镜像迁移执行规范

本文件定义无 Dockerfile 场景的端到端执行规范：覆盖采集分析、决策矩阵、离线提取、Dockerfile 重建、构建验证和运行测试。用于指导 Agent 在信息不完整情况下保持“证据优先、最小变更、可追溯报告”的稳定流程，不负责全局调度与重试策略（由主 Skill 全局执行红线统一约束）。

本文件仅定义场景流程；调度/重试/失败判定以主 Skill 为准。

## 1. 场景执行说明

**适用前提**：没有可访问的 Dockerfile，但源镜像或用户提供的采集产物可访问。开始前必须完成主 Skill 启动门禁。

**信息源**：

- manifest：平台、OS、配置和 layer digest；
- history：可见的构建层命令；
- layer：容器内包、文件、用户和环境信息；当前采集脚本在 ARM64 主机上跳过该项。

**输入**：源镜像列表或采集产物、目标镜像名、`TASK_CTX`。

**输出**：

- `COLLECTED_DATA` 指向的 manifest/history/layer；
- `arm_builds_<YYYYMMDD>/analysis/<project>/decision_matrix.md`；
- `arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64`；
- `build_reports/<project>.json`。

**阶段顺序**：

```text
阶段 1  采集准备与产物分析
阶段 2  分析结论汇总（决策矩阵）
阶段 3  离线资源提取
阶段 4  重建 ARM64 Dockerfile
阶段 5  构建验证
阶段 6  运行测试与固化报告
```

主 Agent 在分配任务前完成 阶段 1 的采集动作，并将以下路径注入执行单元：

```yaml
COLLECTED_DATA:
  "<image>":
    manifest_path: "arm_builds_<date>/analysis/<project>/<safe_name>/manifest.json"
    history_path: "arm_builds_<date>/analysis/<project>/<safe_name>/history.json"
    layer_path: null  # 有有效文件时替换为实际路径
```

全局调度、warning、重试、检查点和会话恢复不在本文件重复定义，统一遵守主 Skill 的全局执行红线。

## 核心原则

- **单一事实来源**：全局调度、告警、重试、检查点和报告一致性以主 Skill 为准
- **证据先于结论**：基础镜像 ARM64 支持、native 库兼容性和失败判定必须附可追溯证据，不得凭经验推断
- **最小变更闭环**：每个阶段只产出该阶段工件；跨阶段问题通过决策矩阵与检查点回流，不跳过必要验证
- **受控降级透明化**：`LAYER_NOT_COLLECTED`、`WARN-OPAQUE-LAYER-*` 等降级必须在决策矩阵和报告中显式记录

---

## 阶段 1. 采集准备与产物分析

在进入逆向信息采集前，先确认用户是否已提供采集好的镜像元数据（manifest.json / history.json / layer.json）。
若缺少数据，根据当前机器架构和环境决定采集方式。

> 采集工具：`scripts/image_collector_cli/collect.sh`。manifest 与 history 通常可直接从 registry 获取；layer 需要运行容器，可能触发本地 pull。当前脚本在 ARM64 主机上会保守地跳过 layer。
> 以下命令默认在仓库根目录执行；工具详细说明见 [references/image_collector_reference.md](../references/image_collector_reference.md)。

---

### 1.1 检查已有采集数据

```text
检查用户是否提供了以下采集产物（每个镜像一个子目录）：
  <output_dir>/<image_name>/
    manifest.json        ← 镜像 manifest（架构/OS/ENV/CMD/layers）
    history.json         ← 构建层历史（每层 RUN/COPY 命令）
    layer.json           ← 容器内环境成分（pip 包/apt 包/系统信息等）

`manifest.json` 和 `history.json` 均存在、非空且可解析：
  - 若 `layer.json` 同时存在 → 跳过对应采集，进入 1.5。
  - 若仅缺少 `layer.json` → 必须先交互式提示用户：
    "无法采集 layer 层信息，是否继续迁移？继续后构建镜像可能不完整。建议先在 x86_64 机器手动采集 layer 并上传后再迁移。"
    用户确认继续（yes）→ 记录 `LAYER_NOT_COLLECTED` 后进入 1.5；
    用户不继续（no）→ 停止迁移，等待用户上传手动采集产物（layer.json 或完整采集包）后再执行。
manifest 或 history 缺失/不可解析 → 进入 1.2，重新运行采集以补齐核心项。
```

### 1.2 检查 Registry 访问

```text
对每个待采集镜像，检查是否能连接到目标 registry：

  docker manifest inspect <image> 2>&1 | head -5

  ✗ 返回 "unauthorized" / "denied" / "authentication required"
    → 交互式提示用户：
      "无法访问 <registry>，请执行 docker login 后回车继续，或输入 skip 跳过该镜像。"
    → 用户 login 后重新检查，仍失败则标记该镜像为 FAILED(REGISTRY_UNAUTHORIZED)
  ✗ 返回 "manifest unknown" / "not found" / "name unknown"
    → 必须暂停并交互式提示用户：
      "未找到镜像 <image>。请确认镜像名和 tag 是否正确，或提供可替代镜像；
       未确认前我不会继续执行迁移。"
    → 用户确认新镜像后重新执行 1.2；若用户选择 skip 则跳过该镜像并记录原因
  ✗ 返回 "connection refused" / "timeout"
    → 报告中标 WARNING，继续尝试采集（可能是临时故障）
    → 多次访问失败，必须暂停并交互式提示用户，确认镜像源在执行环境是否可达
  ✓ 正常返回 → 进入 1.3。
```

### 1.3 选择采集环境

```text
当前架构：uname -m
  = x86_64 → 环境 A：当前机器可直接运行 docker pull 采集 layer
  = aarch64 / arm64 → 进入 1.3.1。
```

#### 1.3.1 ARM64 主机的 layer 采集限制

```text
只检测 QEMU 用户态能力，不安装软件、不修改 `binfmt_misc`：
  ls /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null
  或 find / -name "qemu-x86_64-static" 2>/dev/null | head -1

  有 QEMU → 环境 B：ARM64 + QEMU。当前 `collect.sh` 仍会在 ARM64 主机上跳过 layer。
            若未提供远程 x86_64 采集机，必须先交互式提示用户：
            "无法采集 layer 层信息，是否继续迁移？继续后构建镜像可能不完整。建议先在 x86_64 机器手动采集 layer 并上传后再迁移。"
            用户确认继续（yes）→ 记录 `LAYER_NOT_COLLECTED`，仅采集 manifest/history 后继续；
            用户不继续（no）→ 停止迁移并等待用户上传手动采集产物。

  无 QEMU → 环境 C：ARM64 无 QEMU，无法本地采集 layer，需要远程 x86_64 机器。
            → 在启动门禁完成后、任务分配前优先请求可 SSH 的 x86_64 采集机；
              远程机必须已安装 Docker 且可访问目标 Registry。
            → 若未提供远程采集机，必须先交互式提示用户：
              "无法采集 layer 层信息，是否继续迁移？继续后构建镜像可能不完整。建议先在 x86_64 机器手动采集 layer 并上传后再迁移。"
              用户确认继续（yes）→ 记录 `LAYER_NOT_COLLECTED`，仅采集 manifest/history 后继续；
              用户不继续（no）→ 停止迁移并等待用户上传手动采集产物。

            已获得远程信息时：
              1. 上传 `scripts/image_collector_cli/` 到远程 x86_64 机器；
              2. 远程执行 `collect.sh --mode base --image <image> --output <dir>`；
              3. 回传并校验 `<dir>.tar.gz`；
              4. 解压后进入 1.5。

            未提供远程采集机 → 仅采集 manifest/history（无 `layer.json`），跳过 1.6.3，
                              报告中记录 `LAYER_NOT_COLLECTED`。
```

> 不主动安装 QEMU，也不修改系统 `binfmt_misc`。需要系统级变更时按主 Skill 的确认流程请求用户确认。

### 1.4 执行采集

```text
根据 1.3 确定的环境执行：

环境 A（x86_64）：
  bash scripts/image_collector_cli/collect.sh \
    --mode base \
    --image <SOURCE_IMAGE> \
    --output arm_builds_<date>/analysis/<project>

环境 B（ARM64 + QEMU，按当前脚本行为）：
  # collect.sh 仅采集 manifest + history；如需 layer，按环境 C 使用远程 x86_64 机器。
  bash scripts/image_collector_cli/collect.sh \
    --mode base \
    --image <SOURCE_IMAGE> \
    --output arm_builds_<date>/analysis/<project>

环境 C（ARM64 无 QEMU，已提供 SSH）：
  scp -r scripts/image_collector_cli/ <user>@<host>:/tmp/image_collector_cli/
  ssh <user>@<host> "cd /tmp/image_collector_cli/ && bash collect.sh --mode base --image <image> --output /tmp/out_<project> && tar -czf /tmp/out_<project>.tar.gz -C /tmp out_<project>"
  scp <user>@<host>:/tmp/out_<project>.tar.gz arm_builds_<date>/analysis/<project>/
  # 仅在确认变量已展开且目录为本次任务创建后执行清理
  ssh <user>@<host> "rm -rf /tmp/image_collector_cli/ /tmp/out_<project> /tmp/out_<project>.tar.gz"
  tar -xzf arm_builds_<date>/analysis/<project>/out_<project>.tar.gz \
    -C arm_builds_<date>/analysis/<project>/

环境 C（ARM64 无 QEMU，未提供远程采集机）：
  # 执行前必须先完成用户确认：
  # "无法采集 layer 层信息，是否继续迁移？继续后构建镜像可能不完整。建议先在 x86_64 机器手动采集 layer 并上传后再迁移。"
  # 仅当用户明确选择继续（yes）时，才允许执行以下命令。
  bash scripts/image_collector_cli/collect.sh \
    --mode base \
    --image <SOURCE_IMAGE> \
    --output arm_builds_<date>/analysis/<project>
  # collect.sh 在 ARM 上自动跳过 layer 采集，只获取 manifest + history；
  # 必须在报告中记录 LAYER_NOT_COLLECTED，并提示用户手动采集 layer 后上传。
```

### 1.5 确认采集产物

```text
采集产物位于 arm_builds_<date>/analysis/<project>/<safe_image_name>/：
  manifest.json  → 1.6.1 平台证据检查
  history.json   → 1.6.2 层历史解读
  layer.json     → 1.6.3 容器内状态（若缺失则跳过）
```

---

### 1.6 分析采集产物

> 前置检查已完成，采集产物（manifest.json / history.json / layer.json）位于 `arm_builds_<date>/analysis/<project>/<safe_image_name>/`。
> 以下步骤基于已采集的产物进行分析，不再执行任何 docker 采集命令。

#### 1.6.1 源镜像与基础镜像平台证据

先读取源镜像 `manifest.json`：

```text
architecture = arm64/aarch64 → 记录“源镜像已提供 ARM64 变体”；仍需确认用户是否要求重建或仅验证。
architecture = amd64/x86_64 → 符合迁移输入，继续确定基础镜像候选。
architecture 缺失或其他值 → 标记证据不足，尝试重新获取 manifest；仍缺失时不得推断平台。
```

基础镜像候选按以下证据优先级确定：

1. 用户明确提供的原始基础镜像；
2. `diff.json.diff_meta.base_image` 或 `_base_index.json` 的匹配结果；
3. 镜像 label、构建元数据或 history 中明确出现的基础镜像；
4. 根据 OS、运行时和软件包集合推断的候选。

`docker history` 通常不包含可靠的 `FROM` 行，不能把 grep 不到 `FROM` 当作“无基础镜像”或“无 ARM64 支持”。第 4 类只能标记 `[BASE-IMAGE-INFERRED]`，必须在决策矩阵写出依据和不确定性。

对每个候选执行 manifest 平台检查：

```bash
docker buildx imagetools inspect <BASE_IMAGE>
# 或
docker manifest inspect <BASE_IMAGE>
```

- 有 `linux/arm64`：保存 tag/digest 与命令输出，进入 1.6.2。
- 明确无 `linux/arm64`：执行"基础镜像优先迁移"流程（见下方），不得自动降级为公开基础镜像。
- 认证失败、超时或 Registry 不可达：属于证据缺失，不得等同于“不支持 ARM64”。

官方镜像族的最小构建探测边界统一见 `../references/build_knowledge_reference.md`；最终报告仍需 manifest 或等价平台证据。

**基础镜像优先迁移**（基础镜像明确无 ARM64 或为用户自研版本时触发）：

```text
1. 拉取 x86 基础镜像
   docker pull --platform linux/amd64 <原基础镜像>
   拉取失败 → 交互提示用户：
     "无法拉取基础镜像 <image>，请确认基础镜像来源：
      提供可拉取的镜像地址 / 提供基础镜像的 Dockerfile / 跳过本项目"
   用户未确认前不得继续

2. 优先迁移基础镜像
   - 有基础镜像的 Dockerfile → 按 dockerfile_migration.md 流程迁移，生成 Dockerfile.arm64 并构建
   - 无基础镜像的 Dockerfile → 按本文件流程逆向重构基础镜像（采集 manifest/history/layer → 决策矩阵 → 重建 → 构建）
   - 基础镜像迁移成功后，获得 ARM64 基础镜像：<image>-arm64:latest

3. 逐行验证 docker history
   docker history --no-trunc --format "{{.CreatedBy}}" <image>-arm64:latest
   逐层检查：
     - 每个 RUN 层涉及的包/库在 ARM64 上可安装（apt 包有 arm64 版、pip 包有 aarch64 wheel）
     - 无 x86_64/amd64 架构残留（ELF 文件、.so 库），必要时用 DevKit pkg-mig 扫描
     - COPY/ADD 引入的文件无 x86 native 库
   验证不通过 → 回到步骤 2 修复基础镜像迁移，不得进入业务镜像迁移

4. 使用迁移后的 ARM64 基础镜像
   阶段 4 重建 Dockerfile 时 FROM 改为：
     FROM --platform=linux/arm64 <image>-arm64:latest
   标记 [CHANGE-FROM-BASE-MIGRATED]，记录原基础镜像名、迁移后镜像名、history 验证结论
```

#### 1.6.2 `history.json` 解读

从 `history.json` 逐条读取 `history[].created_by`，按以下规则分类：

| CreatedBy 含 | 含义 | 迁移动作 |
|-------------|------|---------|
| 明确出现 `FROM <image>` | 基础镜像候选 | 记录为补充证据，并按 1.6.1 验证；不要假定 history 必然含 FROM |
| `apt-get install -y <pkgs>` | 系统包 | 提取包名，构建时替换 apt 源后重建 |
| `pip install <pkgs>` | Python 包 | 提取版本，查 [build_knowledge_reference.md](../references/build_knowledge_reference.md) 检查兼容性 |
| `git clone <url>` | 源码下载 | 按 `GIT_HOSTS`、主 Skill 全局执行红线中的启动门禁第 4 项（软件包源）和 `AIRGAP_MODE` 决定重新拉取；不可达时再进入 阶段 3 提取 |
| `WORKDIR` / `ENV` / `CMD` / `ENTRYPOINT` | 元信息 | 记录，完整还原 |
| `COPY / ADD <src> <dst>` | 文件拷贝 | 标记来源，需从 x86 镜像提取或重新获取 |
| **不透明 commit 层** (识别规则见下) | **手动 commit** | **从 layer.json directory_tree 补齐** |

**不透明层识别规则** (满足任一即判定为不透明层):

- A. CreatedBy 为空字符串或仅含空格
- B. CreatedBy 以 `#(nop)` 开头 (docker commit 自动添加的前缀)
- C. CreatedBy 为 `/bin/sh -c #(nop)` 但 Size > 0 (理论上 nop 不应有大小)
- D. CreatedBy 为 `/bin/bash` / `/bin/sh` 且无后续命令 (如 `bash -c "..."`)

#### 1.6.3 `layer.json` 解读（缺失时跳过）

从 `layer.json` 提取关键字段：

| 字段 | 用途 |
|------|------|
| `os.pretty_name` | 确认 OS（Ubuntu 22.04 → apt 源用 ubuntu-ports） |
| `environment` | 还原所有 ENV 变量 |
| `pip_packages[*]` | 获取精确版本号，补全 history 中 `-r requirements.txt` 安装的版本 |
| `apt_packages[*]` | 补全不透明层安装的系统包 |
| `directory_tree` | 定位业务代码/资源路径（用于 阶段 3 docker cp） |
| `users` | 确认运行用户（决定 `USER`/`WORKDIR`） |

> 无 layer.json 时（ARM 无 QEMU 且选择了 skip）：阶段 3 离线资源提取可能不完整，报告中标注 `LAYER_NOT_COLLECTED`。

#### 1.6.4 分析结果确认

```text
检查 arm_builds_<date>/analysis/<project>/<safe_image_name>/ 下的文件：
  manifest.json  ✓ → 供 1.6.1 使用
  history.json   ✓ → 供 1.6.2 使用
  layer.json     ✓ → 供 1.6.3 使用（缺失则记录 warning）
```

---

## 阶段 2. 分析结论汇总（决策矩阵）

完成 阶段 1 后，按模板逐项填写决策矩阵，**所有条目必须填写完毕再进入 阶段 3**：

- 模板位置：[`asserts/decision_matrix.md`](../asserts/decision_matrix.md)

---

## 阶段 3. 离线资源提取（docker cp）

**需要提取的资源**：内网不可达 git 资源 / 无公网包的内网 pip / 大型二进制 / 不透明层文件。
**不需要提取**：来自 GitHub/PyPI 的标准包，系统包（apt 重建），标准代码。

```bash
docker pull --platform linux/amd64 <SOURCE_IMAGE>   # 若 阶段 1 已拉取则可跳过
CID=$(docker create --platform linux/amd64 <SOURCE_IMAGE>)
docker cp $CID:<CONTAINER_PATH> <LOCAL_BUILD_CONTEXT_PATH>
docker rm $CID
# 仅当该镜像由本次任务拉取且未被其他任务使用时，才可清理：docker rmi <SOURCE_IMAGE>
```

**提取后必做：so 兼容性扫描**

> 统一按 [references/devkit_pkg_mig_reference.md](../references/devkit_pkg_mig_reference.md) 执行工具检查、结构化扫描或 fallback。DevKit 不可用时必须注明“手动初筛”，不得把 fallback 结果写成工具判定。

| 扫描结果 | 处理 |
|---------|------|
| `x86-64` / `x86_64` / `80386` | 功能无关→删除；有替代→替换 aarch64；自研→`FAILED(PROPRIETARY_X86_SO)` |
| `ARM aarch64` / 为空 | 兼容，无需处理 |

---

## 阶段 4. 重建 ARM64 Dockerfile

### 4.1 文件头注释（必须）

```dockerfile
# ════════════════════════════════════════════════════════
# ARM64 重建 Dockerfile（逆向分析）
# 原镜像：<SOURCE_IMAGE>    重建日期：<YYYY-MM-DD>
# 信息来源：docker history + inspect_image_layout
#
# 关键决策：
#   [BASE-IMAGE]       → <选定 ARM64 兼容基础镜像>
#   [FIX-APT-SOURCE]   apt 源 → ubuntu-ports/tsinghua
#   [FIX-TORCH]        torch CUDA 版 → CPU-only
#   [DELETE-CUDA-PKG]  删除 nvidia-* / triton
#   [COPY-FROM-X86]    内网资源 → 从 x86 镜像提取后 COPY
#
# WARNINGS：
#   [WARN-X86-NATIVE-SO]    已去除 x86_64 native .so
#   [WARN-OPAQUE-LAYER]     不透明层，重建内容来自 layout 推断，可能不完整
# ════════════════════════════════════════════════════════
```

### 4.2 基础镜像选择

```text
公开官方镜像（ubuntu/python/node...）→ 确认 manifest 后使用 `--platform=linux/arm64`

内网定制镜像（含 INTERNAL_REGISTRIES）→ 推断 ARM64 tag：
  {repo}:{tag}-arm64  /  {repo}:{tag}_arm64  /  {repo}:{tag}-aarch64
  推断失败（manifest unknown 或用户自研版本）→ 执行"基础镜像优先迁移"流程（见 1.6.1 末尾），
  不得自动降级为公开基础镜像（会导致基础镜像组件缺失）

  迁移后标记 [CHANGE-FROM-BASE-MIGRATED]，报告中说明原内网镜像名、迁移后镜像名及 history 验证结论
```

### 4.3 层重建顺序（按 history 从旧到新）

```dockerfile
# [BASE-IMAGE] 原 FROM：<原镜像>，OS：Ubuntu 22.04，已确认 ARM64 manifest 存在
FROM --platform=linux/arm64 ubuntu:22.04

# [FIX-APT-SOURCE] Ubuntu ARM64 必须使用 ubuntu-ports
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends <history 中 apt 包列表，已去 :amd64 后缀> \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# [RESTORE-ENV] 来自 layout.environment，还原全部 ENV
ENV DISPLAY=:99 JAVA_HOME=/usr/lib/jvm/... <其他>

# [COPY-FROM-X86] 内网资源（阶段 3 提取）
WORKDIR <工作目录>
COPY _build_context/<project>/ ./<project>/

# [FIX-TORCH] CPU-only（来自 layout pip_packages）
# [DELETE-CUDA-PKG] 删除 nvidia-* 等
RUN pip3 install "torch==<CPU-only 版本>" <其他包，已去 CUDA 包> -i <PIP_INDEX_URL>

# [WARN-X86-NATIVE-SO] 已去除：COPY libs/librender_x86_64.so /usr/lib/librender.so
# WARNING: x86_64 native 库已移除，相关功能不可用。需 aarch64 版本替换。
# COPY libs/librender_x86_64.so /usr/lib/librender.so

CMD ["<原始启动命令>"]
```

### 4.4 不透明层处理

```text
1. layout directory_tree 已定位文件 → docker cp 提取，用 COPY 还原
   注释：# [OPAQUE-LAYER-COPY]

2. layout apt_packages 有不在 history 中的系统包 → apt-get install 补充
   注释：# [OPAQUE-LAYER-APT]

3. layout pip_packages 有不在 history 中的 Python 包 → pip install 补充
   注释：# [OPAQUE-LAYER-PIP]

4. 以上均无法还原 → 标记 [WARN-OPAQUE-LAYER-UNRESOLVED]，继续构建
   测试阶段发现缺失功能再针对性补充
```

### 4.5 输出路径

```text
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64
arm_builds_<YYYYMMDD>/analysis/<project>/decision_matrix.md
```

---

## 阶段 5. 构建验证

> 构建只使用主 Skill 全局执行红线在启动门禁阶段已验证的软件源决策；不要在本阶段重新探测或硬编码替换。

```bash
docker build --platform linux/arm64 \
  -t <OUTPUT_TAG_PREFIX>-<project>:latest \
  -f arm_builds_<date>/dockerfiles/<project>/Dockerfile.arm64 \
  <build_context>
```

**失败处理**：
1. 出现失败或准备判定 `FAILED(...)` 前，必须先按 `failure_reason` 检索 `../references/build_knowledge_reference.md` 对应章节，并记录命中章节号。
2. 仅当“检索无可用方案”或“已按方案尝试仍失败”时，才允许写 `FAILED(...)` 结论。
3. 每次失败结论必须在报告中最少记录：失败命令与退出码、关键日志、检索章节、已尝试修复动作。

**本场景特有错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `COPY failed: file not found` | 阶段 3 未提取或路径有误 | 检查 阶段 2 decision_matrix，确认标记为 [NEED-DOCKER-CP] 的资源已在 阶段 3 提取；检查 docker cp 本地路径与 Dockerfile COPY 路径一致 |
| `ImportError / ModuleNotFoundError` | 不透明层 pip 包未还原 | 查 layout pip_packages，补充安装 |
| `dpkg: error: parsing file` | 不透明层 apt 包未还原 | 查 layout apt_packages，补充安装 |
| 启动命令 `exec: not found` | CMD 路径与原镜像不一致 | 比对 history 最后一层 CMD |
| 运行时缺少环境变量 | layout ENV 未完整还原 | 检查 layout.environment，补全 ENV 层 |

---

## 阶段 6. 运行时测试 + 固化报告

### 6.1 运行验证

> 必须先执行层次 0（真实启动验证），通过后才执行后续层次。分层策略见 `build_knowledge_reference.md` 第 21 节。

```bash
# 步骤 1（必须）：真实 ENTRYPOINT/CMD 启动验证——不覆盖原始命令
docker inspect <IMAGE> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'
docker run -d --platform linux/arm64 --name test-real-<project> <IMAGE>
sleep 8
if docker ps -a --filter "name=test-real-<project>" --filter "status=running" | grep -q test-real-<project>; then
  echo "STARTUP_OK"
  docker logs test-real-<project> 2>&1 | tail -20
else
  echo "STARTUP_CRASH"
  docker logs test-real-<project> 2>&1 | tail -50
  # 记录崩溃日志，进入 6.2 增量 patch 修复
fi
docker rm -f test-real-<project> 2>/dev/null

# 步骤 2：容器可启动（覆盖命令的基础探活）
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"
docker run --rm --platform linux/arm64 <IMAGE> python3 -c "import <core_module>; print('OK')"
docker run -d --platform linux/arm64 --name test-<project> -p <HOST>:<CONTAINER> <IMAGE>
sleep 5
docker ps | grep test-<project>
docker logs test-<project> 2>&1 | tail -20
curl -s http://localhost:<HOST>/health || curl -s http://localhost:<HOST>/monitor/alive
docker stop test-<project>
```

### 6.2 运行失败与增量 patch

按 [dockerfile_migration.md](./dockerfile_migration.md) 第 5.2 节和主 Skill 的失败处理规则执行；涉及基础镜像、系统包或构建参数时回到 阶段 4/5。

### 6.3 写报告

> 报告 JSON 格式见 [templates/image_reconstruction_report_template.md](../templates/image_reconstruction_report_template.md)。本场景 `migration_mode = "IMAGE_RECONSTRUCTION"`，额外含 `source_image` 和 `reconstruction_info` 字段（见模板 场景 2）。

`_summary.json` 格式同 [templates/image_reconstruction_report_template.md](../templates/image_reconstruction_report_template.md) 的“总览报告”部分，`migration_mode` 改为 `IMAGE_RECONSTRUCTION`。
