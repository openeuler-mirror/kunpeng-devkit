## 无 Dockerfile 场景镜像迁移执行规范

本文件定义无 Dockerfile 场景的端到端执行规范：覆盖采集分析、决策矩阵、离线提取、Dockerfile 重建、构建验证和运行测试。用于指导 Agent 在信息不完整情况下保持”证据优先、最小变更、可追溯报告”的稳定流程。调度/重试/失败判定以主 Skill 为准。

## 1. 场景执行说明

**适用前提**：没有可访问的 Dockerfile，但源镜像或用户提供的采集产物可访问。开始前必须完成主 Skill 启动门禁。

**信息源**：

- manifest：平台、OS、配置和 layer digest；
- history：可见的构建层命令（仅来自 registry 元数据，buildx/skopeo 跨架构采集，不依赖本地镜像）；
- layer：容器内包、文件、用户和环境信息；当前 `collect` 子命令在 ARM64 主机上跳过该项。

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

> 采集工具：`./ai-migration image-migration collect`。manifest 与 history 均从 registry 获取（buildx/skopeo，跨架构可用，不依赖本地镜像）；layer 需要运行容器，可能触发本地 pull。ARM64 主机上 `collect` 跳过 layer 采集。
> 以下命令中的 `./ai-migration` 是简写，执行前需替换为 `ai-migration` 的实际绝对路径，或先 `cd` 到安装目录。定位方法、工具说明与采集边界见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「工具定位」「采集边界」。
>
> ⚠️ **所有机器禁止 `python3` 直接调用采集/分析脚本**：不存在可直接运行的 `collect.py`、`analyze.py` 等 Python 脚本，ARM64 主控端和 x86_64 采集机均必须使用 `${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>` 调用。

---

### 1.1 检查已有采集数据

```text
检查用户是否提供了以下采集产物（每个镜像一个子目录，子目录名为 `safe_name`，见 1.5）：
  <output_dir>/<safe_image_name>/
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
ARM64 主机无法运行 x86_64 容器，因此无法本地采集 layer。

有远程 x86_64 采集机 → 环境 B：manifest/history/layer 全部在 x86_64 采集机上通过其工具包预编译二进制远程采集（collect-x86 采 manifest+history，env 采 layer），回传 ARM64 后只做 analyze。
            已获得远程信息时：
              1. 检查 x86_64 采集机前置条件（Docker 可用）；
              2. 在 x86_64 采集机上定位 x86 工具包（优先 `/opt/huawei/devkit` 安装目录，无则工作目录，仍无则下载或获取，见 references/x86_remote_setup_reference.md 步骤 2/2.1）；
              3. 验证预编译二进制子命令可执行；
              4. 远程执行采集命令（collect-x86 采 manifest+history，env 采 layer）；
              5. 回传并校验采集产物；
              6. 解压后进入 1.5。
              详细步骤见 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md)。

无远程 x86_64 采集机 → 环境 C：ARM64 无远程采集机，无法采集 layer，也无法对 x86_64 镜像采集本地 history。
            → 必须先交互式提示用户（提示语同 1.1）：
              用户确认继续（yes）→ 记录 `LAYER_NOT_COLLECTED`，仅通过 ARM64 collect 采集 manifest + registry history 后继续；
              用户不继续（no）→ 停止迁移并等待用户上传手动采集产物。

            未提供远程采集机 → 仅通过 ARM64 collect 采集 manifest + registry history（无 `layer.json`，无本地 history），跳过 1.6.3，
                              报告中记录 `LAYER_NOT_COLLECTED`。
```

> 不在 x86_64 机器上执行系统级变更；需要运行 x86_64 容器的采集/扫描操作统一通过工具包的预编译二进制经 SSH 远程调用（`${AI_MIGRATION_DIR}/ai-migration image-migration <subcommand>`），工具包优先复用 `/opt/huawei/devkit` 安装目录，无则工作目录。python3 禁令同 1.1。

### 1.4 执行采集

