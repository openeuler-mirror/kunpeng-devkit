# Dockerfile → ARM64 迁移（有 Dockerfile + 仓库访问权限）

> **适用场景**：已有 x86_64 Dockerfile，ARM 执行机对源码仓库和镜像仓库有直接访问权限。
> `docker cp` 仅在 § 1.5 ② 从 x86 镜像提取缺失资源时按需使用，不用于反推 Dockerfile。

---

## Agent 编排（主 Agent + 子 Agent）

### 主 Agent 职责

```
启动阶段：
  1. 读取 config.yaml，校验 § 2 必填项（AIRGAP_MODE=true 时额外校验）
  2. 网络连通性探测（★ 分发任务前统一执行一次，结果存入 NETWORK_CTX）
     → 详见 SKILL.md § ② Step 3；探测完成后得到：
       · dockerhub_official / dockerhub_web 是否可达
       · 每条 INTERNAL_REGISTRIES 是否可达
       · primary_mirror（官方不可达时的首个可用国产镜像站，否则为 null）
  3. WORKER_COUNT = 1  → 单任务模式：主 Agent 自身直接顺序执行全部项目的 PHASE 1-5
                          （执行时携带 NETWORK_CTX，不再重复探测）
     WORKER_COUNT ≥ 2  → 并发模式：
       4. 收集所有 Dockerfile，得到完整项目列表（共 N 个）
       5. 将 N 个项目均分为 WORKER_COUNT 份（余数项追加到前几个 Worker）
          示例：12 个项目 / 4 Worker → 每个 Worker 分得 3 个项目
          示例：10 个项目 / 4 Worker → Worker-1/2 各 3 个，Worker-3/4 各 2 个
       6. 一次性同时启动全部 WORKER_COUNT 个子 Agent，
          每个子 Agent 的启动 prompt 携带：自己的项目列表 + NETWORK_CTX

运行阶段：等待所有子 Agent 完成（各自独立运行，无需干预轮转）
  可选监控：每隔 WORKER_STALL_TIMEOUT_MIN 分钟检查子 Agent 状态：
    ✓ 正常推进  → 无需干预
    ✗ 卡住      → 执行干预流程（见下方）
    ✗ 崩溃/退出 → 读取最后日志，判断是否重启

结束阶段：所有子 Agent 返回后汇总报告，输出 _summary.json
```

### 主 Agent 干预流程（子 Agent 卡住时）

```
触发：子 Agent 超过 WORKER_STALL_TIMEOUT_MIN 分钟无进展

Step 1  读取最近 50 行日志，识别原因：
          - docker build 无输出（网络/编译卡死）
          - pip install 重试（源不可达）
          - 等待确认（[WARN-*] 未处理）

Step 2  注入修复：
          网络卡住  → 检查 AIRGAP_MODE，切换备用 pip 源
          等待确认  → 自动决策：
                        [WARN-ARCH-KEYWORD]  → 按 [FIX-PLATFORM] 规则修复
                        [WARN-X86-NATIVE-SO] → 自动注释 + 记录 WARNING，继续构建
                        其他 [WARN-*]        → 注释问题行，继续构建，报告中标注

Step 3  注入后仍无进展 → 强制中止，标记 FAILED(STALLED)，继续处理其他项目

Step 4  所有干预动作记录到 _summary.json interventions 数组
```

### 子 Agent 职责

