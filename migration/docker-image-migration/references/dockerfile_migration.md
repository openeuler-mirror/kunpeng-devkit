## 有 Dockerfile 场景镜像迁移执行规范

本文件定义有 Dockerfile 场景的标准迁移流程：先解析与归类 x86 Dockerfile 指令，再形成迁移决策表并生成 ARM64 Dockerfile，最后完成构建与运行验证。用于约束每一步的输入输出、变更标记和失败处理路径，确保迁移结果可复现、可审计。调度/重试/失败判定以主 Skill 为准。

## 1. 场景执行说明

**适用前提**：存在可访问的 Dockerfile 和源码/构建上下文。开始前必须完成主 Skill 启动门禁。

**输入**：Dockerfile 路径、构建上下文、目标镜像名、`TASK_CTX`。

**输出**：

- `arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64`
- 原 Dockerfile 备份与决策表
- `build_reports/<project>.json`

**阶段顺序**：

```text
阶段 1  解析 x86 Dockerfile
阶段 2  生成迁移决策表
阶段 3  输出 ARM64 Dockerfile
阶段 4  构建验证
阶段 5  运行测试与固化报告
```

---

## 阶段 1. 解析 x86 Dockerfile

### 1.1 读取配置

```text
从 references/config_reference.md 获取：
  INTERNAL_REGISTRIES     内网镜像仓地址（识别 FROM 是否内网）
  GIT_HOSTS               构建环境可直连的 git 域名
  INTERNAL_PYPI_HOSTS     构建环境可直连的内网 PyPI
  PIP_INDEX_URL           公开 pip 镜像源
  AIRGAP_MODE             true 时禁止公网域名
  CUDA_PACKAGES_SKIP      需删除的 CUDA/GPU 包前缀
  TORCH_VERSION_MAP       torch CUDA 版 → CPU-only 映射
  FORCE_VERSION_OVERRIDES 末尾强制覆盖的包版本
```

### 1.2 FROM 指令分析

```text
A. 含 INTERNAL_REGISTRIES 域名（内网镜像）
   → 生成 ARM64 tag 候选：
       {repo}:{tag}-arm64  /  {repo}:{tag}_arm64  /  {repo}:{tag}-aarch64  /  {repo}-arm64:{tag}
   → 使用 manifest 检查逐个验证，不用 `docker pull` 代替存在性判断
   → 仅对验证通过的候选标记 [CHANGE-FROM-GUESS]，并记录候选、命中项和 manifest 证据
   → 所有候选均无效：
       - 能从原镜像 metadata 和应用依赖确定等价公开基础镜像时，生成 [FALLBACK-TO-PUBLIC-BASE] 候选；
         基础镜像语义可能变化时必须先获得用户确认
       - 无法证明等价时标记 FAILED(INTERNAL_IMAGE_UNAVAILABLE)，由主 Agent 汇总待确认项

B. 公开镜像（Docker Hub / 官方）
   → 先验证目标 tag 存在 `linux/arm64` manifest
   → 验证通过：加 `--platform=linux/arm64`，标记 [KEEP-FROM-PUBLIC]
   → 验证失败：检索 `references/build_knowledge_reference.md` 的替代或升级方案；无方案时按主 Skill 全局执行红线失败
```

### 1.3 RUN 指令分类

