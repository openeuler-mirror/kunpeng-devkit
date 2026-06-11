# 纯镜像重构（无 Dockerfile + history/layout/manifest 逆向分析）

> **适用场景**：只有现成的 x86_64 镜像，**没有 Dockerfile 源文件**，需要通过逆向分析镜像结构来重建 ARM64 版本。
>
> **触发关键词**：`只有镜像没有 Dockerfile` / `逆向重建镜像` / `镜像重构 arm64` / `image reconstruction` / `docker history 分析迁移`
>
> **与 DOCKERFILE_MIGRATION.md 的区别**：Dockerfile 不存在，信息源是 `docker history`（层命令）+ `inspect_image_layout`（容器内状态）+ `docker manifest`（基础镜像支持判断）；需要额外的 **PHASE 0 逆向信息采集** 阶段，采集结束后进入与 DOCKERFILE_MIGRATION.md 类似的构建流程。

---

## 必读文件（每次任务启动前）

```
本文件（IMAGE_RECONSTRUCTION.md）          ← 完整执行流程
config.yaml                               ← 可配置参数（仓库地址、镜像源等）★ 启动前必须确认已按实际环境修改
BUILD_KNOWLEDGE.md                        ← 构建/修复知识库（遇到错误先查这里）
```

---

## Agent 编排（主 Agent + 子 Agent）

> 编排模型与 DOCKERFILE_MIGRATION.md 完全一致：`WORKER_COUNT = 1` 单任务模式，`WORKER_COUNT ≥ 2` 并发模式。  
> 区别在于**子 Agent 多了一个 PHASE 0 逆向采集阶段**，采集结果作为 PHASE 1 的输入。

### 主 Agent 职责

```
启动阶段：
  1. 读取 config.yaml，校验必填项（§ 2 内网地址不能留占位符；AIRGAP_MODE=true 时额外校验）
  2. 检查 WORKER_COUNT：
       WORKER_COUNT = 1  → 单任务模式：主 Agent 自身直接执行 PHASE 0-5，不再启动子 Agent
       WORKER_COUNT ≥ 2  → 并发模式：按以下步骤进行
  3. 收集所有待迁移的镜像列表（migration_list.txt），按镜像名拆分任务队列
  4. 按 WORKER_COUNT 启动子 Agent，每个子 Agent 分配一个镜像任务

运行阶段（持续监控）：
  每隔 WORKER_STALL_TIMEOUT_MIN 分钟检查一次所有子 Agent 状态：
    ✓ 正常推进  → 无需干预，记录进度
    ✗ 无新日志输出（卡住）→ 执行干预流程（同 DOCKERFILE_MIGRATION.md 主 Agent 干预流程）
    ✗ 子 Agent 崩溃/退出  → 读取其最后日志，判断是否可自动重启

结束阶段：
  所有镜像完成后，汇总各子 Agent 的报告，输出总览报告（_summary.json）
```

### 子 Agent 职责

```
每个子 Agent 独立完成单个镜像的完整重构：
  PHASE 0 → PHASE 1 → PHASE 2 → PHASE 3 → PHASE 4 → PHASE 5

  - 子 Agent 不感知其他子 Agent 的状态，只管自己的镜像
  - 每完成一个 PHASE 输出一条结构化日志（供主 Agent 监控）：
      [WORKER-{id}] PHASE{n} DONE  image={image}  elapsed={sec}s
  - 遇到需要人工确认的 [WARN-*]，先挂起并通知主 Agent
  - 退出时写出标准格式的单镜像报告（§ 5.3）
```

---

## 整体流程（六阶段）

```
PHASE 0: 逆向信息采集（docker history + layout + manifest）
PHASE 1: 分析结论汇总（决策矩阵）
PHASE 2: 离线资源提取（docker cp，仅限无法重建的资源）
PHASE 3: 重建 ARM64 Dockerfile
PHASE 4: 构建验证
PHASE 5: 运行时测试 + 固化报告
```

---

## PHASE 0 · 逆向信息采集

> **目标**：在不运行镜像业务进程的前提下，从三个维度完整还原原镜像的构建意图。