```text
根据 1.3 确定的环境执行：

环境 A（x86_64，本机即为采集机）：
  # 步骤 1：采集 manifest + history（collect-x86，目标镜像须先 docker pull 到本地）
  ${AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
    --mode base \
    <SOURCE_IMAGE> \
    --output arm_builds_<date>/analysis/<project>
  # 步骤 2：采集 layer（env，需 docker run 目标容器）
  ${AI_MIGRATION_DIR}/ai-migration image-migration env \
    --image <SOURCE_IMAGE> --output arm_builds_<date>/analysis/<project>/<safe_image_name>/layer.json
  # 步骤 3：分析 + 打包
  ${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
    --mode base --output arm_builds_<date>/analysis/<project>

环境 B（ARM64 + 远程 x86_64 采集机）：
  # 分步采集：x86_64 端采集 manifest/history + layer，最后 ARM64 端分析
  # 按 references/x86_remote_setup_reference.md 完成工具包定位和环境检查
  # ${X86_AI_MIGRATION_DIR} = x86_64 采集机工具包目录，${AI_MIGRATION_DIR} = ARM64 主控端工具包目录
  #
  # 可选优化（非默认路径，见 references/image_collector_cli_reference.md §6「按需优化」）：
  #   若 ARM 端 collect 已能 got_history=true 且无需本地 history，可省略步骤 1 的 collect-x86 跨机采集，
  #   直接在 ARM64 用 collect 采 manifest+registry history，仅步骤 2 的 layer 仍须在 x86 采。
  #   默认按下方步骤 1→2→3 执行，避免 ARM/x86 各采一半再合并。

  # 步骤 1：在 x86_64 采集机采集 manifest + history（collect-x86，目标镜像须先 docker pull 到 x86 本地）
  ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
    --mode base <SOURCE_IMAGE> --output /tmp/collect_<project>"
  # 回传 manifest + history 采集产物
  scp -r <user>@<host>:/tmp/collect_<project> \
    arm_builds_<date>/analysis/<project>
  ssh <user>@<host> "rm -rf /tmp/collect_<project>"

  # 步骤 2：在 x86_64 采集机远程采集 layer（需要 docker run 目标容器）
  ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration env \
    --image <SOURCE_IMAGE> --output /tmp/layer_<project>.json"
  # 回传 layer 采集产物
  scp <user>@<host>:/tmp/layer_<project>.json \
    arm_builds_<date>/analysis/<project>/<safe_image_name>/layer.json
  # 清理远程临时产物，不删除工具包目录（后续 inspect/docker cp 仍需使用）
  ssh <user>@<host> "rm -f /tmp/layer_<project>.json"

  # 步骤 3：ARM64 端分析 + 打包（刷新 _status.json，运行 Analyzer，写汇总和打包）
  ${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
    --mode base --output arm_builds_<date>/analysis/<project>

环境 C（ARM64 无远程采集机）：
  # 执行前必须先完成 1.3.1 环境 C 的用户确认（提示语同 1.1）；
  # 仅当用户明确选择继续（yes）时，才允许执行以下命令。
  # 步骤 1：ARM64 端采集 manifest + registry history（collect，仅 registry 元数据，无本地 history）
  ${AI_MIGRATION_DIR}/ai-migration image-migration collect \
    --mode base \
    --image <SOURCE_IMAGE> \
    --output arm_builds_<date>/analysis/<project>
  # 步骤 2：分析 + 打包（layer 缺失，diff 将被跳过）
  ${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
    --mode base --output arm_builds_<date>/analysis/<project>
  # 必须在报告中记录 LAYER_NOT_COLLECTED，并提示用户手动采集 layer 后上传。
```

#### 1.4.1 批量场景的 biz 模式（生成 diff.json）

> 单镜像迁移默认使用 `--mode base`，**不生成 `diff.json`**。阶段 1.6.1 基础镜像候选证据优先级第 2 项（`diff.json.diff_meta.base_image`）仅在以下批量流程中可用。

当用户提供镜像清单且已标注基础镜像时，分两步采集：

**环境 A（x86_64 本地）**：

```bash
# 步骤 1：采集所有基础镜像 manifest + history（collect-x86）
${AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
  --mode base \
  --images-file <base_images.txt> \
  --output arm_builds_<date>/analysis/<project>/base

# 步骤 2：分析基础镜像，生成 _base_index.json + 打包
${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
  --mode base --output arm_builds_<date>/analysis/<project>/base

# 步骤 3：采集业务镜像 manifest + history（collect-x86）
${AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
  --mode biz \
  --images-file <biz_images.txt> \
  --output arm_builds_<date>/analysis/<project>

# 步骤 4：分析业务镜像，与基础镜像做 diff，生成 diff.json + 打包
${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
  --mode biz \
  --base-output arm_builds_<date>/analysis/<project>/base \
  --output arm_builds_<date>/analysis/<project>
```

