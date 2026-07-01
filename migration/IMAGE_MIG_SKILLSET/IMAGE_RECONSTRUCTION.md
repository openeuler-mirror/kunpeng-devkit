# 纯镜像重构（无 Dockerfile + history/layout/manifest 逆向分析）

> **适用场景**：只有现成的 x86_64 镜像，没有 Dockerfile，通过逆向分析镜像结构重建 ARM64 版本。
> 信息源：`docker history`（层命令）+ `inspect_image_layout`（容器内状态）+ `docker manifest`（基础镜像支持判断）。

---

## Agent 编排

> 编排逻辑与 `DOCKERFILE_MIGRATION.md` 完全一致（主 Agent 调度 + 子 Agent 并行），**区别仅在于子 Agent 多了 PHASE 0 逆向采集**。主 Agent 干预流程参见 `DOCKERFILE_MIGRATION.md § 主 Agent 干预流程`。

### 子 Agent 职责

```
启动时收到主 Agent 分配的镜像列表 + NETWORK_CTX，按顺序逐个执行，全部完成后退出：

# 启动 prompt 中的 NETWORK_CTX 示例（由主 Agent 探测后注入，子 Agent 直接使用，不再重复探测）：
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

for each image in 分配的镜像列表：
  1. 检查磁盘空间（< MIN_DISK_SPACE_GB 则清理后重试，仍不足写 FAILED 报告跳过本镜像）
  2. 已有 build_reports/<project>.json → 直接跳过
  3. 顺序执行：PHASE 0 → 1 → 2 → 3 → 4 → 5
     ⚑ 拉取镜像 / pip install 等网络操作：
       · NETWORK_CTX.dockerhub_official = reachable   → 直接使用官方源
       · NETWORK_CTX.primary_mirror ≠ null            → 镜像站替换规则（详细规则见 DOCKERFILE_MIGRATION.md 子 Agent 职责）：
           - 官方库镜像加 /library/ 前缀：python:3.10 → <primary_mirror>/library/python:3.10
           - 用户库直接拼接：user/repo:tag → <primary_mirror>/user/repo:tag
           - pip/apt/npm 指向对应国内源
       · 所有 INTERNAL_REGISTRIES 均不可达            → 跳过内源拉取步骤，报告中标注
  4. 每完成一个 PHASE 输出：[WORKER-{id}] PHASE{n} DONE  image={image}  elapsed={sec}s
  5. 每完成一个 PHASE 立即写出中间工件作为断点续跑检查点
  6. 遇到 [WARN-*] 时自动决策（子 Agent 并发运行中，无法等待人工）：
       [WARN-ARCH-KEYWORD]  → 按 [FIX-PLATFORM] 规则修复，继续构建
       [WARN-X86-NATIVE-SO] → 注释该依赖行，报告中标注 WARNING，继续构建
       其他 [WARN-*]        → 注释问题行，报告中标注，继续构建；无法自动修复则写 FAILED 报告跳过本镜像
  7. 写出单镜像报告（§ 5.3）后继续执行列表中下一个镜像
```

### 主 Agent 调度伪代码