### 0.1 基础镜像 ARM64 支持检查（快速失败）

在做任何采集前，先确认基础镜像是否具备 ARM64 manifest，避免无效工作：

```bash
# 提取 FROM 层中的基础镜像名（history 的最早一条，或 FROM 行）
BASE_IMAGE=$(docker history --no-trunc --format "{{.CreatedBy}}" <SOURCE_IMAGE> \
  | grep -E "^FROM" | tail -1 | awk '{print $2}')

# 检查 arm64 manifest 是否存在
docker manifest inspect ${BASE_IMAGE} 2>&1 | grep -c "arm64\|aarch64"
# 返回 0 → 标记 FAILED(NO_ARM64_SUPPORT)，跳过后续所有步骤
# 返回 > 0 → 继续
```

> ⚠️ 网络超时会让 `manifest inspect` 返回空，误判为不支持。对 `python/node/ubuntu/debian` 等官方镜像，超时时放行，继续采集。详见 `BUILD_KNOWLEDGE.md § 1`。

### 0.2 采集层历史（docker history）

```bash
# 确保镜像已在本地（若无则先 pull x86 版本）
docker pull --platform linux/amd64 <SOURCE_IMAGE>

# 查看完整层历史（--no-trunc 显示完整命令）
docker history --no-trunc --format \
  "{{.ID}}\t{{.Size}}\t{{.CreatedBy}}" <SOURCE_IMAGE> > /tmp/<project>_history.txt
```

**解读规则（逐层分析）**：

| 层特征（CreatedBy 含） | 含义 | 迁移动作 |
|----------------------|------|---------|
| `FROM <image>` | 基础镜像 | 记录，§ 0.1 已确认 ARM64 支持 |
| `apt-get install -y <pkgs>` | 系统包安装 | 提取包名，构建时替换 apt 源后重建 |
| `pip install <pkgs>` | Python 包 | 提取版本，查 `BUILD_KNOWLEDGE.md § 4-5` 检查兼容性 |
| `git clone <url>` | 源码下载 | 判断是否内网 → 内网则标记需 `docker cp` 提取 |
| `WORKDIR <path>` | 工作目录 | 记录，用于 PHASE 2 `docker cp` 路径定位 |
| `ENV <key>=<val>` | 环境变量 | 记录，还原到新 Dockerfile ENV 层 |
| `COPY / ADD <src> <dst>` | 文件拷贝 | 标记来源，需从 x86 镜像提取或重新获取 |
| `CMD / ENTRYPOINT` | 启动命令 | 记录，完整还原 |
| `/bin/bash`（无命令，Size > 0） | 不透明 commit 层 | 无法从 history 重建，**必须进入 § 0.3 full 模式采集** |

> **不透明层识别**：`CreatedBy` 仅为 `/bin/bash` 或 `bash -c #(nop)` 且 `Size > 0`，说明该层通过 `docker commit` 产生，命令已丢失。**必须用 `inspect_image_layout.py --mode full` 补齐内容。**

### 0.3 采集容器内状态（inspect_image_layout）

```bash
# rebuild 模式（必做）：采集 OS/ENV/pip 包/系统包
python3 scripts/inspect/inspect_image_layout.py \
  <SOURCE_IMAGE> \
  --mode rebuild \
  --output /tmp/<project>_layout.json \
  --pretty

# full 模式（有不透明层时额外执行）：额外采集目录树
python3 scripts/inspect/inspect_image_layout.py \
  <SOURCE_IMAGE> \
  --mode full \
  --depth 3 \
  --output /tmp/<project>_layout_full.json \
  --pretty
```

> **原理**：脚本通过 `docker run --rm` 向容器注入 base64 编码的 shell 脚本，在容器内执行 `pip list`、`dpkg -l`、`env`、`find` 等命令，输出结构化 JSON，无需上 x86 机器，利用本地 QEMU 仿真。

**layout 输出关键字段及用途**：