**环境 B（ARM64 + 远程 x86_64 采集机）**：

> ARM64 + 远程 x86_64 采集机环境下必须采用拆分采集流程（见阶段 1.4 环境 B 说明和 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「拆分采集流程」）。

```bash
# ────────────── 基础镜像 ──────────────
# ${X86_AI_MIGRATION_DIR} = x86_64 采集机工具包目录，${AI_MIGRATION_DIR} = ARM64 主控端工具包目录

# 步骤 1：x86_64 采集机采集基础镜像 manifest + history（collect-x86），回传 ARM64
ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
  --mode base --images-file <base_images.txt> --output /tmp/collect_base"
scp -r <user>@<host>:/tmp/collect_base \
  arm_builds_<date>/analysis/<project>/base
ssh <user>@<host> "rm -rf /tmp/collect_base"

# 步骤 2：x86_64 采集机远程采集基础镜像 layer
# 使用 get-safe-name 子命令获取 safe_name，避免在 shell 中内嵌复杂 Python 代码
# get-safe-name 从 _status.json 中读取 safe_name 字段，安全且与 Python 算法完全一致
while IFS=$'\t' read -r image safe_name; do
  [ -z "$image" ] && continue
  ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration env \
    --image '$image' --output /tmp/layer_${safe_name}.json"
  scp <user>@<host>:/tmp/layer_${safe_name}.json \
    arm_builds_<date>/analysis/<project>/base/${safe_name}/layer.json
  ssh <user>@<host> "rm -f /tmp/layer_${safe_name}.json"
done < <(ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration get-safe-name --scan-dir /tmp/collect_base")

# 步骤 3：ARM64 端分析基础镜像（生成含 _layer_data 的 _base_index.json）+ 打包
${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
  --mode base --output arm_builds_<date>/analysis/<project>/base

# ────────────── 业务镜像 ──────────────

# 步骤 4：x86_64 采集机采集业务镜像 manifest + history（collect-x86），回传 ARM64
ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration collect-x86 \
  --mode biz --images-file <biz_images.txt> --output /tmp/collect_biz"
scp -r <user>@<host>:/tmp/collect_biz \
  arm_builds_<date>/analysis/<project>
ssh <user>@<host> "rm -rf /tmp/collect_biz"

# 步骤 5：x86_64 采集机远程采集业务镜像 layer
# 使用 get-safe-name 子命令获取 safe_name（同步骤 2 的方式）
while IFS=$'\t' read -r image safe_name; do
  [ -z "$image" ] && continue
  ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration env \
    --image '$image' --output /tmp/layer_${safe_name}.json"
  scp <user>@<host>:/tmp/layer_${safe_name}.json \
    arm_builds_<date>/analysis/<project>/${safe_name}/layer.json
  ssh <user>@<host> "rm -f /tmp/layer_${safe_name}.json"
done < <(ssh <user>@<host> "${X86_AI_MIGRATION_DIR}/ai-migration image-migration get-safe-name --scan-dir /tmp/collect_biz")

# 步骤 6：ARM64 端分析业务镜像（生成 diff.json，刷新 _status.json）+ 打包
${AI_MIGRATION_DIR}/ai-migration image-migration analyze \
  --mode biz \
  --base-output arm_builds_<date>/analysis/<project>/base \
  --output arm_builds_<date>/analysis/<project>
```

- `--base-output` 是 `analyze` 子命令的参数，指向步骤 1 的输出目录；缺省时 biz 模式跳过 diff。
- 产出的 `diff.json` 位于每个业务镜像子目录下，供阶段 1.6.1 读取。
- 单镜像场景或用户未提供基础镜像清单时，跳过本步，阶段 1.6.1 直接使用优先级第 3-4 类证据。

> `collect-x86`/`collect` 采集 manifest + history，`env` 产出 `layer.json`（不含文件树，文件树须由 1.7 的 `inspect` 另行采集）。当 1.6.2/1.6.3/阶段 3/阶段 4.4 需要 `directory_tree` 时，按 **1.7 inspect 按需补充采集** 执行。

### 1.5 确认采集产物

```text
采集产物位于 arm_builds_<date>/analysis/<project>/<safe_image_name>/：
  manifest.json  → 1.6.1 平台证据检查
  history.json   → 1.6.2 层历史解读
  layer.json     → 1.6.3 容器内状态（若缺失则跳过；不含 directory_tree）
  layout.json    → 1.6.3 directory_tree（由 1.7 按需采集，缺失则跳过）
  _status.json   → 采集状态判定（见下）
```