```
启动时收到主 Agent 分配的项目列表 + NETWORK_CTX，按顺序逐个执行，全部完成后退出：

# 启动 prompt 中的 NETWORK_CTX 示例（由主 Agent 在探测后注入，子 Agent 直接使用，不再重复探测）：
# NETWORK_CTX = {
#   dockerhub_official:  reachable,
#   dockerhub_web:       reachable,
#   internal_registries: {"harbor.example.com": reachable},
#   primary_mirror:      null,          # 官方可达，无需镜像站
#   mirrors_checked:     []
# }
# 或（官方不可达时）：
# NETWORK_CTX = {
#   dockerhub_official:  unreachable,
#   primary_mirror:      "https://mirror.ccs.tencentyun.com",
#   mirrors_checked:     [{url: "https://mirror.ccs.tencentyun.com", status: "reachable"}, ...]
# }

for each project in 分配的项目列表：
  1. 检查磁盘空间（< MIN_DISK_SPACE_GB 则清理后重试，仍不足写 FAILED 报告跳过本项目）
  2. 已有 build_reports/<project>.json → 直接跳过
  3. 顺序执行：PHASE 1 → 2 → 3 → 4 → 5
     ⚑ 拉取镜像 / pip install 等网络操作：
       · NETWORK_CTX.dockerhub_official = reachable   → 直接使用官方源
       · NETWORK_CTX.primary_mirror ≠ null            → 镜像站替换规则（详细说明见下）：
           - FROM 语句：python:3.10 → <primary_mirror>/library/python:3.10
           - FROM 语句（官方库）：ubuntu:22.04 → <primary_mirror>/library/ubuntu:22.04
           - FROM 语句（用户库）：user/repo:tag → <primary_mirror>/user/repo:tag
           - pip/apt/npm 指向对应国内源（按 config.yaml PIP_INDEX_URL 等配置）
       · 所有 INTERNAL_REGISTRIES 均不可达            → 跳过内源拉取步骤，报告中标注
       
       ※ 镜像站替换详细规则：
         primary_mirror = "https://mirror.ccs.tencentyun.com" 时：
           FROM python:3.10-slim → FROM mirror.ccs.tencentyun.com/library/python:3.10-slim
           FROM myuser/myapp:v1  → FROM mirror.ccs.tencentyun.com/myuser/myapp:v1
         注意：DockerHub 官方镜像需补 /library/ 路径前缀
  4. 每完成一个 PHASE 输出日志：[WORKER-{id}] PHASE{n} DONE  project={project}  elapsed={sec}s
  5. 每完成一个 PHASE 立即写出中间工件（Dockerfile 草稿等）作为断点续跑检查点
  6. 遇到 [WARN-*] 时自动决策（子 Agent 并发运行中，无法等待人工）：
       [WARN-ARCH-KEYWORD]  → 按 [FIX-PLATFORM] 规则修复，继续构建
       [WARN-X86-NATIVE-SO] → 注释该依赖行，报告中标注 WARNING，继续构建
       其他 [WARN-*]        → 注释问题行，报告中标注，继续构建；无法自动修复则写 FAILED 报告跳过本项目
  7. 写出单项目报告（§ 5.3）后继续执行列表中下一个项目
```

---

## 整体流程（五阶段）

```
PHASE 1: 解析 x86 Dockerfile（信息提取 + 兼容性分析）
PHASE 2: 生成迁移决策表（差异清单，自动决策执行）
PHASE 3: 输出 ARM64 Dockerfile
PHASE 4: 构建验证
PHASE 5: 运行时测试 + 固化报告
```

---

## PHASE 1 · 解析 x86 Dockerfile

### 1.1 读取配置

```
从 config.yaml 获取：
  INTERNAL_REGISTRIES     内网镜像仓地址（识别 FROM 是否内网）
  GIT_HOSTS               ARM 机可直连的 git 域名
  INTERNAL_PYPI_HOSTS     ARM 机可直连的内网 PyPI
  PIP_INDEX_URL           公开 pip 镜像源
  AIRGAP_MODE             true 时禁止公网域名
  CUDA_PACKAGES_SKIP      需删除的 CUDA/GPU 包前缀
  TORCH_VERSION_MAP       torch CUDA 版 → CPU-only 映射
  FORCE_VERSION_OVERRIDES 末尾强制覆盖的包版本
```

### 1.2 FROM 指令分析