| 字段路径 | 用途 |
|---------|------|
| `os.pretty_name` | 确认基础 OS 版本（Ubuntu 22.04 → ARM 源必须用 ubuntu-ports） |
| `environment` | 还原容器内所有 ENV 变量（如 `DISPLAY=:99`、`JAVA_HOME`、自定义变量） |
| `pip_packages[*]` | 获取**精确版本号**，补全 history 中 `-r requirements.txt` 安装的实际版本 |
| `apt_packages[*]` | 补全 history 不透明层中安装的系统包 |
| `directory_tree` | full 模式：定位业务代码/资源文件路径（用于 PHASE 2 docker cp） |
| `users` | 确认运行用户（如 `sandbox`），决定 `USER`/`WORKDIR` |

### 0.4 采集结果存档

将以下三份原始数据保存，供 PHASE 1 分析和后续参考：

```
arm_builds_<YYYYMMDD>/
  analysis/<project>/
    history.txt                 ← docker history 原始输出
    layout_rebuild.json         ← inspect_image_layout --mode rebuild 输出
    layout_full.json            ← （有不透明层时）--mode full 输出
    decision_matrix.md          ← PHASE 1 填写的决策矩阵
```

---

## PHASE 1 · 分析结论汇总（决策矩阵）

完成 PHASE 0 后，填写以下决策矩阵。**必须全部填写，不得留空**，再进入 PHASE 2。

```
═══════════════════════════════════════════════════════
 镜像重构决策矩阵
 源镜像：<SOURCE_IMAGE>
 分析日期：<YYYY-MM-DD>
═══════════════════════════════════════════════════════

【基础信息】
[ ] 基础镜像（FROM）：___________
[ ] OS 版本（来自 layout os.pretty_name）：___________
[ ] 运行用户：___________
[ ] 工作目录（WORKDIR）：___________
[ ] 启动命令（CMD/ENTRYPOINT）：___________
[ ] 技术栈（Python/Java/Node/Go/...）：___________

【不透明层】
[ ] 是否存在不透明 commit 层（Size > 0 但 CreatedBy=/bin/bash）：是 / 否
    → 是：已执行 layout full 模式，已从 directory_tree 补全

【资源获取方式】
[ ] git clone 类资源：___________
    → 内网地址（在 GIT_HOSTS 中）：可直连重建 [KEEP-GIT-INTERNAL]
    → 内网地址（不可达）：需 PHASE 2 docker cp 提取 [NEED-DOCKER-CP]
    → 外网地址：可重建，注释提示确认网络
[ ] COPY / ADD 引入的非标准文件：___________
    → 大型二进制/模型文件：需 PHASE 2 docker cp 提取
    → 标准代码文件：随 git clone 或重建获取

【架构相关】
[ ] CUDA/GPU 相关包（nvidia-*, triton, cu12）：有 / 无
    → 有：全部跳过或替换（见 config.yaml CUDA_PACKAGES_SKIP）
[ ] Java/JVM 组件：有 / 无
    → 有：已检查 JAR 内 native .so 架构
[ ] x86 专属 native .so（文件名含 x86_64/amd64）：有 / 无
    → 有：标记 [WARN-X86-NATIVE-SO]，按 § 1.3a 三类策略处理

【环境变量】
[ ] 关键 ENV 变量（来自 layout.environment）：___________

【已知兼容性问题】
[ ] 查 BUILD_KNOWLEDGE.md，pip_packages 中有无已知不兼容包：___________

═══════════════════════════════════════════════════════
```

---

## PHASE 2 · 离线资源提取（docker cp）

> **目标**：把 x86 镜像内**无法在 ARM64 构建时重新获取**的资源提取到本地构建上下文。

### 2.1 判断哪些资源需要提取

**需要 docker cp 提取的资源特征**：
- 来自内网 git 仓库（ARM 机当前不可达）
- 来自内网私有 pip 源且公网无对应包
- 大型二进制/模型文件，无法通过其他方式重新下载
- 不透明层（`/bin/bash`）产生的文件（无法从命令重建）

**不需要提取（可重建）的资源**：
- 来自 GitHub / PyPI 官方源的所有包（替换镜像源后重建）
- 标准 Python/Java/Node 代码
- 系统包（apt-get 重建即可）