| 识别模式                                          | 动作                                                         | 标记                                                   |
| ------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------ |
| `apt-get update/install`                          | 保持目标发行版的 ARM64 正确仓库；仅当主 Skill 启动门禁第 4 项（软件包源）证据要求时替换源 | `[FIX-APT-SOURCE]`                                     |
| 包名含 `:amd64` / `:x86_64`                       | 删除架构后缀                                                 | `[FIX-APT-ARCH]`                                       |
| `pip install` + CUDA 版 torch                     | 仅默认 CPU 场景按 `TORCH_VERSION_MAP` 替换；GPU 场景按目标栈验证 | `[FIX-TORCH]`                                          |
| `pip install` + `nvidia-*` / `triton` / `cudnn`   | 仅命中 `CUDA_PACKAGES_SKIP` 且目标为 CPU 场景时删除          | `[DELETE-CUDA-PKG]`                                    |
| `pip install` + 外网 pip 源                       | `AIRGAP_MODE=true` 或主 Skill 启动门禁第 4 项（软件包源）判定不可达时，替换为已验证的 `PIP_INDEX_URL` | `[FIX-PIP-SOURCE]`                                     |
| `pip install` + `INTERNAL_PYPI_HOSTS` 内网源      | 保留；依赖是否可选必须由项目证据决定，禁止默认追加 `\|\| echo` 掩盖失败 | `[KEEP-PIP-INTERNAL]`                                  |
| `git clone` + `GIT_HOSTS` 域名                    | 经主 Skill 启动门禁第 4 项（软件包源）/配置确认可达后保留    | `[KEEP-GIT-INTERNAL]`                                  |
| `git clone` + 外网                                | `AIRGAP_MODE=true` 时禁止；否则经主 Skill 启动门禁第 4 项（软件包源）确认可达后保留 | `[KEEP-GIT-PUBLIC]`                                    |
| `npm install/ci` + 默认源不可达                   | 使用主 Skill 启动门禁第 4 项（软件包源）已验证且在配置中声明的 `NPM_REGISTRY` | `[FIX-NPM-SOURCE]`                                     |
| `wget/curl` + `archive.apache.org`                | 替换为 APACHE_MIRROR                                         | `[FIX-APACHE-MIRROR]`                                  |
| `x86_64` / `amd64` / `i386` 关键词（非 pkg 后缀） | 仅在目标值唯一且可验证时替换架构关键词；否则保留 WARN        | `[WARN-ARCH-KEYWORD]`                                  |
| `--platform=linux/amd64`                          | 改为 `linux/arm64`                                           | `[FIX-PLATFORM]`                                       |
| COPY/ADD/wget 引入 `.so` / `.a` / ELF             | 按 1.4 处理顺序与 1.7 三类策略处理                           | `[WARN-X86-NATIVE-SO]` / `[FIXED-SO-REPLACED-AARCH64]` |

### 1.4 native 文件候选识别与处理

下列模式只表示“需要检查”。**文件名、命令文本、归档内路径或目录名中的架构关键词（x86_64 / amd64 / i686 / x86 等）只能用于筛选候选，不得单独作为兼容性判定依据**：

```text
A. COPY/ADD 的 src 文件名匹配 *.so* / *.a / *.o / *.dylib
B. RUN wget/curl 下载 URL 含 x86_64/amd64/i686，且产物可能包含 native 文件
C. RUN 含 ldconfig、链接或安装 native 库的命令
D. 构建或运行日志出现 ELF x86-64、illegal instruction、SIGILL、UnsatisfiedLinkError
E. 构建上下文中的 JAR/WAR/EAR、.tar.gz/.zip 归档、RPM 包（无论文件名或内部路径是否含架构关键词）
```

处理顺序：

1. **松散文件**（未打包的 `.so` / `.a` / `.o` / ELF 二进制）：执行 `file`，其输出即为判定证据。
2. **归档/JAR/RPM**：**必须**按 [references/devkit_pkg_mig_reference.md](references/devkit_pkg_mig_reference.md) 第 1 节留档工具可用性结论后，执行第 2 节 `devkit porting pkg-mig ... -r json` 结构化扫描并保存 JSON；工具不可用时按第 3 节 fallback 执行（先解压、再对 ELF 逐个 `file`）并留档证据。
3. **未取得合法判定证据（pkg-mig JSON 或解压后 ELF 的 `file` 输出）前，不得对归档内文件给出兼容/不兼容结论，不得写 `[WARN-X86-NATIVE-SO]` / `[FIXED-SO-REPLACED-AARCH64]` 标记，也不得进入 1.7 分类。**
4. 证据确认 x86_64 后，进入 1.7 的功能影响分类。
5. 功能无关且有证据时可注释原命令，并记录 `[WARN-X86-NATIVE-SO]`。
6. 功能相关时优先替换 ARM64 版本或源码重编译；无法处理时使用 `FAILED(PROPRIETARY_X86_SO)`。
7. 架构或功能影响不确定时保留原行到决策表，不得先删除再验证。

**合法判定依据只有两种**，任一缺失即视为未判定：

| 判定依据                                                 | 说明                                                         |
| -------------------------------------------------------- | ------------------------------------------------------------ |
| pkg-mig JSON 的 `is_aarch64` / `path_ext` 字段           | 按 `references/devkit_pkg_mig_reference.md` 第 4 节解读      |
| 对**解压后**的 `.so` / `.a` / ELF 逐个执行 `file` 的输出 | `x86-64` / `x86_64` / `80386` → 不兼容；`ARM aarch64` → 架构一致，仍需构建运行验证 |