```
A. 含 INTERNAL_REGISTRIES 域名（内网镜像）
   → 按优先级推断 ARM64 tag：
       {repo}:{tag}-arm64  /  {repo}:{tag}_arm64  /  {repo}:{tag}-aarch64  /  {repo}-arm64:{tag}
   → 标记 [CHANGE-FROM-GUESS]，注释列出完整候选
   ⚠️ 所有候选 tag pull 返回 manifest unknown → 启用备选方案：
       - 方案 A（推荐）：读取镜像 metadata (docker inspect)，提取 OS/Python 版本信息
         → 降级到对应公开官方镜像（如 ubuntu:22.04 / python:3.10-slim）
         → 标记 [FALLBACK-TO-PUBLIC-BASE]，报告中说明原内网镜像信息
       - 方案 B（手动干预）：WORKER_COUNT=1 时暂停，输出候选 tag 列表，等用户提供正确 tag
         → WORKER_COUNT≥2 时无法暂停，写 FAILED(INTERNAL_IMAGE_UNAVAILABLE) 报告，跳过本项目

B. 公开镜像（DockerHub / 官方）
   → 加 --platform=linux/arm64
   → 标记 [KEEP-FROM-PUBLIC]
```

### 1.3 RUN 指令分类

| 识别模式 | 动作 | 标记 |
|----------|------|------|
| `apt-get update/install` | 在 update 前注入 apt 源替换 | `[FIX-APT-SOURCE]` |
| 包名含 `:amd64` / `:x86_64` | 删除架构后缀 | `[FIX-APT-ARCH]` |
| `pip install` + CUDA 版 torch | → CPU-only（按 TORCH_VERSION_MAP） | `[FIX-TORCH]` |
| `pip install` + `nvidia-*` / `triton` / `cudnn` | 删除整个包 | `[DELETE-CUDA-PKG]` |
| `pip install` + 外网 pip 源 | 替换为 PIP_INDEX_URL | `[FIX-PIP-SOURCE]` |
| `pip install` + INTERNAL_PYPI_HOSTS 内网源 | 保留；无 `\|\| echo` 保护则追加 | `[KEEP-PIP-INTERNAL]` |
| `git clone` + GIT_HOSTS 域名 | 保留 | `[KEEP-GIT-INTERNAL]` |
| `git clone` + 外网 | 保留，注释提示确认 | `[KEEP-GIT-PUBLIC]` |
| `npm install/ci` + 无内网源 | 追加 `--registry NPM_REGISTRY` | `[FIX-NPM-SOURCE]` |
| `wget/curl` + `archive.apache.org` | 替换为 APACHE_MIRROR | `[FIX-APACHE-MIRROR]` |
| `x86_64` / `amd64` / `i386` 关键词（非 pkg 后缀） | 按 [FIX-PLATFORM] 自动替换架构关键词，标记 WARN | `[WARN-ARCH-KEYWORD]` |
| `--platform=linux/amd64` | 改为 `linux/arm64` | `[FIX-PLATFORM]` |
| COPY/ADD/wget 引入 `.so` / `.a` / ELF | 按 § 1.3a 三类策略处理 | `[WARN-X86-NATIVE-SO]` / `[FIXED-SO-REPLACED-AARCH64]` |

### 1.3a x86 native `.so` 识别规则

```
识别条件（满足任意一条即判定为 x86 native 库）：
  A. COPY/ADD 的 src 文件名匹配 *.so* / *.a / *.o / *.dylib
  B. RUN wget/curl 下载 URL 含 x86_64/amd64/i686，后缀为 .so/.tar.gz/.zip
  C. RUN 含 ldconfig / ln -s *.so / install *.so，路径含 x86_64/amd64
  D. 构建输出出现 ELF 64-bit LSB ... x86-64

⚠️ 以下情况改为 [WARN-ARCH-KEYWORD] 人工确认（不自动删除）：
  - .so 文件名不含架构关键词
  - .so 是业务核心功能依赖（如 LWJGL、JNA native）→ 需找 aarch64 替代
```

**处理动作**：在该行上方追加注释（不硬删），并在报告 warnings 数组追加条目：

```dockerfile
# [WARN-X86-NATIVE-SO] 已去除：<原命令摘要>
# ⚠️  WARNING: x86_64 native 库已移除，相关功能在 ARM64 上不可用。
#             若该功能为必需，请提供 aarch64 版本替换。
# <原命令内容，注释掉>
```