```python
images = load_migration_list()            # 所有待迁移镜像（共 N 个）

# ★ Step 1: 网络探测（分发任务前统一执行一次，结果注入全部子 Agent）
# 详见 SKILL.md § ② Step 3
NETWORK_CTX = probe_network(
    dockerhub_official = "https://registry-1.docker.io/v2/",
    dockerhub_web      = "https://hub.docker.com",
    internal_registries = config["INTERNAL_REGISTRIES"],
    mirrors = [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://hub-mirror.c.163.com",
        "https://registry.cn-hangzhou.aliyuncs.com",
    ]
)
# 返回示例：
# { dockerhub_official: "reachable", primary_mirror: null, internal_registries: {...} }
# { dockerhub_official: "unreachable", primary_mirror: "https://mirror.ccs.tencentyun.com", mirrors_checked: [...] }

# 均分任务列表（一次性分配，不做批次轮转）
worker_lists = split_evenly(images, WORKER_COUNT)
# 示例：12 个镜像 / 4 Worker → 每个 Worker 分得 [img1..3] [img4..6] [img7..9] [img10..12]
# 示例：10 个镜像 / 4 Worker → Worker-1/2 各 3 个，Worker-3/4 各 2 个

# 一次性并行启动全部 Worker，每个携带：自己的完整任务列表 + NETWORK_CTX
agents = [launch_sub_agent(worker_lists[i], worker_id=i+1, network_ctx=NETWORK_CTX)
          for i in range(WORKER_COUNT)]

# 等待所有 Worker 完成（各自独立，互不影响）
results = wait_all(agents)

# 结果处理
for agent, result in zip(agents, results):
    if result == "did not return any content":
        completed = [img for img in agent.task_list if report_exists(img)]
        remaining = [img for img in agent.task_list if not report_exists(img)]

        if not remaining:
            mark_all_success(agent.task_list)   # 全部已完成，报告已写出
        elif artifact_exists(remaining[0]):
            resume(agent.agentId,               # 携带 agentId resume
                   prompt=f"跳过已有报告的镜像，从 {remaining[0]} 继续，"
                          f"剩余任务列表：{remaining}")
        else:
            restart_fresh(remaining,            # 全新会话，携带剩余任务列表
                          prompt=f"处理以下镜像列表：{remaining}，"
                                 f"已完成：{completed}，直接跳过")

write_summary()
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

### 0.1 基础镜像 ARM64 支持检查（快速失败）

```bash
BASE_IMAGE=$(docker history --no-trunc --format "{{.CreatedBy}}" <SOURCE_IMAGE> \
  | grep -E "^FROM" | tail -1 | awk '{print $2}')

docker manifest inspect ${BASE_IMAGE} 2>&1 | grep -c "arm64\|aarch64"
# 返回 0 → FAILED(NO_ARM64_SUPPORT)
# 返回 > 0 → 继续
```

> ⚠️ 网络超时会返回空，误判为不支持。以下 DockerHub 官方镜像族，超时时一律放行继续采集：
> `python` / `node` / `ubuntu` / `debian` / `golang` / `rust` / `ruby` / `php` / `openjdk` /
> `amazoncorretto` / `eclipse-temurin` / `maven` / `gradle` / `alpine` / `centos` / `fedora` /
> `nginx` / `postgres` / `mysql` / `redis` / `mongo`
> 上述官方镜像均有 ARM64 支持，网络超时时直接进入 PHASE 0.2 采集。详见 `BUILD_KNOWLEDGE.md § 1`。

### 0.2 采集层历史

```bash
docker pull --platform linux/amd64 <SOURCE_IMAGE>
docker history --no-trunc --format "{{.ID}}\t{{.Size}}\t{{.CreatedBy}}" \
  <SOURCE_IMAGE> > /tmp/<project>_history.txt
```

**解读规则**：

| CreatedBy 含 | 含义 | 迁移动作 |
|-------------|------|---------|
| `FROM <image>` | 基础镜像 | 记录，§ 0.1 已确认 ARM64 支持 |
| `apt-get install -y <pkgs>` | 系统包 | 提取包名，构建时替换 apt 源后重建 |
| `pip install <pkgs>` | Python 包 | 提取版本，查 `BUILD_KNOWLEDGE.md § 4-5` 检查兼容性 |
| `git clone <url>` | 源码下载 | 内网 → 标记需 docker cp；外网 → 可直接重建 |
| `WORKDIR` / `ENV` / `CMD` / `ENTRYPOINT` | 元信息 | 记录，完整还原 |
| `COPY / ADD <src> <dst>` | 文件拷贝 | 标记来源，需从 x86 镜像提取或重新获取 |
| **不透明 commit 层** (识别规则见下) | **手动 commit** | **必须进入 § 0.3 full 模式补齐** |

**不透明层识别规则** (满足任一即判定为不透明层):

- A. CreatedBy 为空字符串或仅含空格
- B. CreatedBy 以 `#(nop)` 开头 (docker commit 自动添加的前缀)
- C. CreatedBy 为 `/bin/sh -c #(nop)` 但 Size > 0 (理论上 nop 不应有大小)
- D. CreatedBy 为 `/bin/bash` / `/bin/sh` 且无后续命令 (如 `bash -c "..."`)

### 0.3 采集容器内状态

