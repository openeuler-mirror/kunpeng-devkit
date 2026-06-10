# Dockerfile → ARM64 迁移（有 Dockerfile + 仓库访问权限）

> **适用场景**：已有 x86_64 Dockerfile，且 ARM 执行机对**源码仓库**和**镜像仓库**有直接访问权限，无需离线提取资源。
>
> **触发关键词**：`从 Dockerfile 迁移 arm64` / `有 Dockerfile 迁移` / `Dockerfile 改 arm` / `dockerfile to arm64` / `有源码仓权限迁移`
>
> **与通用流程的区别**：无需运行 `inspect_image_history.sh` / `inspect_image_layout.py` / `docker history` / `docker manifest inspect` 逆向解析层结构，Dockerfile 本身即信息源。
> `docker cp` 仅在 § 1.5 ② 从 x86 镜像提取缺失资源时按需使用，不用于反推 Dockerfile。

---

## 必读文件（每次任务启动前）

```
本文件（DOCKERFILE_MIGRATION.md）          ← 完整执行流程
config.yaml                              ← 可配置参数（仓库地址、镜像源等）★ 启动前必须确认已按实际环境修改
BUILD_KNOWLEDGE.md                       ← 构建/修复知识库（遇到错误先查这里，包含规则和速查）
```

---

## Agent 编排（主 Agent + 子 Agent）

> 本 Skill 默认以**并发模式**运行：1 个主 Agent 管理调度，`WORKER_COUNT`（默认 3）个子 Agent 并行执行各自的迁移任务。
> 可通过 `config.yaml § 0` 调整并发数和超时阈值。

### 主 Agent 职责

```
启动阶段：
  1. 读取 config.yaml，校验必填项（§ 2 内网地址不能留占位符；AIRGAP_MODE=true 时额外校验）
  2. 检查 WORKER_COUNT：
       WORKER_COUNT = 1  → 单任务模式：主 Agent 自身直接执行 PHASE 1-5，不再启动子 Agent
       WORKER_COUNT ≥ 2  → 并发模式：按以下步骤进行
  3. 收集所有待迁移的 Dockerfile 列表，按项目名拆分任务队列
  4. 按 WORKER_COUNT 启动子 Agent，每个子 Agent 分配一个项目任务

运行阶段（持续监控）：
  每隔 WORKER_STALL_TIMEOUT_MIN 分钟检查一次所有子 Agent 状态：
    ✓ 正常推进  → 无需干预，记录进度
    ✗ 无新日志输出（卡住）→ 执行干预流程（见下方）
    ✗ 子 Agent 崩溃/退出  → 读取其最后日志，判断是否可自动重启

  子 Agent 完成后：
    → 从任务队列取下一个项目，启动新的子 Agent（保持并发数不超过 WORKER_COUNT）

结束阶段：
  所有项目完成后，汇总各子 Agent 的报告，输出总览报告（SUCCESS / FAILED 统计）
```

### 主 Agent 干预流程（子 Agent 卡住时）

```
触发条件：子 Agent 超过 WORKER_STALL_TIMEOUT_MIN 分钟无任何进展

干预步骤：
  Step 1  读取该子 Agent 最近 50 行日志，识别卡住原因：
            - docker build 长时间无输出（网络拉取/编译卡死）
            - pip install 一直重试（源不可达）
            - 等待人工确认（[WARN-*] 未处理）

  Step 2  根据原因注入修复：
            网络卡住  → 检查 AIRGAP_MODE 配置，切换备用 pip 源（§ 4 备选列表）
            等待确认  → 主 Agent 代为决策：
                          [WARN-ARCH-KEYWORD]   → 按 [FIX-PLATFORM] 规则自动修复
                          [WARN-X86-NATIVE-SO]  → 自动注释掉 + 记录 WARNING，继续构建
                          其他 [WARN-*]         → 保守处理：注释问题行，继续构建，报告中标注

  Step 3  若注入后 WORKER_STALL_TIMEOUT_MIN 分钟仍无进展 → 强制中止该子 Agent，
          在报告中标记 FAILED(STALLED)，继续处理队列中的其他项目

  Step 4  所有干预动作记录到总览报告的 interventions 数组
```

### 子 Agent 职责