> 仅凭 `unzip -l` / `tar -t` 列表或路径关键词（如 `linux/amd64/`、`deb/lib64/x86/`）得出结论属于违规判定：fat JAR 可能同时打包多平台 native，关键词会误判；无架构关键词的 native（如 JAR 内捆绑的 `cal` / `pwd` 等系统命令二进制）会被漏判。

本节完成前，必须将下列清单写入阶段记录（无 native 候选时记录“无候选”）：

```text
[ ] 候选=<文件>  类型=松散文件|归档/JAR|RPM  检查方式=pkg-mig|fallback-file  证据=<JSON路径或file输出>  结论=兼容|不兼容|待确认
```

功能无关且确认允许移除时，使用以下注释格式：

```dockerfile
# [WARN-X86-NATIVE-SO] 已确认并移除可选的 x86_64 native 库：<原命令摘要>
# 影响：<被禁用的可选功能>；恢复条件：提供对应 ARM64 库并更新路径。
# <原命令内容，注释掉>
```

### 1.5 ENV 指令分析

```text
目标明确为无 NVIDIA GPU 的 CPU 场景，且变量只服务 CUDA/NVIDIA 运行时时，才删除并标记 `[DELETE-CUDA-ENV]`：
  CUDA_VERSION=*  /  NVIDIA_*=*  /  CUDNN_*=*  /  LD_LIBRARY_PATH 含 cuda 路径
```

### 1.6 COPY / ADD / wget 外部资源获取

> 当当前机器为 ARM64 且需要从 x86 镜像提取资源时（下方路径 (2)），需先按 [x86_remote_setup_reference.md](references/x86_remote_setup_reference.md) 完成环境检查。`docker pull --platform linux/amd64` 和 `docker cp` 操作需在 x86_64 采集机上通过 SSH 远程执行。**`docker pull` 属于系统环境变更（可能占用大量磁盘空间），须按 SKILL.md「系统环境变更确认」原则请求用户确认后方可执行，不得自行静默拉取。**

```text
待检查源：src 路径不在当前构建上下文，或 wget/curl 拉取非公开地址

(1) 内网 Git 仓库直连（首选）
    条件：src/URL 含 GIT_HOSTS 域名或判断为内网资源
    操作：直接 git clone/wget/curl → 成功 [KEEP-RESOURCE-FROM-GIT] → 失败进入 (2)

(2) 从 x86 镜像提取
    # ⚠️ docker pull 须经用户确认后方可执行
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

(3) 均失败 → [WARN-MISSING-COPY-SRC]，写失败报告并结束当前 target；主 Agent 在汇总中集中列出待补资源
```

### 1.7 资源原生库兼容性检查（进入决策表前必做）

> **适用范围**：凡 1.4 命中的 native 候选——无论文件来自构建上下文（COPY/ADD 的 src）还是 1.6 的外部资源获取——进入阶段 2 决策表前都必须完成本节检查。使用 Kunpeng DevKit `pkg-mig` 工具进行结构化扫描，工具参考：[references/devkit_pkg_mig_reference.md](references/devkit_pkg_mig_reference.md)。

**执行方式**：

1. 按该文档第 1 节完成工具可用性检查，并在阶段记录写入 `DEVKIT_BIN=<path>` 或 `DEVKIT_BIN=not_found + 原因（含主机架构）`；**未留档可用性结论前，不得进入 fallback**。不要在本阶段主动安装。
2. 工具可用时：对每个归档/JAR/RPM 候选执行该文档第 2 节的结构化扫描，保存 JSON 并记录路径，回填到决策表与报告的 `evidence_source`。
3. 工具不可用时：执行该文档第 3 节的 fallback（先解压，再对 ELF 逐个 `file`），报告中标注“手动初筛”，并注明“建议在 aarch64 主机补扫 pkg-mig”。
4. 按该文档第 4 节解读结果，再应用下方三类处理策略。

**判断**：出现 `x86-64` / `x86_64` / `80386` → 不兼容，按三类策略处理：

| 情况                       | 处理                                                         |
| -------------------------- | ------------------------------------------------------------ |
| 功能无关 / 可选            | 删除 .so，追加 `# [WARN-X86-NATIVE-SO]`                      |
| 功能相关 / 有 aarch64 替代 | 替换，追加 `# [FIXED-SO-REPLACED-AARCH64]`                   |
| 自研 / 无替代              | 标记 `FAILED(PROPRIETARY_X86_SO)`，写失败报告，结束当前 target |

```bash
# JAR 内替换 x86 so（示例）
zip -d <path>.jar "lib/linux-x86_64/libxxx.so"
zip -j <path>.jar <aarch64_libxxx.so>
```

---