```bash
# rebuild 模式（必做）：采集 OS/ENV/pip 包/系统包
python3 scripts/inspect/inspect_image_layout.py <SOURCE_IMAGE> \
  --mode rebuild --output /tmp/<project>_layout.json --pretty

# full 模式（有不透明层时额外执行）：额外采集目录树
python3 scripts/inspect/inspect_image_layout.py <SOURCE_IMAGE> \
  --mode full --depth 3 --output /tmp/<project>_layout_full.json --pretty
```

**layout 关键字段**：

| 字段 | 用途 |
|------|------|
| `os.pretty_name` | 确认 OS（Ubuntu 22.04 → apt 源用 ubuntu-ports） |
| `environment` | 还原所有 ENV 变量 |
| `pip_packages[*]` | 获取精确版本号，补全 history 中 `-r requirements.txt` 安装的版本 |
| `apt_packages[*]` | 补全不透明层安装的系统包 |
| `directory_tree` | full 模式：定位业务代码/资源路径（用于 PHASE 2 docker cp） |
| `users` | 确认运行用户（决定 `USER`/`WORKDIR`） |

### 0.4 采集结果存档

```
arm_builds_<YYYYMMDD>/analysis/<project>/
  history.txt           ← docker history 原始输出
  layout_rebuild.json   ← --mode rebuild 输出
  layout_full.json      ← （有不透明层时）--mode full 输出
  decision_matrix.md    ← PHASE 1 填写的决策矩阵
```

---

## PHASE 1 · 分析结论汇总（决策矩阵）

完成 PHASE 0 后填写以下矩阵，**所有条目必须填写完毕再进入 PHASE 2**：

```
【基础信息】
[ ] FROM 基础镜像：___________
[ ] OS 版本（layout os.pretty_name）：___________
[ ] 运行用户：___________    [ ] WORKDIR：___________
[ ] CMD/ENTRYPOINT：___________    [ ] 技术栈：___________

【不透明层】
[ ] 存在不透明层（Size > 0，CreatedBy=/bin/bash）：是 / 否
    → 是：已执行 layout full，已从 directory_tree 补全

【资源获取方式】
[ ] git clone 类资源：___________
    内网（GIT_HOSTS 命中） → 直连重建 [KEEP-GIT-INTERNAL]
    内网（不可达）         → PHASE 2 docker cp [NEED-DOCKER-CP]
    外网                   → 可重建，注释提示确认网络
[ ] COPY/ADD 引入的非标准文件：___________
    大型二进制/模型文件    → PHASE 2 docker cp
    标准代码文件           → 随 git clone 重建

【架构相关】
[ ] CUDA/GPU 包（nvidia-*/triton/cu12）：有 / 无 → 有则全部跳过/替换
[ ] x86 专属 native .so（文件名含 x86_64/amd64）：有 / 无
    → 有：[WARN-X86-NATIVE-SO]，按 DOCKERFILE_MIGRATION.md § 1.3a 三类处理
[ ] JAR 内 native 库：有 / 无 → 有则检查 ELF 架构

【环境变量】
[ ] 关键 ENV（来自 layout.environment）：___________

【兼容性预检】
[ ] pip_packages 中已知不兼容包（查 BUILD_KNOWLEDGE.md § 4-5）：___________
```

---

## PHASE 2 · 离线资源提取（docker cp）

**需要提取的资源**：内网不可达 git 资源 / 无公网包的内网 pip / 大型二进制 / 不透明层文件。
**不需要提取**：来自 GitHub/PyPI 的标准包，系统包（apt 重建），标准代码。

```bash
docker pull --platform linux/amd64 <SOURCE_IMAGE>   # 已在 PHASE 0 拉取可跳过
CID=$(docker create --platform linux/amd64 <SOURCE_IMAGE>)
docker cp $CID:<CONTAINER_PATH> <LOCAL_BUILD_CONTEXT_PATH>
docker rm $CID
# 不再需要 x86 镜像时：docker rmi <SOURCE_IMAGE>
```

**提取后必做：so 兼容性扫描**（规则同 `DOCKERFILE_MIGRATION.md § 1.5a`）：