```
每个子 Agent 独立完成单个项目的完整迁移：
  PHASE 1 → PHASE 2 → PHASE 3 → PHASE 4 → PHASE 5

关键约束：
  - 子 Agent 不感知其他子 Agent 的状态，只管自己的项目
  - 每完成一个 PHASE 输出一条结构化日志（供主 Agent 监控）：
      [WORKER-{id}] PHASE{n} DONE  project={project}  elapsed={sec}s
  - 遇到需要人工确认的 [WARN-*]，先挂起并通知主 Agent，
    等待主 Agent 决策（或超时后主 Agent 自动处理）
  - 退出时写出标准格式的单项目报告（§ 5.3）
```

### 启动示例

```
用户提供：
  - 待迁移镜像列表（migration_list.txt）
  - Dockerfile 索引文件（dockerfile_index.yaml）或等效的路径规律描述
  - 已填好的 config.yaml

主 Agent 启动后输出：
  [MAIN] 发现 7 个项目，WORKER_COUNT=3，分 3 批执行
  [MAIN] 启动 Worker-1 → projectA
  [MAIN] 启动 Worker-2 → projectB
  [MAIN] 启动 Worker-3 → projectC
  ...
  [MAIN] Worker-2 已卡住 20min（原因：等待确认 [WARN-X86-NATIVE-SO]），自动干预
  [MAIN] Worker-2 干预成功，恢复执行
  ...
  [MAIN] 全部完成：5 SUCCESS / 2 FAILED  总耗时 1h23m
  [MAIN] 总览报告 → arm_builds_20260609/build_reports/_summary.json
```

---

## 整体流程（五阶段）

> 以下为**单个子 Agent** 执行一个项目时的完整流程。

```
PHASE 1: 解析 x86 Dockerfile（信息提取 + 兼容性分析）
PHASE 2: 生成迁移决策表（差异清单，人工确认或直接执行）
PHASE 3: 输出 ARM64 Dockerfile
PHASE 4: 构建验证
PHASE 5: 运行时测试 + 固化报告
```

---

## PHASE 1 · 解析 x86 Dockerfile

> **目标**：逐条读取输入 Dockerfile，分类标记每条指令的迁移动作。

### 1.1 读取配置

```
先读取 config.yaml，获取：
  INTERNAL_REGISTRIES     ← 内网镜像仓地址（用于识别 FROM 是否为内网镜像）
  GIT_HOSTS               ← ARM 机可直连的 git 仓库域名
  INTERNAL_PYPI_HOSTS     ← ARM 机可直连的内网 PyPI 地址
  PIP_INDEX_URL           ← 公开 pip 镜像源（国内加速）
  AIRGAP_MODE             ← true 时禁止出现公网域名
  CUDA_PACKAGES_SKIP      ← 需要删除的 CUDA/GPU 包前缀列表
  TORCH_VERSION_MAP       ← torch CUDA 版本 → CPU-only 版本映射
  FORCE_VERSION_OVERRIDES ← 需要在末尾强制覆盖的包版本
  WORKER_COUNT            ← 并发子 Agent 数量（主 Agent 用于分发任务）
```

### 1.2 FROM 指令分析

```
① 提取 FROM 中的镜像名（去掉已有的 --platform 参数）

② 判断类型：
   A. 镜像地址含 INTERNAL_REGISTRIES 中的域名（内网镜像）
      → 自动推断 ARM64 tag（按优先级依次尝试）：
          {repo}:{tag}-arm64
          {repo}:{tag}_arm64
          {repo}:{tag}-aarch64
          {repo}-arm64:{tag}
      → 标记 [CHANGE-FROM-GUESS]，在注释中列出完整候选列表，提示人工确认

   B. 公开镜像（DockerHub / 官方镜像）
      → 加 --platform=linux/arm64，docker buildx 自动拉 arm64 层
      → 标记 [KEEP-FROM-PUBLIC]

   ⚠️ 若推断的内网 ARM64 tag 在 pull 时返回 manifest unknown，
      立即停下来提示用户提供正确的 ARM64 镜像地址，不要继续构建。
```

### 1.3 RUN 指令分类

对每条 `RUN` 指令，逐一识别以下模式（一条 RUN 可命中多个）：