**采集状态判定**（退出码为 0 不代表采集成功）：

读取每个镜像子目录下的 `_status.json`，按以下顺序判定：

1. `_status.json` 可解析；
2. `got_manifest`、`got_history`、`got_layer` 与实际文件存在情况一致；
3. `manifest.json` 和 `history.json` 均存在、非空且可解析 → 核心数据可用，进入 1.6；
4. `layer.json` 缺失但 `got_layer=false` → 记录 `LAYER_NOT_COLLECTED`，按 1.1 的降级流程继续；
5. `manifest.json` 或 `history.json` 缺失/不可解析 → 回到 1.2 重新采集。

> 详细字段说明见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「collect-x86 / collect 子命令」与「analyze 子命令」参数表。

---

### 1.6 分析采集产物

> 前置检查已完成，采集产物（manifest.json / history.json / layer.json）位于 `arm_builds_<date>/analysis/<project>/<safe_image_name>/`。
> 以下步骤基于已采集的产物进行分析，不再执行任何 docker 采集命令；若分析中发现需要 `directory_tree`，按 **1.7** 触发 `inspect` 按需补充采集。

#### 1.6.1 源镜像与基础镜像平台证据

先读取源镜像 `manifest.json`：

```text
architecture = arm64/aarch64 → 记录“源镜像已提供 ARM64 变体”；仍需确认用户是否要求重建或仅验证。
architecture = amd64/x86_64 → 符合迁移输入，继续确定基础镜像候选。
architecture 缺失或其他值 → 标记证据不足，尝试重新获取 manifest；仍缺失时不得推断平台。
```

基础镜像候选按以下证据优先级确定：

1. 用户明确提供的原始基础镜像；
2. `diff.json.diff_meta.base_image` 或 `_base_index.json` 的匹配结果（仅批量 biz 模式采集时可用，见 1.4.1；单镜像 `--mode base` 场景无 `diff.json`，跳过此项）；
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
- 明确无 `linux/arm64`：先检索 [build_knowledge_reference.md](references/build_knowledge_reference.md) 的替代或版本升级方案；无方案时使用 `FAILED(NO_ARM64_SUPPORT)`。
- 认证失败、超时或 Registry 不可达：属于证据缺失，不得等同于“不支持 ARM64”。

官方镜像族的最小构建探测边界统一见 `references/build_knowledge_reference.md`；最终报告仍需 manifest 或等价平台证据。

#### 1.6.2 `history.json` 解读

从 `history.json` 逐条读取 `history[].created_by`，按以下规则分类：

| CreatedBy 含                             | 含义            | 迁移动作                                                     |
| ---------------------------------------- | --------------- | ------------------------------------------------------------ |
| 明确出现 `FROM <image>`                  | 基础镜像候选    | 记录为补充证据，并按 1.6.1 验证；不要假定 history 必然含 FROM |
| `apt-get install -y <pkgs>`              | 系统包          | 提取包名，构建时替换 apt 源后重建                            |
| `pip install <pkgs>`                     | Python 包       | 提取版本，查 [build_knowledge_reference.md](references/build_knowledge_reference.md) 检查兼容性 |
| `git clone <url>`                        | 源码下载        | 按 `GIT_HOSTS`、主 Skill 全局执行红线中的启动门禁第 4 项（软件包源）和 `AIRGAP_MODE` 决定重新拉取；不可达时再进入 阶段 3 提取 |
| `WORKDIR` / `ENV` / `CMD` / `ENTRYPOINT` | 元信息          | 记录，完整还原                                               |
| `COPY / ADD <src> <dst>`                 | 文件拷贝        | 标记来源，需从 x86 镜像提取或重新获取                        |
| **不透明 commit 层** (识别规则见下)      | **手动 commit** | **从 layout.json directory_tree 补齐（触发 1.7 采集）**      |

**不透明层识别规则** (满足任一即判定为不透明层):

- A. CreatedBy 为空字符串或仅含空格
- B. CreatedBy 以 `#(nop)` 开头 (docker commit 自动添加的前缀)
- C. CreatedBy 为 `/bin/sh -c #(nop)` 但 Size > 0 (理论上 nop 不应有大小)
- D. CreatedBy 为 `/bin/bash` / `/bin/sh` 且无后续命令 (如 `bash -c "..."`)

#### 1.6.3 `layer.json` / `layout.json` 解读（缺失时跳过）