```bash
find <resource_path> -name "*.so*" -o -name "*.a" | \
  xargs -I{} file {} | grep -v "ARM aarch64\|symbolic link\|ASCII\|directory"
unzip -l <path>.jar | grep -E "\.so|linux"
```

| 扫描结果 | 处理 |
|---------|------|
| `x86-64` / `x86_64` / `80386` | 功能无关→删除；有替代→替换 aarch64；自研→`FAILED: PROPRIETARY_X86_SO` |
| `ARM aarch64` / 为空 | 兼容，无需处理 |

---

## PHASE 3 · 重建 ARM64 Dockerfile

### 3.1 文件头注释（必须）

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
# ⚠️ WARNINGS：
#   [WARN-X86-NATIVE-SO]    已去除 x86_64 native .so
#   [WARN-OPAQUE-LAYER]     不透明层，重建内容来自 layout 推断，可能不完整
# ════════════════════════════════════════════════════════
```

### 3.2 基础镜像选择

```
公开官方镜像（ubuntu/python/node...）→ 直接加 --platform=linux/arm64

内网定制镜像（含 INTERNAL_REGISTRIES）→ 推断 ARM64 tag：
  {repo}:{tag}-arm64  /  {repo}:{tag}_arm64  /  {repo}:{tag}-aarch64
  推断失败（manifest unknown）→ 退回到 layout os.pretty_name + pip_packages 对应公开镜像：

  OS 回退映射表（按 layout.os.pretty_name 匹配）：
    Ubuntu 22.04 + Python 3.x  → python:3.x-slim-jammy
    Ubuntu 20.04 + Python 3.x  → python:3.x-slim-focal
    Ubuntu 22.04 (无 Python)   → ubuntu:22.04
    Ubuntu 20.04 (无 Python)   → ubuntu:20.04
    Debian 12 + Python 3.x    → python:3.x-slim-bookworm
    Debian 11 + Python 3.x    → python:3.x-slim-bullseye
    Debian 12 (无 Python)     → debian:bookworm-slim
    Debian 11 (无 Python)     → debian:bullseye-slim
    Node.js (layout有 node)   → node:<version>-slim（版本来自 layout）
    Java (layout有 java/jvm)  → eclipse-temurin:<version>-jre-jammy

  ★ 回退后必须标记 [FALLBACK-TO-PUBLIC-BASE]，报告中说明原内网镜像名及回退原因
```

### 3.3 层重建顺序（按 history 从旧到新）

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

# [COPY-FROM-X86] 内网资源（PHASE 2 提取）
WORKDIR <工作目录>
COPY _build_context/<project>/ ./<project>/

# [FIX-TORCH] CPU-only（来自 layout pip_packages）
# [DELETE-CUDA-PKG] 删除 nvidia-* 等
RUN pip3 install "torch==<CPU-only 版本>" <其他包，已去 CUDA 包> -i <PIP_INDEX_URL>

# [WARN-X86-NATIVE-SO] 已去除：COPY libs/librender_x86_64.so /usr/lib/librender.so
# ⚠️  WARNING: x86_64 native 库已移除，相关功能不可用。需 aarch64 版本替换。
# COPY libs/librender_x86_64.so /usr/lib/librender.so

CMD ["<原始启动命令>"]
```

### 3.4 不透明层处理

```
① layout directory_tree 已定位文件 → docker cp 提取，用 COPY 还原
   注释：# [OPAQUE-LAYER-COPY]

② layout apt_packages 有不在 history 中的系统包 → apt-get install 补充
   注释：# [OPAQUE-LAYER-APT]

③ layout pip_packages 有不在 history 中的 Python 包 → pip install 补充
   注释：# [OPAQUE-LAYER-PIP]

④ 以上均无法还原 → 标记 [WARN-OPAQUE-LAYER-UNRESOLVED]，继续构建
   测试阶段发现缺失功能再针对性补充
```

### 3.5 输出路径

```
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64
arm_builds_<YYYYMMDD>/analysis/<project>/decision_matrix.md
```

---

## PHASE 4 · 构建验证

```bash
docker build --platform linux/arm64 \
  -t <OUTPUT_TAG_PREFIX>-<project>:latest \
  -f arm_builds_<date>/dockerfiles/<project>/Dockerfile.arm64 \
  <build_context>
```