### 2.2 执行提取

```bash
# 1. 拉取 x86 版本（已在 PHASE 0 拉取可跳过）
docker pull --platform linux/amd64 <SOURCE_IMAGE>

# 2. 创建不启动的临时容器（展开文件系统）
CID=$(docker create --platform linux/amd64 <SOURCE_IMAGE>)

# 3. 按 PHASE 1 决策矩阵中的路径逐项提取
docker cp $CID:<CONTAINER_PATH> <LOCAL_BUILD_CONTEXT_PATH>

# 4. 清理（释放磁盘空间）
docker rm $CID
# 若不再需要 x86 镜像：
docker rmi <SOURCE_IMAGE>
```

> 路径来源：PHASE 0.2 history 中的 `WORKDIR` + `git clone` 目标路径，或 PHASE 0.3 layout `directory_tree` 中定位的路径。

### 2.3 提取内容 so 兼容性检查（必做）

提取资源后，在构建前**必须扫描 .so 兼容性**（与 DOCKERFILE_MIGRATION.md § 1.5a 规则相同）：

```bash
# 扫描目录下所有 .so 文件的 ELF 架构
find <resource_path> -name "*.so*" -o -name "*.a" | \
  xargs -I{} file {} | grep -v "ARM aarch64\|symbolic link\|ASCII\|directory"

# 对 JAR 包：检查内嵌 native 库
unzip -l <path>.jar | grep -E "\.so|linux"
```

**判断结果**：输出中出现 `x86-64` / `x86_64` / `80386` → 不兼容，按下表处理：

| 情况 | 处理 |
|------|------|
| 功能无关 / 可选（如性能采集、调试 hook） | 从资源包中删除该 .so |
| 功能相关 / 有公开 aarch64 替代版本 | 替换为 aarch64 版本 |
| 自研 / 无源码 / 无替代 | **暂停**，标记 `FAILED: PROPRIETARY_X86_SO`，等待人工处理 |

```bash
# JAR 内替换 x86 so 为 aarch64 版本（示例）
zip -d <path>.jar "lib/linux-x86_64/libxxx.so"
zip -j <path>.jar <aarch64_libxxx.so>
```

---

## PHASE 3 · 重建 ARM64 Dockerfile

> 基于 PHASE 1 决策矩阵和 PHASE 0 采集结果，从零编写 Dockerfile。

### 3.1 文件头注释（必须）

```dockerfile
# ════════════════════════════════════════════════════════════════════════
# ARM64 重建 Dockerfile（逆向分析）
# 原镜像：<SOURCE_IMAGE>
# 重建日期：<YYYY-MM-DD>
# 信息来源：docker history + inspect_image_layout（rebuild + full 模式）
#
# 关键决策（来自 PHASE 1 决策矩阵）：
#   [BASE-IMAGE]       基础镜像 → <选定的 ARM64 兼容基础镜像>
#   [FIX-APT-SOURCE]   apt 源 → ubuntu-ports / tsinghua（ARM64 必须）
#   [FIX-TORCH]        torch CUDA 版 → CPU-only（见 config.yaml TORCH_VERSION_MAP）
#   [DELETE-CUDA-PKG]  删除 nvidia-* / triton 等 CUDA 包
#   [COPY-FROM-X86]    内网资源 → 从 x86 镜像提取后 COPY
#
# ⚠️  WARNINGS：
#   [WARN-X86-NATIVE-SO]     已去除 x86_64 native .so（见下方注释）
#   [WARN-OPAQUE-LAYER]      存在不透明层，重建内容来自 layout 推断，可能不完整
# ════════════════════════════════════════════════════════════════════════
```

### 3.2 基础镜像选择