| 识别模式 | 动作 | 标记 |
|---------|------|------|
| `apt-get update` / `apt-get install` | 在 update 前注入 apt 源替换 sed 命令 | `[FIX-APT-SOURCE]` |
| 包名含 `:amd64` / `:x86_64` 后缀 | 删除架构后缀 | `[FIX-APT-ARCH]` |
| `pip install` / `pip3 install` + 含 CUDA 版 torch | torch CUDA 版 → CPU-only 版（按 TORCH_VERSION_MAP） | `[FIX-TORCH]` |
| `pip install` + 含 `nvidia-*` / `triton` / `cudnn` 等 | 删除整个包参数 | `[DELETE-CUDA-PKG]` |
| `pip install` + 使用外网 pip 源（非内网） | 替换 `-i` 参数为 PIP_INDEX_URL | `[FIX-PIP-SOURCE]` |
| `pip install` + 使用 INTERNAL_PYPI_HOSTS 中的内网源 | 保留（ARM 机可直连）；若无 `\|\| echo` 保护则追加 | `[KEEP-PIP-INTERNAL]` |
| `git clone <url>` + url 含 GIT_HOSTS 域名 | 保留（ARM 机可直连）| `[KEEP-GIT-INTERNAL]` |
| `git clone <url>` + url 为外网 | 保留，注释提示确认网络可达 | `[KEEP-GIT-PUBLIC]` |
| `npm install` / `npm ci` + 无内网源 | 追加 `--registry NPM_REGISTRY` | `[FIX-NPM-SOURCE]` |
| `wget/curl` + `archive.apache.org` | 替换为 APACHE_MIRROR | `[FIX-APACHE-MIRROR]` |
| `x86_64` / `amd64` / `i386` 关键词（非 pkg 后缀） | 标记 ⚠ 人工确认 | `[WARN-ARCH-KEYWORD]` |
| `--platform=linux/amd64` 参数 | 改为 `--platform=linux/arm64` | `[FIX-PLATFORM]` |
| COPY / ADD / wget 引入 `.so` / `.a` / ELF 二进制文件（含 x86 native 库） | 按 §1.3a 三类策略处理（功能无关/删除、有替代/替换、自研/失败） | `[WARN-X86-NATIVE-SO]` / `[FIXED-SO-REPLACED-AARCH64]` |

### 1.3a x86 native `.so` 识别规则（重要）

以下情形判定为「深度绑定 x86 的 native 库」，**自动去掉引入步骤，但必须同时在 Dockerfile 和报告中写入 WARNING**：

```
识别条件（满足任意一条）：
  A. COPY / ADD 的 src 文件名匹配：*.so* / *.a / *.o / *.dylib
  B. RUN wget/curl 下载的 URL 含：x86_64 / amd64 / i686 且文件后缀为 .so/.tar.gz/.zip
  C. RUN 命令中含：ldconfig / ln -s *.so / install *.so 且路径含 x86_64/amd64
  D. 构建阶段输出出现：ELF 64-bit LSB ... x86-64（file 命令输出）

⚠️  注意：以下情况不自动删除，改为 [WARN-ARCH-KEYWORD] 人工确认：
  - .so 文件名不含架构关键词（无法确定是否 x86 专属）
  - .so 是业务核心功能依赖（如 Minecraft LWJGL、JNA native）
    → 这类需要找 aarch64 替代版本，不能直接删，见 BUILD_KNOWLEDGE.md §6
```

**处理动作**：
1. 注释掉（不硬删）引入 `.so` 的 COPY/RUN 行，保留原内容供参考
2. 在该行上方追加：
   ```dockerfile
   # [WARN-X86-NATIVE-SO] 已去除：<原命令摘要>
   # ⚠️  WARNING: x86_64 native 库已移除，相关功能在 ARM64 上不可用。
   #             若该功能为必需，请提供 aarch64 版本替换。
   # <原命令内容，注释掉>
   ```
3. 在报告 `warnings` 数组中追加条目（见 §5.3）

### 1.4 ENV 指令分析

```
检查 ENV 变量名，匹配以下模式则删除整行：
  CUDA_VERSION=*
  NVIDIA_*=*
  CUDNN_*=*
  LD_LIBRARY_PATH 中含 cuda 路径

标记：[DELETE-CUDA-ENV]
```

### 1.5 COPY / ADD / wget 外部资源获取