> `layer.json`（env 模块产出）= 深度环境检测：各语言运行时版本+项目文件+源码信息，由 collect 自动采集。
> `layout.json`（layout.py 产出）= 结构布局扫描：文件树+可执行文件+用户+磁盘+自定义工具，由 1.7 按需采集。
> 两者字段结构不同（如 env 变量在 layer.json 为 `image_env`，在 layout.json 为 `env_vars`；语言信息在 layer.json 为嵌套对象，在 layout.json 为扁平 `runtimes` 字典），不可互换。读取环境变量时统一使用 `image_env` 字段。

从 `layer.json` 提取关键字段：

| 字段                           | 用途                                                         |
| ------------------------------ | ------------------------------------------------------------ |
| `os.pretty_name`               | 确认 OS（Ubuntu 22.04 → apt 源用 ubuntu-ports）              |
| `image_env`                    | 还原所有 ENV 变量                                            |
| `python.installed_packages[*]` | 获取精确版本号，补全 history 中 `-r requirements.txt` 安装的版本 |
| `packages.list[*]`             | 补全不透明层安装的系统包（apt/yum/apk 等）                   |
| `source_code`                  | 获取 git repo_url/commit_id/branch，用于判断源码来源         |

> 注意：`layer.json` **不含** `directory_tree`、`users`、`executables`——这些仅在 `layout.json` 中。

从 `layout.json` 提取关键字段（需先在 1.7 触发 `inspect --mode full` 采集）：

| 字段             | 用途                                                         |
| ---------------- | ------------------------------------------------------------ |
| `directory_tree` | 定位业务代码/资源路径（用于 阶段 3 docker cp）               |
| `executables`    | 可执行文件清单（`normal`/`full` 模式，用于校验 RUN 安装结果） |
| `users`          | 确认运行用户（决定 `USER`/`WORKDIR`）                        |
| `image_info`     | 镜像元信息（id/arch/size/labels 等，补充 manifest.json）     |

> 无 layer.json 时（ARM64 无远程 x86_64 采集机且选择了 skip）：阶段 3 离线资源提取可能不完整，报告中标注 `LAYER_NOT_COLLECTED`。
> 无 layout.json 时（未执行 1.7 或 ARM64 无法采集）：阶段 3 的 `docker cp` 路径只能依据 history 推断，阶段 4.4 不透明层可能无法完整还原，报告中标注 `LAYOUT_NOT_COLLECTED`。

#### 1.6.4 分析结果确认

```text
检查 arm_builds_<date>/analysis/<project>/<safe_image_name>/ 下的文件：
  manifest.json  ✓ → 供 1.6.1 使用
  history.json   ✓ → 供 1.6.2 使用
  layer.json     ✓ → 供 1.6.3 使用（缺失则记录 warning，不含 directory_tree）
  layout.json    ○ → 供 1.6.3 directory_tree 使用（由 1.7 按需采集，缺失则记录 LAYOUT_NOT_COLLECTED）
```

---

### 1.7 inspect 按需补充采集

> `env` 产出的 `layer.json` 不含文件树（`directory_tree` 等，见 1.6.3）。当后续阶段需要文件树证据时，调用 `inspect` 补充采集，产物写入 `layout.json`。本节为按需触发，非必执行步骤。

**触发时机**（满足任一即触发）：

- 1.6.2 解读 `history.json` 时识别到不透明 commit 层（识别规则见 1.6.2）
- 1.6.3 需要 `directory_tree` 定位业务代码/资源路径
- 阶段 3 离线资源提取需要 `directory_tree` 定位 `docker cp` 的容器路径
- 阶段 4.4 不透明层还原需要文件树证据

**执行环境**：与 1.4 的采集环境一致。x86_64 主机直接执行；ARM64 主机需远程到 x86_64 机器执行（`inspect` 需运行容器，ARM64 上无法采集 x86_64 镜像的内部结构）。未提供远程采集机且本地为 ARM64 时，跳过本步并在报告中标注 `LAYOUT_NOT_COLLECTED`，阶段 3/4.4 仅能依据 history 推断，可能不完整。

> ⚠️ **注意**：`inspect`（`x86_remote_collector/inspectors/layout.py`）不会自动拉取镜像。如果目标镜像不在本地，需先 `docker pull <SOURCE_IMAGE>` 后再执行 `inspect`，否则会因容器启动失败而报错。在 x86_64 远程采集机上执行 `docker pull` 属于系统环境变更（可能占用大量磁盘空间），须按 SKILL.md「系统环境变更确认」原则请求用户确认后方可执行，不得自行静默拉取。