### 1.4 ENV 指令分析

```
匹配以下模式 → 删整行，标记 [DELETE-CUDA-ENV]：
  CUDA_VERSION=*  /  NVIDIA_*=*  /  CUDNN_*=*  /  LD_LIBRARY_PATH 含 cuda 路径
```

### 1.5 COPY / ADD / wget 外部资源获取

```
待检查源：src 路径不在当前构建上下文，或 wget/curl 拉取非公开地址

① 内网 Git 仓库直连（首选）
   条件：src/URL 含 GIT_HOSTS 域名或判断为内网资源
   操作：直接 git clone/wget/curl → 成功 [KEEP-RESOURCE-FROM-GIT] → 失败进入 ②

② 从 x86 镜像提取
   docker pull --platform linux/amd64 <原 FROM 镜像> || { echo "[ERROR] pull x86 image failed"; exit 1; }
   CID=$(docker create --platform linux/amd64 --name _x86_tmp_$(date +%s) <镜像>) \
       || { echo "[ERROR] docker create failed"; exit 1; }
   docker export $CID | tar -t | grep -E "<资源文件名关键词>" > /tmp/resource_list.txt
   if [ ! -s /tmp/resource_list.txt ]; then
       echo "[ERROR] 资源未在镜像中找到"; docker rm $CID; exit 1
   fi
   docker cp $CID:<容器内路径> <本地构建上下文路径> \
       || { echo "[ERROR] docker cp failed"; docker rm $CID; exit 1; }
   docker rm $CID
   → Dockerfile 原行改为 COPY，行上方加：# [FIX-RESOURCE-FROM-X86]
   → 标记 [FIXED-RESOURCE-EXTRACTED-X86]

③ 均失败 → [WARN-MISSING-COPY-SRC]，记录报告并跳过本项目（子 Agent 无法等待人工）
```

### 1.5a 资源 so 兼容性检查（获取资源后必做）

```bash
# 扫描目录下所有 .so 文件的 ELF 架构
find <resource_path> -name "*.so*" -o -name "*.a" | \
  xargs -I{} file {} | grep -v "ARM aarch64\|symbolic link\|ASCII\|directory"

# JAR 包检查内嵌 native 库
unzip -l <path>.jar | grep -E "\.so|linux"
```

**判断**：出现 `x86-64` / `x86_64` / `80386` → 不兼容，按三类策略处理：

| 情况 | 处理 |
|------|------|
| 功能无关 / 可选 | 删除 .so，追加 `# [WARN-X86-NATIVE-SO]` |
| 功能相关 / 有 aarch64 替代 | 替换，追加 `# [FIXED-SO-REPLACED-AARCH64]` |
| 自研 / 无替代 | 标记 `FAILED: PROPRIETARY_X86_SO`，写失败报告，跳过本项目 |

```bash
# JAR 内替换 x86 so（示例）
zip -d <path>.jar "lib/linux-x86_64/libxxx.so"
zip -j <path>.jar <aarch64_libxxx.so>
```

---

## PHASE 2 · 生成迁移决策表

**[WARN-*] 处理规则**：

| 模式 | 行为 |
|------|------|
| 并发模式（WORKER_COUNT ≥ 2） | 子 Agent 自动决策，不暂停（无法等待人工）：WARN 项直接按下方自动决策策略处理 |
| 单任务模式（WORKER_COUNT = 1） | 列出所有 [WARN-*] 后**暂停**，等用户确认再继续 PHASE 3 |
| `[WARN-ARCH-KEYWORD]` | 自动替换架构关键词，报告中标注 |
| `[WARN-MISSING-COPY-SRC]` | 写 FAILED 报告，跳过本项目 |
| `[WARN-X86-NATIVE-SO]` | 注释该依赖行，报告中标注 WARNING，继续构建 |

**决策表格式**（每条指令一条记录）：