```
待检查源：COPY / ADD 的 src 路径不存在于当前构建上下文，
      或 RUN wget/curl 拉取的 URL 指向非公开地址。

① 内网 Git 仓库直连（首选）
   条件：src 或 URL 含 GIT_HOSTS 中的域名，或判断为内网资源
   操作：
     - 尝试直接 git clone / wget / curl 获取
     - 成功后标记 [KEEP-RESOURCE-FROM-GIT]，继续 PHASE 3
     - 失败则进入 ②

② 从 x86 镜像提取（兼容层提取）
   条件：① 失败，或资源来自构建上下文 / 局域文件系统
   操作：
     a. 在当前 ARM 环境下拉取 x86 基础镜像：
          docker pull --platform linux/amd64 <原 FROM 镜像>
     b. 启动临时容器并定位资源：
          docker create --platform linux/amd64 --name _x86_tmp <镜像>
          docker export _x86_tmp | tar -t | grep -E "<资源文件名关键词>"
     c. 将资源 cp 到本地构建上下文：
          docker cp _x86_tmp:<容器内路径> <本地构建上下文路径>
          docker rm _x86_tmp
     d. 将 Dockerfile 中原行改为 COPY 引用本地文件，并在行上方添加：
          # [FIX-RESOURCE-FROM-X86] 资源来源：从 x86 镜像 <镜像名> 提取至 <本地路径>
     e. 成功后标记 [FIXED-RESOURCE-EXTRACTED-X86]

③ 两种方式均失败
   → 标记 [WARN-MISSING-COPY-SRC]，暂停并说明已尝试的方式，等待人工确认资源来源
```

**步骤 ② 快捷命令参考**：
```bash
# 拉取 x86 镜像并创建临时容器
docker pull --platform linux/amd64 <IMAGE>
docker create --platform linux/amd64 --name _x86_tmp <IMAGE>

# 查找资源文件位置
docker export _x86_tmp | tar -t | grep -i "<关键词>"

# 提取到本地
docker cp _x86_tmp:/path/to/resource ./build_context/resource

# 清理临时容器
docker rm _x86_tmp
```

### 1.5a 资源 so 兼容性检查（必做，获取资源后立即执行）

> **无论通过 ① 还是 ② 成功拿到资源，都必须在构建前对资源内容做 so 兼容性扫描。**

```
扫描目标：
  - 拉取的目录 / 压缩包 / JAR 中所有 *.so* / *.a / *.o 文件
  - 资源包本身如为二进制（无扩展名的可执行文件同样检查）

检查命令：
  # 扫描目录下所有 .so 文件的 ELF 架构
  find <resource_path> -name "*.so*" -o -name "*.a" | \
    xargs -I{} file {} | grep -v "ARM aarch64\|symbolic link\|ASCII\|directory"

  # 对 JAR 包：检查内嵌 native 库
  unzip -l <path>.jar | grep -E "\.so|linux"

判断规则：
  输出中出现 "x86-64" / "x86_64" / "80386" → 该 .so 不兼容 ARM64
  输出中出现 "ARM aarch64" / "AArch64"      → 兼容，无需处理
  输出为空 / 纯文本脚本                      → 无 native 库，安全
```

**发现不兼容 so 时，按 § 1.3a 的三类处理策略处理**：

| 情况 | 处理 |
|------|------|
| 功能无关 / 可选（如性能采集、调试 hook） | 从资源包中删除该 .so，追加 `# [WARN-X86-NATIVE-SO]` |
| 功能相关 / 有公开 aarch64 替代版本 | 替换为 aarch64 版本，追加 `# [FIXED-SO-REPLACED-AARCH64]` |
| 自研 / 无源码 / 无替代 | **暂停**，标记 `FAILED: PROPRIETARY_X86_SO`，说明资源路径和 .so 名称，等待人工处理 |

```bash
# 替换 JAR 内 x86 so 为 aarch64 版本（示例）
zip -d <path>.jar "lib/linux-x86_64/libxxx.so"
zip -j <path>.jar <aarch64_libxxx.so>

# 从目录资源中删除不兼容 so（功能无关时）
rm <resource_path>/lib/libxxx_x86_64.so
```

---

## PHASE 2 · 生成迁移决策表

输出标准格式决策表。

**[WARN-*] 处理规则（并发与单任务模式统一）：**