```
原镜像基础是公开官方镜像（ubuntu/python/node/...）：
  → 直接加 --platform=linux/arm64 使用

原镜像基础是内网定制镜像（含 INTERNAL_REGISTRIES 域名）：
  → 优先级依次尝试推断 ARM64 tag：
      {repo}:{tag}-arm64
      {repo}:{tag}_arm64
      {repo}:{tag}-aarch64
  → 推断失败（manifest unknown）→ 退回到用 layout os.pretty_name 对应的公开 OS 镜像

layout os.pretty_name → 基础镜像参考：
  "Ubuntu 22.04 LTS"  → ubuntu:22.04
  "Ubuntu 20.04 LTS"  → ubuntu:20.04
  "Debian GNU/Linux 12 (bookworm)" → python:3.x-slim-bookworm
  "Debian GNU/Linux 11 (bullseye)" → python:3.x-slim-bullseye
```

### 3.3 层重建顺序

按 history 层序（从旧到新）依次重建，逐层附行内注释：

```dockerfile
# [BASE-IMAGE] 原 FROM：<原镜像名>，OS：Ubuntu 22.04，已确认 ARM64 manifest 存在
FROM --platform=linux/arm64 ubuntu:22.04

# [FIX-APT-SOURCE] Ubuntu ARM64 必须使用 ubuntu-ports
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends \
       <来自 history apt-get install 的包列表，已去掉 :amd64 后缀> \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# [RESTORE-ENV] 来自 layout.environment，还原全部关键 ENV 变量
ENV DISPLAY=:99 \
    JAVA_HOME=/usr/lib/jvm/... \
    <其他 ENV 变量>

# [COPY-FROM-X86] 内网资源（来自 PHASE 2 docker cp）
# 原构建中通过 git clone <内网地址> 获取，ARM 执行机不可达，已从 x86 镜像提取
WORKDIR <工作目录>
COPY _build_context/<project>/ ./<project>/

# [FIX-TORCH] torch CUDA 版 → CPU-only（来自 layout pip_packages）
# [DELETE-CUDA-PKG] 删除 nvidia-cudnn9-cu12 等
RUN pip3 install \
    "torch==<CPU-only 版本>" \
    <其他 pip 包，来自 layout pip_packages，已去掉 CUDA 包> \
    -i <PIP_INDEX_URL>

# [WARN-X86-NATIVE-SO] 已去除：COPY libs/librender_x86_64.so /usr/lib/librender.so
# ⚠️  WARNING: x86_64 native 库已移除，相关功能在 ARM64 上不可用。
#             若该功能为必需，请提供 aarch64 版本替换。
# COPY libs/librender_x86_64.so /usr/lib/librender.so

# [WARN-OPAQUE-LAYER] 以下内容来自不透明层的 layout 推断，可能不完整
# 原层：docker commit（无命令），Size = <XXX>MB
# 已通过 layout directory_tree 定位以下文件，通过 COPY 还原：
COPY _build_context/opaque_layer_files/ /path/to/destination/

# [RESTORE-CMD] 来自 history 最后一层 CMD
CMD ["<原始启动命令>"]
```

### 3.4 不透明层处理专项

> 不透明层（`/bin/bash` commit 层）是纯镜像重构场景特有的难点，需特殊处理。

```
不透明层重建策略（按可信度排序）：

① layout directory_tree（full 模式）已定位文件路径
  → 从 PHASE 2 docker cp 提取，用 COPY 还原
  → 注释：# [OPAQUE-LAYER-COPY] 来自不透明层，通过 layout full 模式定位

② layout apt_packages 显示有不在 history 中的系统包
  → 在 Dockerfile 中补充 apt-get install 安装
  → 注释：# [OPAQUE-LAYER-APT] 不透明层追加的系统包

③ layout pip_packages 显示有不在 history pip install 中的 Python 包
  → 在 Dockerfile 中补充 pip install
  → 注释：# [OPAQUE-LAYER-PIP] 不透明层追加的 pip 包

④ 以上均无法还原（layout 信息不足）
  → 标记 [WARN-OPAQUE-LAYER-UNRESOLVED]，在报告中说明，继续构建
  → 构建后测试时若缺失功能，再针对性补充
```

### 3.5 FORCE_VERSION_OVERRIDES 追加层