```
[FROM] L1  原: <image>  改: <arm64-image>  依据: <原因>  标记: [CHANGE-FROM-GUESS]
[RUN] L5   改: 注入 apt 源替换 + 删除 :amd64 后缀  标记: [FIX-APT-SOURCE] [FIX-APT-ARCH]
[COPY] L35 去除 x86_64 native .so  ⚠️ WARNING: 相关功能不可用  标记: [WARN-X86-NATIVE-SO]
────
汇总：自动处理 N 项，FAILED N 项，保留不变 N 项
```

> ℹ️ 存在 `[WARN-ARCH-KEYWORD]`：并发模式下自动替换架构关键词并继续构建；单任务模式下暂停等用户确认。
> ℹ️ 存在 `[WARN-MISSING-COPY-SRC]`：并发模式下写 FAILED 报告跳过本项目；单任务模式下暂停等用户确认。

---

## PHASE 3 · 输出 ARM64 Dockerfile

### 3.1 文件头注释（必须）

```dockerfile
# ════════════════════════════════════════════════════════
# ARM64 迁移 Dockerfile
# 原 Dockerfile：<source_path>    迁移日期：<YYYY-MM-DD>
#
# 关键变更：
#   [CHANGE-FROM-GUESS]  基础镜像 → 内网 ARM64 推断版本
#   [FIX-APT-SOURCE]     apt 源 → ubuntu-ports
#   [FIX-TORCH]          torch CUDA 版 → CPU-only
#   [DELETE-CUDA-PKG]    删除 nvidia-* / triton 等 CUDA 包
#   [DELETE-CUDA-ENV]    删除 CUDA_VERSION / NVIDIA_* ENV
#
# ⚠️ WARNINGS（功能可能受损）：
#   [WARN-X86-NATIVE-SO] 已去除 x86_64 native .so（见下方注释）
# ════════════════════════════════════════════════════════
```

### 3.2 每处修改附行内注释

```dockerfile
# [CHANGE-FROM-GUESS] <your-registry>/base-python310:v2.1 → arm64 推断版本
FROM --platform=linux/arm64 <your-registry>/base-python310-arm64:v2.1

# [FIX-APT-SOURCE] Ubuntu ARM64 必须使用 ubuntu-ports
# [FIX-APT-ARCH]   删除 libcuda1:amd64 的 :amd64 后缀
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends python3-dev build-essential libgl1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

### 3.3 FORCE_VERSION_OVERRIDES 追加层

若 config.yaml 有配置，在 Dockerfile **末尾**追加：

```dockerfile
# [FORCE-VERSION-OVERRIDES] 强制覆盖被依赖树拖回旧版本的包
RUN pip3 install "networkx>=2.6" -i <PIP_INDEX_URL> --quiet
```

### 3.4 输出路径

```
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64    ← 生成文件
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.x86_orig ← 原文件备份
```

---

## PHASE 4 · 构建验证

```bash
docker build --platform linux/arm64 \
  -t <OUTPUT_TAG_PREFIX>-<project>:latest \
  -f arm_builds_<date>/dockerfiles/<project>/Dockerfile.arm64 \
  <build_context>
```

**失败处理**：

```
1. 查 BUILD_KNOWLEDGE.md 对应关键词
2. 未找到 → 自行分析修复
3. Dockerfile 修改处追加 # [FIX-<N>] 原因 → 修复方式
4. retry_count++ → ≥ 5 次：FAILED(EXCEEDED_ATTEMPTS)
5. > 60min：FAILED(TIMEOUT)
```

**本场景特有错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `manifest unknown` | 推断的 ARM64 tag 不存在 | 检查候选列表，询问用户正确 tag |
| `fatal: unable to connect to git.xxx` | git clone 失败 | 确认 ARM 机网络 / SSH key |

---

## PHASE 5 · 运行时测试 + 固化报告

### 5.1 基础存活验证

```bash
# 层次 1：容器可启动
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"

# 层次 2：核心模块可 import（Python 项目）
docker run --rm --platform linux/arm64 <IMAGE> python3 -c "import <core_module>; print('OK')"