## 阶段 2. 生成迁移决策表

### 2.0 先做失败前检索

在给出任何失败结论前，必须先查 `references/build_knowledge_reference.md`，确认是否已有可复用修复方案。
只有“已检索且无可用方案”时，才能进入失败判定。

对应检索建议：

- `ARCH_INCOMPATIBILITY`：优先查 37（替代方案）、38（版本升级）、40（构建策略）
- `PROPRIETARY_X86_SO`：优先查 6（架构关键词与 native 库）；若判定为闭源整软件无 ARM64 版本，再补查 37（替代方案）与 38（版本升级）
- `VERSION_INCOMPATIBILITY`：优先查 4-8（语言版本兼容）和 38（版本升级）

### 2.1 本阶段产出边界

本阶段只做三件事：**整理证据、给出拟执行动作、标注风险**。
不在本阶段直接改 Dockerfile，不提前写最终成功/失败结论。

### 2.2 warning 处理规则（按模式）

| 场景                             | 处理方式                                                     |
| -------------------------------- | ------------------------------------------------------------ |
| 并发模式（`WORKER_COUNT >= 2`）  | 按主 Skill 全局执行红线处理；没有确定规则时写失败报告，不做泛化注释替换 |
| 单任务模式（`WORKER_COUNT = 1`） | 汇总所有 `[WARN-*]` 后暂停，等待用户确认，再进入阶段 3       |
| `[WARN-ARCH-KEYWORD]`            | 仅当替换值唯一且验证通过时自动替换；否则等待确认或失败       |
| `[WARN-MISSING-COPY-SRC]`        | 直接写失败报告，跳过本项目                                   |
| `[WARN-X86-NATIVE-SO]`           | 先判定功能影响；功能相关或影响不明确时，不允许仅靠注释继续；标记必须附 1.4 的合法判定证据（`evidence_source`），仅有文件名/路径关键词时不得写入此标记 |

### 2.3 决策表输出格式

```text
[FROM] L1  原: <image>  改: <arm64-image>  依据: <原因>  标记: [CHANGE-FROM-GUESS]
[RUN] L5   改: 注入 apt 源替换 + 删除 :amd64 后缀  标记: [FIX-APT-SOURCE] [FIX-APT-ARCH]
[COPY] L35 去除 x86_64 native .so   WARNING: 相关功能不可用  标记: [WARN-X86-NATIVE-SO]
────
汇总：自动处理 N 项，FAILED N 项，保留不变 N 项
```

补充约束：

- 出现 `[WARN-ARCH-KEYWORD]` 时，必须记录原值、候选值、验证依据
- 出现 `[WARN-MISSING-COPY-SRC]` 时：并发模式写失败报告；单任务模式向用户请求资源或替代来源
- native 相关行（`[WARN-X86-NATIVE-SO]` / `[FIXED-SO-REPLACED-AARCH64]`）必须注明证据来源（pkg-mig JSON 路径或解压后 `file` 输出）；无证据的行只能标“待确认”，不得写兼容结论

---

## 阶段 3. 输出 ARM64 Dockerfile

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
#  WARNINGS（功能可能受损）：
#   [WARN-X86-NATIVE-SO] 已处理经证据确认的 x86_64 native 库（实际影响见对应注释）
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

若 [references/config_reference.md](references/config_reference.md) 有配置，在 Dockerfile **末尾**追加：

```dockerfile
# [FORCE-VERSION-OVERRIDES] 强制覆盖被依赖树拖回旧版本的包
RUN pip3 install "networkx>=2.6" -i <PIP_INDEX_URL> --quiet
```

### 3.4 输出路径

```text
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.arm64    ← 生成文件
arm_builds_<YYYYMMDD>/dockerfiles/<project>/Dockerfile.x86_orig ← 原文件备份
```

---

## 阶段 4. 构建验证

> 构建只使用主 Skill 全局执行红线已验证的软件源决策；不要在本阶段重新探测或硬编码替换。

> **QEMU 模拟构建超时提示**：当 `ARCH_COMPAT=emulated` 时，ARM64 构建通过 QEMU 模拟执行，速度远低于原生构建。建议将 `BUILD_TIMEOUT_MIN` 调整为默认值的 2–3 倍（即 120–180 分钟），尤其是含编译步骤（C/C++/Rust）的镜像。若构建超时但无编译错误，先检查是否为 QEMU 性能瓶颈而非代码问题。