**远程执行命令**（ARM64 主控端 + 远程 x86_64 采集机）：

```bash
# 通过 ai-migration 统一入口运行 inspect
ssh <user>@<host> "${AI_MIGRATION_DIR}/ai-migration image-migration layout \
  <SOURCE_IMAGE> --mode full --depth 3 --output /tmp/layout_<project>.json --pretty"

# 回传结果到 ARM64 主控端的采集产物目录
scp <user>@<host>:/tmp/layout_<project>.json \
  arm_builds_<date>/analysis/<project>/<safe_image_name>/layout.json

# 仅清理远程临时产物，不删除脚本目录
ssh <user>@<host> "rm -f /tmp/layout_<project>.json"
```

> `inspect` 使用 `--output` 写入单文件，不会像 `collect` 那样自动生成 `.tar.gz`，因此直接 scp 单个 JSON 文件即可。
> 远程调用通过 `ai-migration image-migration layout` 统一入口，无需额外传输脚本。

**本地 x86_64 主机执行命令**（默认 `full` 模式以获取 `directory_tree`）：

```bash
${AI_MIGRATION_DIR}/ai-migration image-migration layout \
  <SOURCE_IMAGE> \
  --mode full \
  --depth 3 \
  --output arm_builds_<date>/analysis/<project>/<safe_image_name>/layout.json \
  --pretty
```

> `--depth` 默认 3，扫描根目录默认 `/app /opt /home /etc /srv /data /workspace /code /project`，可按镜像实际 WORKDIR 调整 `--scan-dirs`。
> 仅需 OS/运行时/系统包/配置（无需文件树）时可用 `--mode rebuild`，文件小速度快，但不含 `directory_tree`。
> 工具详细参数见 [image_collector_cli_reference.md](references/image_collector_cli_reference.md)「子命令速查表」`layout` 行。

**报告记录**：执行 `inspect` 后，将实际使用的 `--mode` 值（`rebuild` / `normal` / `full`）记录到报告的 `reconstruction_info.layout_mode_used` 字段；未执行 `inspect` 时该字段留空。

---

## 阶段 2. 分析结论汇总（决策矩阵）

完成 阶段 1 后，按模板逐项填写决策矩阵，**所有条目必须填写完毕再进入 阶段 3**：

- 模板位置：[`asserts/decision_matrix.md`](asserts/decision_matrix.md)

---

## 阶段 3. 离线资源提取（docker cp）

**需要提取的资源**：内网不可达 git 资源 / 无公网包的内网 pip / 大型二进制 / 不透明层文件。
**不需要提取**：来自 GitHub/PyPI 的标准包，系统包（apt 重建），标准代码。

```bash
# 检查镜像是否已在 x86_64 采集机上（根据 _status.json 的 image_pulled_locally 字段判断）
# 若 image_pulled_locally=false 或镜像已被清理，需要重新 pull
# ⚠️ docker pull 属于系统环境变更（可能占用大量磁盘空间），须按 SKILL.md「系统环境变更确认」原则请求用户确认后方可执行
docker image inspect <SOURCE_IMAGE> >/dev/null 2>&1 || \
  docker pull --platform linux/amd64 <SOURCE_IMAGE>
CID=$(docker create --platform linux/amd64 <SOURCE_IMAGE>)
docker cp $CID:<CONTAINER_PATH> <LOCAL_BUILD_CONTEXT_PATH>
docker rm $CID
# 仅当该镜像由本次任务拉取且未被其他任务使用时，才可清理：docker rmi <SOURCE_IMAGE>
```

**提取后必做：so 兼容性扫描**

> 统一按 [references/devkit_pkg_mig_reference.md](references/devkit_pkg_mig_reference.md) 执行工具检查、结构化扫描或 fallback。DevKit 不可用时必须注明“手动初筛”，不得把 fallback 结果写成工具判定。

| 扫描结果                      | 处理                                                         |
| ----------------------------- | ------------------------------------------------------------ |
| `x86-64` / `x86_64` / `80386` | 功能无关→删除；有替代→替换 aarch64；自研→`FAILED(PROPRIETARY_X86_SO)` |
| `ARM aarch64` / 为空          | 兼容，无需处理                                               |

---

## 阶段 4. 重建 ARM64 Dockerfile