| 模式 | [WARN-*] 出现时的行为 |
|------|----------------------|
| 并发模式（WORKER_COUNT ≥ 2） | 子 Agent **不暂停**，将 WARN 项上报给主 Agent；主 Agent 按干预流程自动决策，子 Agent 继续执行 |
| 单任务模式（WORKER_COUNT = 1） | 列出所有 [WARN-*] 项后**暂停**，等待用户确认后再继续 PHASE 3 |
| 严重 WARN（`[WARN-MISSING-COPY-SRC]` / `[WARN-ARCH-KEYWORD]`） | 两种模式下均**暂停**，必须人工确认（注：`[WARN-MISSING-COPY-SRC]` 仅在 § 1.5 ①② 均失败后才出现） |
| 普通 WARN（`[WARN-X86-NATIVE-SO]`） | 并发模式下主 Agent 自动决策（注释掉问题行）；单任务模式下暂停等用户确认 |

```
════════════════════════════════════════════════════════
 Dockerfile ARM64 迁移决策表
 原文件：<input_dockerfile>
 日期：<YYYY-MM-DD>
 ARM64 执行机可访问：源码仓 <GIT_HOSTS>，镜像仓 <INTERNAL_REGISTRIES>
════════════════════════════════════════════════════════

[FROM] L1
  原: FROM registry.example.com/base-python310:v2.1
  改: FROM registry.example.com/base-python310-arm64:v2.1
  依据: 内网镜像，自动推断 -arm64 后缀（需确认该 tag 存在）
  标记: [CHANGE-FROM-GUESS]

[RUN] L5  apt-get update && apt-get install -y ...
  改: 在 apt-get update 前注入 sed 替换 apt 源 → mirrors.aliyun.com/ubuntu-ports
  改: 删除 libcuda1:amd64 包名 :amd64 后缀
  标记: [FIX-APT-SOURCE] [FIX-APT-ARCH]

[RUN] L12  pip install torch==2.8.0+cu124 torchvision nvidia-cudnn9-cu12
  改: torch==2.8.0+cu124 → torch==2.6.0（CPU-only，按 TORCH_VERSION_MAP）
  改: 删除 nvidia-cudnn9-cu12（CUDA_PACKAGES_SKIP 命中）
  改: --index-url https://download.pytorch.org/whl/cu124 → https://download.pytorch.org/whl/cpu
  标记: [FIX-TORCH] [DELETE-CUDA-PKG]

[RUN] L18  git clone https://git.company.com/team/project.git
  保留: git.company.com 在 GIT_HOSTS，ARM 机可直连
  标记: [KEEP-GIT-INTERNAL]

[RUN] L24  pip install internal-pkg -i http://pypi.company.com/simple
  保留: pypi.company.com 在 INTERNAL_PYPI_HOSTS，ARM 机可直连
  加保护: 追加 || echo "[ARM64-WARN] internal pip install failed, continuing"
  标记: [KEEP-PIP-INTERNAL]

[ENV] L30  CUDA_VERSION=12.4
  删除: CUDA/GPU ENV 变量（ARM64 无 GPU）
  标记: [DELETE-CUDA-ENV]

[COPY] L35  COPY libs/librender_x86_64.so /usr/lib/librender.so
  去除: x86_64 native .so 文件（ARM64 无法加载）
  ⚠️  WARNING: librender.so 为 x86_64 ELF，已注释掉 COPY 步骤。
              依赖此库的功能在 ARM64 上不可用，如需恢复请提供 aarch64 版本。
  标记: [WARN-X86-NATIVE-SO]

────────────────────────────────────────────────────────
 汇总：
   自动处理：6 项
   需人工确认（[WARN-*]）：1 项  ← [WARN-X86-NATIVE-SO]（并发模式由主 Agent 代决策）
   保留不变：3 项
════════════════════════════════════════════════════════
```

> ⚠️ 若存在 `[WARN-ARCH-KEYWORD]` 或 `[WARN-MISSING-COPY-SRC]` 条目，**无论并发/单任务模式均停止**，列出待确认项后等待人工处理，再生成 PHASE 3 Dockerfile。

---

## PHASE 3 · 输出 ARM64 Dockerfile

### 3.1 文件头注释（必须）