# 层次 3：HTTP 端口探活（服务类项目）
docker run -d --platform linux/arm64 --name test-<project> -p <HOST>:<CONTAINER> <IMAGE>
sleep 5
curl -s http://localhost:<HOST>/health || curl -s http://localhost:<HOST>/monitor/alive
docker stop test-<project>
```

### 5.2 运行时崩溃 → 增量 patch 修复

**不重新全量构建**，使用增量 patch 镜像：

```dockerfile
FROM <IMAGE>:latest
# [FIX-RTE-001] 修复说明
COPY _patches/fixed_server.py /app/server.py
RUN find /app -name '*.pyc' -delete
```

```bash
docker build --platform linux/arm64 -t <IMAGE>-patched:latest -f Dockerfile.patch .
```

### 5.3 写报告

`arm_builds_<date>/build_reports/<project>.json`：

```json
{
  "project": "<project>",
  "status": "SUCCESS|FAILED",
  "failure_reason": "<枚举值，见 BUILD_KNOWLEDGE.md 附录；成功时省略>",
  "image": "<OUTPUT_TAG_PREFIX>-<project>:latest",
  "build_status": "success|fail",
  "test_status": "pass|fail|skip",
  "migration_mode": "IMAGE_MIG_SKILLSET",
  "retry_count": 0,
  "changes_applied": ["CHANGE-FROM-GUESS", "FIX-APT-SOURCE", "FIX-TORCH"],
  "warnings": [
    {
      "type": "WARN-X86-NATIVE-SO",
      "file": "libs/librender_x86_64.so",
      "original_cmd": "COPY libs/librender_x86_64.so /usr/lib/librender.so",
      "impact": "x86_64 native .so 已移除，相关功能不可用",
      "action_required": "提供 aarch64 版本并更新 COPY 路径"
    }
  ],
  "notes": "<关键变更说明>",
  "timestamp": "<ISO8601>"
}
```

### 5.3a 主 Agent 总览报告（`_summary.json`）

```json
{
  "total": 7, "success": 5, "failed": 2, "worker_count": 3, "elapsed_min": 83,
  "projects": [
    { "project": "projectA", "status": "SUCCESS", "worker_id": 1 },
    { "project": "projectB", "status": "FAILED",  "worker_id": 2, "reason": "STALLED" }
  ],
  "interventions": [
    { "worker_id": 2, "project": "projectB", "trigger": "WARN-X86-NATIVE-SO",
      "action": "auto-commented + WARNING recorded", "resolved": true }
  ],
  "timestamp": "<ISO8601>"
}
```

---

## 决策速查卡

```
git clone 是内网仓？
  GIT_HOSTS 命中 → 保留    /    未命中 → 保留，注释提示确认网络

pip install 是内网源？
  INTERNAL_PYPI_HOSTS 命中 → 保留 + 加 || echo WARNING 保护
  未命中 → 替换为 PIP_INDEX_URL

FROM 是内网镜像？
  INTERNAL_REGISTRIES 命中 → 推断 -arm64 tag，注释列出候选
  公开镜像 → 加 --platform=linux/arm64
  pull 失败（manifest unknown） → 停下询问用户

COPY/ADD/wget 资源缺失？（§ 1.5）
  ① GIT_HOSTS 命中 → 直连拉取 [KEEP-RESOURCE-FROM-GIT]
  ② ① 失败 → docker cp 从 x86 镜像提取 [FIXED-RESOURCE-EXTRACTED-X86]
  均失败 → [WARN-MISSING-COPY-SRC]，并发模式：写 FAILED 跳过；单任务模式：暂停等用户确认

torch 含 +cu?  → TORCH_VERSION_MAP 精确替换 / 无精确映射 → 去掉 +cuXXX
nvidia-* / triton / cudnn?  → 全部删除
*.so / ELF binary?
  文件名含 x86_64/amd64 → 自动注释 + [WARN-X86-NATIVE-SO]
  文件名不含架构关键词  → [WARN-ARCH-KEYWORD] 自动替换架构关键词，报告中标注
  自研 .so / 无 aarch64 替代  → FAILED: PROPRIETARY_X86_SO，跳过本项目
```