> **构建网络模式**：`docker build` 的 `RUN` 步骤运行在独立容器网络命名空间，DNS 解析器在该命名空间未必可达（`docker pull` 正常但 `pip install` / `npm install` 报 `Temporary failure in name resolution`）。**不要在本阶段重新探测**，直接使用启动门禁生成的 `BUILD_NET_CTX`：`${BUILD_NET_ARG}` 为网络参数（`--network=host` 或空串），`${BUILD_PROXY_ARGS}` 为代理 build-arg（见 `build_knowledge_reference.md` §20 模板）。

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
| `Temporary failure in name resolution` / `Could not resolve host` | 构建容器网络命名空间 DNS 不可达（`docker pull` 仍正常）      | 确认 `BUILD_NET_CTX.build_net_mode`；切到 `--network=host`（`${BUILD_NET_ARG}`）；仍失败按 `build_knowledge_reference.md` §「容器 DNS 解析失败」处理 |
| `npm ERR! code E407` / `407 Proxy Authentication Required`   | npm 不读 `HTTP_PROXY` 环境变量做代理认证，`--build-arg` 注入的代理对 npm 无效 | 按 `build_knowledge_reference.md` §8「npm 代理 407」处理：宿主机 `npm install` 后 `COPY node_modules`，或 Dockerfile 内 `npm config set proxy` |
| `manifest unknown`                                           | 推断的 ARM64 tag 不存在                                      | 检查候选列表，询问用户正确 tag                               |
| `fatal: unable to connect to git.xxx`                        | git clone 失败                                               | 确认构建环境网络、凭据和 `GIT_HOSTS` 配置                    |

---

## 阶段 5. 运行时测试 + 固化报告

### 5.1 运行验证

> 必须先执行层次 0（真实启动验证），通过后才执行后续层次。分层策略见 `build_knowledge_reference.md` 第 21 节。

```bash
# 步骤 1（必须）：真实 ENTRYPOINT/CMD 启动验证——不覆盖原始命令
#   先确认镜像的 ENTRYPOINT 和 CMD 内容
docker inspect <IMAGE> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'

#   后台启动，不覆盖任何命令，等待数秒后检查进程存活
docker run -d --platform linux/arm64 --name test-real-<project> <IMAGE>
sleep 8
if docker ps -a --filter "name=test-real-<project>" --filter "status=running" | grep -q test-real-<project>; then
  echo "STARTUP_OK"
  docker logs test-real-<project> 2>&1 | tail -20
else
  echo "STARTUP_CRASH"
  docker logs test-real-<project> 2>&1 | tail -50
  # 记录崩溃日志，进入 5.2 增量 patch 修复
fi
docker rm -f test-real-<project> 2>/dev/null

# 步骤 2：容器可启动（覆盖命令的基础探活）
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"

# 步骤 3：Python 项目的核心模块可 import
docker run --rm --platform linux/arm64 <IMAGE> python3 -c "import <core_module>; print('OK')"

# 步骤 4：服务类项目的 HTTP 端口探活
docker run -d --platform linux/arm64 --name test-<project> -p <HOST>:<CONTAINER> <IMAGE>
sleep 5
curl -s http://localhost:<HOST>/health || curl -s http://localhost:<HOST>/monitor/alive
docker stop test-<project>
```

### 5.2 运行时崩溃 → 增量 patch 修复

当问题可由小范围文件或命令修复时，优先使用增量 patch 镜像；涉及基础镜像、系统包或构建参数时仍需回到 阶段 3/4。

```dockerfile
FROM <IMAGE>:latest
# [FIX-RTE-001] 修复说明
COPY _patches/fixed_server.py /app/server.py
RUN find /app -name '*.pyc' -delete
```

```bash
docker build --platform linux/arm64 \
  ${BUILD_NET_ARG} ${BUILD_PROXY_ARGS} \
  -t <IMAGE>-patched:latest -f Dockerfile.patch .
```

### 5.3 写报告

> 报告 JSON 格式见 [templates/dockerfile_migration_report_template.md](templates/dockerfile_migration_report_template.md)。本场景 `migration_mode = "IMAGE_MIG_SKILLSET"`，无 mode 特有字段。

提交前自检：报告内所有 native 相关标记（`WARN-X86-NATIVE-SO` / `FIXED-SO-REPLACED-AARCH64`）的条目必须带非空 `evidence_source`；缺失任何一条即回到 1.4/1.7 补齐证据后重写，不得提交。

### 5.4 主 Agent 总览报告（`_summary.json`）

> 格式见 [templates/dockerfile_migration_report_template.md](templates/dockerfile_migration_report_template.md) 总览报告。