```dockerfile
# ════════════════════════════════════════════════════════════════════════
# ARM64 迁移 Dockerfile
# 原 Dockerfile：<source_path>
# 迁移日期：<YYYY-MM-DD>
# 说明：ARM64 执行机可直连源码仓/镜像仓，git clone 和内网 pip 均直接保留
#
# 关键变更（来自 PHASE 2 决策表）：
#   [CHANGE-FROM-GUESS]    基础镜像 → 内网 ARM64 推断版本（已确认 tag 存在）
#   [FIX-APT-SOURCE]       apt 源 → ubuntu-ports（Ubuntu ARM 必须）
#   [FIX-TORCH]            torch CUDA 版 → CPU-only
#   [DELETE-CUDA-PKG]      删除 nvidia-* / triton 等 CUDA 包
#   [DELETE-CUDA-ENV]      删除 CUDA_VERSION / NVIDIA_* ENV 变量
#
# ⚠️  WARNINGS（功能可能受损，需人工确认）：
#   [WARN-X86-NATIVE-SO]   已去除 x86_64 native .so，相关功能不可用（见下方注释）
# ════════════════════════════════════════════════════════════════════════
```

### 3.2 每处修改附行内注释

```dockerfile
# [CHANGE-FROM-GUESS] <your-registry>/base-python310:v2.1 → arm64 推断版本（内网镜像，-arm64 后缀）
FROM --platform=linux/arm64 <your-registry>/base-python310-arm64:v2.1

# [FIX-APT-SOURCE] Ubuntu ARM64 必须使用 ubuntu-ports，不能用 archive.ubuntu.com
# [FIX-APT-ARCH]   删除 libcuda1:amd64 的 :amd64 后缀
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends \
       python3-dev build-essential libgl1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

### 3.3 FORCE_VERSION_OVERRIDES 追加层

若 config.yaml 配置了 `FORCE_VERSION_OVERRIDES`，在 Dockerfile **末尾**追加一个强制覆盖层：

```dockerfile
# [FORCE-VERSION-OVERRIDES] 强制覆盖被依赖树拖回旧版本的包
# 原因：某些包（如 pyrender）会将 networkx 降回 2.2，但 networkx 2.2 在 Python 3.10 已不兼容
RUN pip3 install \
    "networkx>=2.6" \
    -i <PIP_INDEX_URL> \
    --quiet
```

### 3.4 输出路径

按 config.yaml `OUTPUT_DOCKERFILE_DIR` 模板写出：
```
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64
```

同时将原始 Dockerfile 保留为：
```
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.x86_orig
```

---

## PHASE 4 · 构建验证

```bash
# 使用 config.yaml OUTPUT_TAG_PREFIX 构建
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

### 常见构建失败速查

> 完整错误库见 **`BUILD_KNOWLEDGE.md`**，此处仅列出本场景特有项：

| 错误 | 原因 | 修复方式 |
|------|------|---------|
| `manifest unknown` / 镜像拉取失败 | 推断的 ARM64 tag 不存在 | 检查 [CHANGE-FROM-GUESS] 候选列表；停下询问用户正确 tag |
| `fatal: unable to connect to git.xxx` | git clone 失败 | 确认 ARM 机网络，或检查 SSH key 配置 |

---

## PHASE 5 · 运行时测试 + 固化报告

### 5.1 基础存活验证

```bash
# 层次 1：容器可启动
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"

# 层次 2：核心模块可 import（Python 项目）
docker run --rm --platform linux/arm64 <IMAGE> \
  python3 -c "import <core_module>; print('OK')"

# 层次 3：HTTP 服务端口可达（HTTP server 类项目）
docker run -d --platform linux/arm64 --name test-<project> \
  -p <HOST_PORT>:<CONTAINER_PORT> <IMAGE>
sleep 5
curl -s http://localhost:<HOST_PORT>/health || \
curl -s http://localhost:<HOST_PORT>/monitor/alive
docker stop test-<project>
```

详细构建修复知识参见：`BUILD_KNOWLEDGE.md`

### 5.2 运行时崩溃 → 增量 patch 修复

运行时发现的 bug，**不重新全量构建**，使用增量 patch 镜像：