同 DOCKERFILE_MIGRATION.md § 3.3，在 Dockerfile **末尾**追加强制覆盖层（若 config.yaml 有配置）：

```dockerfile
# [FORCE-VERSION-OVERRIDES] 强制覆盖已知不兼容版本
RUN pip3 install \
    "networkx>=2.6" \
    -i <PIP_INDEX_URL> \
    --quiet
```

### 3.6 输出路径

按 config.yaml `OUTPUT_DOCKERFILE_DIR` 模板写出：
```
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64
arm_builds_<YYYYMMDD>/analysis/<project>/decision_matrix.md   ← PHASE 1 决策矩阵
```

---

## PHASE 4 · 构建验证

```bash
docker build --platform linux/arm64 \
  -t <OUTPUT_TAG_PREFIX>-<project>:latest \
  -f arm_builds_<date>/dockerfiles/<project>/Dockerfile.arm64 \
  <build_context>
```

### 构建失败处理

```
每次失败：
  1. 查 BUILD_KNOWLEDGE.md 对应错误关键词
  2. 未找到 → 自行分析 → 修复
  3. 在 Dockerfile 修改处追加注释 # [FIX-<序号>] 原因 → 修复方式
  4. retry_count++

retry_count ≥ 5  → FAILED(EXCEEDED_ATTEMPTS)，写报告，停止
构建 > 60min     → FAILED(TIMEOUT)，写报告，停止
```

### 纯镜像重构场景特有构建错误

> 完整错误库见 **`BUILD_KNOWLEDGE.md`**，此处列出本场景特有项：

| 错误 | 原因 | 修复方式 |
|------|------|---------|
| `COPY failed: file not found` | PHASE 2 未提取或路径有误 | 检查 `docker cp` 提取的本地路径，与 Dockerfile COPY 路径对齐 |
| `ImportError` / `ModuleNotFoundError` | 不透明层的 pip 包未还原 | 查 layout pip_packages，补充安装对应包 |
| `dpkg: error: parsing file` | 不透明层的 apt 包未还原 | 查 layout apt_packages，补充 apt-get install |
| 启动命令 `exec: not found` | CMD 路径与原镜像不一致 | 比对 history 最后一层 CMD，修正可执行文件路径 |
| 运行时缺少环境变量 | layout ENV 未完整还原 | 检查 layout.environment，补全 ENV 层 |

---

## PHASE 5 · 运行时测试 + 固化报告

### 5.1 基础存活验证

```bash
# 层次 1：容器可启动
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"

# 层次 2：核心模块可 import（Python 项目）
docker run --rm --platform linux/arm64 <IMAGE> \
  python3 -c "import <core_module>; print('OK')"

# 层次 3：进程探活（后台服务类项目）
docker run -d --platform linux/arm64 --name test-<project> \
  -p <HOST_PORT>:<CONTAINER_PORT> <IMAGE>
sleep 5
docker ps | grep test-<project>
docker logs test-<project> 2>&1 | tail -20

# 层次 4：HTTP 端口探活（服务类项目）
curl -s http://localhost:<HOST_PORT>/health || \
curl -s http://localhost:<HOST_PORT>/monitor/alive
docker stop test-<project>
```

### 5.2 运行时崩溃 → 增量 patch 修复

运行时发现的 bug，**不重新全量构建**，使用增量 patch 镜像：

```dockerfile
# Dockerfile.patch（示例）
FROM <IMAGE>:latest

# [FIX-RTE-001] 修复说明
COPY _patches/fixed_file.py /app/file.py
RUN find /app -name '*.pyc' -delete
```

```bash
docker build --platform linux/arm64 \
  -t <IMAGE>-patched:latest \
  -f Dockerfile.patch .
```

### 5.3 写报告

报告写入 `arm_builds_<date>/build_reports/<project>.json`，格式如下：