> **字段来源约定**：本阶段下文出现的 `layer.<字段>` / `layout.<字段>` 指代两个不同 JSON 的字段——`layer.json`（env 模块产出，含 `image_env`/`os`/`packages`/`python.installed_packages`/`source_code` 等，**不含** `directory_tree`/`users`/`executables`）；`layout.json`（layout.py 产出，含 `directory_tree`/`executables`/`users`/`image_info`/`env_vars`/`runtimes` 等，需在 1.7 采集）。`directory_tree` / `executables` / `users` 仅取自 `layout.json`，其余环境信息优先取自 `layer.json`，缺失时可从 `layout.json` 的 `runtimes`/`env_vars` 回退（注意字段名不同）。

### 4.1 文件头注释（必须）

```dockerfile
# ════════════════════════════════════════════════════════
# ARM64 重建 Dockerfile（逆向分析）
# 原镜像：<SOURCE_IMAGE>    重建日期：<YYYY-MM-DD>
# 信息来源：docker history + inspect（layout.py）
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
  推断失败（manifest unknown）→ 退回到 layer.os.pretty_name + layer.python.installed_packages 对应公开镜像：

  OS 回退映射表（按 layer.os.pretty_name 匹配）：
    Ubuntu 22.04 + Python 3.x  → python:3.x-slim-jammy
    Ubuntu 20.04 + Python 3.x  → python:3.x-slim-focal
    Ubuntu 22.04 (无 Python)   → ubuntu:22.04
    Ubuntu 20.04 (无 Python)   → ubuntu:20.04
    Debian 12 + Python 3.x    → python:3.x-slim-bookworm
    Debian 11 + Python 3.x    → python:3.x-slim-bullseye
    Debian 12 (无 Python)     → debian:bookworm-slim
    Debian 11 (无 Python)     → debian:bullseye-slim
    Node.js (layer 有 node)   → node:<version>-slim（版本来自 layer）
    Java (layer 有 java/jvm)  → eclipse-temurin:<version>-jre-jammy

  ★ 回退后必须标记 [FALLBACK-TO-PUBLIC-BASE]，报告中说明原内网镜像名及回退原因
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

# [RESTORE-ENV] 来自 layer.image_env（缺失时从 layout.env_vars 回退），还原全部 ENV
ENV DISPLAY=:99 JAVA_HOME=/usr/lib/jvm/... <其他>

# [COPY-FROM-X86] 内网资源（阶段 3 提取）
WORKDIR <工作目录>
COPY _build_context/<project>/ ./<project>/

# [FIX-TORCH] CPU-only（来自 layer.python.installed_packages）
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

2. layer.packages.list 有不在 history 中的系统包 → apt-get install 补充
   注释：# [OPAQUE-LAYER-APT]

3. layer.python.installed_packages 有不在 history 中的 Python 包 → pip install 补充
   注释：# [OPAQUE-LAYER-PIP]

4. 以上均无法还原 → 标记 [WARN-OPAQUE-LAYER-UNRESOLVED]，继续构建
   测试阶段发现缺失功能再针对性补充
```

**不透明层缺失影响评估**（写入报告 `reconstruction_info.opaque_layer_assessment`）：

| 数据源可用性                    | 影响程度 | 评估说明                                                     |
| ------------------------------- | -------- | ------------------------------------------------------------ |
| layer.json + layout.json 均可用 | 低       | 不透明层内容可从数据中还原，缺失风险小                       |
| 有 layer.json，无 layout.json   | 中       | 不透明层中的文件（非包管理器安装的文件）无法定位，可能导致 COPY 缺失、运行时找不到资源文件 |
| 有 layout.json，无 layer.json   | 中       | 不透明层中的包（系统包/Python 包）无法精确识别，可能导致运行时缺少依赖 |
| 均缺失                          | 高       | 不透明层完全无法还原，构建出的镜像可能缺少关键业务文件和依赖，运行测试很可能失败 |

> 无论影响程度如何，必须在报告中明确标注 `LAYER_NOT_COLLECTED` 和/或 `LAYOUT_NOT_COLLECTED`，并在 `notes` 中说明具体缺失的不透明层数量及其在 history 中的位置。

### 4.5 输出路径

```text
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64
arm_builds_<YYYYMMDD>/analysis/<project>/decision_matrix.md
```

---

## 阶段 5. 构建验证

> 构建只使用主 Skill 全局执行红线在启动门禁阶段已验证的软件源决策；不要在本阶段重新探测或硬编码替换。