```dockerfile
# Dockerfile.patch（示例）
FROM <IMAGE>:latest

# [FIX-RTE-001] 修复说明
COPY _patches/fixed_server.py /app/server.py

# 清除 .pyc 缓存
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
  "build_status": "success|fail",
  "test_status": "pass|fail|skip",
  "verify_status": "PASS|FAIL|N/A",
  "verify_time": "YYYY-MM-DD",
  "migration_mode": "IMAGE_MIG_SKILLSET",
  "arm_machine_access": {
    "git_hosts": "<见 config.yaml GIT_HOSTS>",
    "pypi_hosts": "<见 config.yaml INTERNAL_PYPI_HOSTS>",
    "registry": "<见 config.yaml INTERNAL_REGISTRIES>"
  },
  "changes_applied": ["CHANGE-FROM-GUESS", "FIX-APT-SOURCE", "FIX-TORCH", "DELETE-CUDA-PKG"],
  "warnings": [
    {
      "type": "WARN-X86-NATIVE-SO",
      "file": "libs/librender_x86_64.so",
      "original_cmd": "COPY libs/librender_x86_64.so /usr/lib/librender.so",
      "impact": "x86_64 native .so 已移除，依赖此库的功能在 ARM64 上不可用",
      "action_required": "如需恢复，请提供 aarch64 版本的 librender.so 并更新 COPY 路径"
    }
  ],
  "runtime_issues_found": [],
  "notes": "<关键变更说明>",
  "timestamp": "<ISO8601>"
}
```

### 5.3a 主 Agent 总览报告（`_summary.json`）

主 Agent 在所有子 Agent 完成后，写出 `arm_builds_<date>/build_reports/_summary.json`：

```json
{
  "total": 7,
  "success": 5,
  "failed": 2,
  "worker_count": 3,
  "elapsed_min": 83,
  "projects": [
    { "project": "projectA", "status": "SUCCESS", "worker_id": 1 },
    { "project": "projectB", "status": "FAILED",  "worker_id": 2, "reason": "STALLED" }
  ],
  "interventions": [
    {
      "worker_id": 2,
      "project": "projectB",
      "trigger": "WARN-X86-NATIVE-SO",
      "action": "auto-commented + WARNING recorded",
      "resolved": true
    }
  ],
  "timestamp": "<ISO8601>"
}
```

### 5.4 经验沉淀

若遇到 `BUILD_KNOWLEDGE.md` 未收录的新错误：
- 修复后**先写项目报告**，再追加到 `BUILD_KNOWLEDGE.md` 对应章节

---

## 决策速查卡（执行时随时参考）

```
git clone 是内网仓？
  → GIT_HOSTS 命中 → 保留（ARM 机直连）
  → 未命中 → 保留，注释提示确认网络

pip install 是内网源？
  → INTERNAL_PYPI_HOSTS 命中 → 保留 + 加 || echo WARNING 保护
  → 未命中 → 替换为 PIP_INDEX_URL

FROM 是内网镜像？
  → INTERNAL_REGISTRIES 命中 → 自动推断 -arm64 tag，注释列出候选，提示确认
  → 公开镜像 → 加 --platform=linux/arm64
  → 推断后 pull 失败（manifest unknown） → 停下来询问用户

COPY / ADD / wget 的 src 资源不在构建上下文？（§ 1.5）
  ① 内网仓库直连（GIT_HOSTS 命中）→ 尝试直接拉取 → [KEEP-RESOURCE-FROM-GIT]
  ② ① 失败 → 拉 x86 镜像 → docker cp 提取到本地 → [FIXED-RESOURCE-EXTRACTED-X86]
  ③ 均失败 → [WARN-MISSING-COPY-SRC]，暂停等人工确认

torch 版本含 +cu?
  → 查 TORCH_VERSION_MAP → 精确替换
  → 无精确映射 → 去掉 +cuXXX 后缀

nvidia-* / triton / cudnn 包？
  → 全部删除（CUDA_PACKAGES_SKIP）

networkx / gym 版本过旧？
  → 追加 FORCE_VERSION_OVERRIDES 层

COPY / wget 引入 *.so / ELF binary？
  → 文件名含 x86_64/amd64 → 自动注释掉 + [WARN-X86-NATIVE-SO]
  → 文件名不含架构关键词 → [WARN-ARCH-KEYWORD] 人工确认
  → 业务核心 .so（如 LWJGL/JNA）→ 人工处理，找 aarch64 替代版本
```