**失败处理**（同 DOCKERFILE_MIGRATION.md PHASE 4）：查 BUILD_KNOWLEDGE.md → 自行修复 → 追加注释 → retry_count++ → ≥ 5 次 FAILED。

**本场景特有错误**：

| 错误 | 原因 | 修复 |
|------|------|------|
| `COPY failed: file not found` | PHASE 2 未提取或路径有误 | 检查 PHASE 1 decision_matrix，确认标记为 [NEED-DOCKER-CP] 的资源已在 PHASE 2 提取；检查 docker cp 本地路径与 Dockerfile COPY 路径一致 |
| `ImportError / ModuleNotFoundError` | 不透明层 pip 包未还原 | 查 layout pip_packages，补充安装 |
| `dpkg: error: parsing file` | 不透明层 apt 包未还原 | 查 layout apt_packages，补充安装 |
| 启动命令 `exec: not found` | CMD 路径与原镜像不一致 | 比对 history 最后一层 CMD |
| 运行时缺少环境变量 | layout ENV 未完整还原 | 检查 layout.environment，补全 ENV 层 |

---

## PHASE 5 · 运行时测试 + 固化报告

### 5.1 基础存活验证（同 DOCKERFILE_MIGRATION.md，多一个进程探活层次）

```bash
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"
docker run --rm --platform linux/arm64 <IMAGE> python3 -c "import <core_module>; print('OK')"
docker run -d --platform linux/arm64 --name test-<project> -p <HOST>:<CONTAINER> <IMAGE>
sleep 5
docker ps | grep test-<project>
docker logs test-<project> 2>&1 | tail -20
curl -s http://localhost:<HOST>/health || curl -s http://localhost:<HOST>/monitor/alive
docker stop test-<project>
```

### 5.2 运行时崩溃 → 增量 patch 修复（同 DOCKERFILE_MIGRATION.md § 5.2）

### 5.3 写报告

`arm_builds_<date>/build_reports/<project>.json`：

```json
{
  "project": "<project>",
  "status": "SUCCESS|FAILED",
  "failure_reason": "<枚举值，见 BUILD_KNOWLEDGE.md 附录；成功时省略>",
  "image": "<OUTPUT_TAG_PREFIX>-<project>:latest",
  "source_image": "<SOURCE_IMAGE>",
  "build_status": "success|fail",
  "test_status": "pass|fail|skip",
  "migration_mode": "IMAGE_RECONSTRUCTION",
  "retry_count": 0,
  "reconstruction_info": {
    "history_layers": "<总层数>",
    "opaque_layers": "<不透明层数，无则 0>",
    "opaque_layer_resolved": true,
    "layout_mode_used": "rebuild|full"
  },
  "changes_applied": ["BASE-IMAGE", "FIX-APT-SOURCE", "FIX-TORCH", "COPY-FROM-X86"],
  "warnings": [],
  "notes": "<关键重建决策说明>",
  "timestamp": "<ISO8601>"
}
```

`_summary.json` 格式与 DOCKERFILE_MIGRATION.md § 5.3a 相同，`migration_mode` 改为 `IMAGE_RECONSTRUCTION`。

---

## 决策速查卡

```
基础镜像有 ARM64 manifest？
  无 → FAILED(NO_ARM64_SUPPORT)
  有 → 继续

history 有不透明层（/bin/bash，Size > 0）？
  有 → 必须 layout --mode full，查 directory_tree 补全

history 中有 git clone 内网地址？
  可直连（GIT_HOSTS 命中） → 保留 git clone 直接重建
  不可达 → PHASE 2 docker cp + COPY 替换

提取资源有 .so 文件？
  文件名含 x86_64/amd64 → 扫描 ELF，按三类策略处理（§ 2）
  文件名不含架构关键词  → [WARN-ARCH-KEYWORD] 自动替换架构关键词，报告中标注

pip_packages 含 CUDA 包？
  nvidia-*/triton/cudnn → 全部删除
  torch+cuXXX → TORCH_VERSION_MAP 替换为 CPU-only

layout 有 ENV 变量？
  全部还原到 Dockerfile ENV 层，不遗漏

不透明层内容无法还原？
  标记 [WARN-OPAQUE-LAYER-UNRESOLVED]，继续构建
```