> **QEMU 模拟构建超时提示**：当 `ARCH_COMPAT=emulated` 时，ARM64 构建通过 QEMU 模拟执行，速度远低于原生构建。建议将 `BUILD_TIMEOUT_MIN` 调整为默认值的 2–3 倍（即 120–180 分钟），尤其是含编译步骤（C/C++/Rust）的镜像。若构建超时但无编译错误，先检查是否为 QEMU 性能瓶颈而非代码问题。

> **构建网络模式**：`docker build` 的 `RUN` 步骤运行在独立容器网络命名空间，其 DNS 解析器（daemon.json 的 `dns`）在该命名空间未必可达——典型表现为 `pip install` / `npm install` / `apt-get` 报 `Temporary failure in name resolution`，而 `docker pull`（宿主机进程）仍成功。**不要在本阶段重新探测**，直接使用启动门禁生成的 `BUILD_NET_CTX`：`${BUILD_NET_ARG}` 为网络参数（`--network=host` 或空串），`${BUILD_PROXY_ARGS}` 为代理 build-arg（见 `build_knowledge_reference.md` §20 模板）。

```bash
docker build --platform linux/arm64 \
  ${BUILD_NET_ARG} \
  ${BUILD_PROXY_ARGS} \
  -t <OUTPUT_TAG_PREFIX>-<project>:latest \
  -f arm_builds_<date>/dockerfiles/<project>/Dockerfile.arm64 \
  <build_context>
```

**失败处理**：

1. 出现失败或准备判定 `FAILED(...)` 前，必须先按 `failure_reason` 检索 `references/build_knowledge_reference.md` 对应章节，并记录命中章节号。
2. 仅当“检索无可用方案”或“已按方案尝试仍失败”时，才允许写 `FAILED(...)` 结论。
3. 每次失败结论必须在报告中最少记录：失败命令与退出码、关键日志、检索章节、已尝试修复动作。

**本场景特有错误**：

| 错误                                                         | 原因                                                         | 修复                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `Temporary failure in name resolution` / `Could not resolve host` | 构建容器网络命名空间 DNS 不可达（`docker pull` 仍正常）      | 确认 `BUILD_NET_CTX.build_net_mode`；若为 `bridge` 失败，切到 `--network=host`（`${BUILD_NET_ARG}`）；仍失败按 `build_knowledge_reference.md` §「容器 DNS 解析失败」处理 |
| `npm ERR! code E407` / `407 Proxy Authentication Required`   | npm 不读 `HTTP_PROXY` 环境变量做代理认证，`--build-arg` 注入的代理对 npm 无效 | 按 `build_knowledge_reference.md` §8「npm 代理 407」处理：宿主机 `npm install` 后 `COPY node_modules`，或 Dockerfile 内 `npm config set proxy` |
| `COPY failed: file not found`                                | 阶段 3 未提取或路径有误                                      | 检查 阶段 2 decision_matrix，确认标记为 [NEED-DOCKER-CP] 的资源已在 阶段 3 提取；检查 docker cp 本地路径与 Dockerfile COPY 路径一致 |
| `ImportError / ModuleNotFoundError`                          | 不透明层 pip 包未还原                                        | 查 layer.python.installed_packages，补充安装                 |
| `dpkg: error: parsing file`                                  | 不透明层 apt 包未还原                                        | 查 layer.packages.list，补充安装                             |
| 启动命令 `exec: not found`                                   | CMD 路径与原镜像不一致                                       | 比对 history 最后一层 CMD                                    |
| 运行时缺少环境变量                                           | ENV 未完整还原                                               | 检查 layer.image_env（缺失时查 layout.env_vars），补全 ENV 层 |

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

按 [dockerfile_migration.md](references/dockerfile_migration.md) 第 5.2 节和主 Skill 的失败处理规则执行；涉及基础镜像、系统包或构建参数时回到 阶段 4/5。

### 6.3 写报告

> 报告 JSON 格式见 [templates/image_reconstruction_report_template.md](templates/image_reconstruction_report_template.md)。本场景 `migration_mode = "IMAGE_RECONSTRUCTION"`，额外含 `source_image` 和 `reconstruction_info` 字段（见模板 2.2 节）。

`_summary.json` 格式同 [templates/image_reconstruction_report_template.md](templates/image_reconstruction_report_template.md) 的“总览报告”部分，`migration_mode` 改为 `IMAGE_RECONSTRUCTION`。