```json
{
  "project": "<project>",
  "status": "SUCCESS|FAILED",
  "image": "<OUTPUT_TAG_PREFIX>-<project>:latest",
  "source_image": "<SOURCE_IMAGE>",
  "build_status": "success|fail",
  "test_status": "pass|fail|skip",
  "verify_status": "PASS|FAIL|N/A",
  "verify_time": "YYYY-MM-DD",
  "migration_mode": "IMAGE_RECONSTRUCTION",
  "reconstruction_info": {
    "history_layers": "<总层数>",
    "opaque_layers": "<不透明层数，无则 0>",
    "opaque_layer_resolved": true,
    "layout_mode_used": "rebuild|full"
  },
  "changes_applied": ["BASE-IMAGE", "FIX-APT-SOURCE", "FIX-TORCH", "DELETE-CUDA-PKG", "COPY-FROM-X86"],
  "warnings": [
    {
      "type": "WARN-X86-NATIVE-SO",
      "file": "libs/librender_x86_64.so",
      "original_cmd": "COPY libs/librender_x86_64.so /usr/lib/librender.so",
      "impact": "x86_64 native .so 已移除，依赖此库的功能在 ARM64 上不可用",
      "action_required": "如需恢复，请提供 aarch64 版本的 librender.so"
    },
    {
      "type": "WARN-OPAQUE-LAYER",
      "layer_size": "<XXX>MB",
      "resolved": true,
      "method": "layout full 模式定位 + docker cp"
    }
  ],
  "runtime_issues_found": [],
  "notes": "<关键重建决策说明>",
  "timestamp": "<ISO8601>"
}
```

### 5.3a 主 Agent 总览报告（`_summary.json`）

格式与 DOCKERFILE_MIGRATION.md § 5.3a 相同，`migration_mode` 字段改为 `IMAGE_RECONSTRUCTION`。

### 5.4 经验沉淀

若遇到 `BUILD_KNOWLEDGE.md` 未收录的新错误：
- 修复后**先写项目报告**，再追加到 `BUILD_KNOWLEDGE.md` 对应章节

---

## 决策速查卡（执行时随时参考）

```
基础镜像有 ARM64 manifest？
  → 无 → FAILED(NO_ARM64_SUPPORT)，停止
  → 有 → 继续

history 中有不透明层（/bin/bash，Size > 0）？
  → 有 → 必须运行 layout --mode full，查 directory_tree 补全
  → 无 → layout --mode rebuild 即可

history 中有 git clone 内网地址？
  → 可直连（GIT_HOSTS 命中） → 保留 git clone，直接重建
  → 不可达 → PHASE 2 docker cp 提取 + COPY 替换

提取资源中有 .so 文件？
  → 文件名含 x86_64/amd64 → 扫描 ELF 架构
      → x86-64 ELF → 按三类策略处理（§ 2.3）
  → 文件名不含架构关键词 → [WARN-ARCH-KEYWORD] 人工确认

pip_packages 含 CUDA 相关包？
  → nvidia-*/triton/cudnn → 全部删除
  → torch+cuXXX → 查 TORCH_VERSION_MAP → 替换为 CPU-only

layout 中有 ENV 变量？
  → 全部还原到 Dockerfile ENV 层，不遗漏

不透明层内容无法还原？
  → 标记 [WARN-OPAQUE-LAYER-UNRESOLVED]
  → 继续构建，测试阶段发现缺失功能再补充
```

---

## 与 DOCKERFILE_MIGRATION.md 的对比

| 维度 | IMAGE_RECONSTRUCTION（本文件） | DOCKERFILE_MIGRATION |
|------|------|------|
| **前提条件** | 只有现成镜像，无 Dockerfile | 有 Dockerfile，有仓库访问权限 |
| **信息来源** | docker history + layout + manifest | Dockerfile 本身 |
| **额外阶段** | PHASE 0 逆向采集 + PHASE 1 决策矩阵 | 无（直接 PHASE 1 解析 Dockerfile） |
| **最大风险** | 不透明层内容无法完整还原 | COPY/ADD 外部资源缺失 |
| **docker cp 用途** | PHASE 2 必须（提取内网资源/不透明层文件） | §1.5 ② 按需（缺失资源备选方案） |
| **构建产物置信度** | 中（依赖逆向推断，可能不完整） | 高（Dockerfile 是权威信息源） |
```
