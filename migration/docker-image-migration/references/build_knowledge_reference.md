## 使用契约

1. 从失败日志提取稳定错误文本、退出码和技术栈。
2. 先搜索精确错误，再搜索组件名与症状；优先选择环境前提最接近的条目。
3. 一次只应用一个最小修复，保存 Dockerfile/patch diff 后重试。
4. 按条目中的验证方式确认修复；没有验证证据时不得标记成功。
5. 未收录的修复先写入项目报告并标记 `NOVEL` 或 `PENDING_REVIEW`，用户确认后再追加。

知识条目应尽量包含：**症状、适用条件、原因、修复、验证、风险/回退**。示例中的版本、镜像站和下载地址必须结合当前环境验证，不得直接视为长期有效事实。

## 目录

- [1. 快速失败判定（直接跳过，不修复）](#1-快速失败判定)
- [2. 镜像源替换（必做）](#2-镜像源替换)
- [3. apt / 系统包错误](#3-apt--系统包错误)
- [4. pip / Python 错误](#4-pip--python-错误)
- [5. CUDA / GPU 包处理](#5-cuda--gpu-包处理)
- [6. 架构关键词与 native 库](#6-架构关键词与-native-库)
- [7. Java / Maven / Gradle 错误](#7-java--maven--gradle-错误)
- [8. Node.js / npm 错误](#8-nodejs--npm-错误)
- [9. 浮点精度差异（ARM64 特有）](#9-浮点精度差异)
- [10. 测试快照不匹配](#10-测试快照不匹配)
- [11. 测试/构建超时（ARM64 性能差异）](#11-测试构建超时)
- [12. Rust / Cargo 错误](#12-rust--cargo-错误)
- [13. Ruby / Gem 错误](#13-ruby--gem-错误)
- [14. C++ / CMake 错误](#14-c--cmake-错误)
- [15. PHP / Composer 错误](#15-php--composer-错误)
- [16. Docker / 环境错误](#16-docker--环境错误)
- [17. 系统工具缺失](#17-系统工具缺失)
- [18. C 扩展 / native 库降级](#18-c-扩展--native-库降级)
- [19. Dockerfile 编写原则](#19-dockerfile-编写原则)
- [20. 构建命令速查](#20-构建命令速查)
- [20.1 容器 DNS 解析失败](#201-容器-dns-解析失败)
- [21. 运行时测试分层策略](#21-运行时测试分层策略)
- [22. 增量 patch 镜像（避免全量重建）](#22-增量-patch-镜像)
- [23. 磁盘管理](#23-磁盘管理)
- [24. 大文件下载失败 / 构建容器 OOM](#24-大文件下载失败--构建容器-oom（exit-code-8--137）)
- [25. ca-certificates 缺失 / apt HTTPS 源兜底](#25-ca-certificates-缺失--apt-https-源兜底)
- [26. apt 镜像源替换不成功](#26-apt-镜像源替换不成功（403--404--不可用）)
- [27. keyserver 不可达 / GPG 密钥获取失败](#27-keyserver-不可达--gpg-密钥获取失败)
- [28. Erlang / RabbitMQ 兼容性](#28-erlang--rabbitmq-兼容性)
- [29. Docker 18.09 兼容性约束](#29-docker-1809-兼容性约束)
- [30. 多阶段构建：替换 JDK / Erlang 运行时](#30-多阶段构建：替换架构依赖的-jdk--erlang--语言运行时)
- [31. 业务二进制替换：官方 aarch64 发行版](#31-业务二进制替换：使用官方-aarch64-发行版替换整个应用)
- [32. QEMU 模拟性能陷阱](#32-qemu-模拟性能陷阱)
- [33. 网络隔离环境下的二进制获取](#33-网络隔离环境下的二进制获取)
- [34. multi-stage：处理不透明 COPY 层](#34-multi-stage-构建模式：处理不透明-copy-层的-jdk-依赖)
- [35. 构建修复决策树（速查）](#35-总结：image_reconstruction-构建修复决策树)
- [36. Dockerfile 语法陷阱](#36-dockerfile-语法陷阱)
- [37. 闭源软件 ARM64 替代方案模式](#37-闭源软件-arm64-替代方案模式)
- [38. 版本升级解锁 ARM64 支持](#38-版本升级解锁-arm64-支持（version-bump-strategy）)
- [39. Debian 发行版兼容性问题](#39-debian-发行版兼容性问题)
- [40. 构建策略优化](#40-构建策略优化)
- [附录：failure_reason 枚举](#附录：failure_reason-枚举)

---

## 1. 快速失败判定

> **STEP 0: 在应用以下快速失败规则前，必须先检索本文档其余章节**，确认报错条件是否有已知修复方案：
>
> - 例如：`ARCH_INCOMPATIBILITY` 触发时，检查 37（闭源替代方案）、38（版本升级）是否有对应映射
> - 例如：`NO_ARM64_SUPPORT` 触发时，检查 37-38 是否有替代品或新版本
> - 仅在确认所有已知修复路径均不适用后，再执行以下快速失败判定。

以下情况**在 BUILD_KNOWLEDGE 无匹配修复方案时**标记 FAILED：

| 条件                                                | failure_reason            | 判断方式                                                  |
| --------------------------------------------------- | ------------------------- | --------------------------------------------------------- |
| 基础镜像无 ARM64 manifest                           | `NO_ARM64_SUPPORT`        | `docker manifest inspect <img> \| grep -c "arm64"` 返回 0 |
| Android 项目（aapt2/d8/R8 工具链）                  | `ARCH_INCOMPATIBILITY`    | image_env 含 `ANDROID_HOME` 或 `build-tools/`             |
| Ruby 项目要求高版本 Ruby 但基础镜像版本低（如 2.6） | `VERSION_INCOMPATIBILITY` | 依赖分析                                                  |

> 网络超时会让 `manifest inspect` 返回空，不能据此判定不支持。以下常见 Docker Hub 官方镜像族可进入最小构建探测，但最终仍需补充 manifest 或等价平台证据：
> `python` / `node` / `ubuntu` / `debian` / `golang` / `rust` / `ruby` / `php` / `openjdk` /
> `amazoncorretto` / `eclipse-temurin` / `maven` / `gradle` / `alpine` / `centos` / `fedora` /
> `nginx` / `postgres` / `mysql` / `redis` / `mongo`

---

## 2. 镜像源替换

### 2.1 镜像拉取优先级

**基础镜像（FROM 行）** 按以下顺序尝试，第一个成功则停止：

```text
1. references/config_reference.md 中配置的内部私有镜像仓库（INTERNAL_REGISTRIES）
2. Docker Hub 官方镜像（docker.io / hub.docker.com）
3. 公共加速镜像站（如腾讯云 mirror.ccs.tencentyun.com 等兜底）
```

> 若 `AIRGAP_MODE: true`，跳过第 2/3 步，仅允许内部仓库。

**每个 ARM64 Dockerfile 的第一个 RUN 层必须替换语言/系统包源**，否则下载速度不可接受。

### 2.2 操作系统 apt 源

| OS                       | 必须替换为                                                   |
| ------------------------ | ------------------------------------------------------------ |
| Ubuntu 20.04 (focal) ARM | `mirrors.aliyun.com/ubuntu-ports`                            |
| Ubuntu 22.04 (jammy) ARM | `mirrors.aliyun.com/ubuntu-ports`（替换 `ports.ubuntu.com`） |
| Ubuntu 24.04 (noble) ARM | `ports.ubuntu.com/ubuntu-ports` → `mirrors.aliyun.com/ubuntu-ports` |
| Debian 12 (bookworm)     | 清华源（DEB822 格式，见本节模板）                            |
| Debian 11 (bullseye)     | 清华源；**必须删除 security 行** `sed -i '/security/d' /etc/apt/sources.list` |
| Debian 10 (buster) EOL   | 阿里云归档源 + `Acquire::Check-Valid-Until false`            |

**Ubuntu ARM64 模板**：

```dockerfile
RUN sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.aliyun.com/ubuntu-ports|g' \
        /etc/apt/sources.list \
    && apt-get update -qq
```

**Debian 12 bookworm DEB822 模板**：

```dockerfile
# 正确：用 printf '%s\n' 确保每行正确输出（单引号中 \n 不会被 shell 解析）
RUN printf '%s\n' \
    'Types: deb' \
    'URIs: https://mirrors.tuna.tsinghua.edu.cn/debian' \
    'Suites: bookworm bookworm-updates' \
    'Components: main' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
    '' \
    'Types: deb' \
    'URIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security' \
    'Suites: bookworm-security' \
    'Components: main' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
    > /etc/apt/sources.list.d/debian.sources
```

**Debian 10 buster EOL 模板**：

```dockerfile
RUN echo "deb https://mirrors.aliyun.com/debian-archive/debian buster main contrib non-free" > /etc/apt/sources.list \
    && echo "deb https://mirrors.aliyun.com/debian-archive/debian-security buster/updates main contrib non-free" >> /etc/apt/sources.list \
    && echo "deb https://mirrors.aliyun.com/debian-archive/debian buster-updates main contrib non-free" >> /etc/apt/sources.list \
    && echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid
```

### 2.3 语言包源

| 语言                 | 镜像源                                                       |
| -------------------- | ------------------------------------------------------------ |
| Python (pip)         | `https://mirrors.aliyun.com/pypi/simple/`                    |
| Node.js (npm)        | `https://registry.npmmirror.com`                             |
| Rust (cargo)         | `sparse+https://rsproxy.cn/index/`                           |
| PHP (Composer)       | `https://mirrors.aliyun.com/composer/`                       |
| Java (Maven)         | 阿里云 central mirror（见本节模板）                          |
| Ruby (gem)           | `https://mirrors.aliyun.com/rubygems/`                       |
| DevKit RPM (Kunpeng) | `https://mirrors.huaweicloud.com/kunpeng/archive/DevKit/Packages/Kunpeng_DevKit/` |

**cargo 镜像模板**：

```dockerfile
RUN mkdir -p ~/.cargo && cat > ~/.cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
```

**Maven settings.xml 模板**：

```dockerfile
RUN mkdir -p ~/.m2 && cat > ~/.m2/settings.xml << 'EOF'
<settings>
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <mirrorOf>central</mirrorOf>
      <name>Aliyun Central</name>
      <url>https://maven.aliyun.com/repository/central</url>
    </mirror>
  </mirrors>
</settings>
EOF
```

---

## 3. apt / 系统包错误

### `E: Unable to locate package`

- **原因**：包名含 `:amd64` 后缀，或使用了 x86_64 专属包名
- **修复**：去掉 `:amd64` 后缀；`binutils-x86-64-linux-gnu` → `binutils`

**必须删除的 amd64 特有后缀/包名**：

```text
:amd64                    → 删除后缀（apt 自动选 arm64 变体）
x86_64-linux-gnu          → 改为 aarch64-linux-gnu（或让 apt 自动选）
binutils-x86-64-linux-gnu → binutils
gcc-N-base:amd64          → gcc
libasan5:amd64            → libasan8（或对应 arm 版本）
```

### `Release file does not have a Release` / `404 Not Found` (apt update)

- **原因 A**：Debian buster EOL，默认源已下线
- **修复 A**：换阿里云归档源 + `Acquire::Check-Valid-Until false`（见 2.1 模板）
- **原因 B**：Debian bullseye security 源失效
- **修复 B**：`sed -i '/security/d' /etc/apt/sources.list`

### `No system certificates available` (apt update HTTPS 源)

- **原因**：容器初始无 ca-certificates，HTTPS 源不可用
- **修复**：先用 `http://` 源安装 ca-certificates，再换 HTTPS

### apt 源被 nodesource 脚本重置

- **原因**：安装 Node.js 时 nodesource 脚本重写 apt 源
- **修复**：不用 nodesource 脚本，直接从 npmmirror 镜像站下载官方 arm64 tar 包（国内访问快）：

```dockerfile
# Node.js 官方源 nodejs.org 国内极慢，改用 npmmirror 镜像加速
ENV NODE_VERSION=20.18.0
RUN curl -fsSL --max-time 300 --retry 3 \
      -o /tmp/node.tar.gz \
      "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz" \
    && tar -xz -C /usr/local --strip-components=1 -f /tmp/node.tar.gz \
    && rm /tmp/node.tar.gz && node --version
```

### Docker CE 安装 SSL 握手失败（`SSL handshake failed` / `GPG key fetch failed`）

- **原因**：国内网络访问 `download.docker.com` 或 `get.docker.com` TLS 握手失败
- **修复**：改用 `docker.io`（Ubuntu 官方 apt 源内置包），功能完全等价：

```dockerfile
# 失败：download.docker.com SSL handshake failed
RUN curl -fsSL https://get.docker.com | sh

# 修复
RUN apt-get update && apt-get install -y docker.io docker-compose \
    && docker --version
```

---

## 4. pip / Python 错误

### `error: externally-managed-environment`

- **原因**：PEP 668，Debian bookworm 上系统 Python 受保护
- **修复**：加 `--break-system-packages`；或改用 venv：

```dockerfile
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install ...
```

### `no such option: --break-system-packages`

- **原因**：pip 版本 < 22.1
- **修复**：去掉该选项；或先 `pip install --upgrade pip`

### `could not find a version that satisfies the requirement`

- **原因**：pip 包无 ARM64 wheel
- **修复**：`--no-binary :all:` 从源码构建；或降/升版本找有 aarch64 wheel 的版本

### `pip install -e .` 导致大依赖重新解析（耗时数十分钟）

- **修复**：先单独安装大包，再用 `--no-deps` 只注册包：

```dockerfile
RUN pip3 install "torch==2.6.0" ...   # 先单独安装
RUN pip3 install -e . --no-deps       # 只注册，不重新解析
```

### `deadsnakes PPA` 不支持 ARM64（Python 3.7-3.12）

- **原因**：`ppa:deadsnakes/ppa` 仅发布 x86_64 deb，ARM64 无法通过 apt 安装非系统默认版本
- **修复方案 A**（推荐）：使用系统自带 Python 版本（Ubuntu 22.04 → python3.10，Ubuntu 24.04 → python3.12）
- **修复方案 B**：从 python.org 源码编译（适用于必须使用特定版本如 3.8/3.9）：

```dockerfile
ENV PYTHON_VERSION=3.8.20
RUN wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" \
    && mkdir -p /usr/src/python && tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz \
    && cd /usr/src/python && ./configure --enable-optimizations --enable-shared --with-ensurepip \
    && make -j $(nproc) && make install && ldconfig && rm -rf /usr/src/python python.tar.xz
```

> 源码编译耗时 **10-20 分钟**，仅在必须使用特定版本时采用

### Poetry / pip bootstrap 脚本超时（`install.python-poetry.org` / `bootstrap.pypa.io`）

- **原因**：官方 bootstrap 脚本依赖特定 CDN，网络不稳定时易超时
- **修复**：

```dockerfile
# Poetry 改用 pip 安装
RUN pip install poetry -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com

# pip bootstrap（旧版 Python 3.7/3.8）用 ensurepip
RUN python3.7 -m ensurepip && python3.7 -m pip install --upgrade pip \
    -i https://mirrors.aliyun.com/pypi/simple/
```

---

## 5. CUDA / GPU 包处理

**默认鲲鹏 CPU 场景不使用 NVIDIA GPU，以下包按配置移除**：

- 前缀匹配删除：`nvidia-`、`triton`、`cuda-`、`cudnn`、`nccl`

**PyTorch CUDA 版 → CPU-only 版替换**：

```dockerfile
# 删除 CUDA 版，安装 CPU-only 版
RUN pip3 install \
    "torch==2.6.0" \
    "torchvision==0.21.0" \
    --index-url https://download.pytorch.org/whl/cpu
```

**常见 torch CUDA 版本映射**：

| CUDA 版                                       | CPU-only 替代                                                |
| --------------------------------------------- | ------------------------------------------------------------ |
| `2.8.0+cu124` / `2.7.0+cu124` / `2.6.0+cu124` | `2.6.0`                                                      |
| `2.5.0+cu121` / `2.4.0+cu121`                 | `2.4.1`                                                      |
| `2.3.0+cu121`                                 | `2.3.1`                                                      |
| `2.2.0+cu121`                                 | `2.2.2`                                                      |
| `2.1.0+cu118`                                 | `2.1.2`                                                      |
| `2.0.0+cu118`                                 | `2.0.1`                                                      |
| 其他 `+cuXXX` 版本                            | 去掉 `+cuXXX` 后缀，保留主版本号；先验证 CPU-only 包是否存在 |

> 完整映射配置见 [config_reference.md](references/config_reference.md) §6 `TORCH_VERSION_MAP`。

**ENV 变量同步删除**：

```text
CUDA_VERSION=*    → 删整行
NVIDIA_*=*        → 删整行
CUDNN_*=*         → 删整行
LD_LIBRARY_PATH 中含 cuda 路径 → 删整行
```

---

## 6. 架构关键词与 native 库

### x86 native `.so` / ELF 二进制识别

以下情形判定为「深度绑定 x86 的 native 库」：

```text
A. COPY / ADD 的 src 文件名匹配：*.so* / *.a / *.o / *.dylib
B. RUN wget/curl 下载的 URL 含 x86_64 / amd64 / i686，且文件后缀为 .so/.tar.gz/.zip
C. RUN 命令中含 ldconfig / ln -s *.so / install *.so，且路径含 x86_64/amd64
D. 构建输出出现：ELF 64-bit LSB ... x86-64（file 命令输出）
E. 运行时报错：illegal instruction / SIGILL / UnsatisfiedLinkError
```

**处理动作**——按 .so 类型分三类处理：

| 类型                                                    | 判断方式                                   | 处理策略                                                     |
| ------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------ |
| **功能无关 / 可选插件**（如调试工具、性能分析 so）      | 去掉后容器核心功能不受影响                 | 注释掉 COPY/RUN 行，追加 `# [WARN-X86-NATIVE-SO]`，报告中记录 |
| **功能相关 / 有公开替代版本**（如 LWJGL、sqlite、zstd） | 有已知 aarch64 release 或上游提供 arm64 包 | 替换为 aarch64 版本，追加 `# [FIXED-SO-REPLACED-AARCH64]`，报告中说明 |
| **自研 so / 无公开来源**（闭源二进制、内部 SDK）        | 无法找到 arm64 等价物                      | **分情况处理**：<br>• 有源码 → 在 Dockerfile 中补充 `RUN make / cmake` 重新编译，追加 `# [WARN-CUSTOM-SO-RECOMPILED]`<br>• 无源码 → **标记迁移失败** `FAILED(PROPRIETARY_X86_SO)`，报告中注明该 so 路径和来源，不可自动处理 |

> **禁止将功能相关的 so 直接注释删除**——必须先评估影响，再按上表选择策略。

**JAR 内 native .so 检查与替换（Java 项目）**：

```bash
# 检查 JAR 内是否含 x86_64 native 库
unzip -l <path>.jar | grep -E "\.so|\.dll|linux"

# 替换（以 LWJGL 为例）
# 从 LWJGL 3.x aarch64 release 提取对应 .so
zip -j <jar_path> <aarch64_so_files>
```

---

## 7. Java / Maven / Gradle 错误

### `Source option 6 is no longer supported. Use 7 or later`

- **原因**：pom.xml 中 `maven.compiler.source=1.6`，但 JDK 11+ 最低支持 Java 7
- **修复**：`./mvnw install -Dmaven.compiler.source=8 -Dmaven.compiler.target=8 -DskipTests -q`

### `Detected Maven Version: 3.6.3 is not in the allowed range [3.9.0,)`

- **原因**：apt 默认安装的 Maven 版本过旧
- **修复**：从阿里云镜像手动下载 Maven 3.9.x：`mirrors.aliyun.com/apache/maven/maven-3/3.9.x/`

### `wget 404`（Maven 下载）

- **原因**：阿里云 Apache Maven 镜像路径不对
- **修复**：改用 `https://archive.apache.org/dist/maven/maven-3/...` 直接下载

### `java.lang.IllegalStateException: Cannot define class using reflection`

- **原因**：Mockito 2.x 等老版本使用 `Unsafe.defineClass`，JDK 11+ 抛出异常
- **修复**：安装 JDK 8 Temurin ARM64：

```dockerfile
RUN curl -sL https://api.adoptium.net/v3/binary/latest/8/ga/linux/aarch64/jdk/hotspot/normal/eclipse \
    -o /tmp/jdk8.tar.gz \
    && mkdir -p /opt/java8 \
    && tar -xzf /tmp/jdk8.tar.gz -C /opt/java8 --strip-components=1 \
    && rm /tmp/jdk8.tar.gz
ENV JAVA_HOME=/opt/java8
```

### `package com.sun.tools.javac does not exist` / `com.sun:tools` 依赖

- **原因**：JDK 9+ 移除了 `tools.jar`
- **修复**：同上，安装 JDK 8 Temurin ARM64（tools.jar 在 JDK 8 中可用）

### Android Build Tools（`aapt2`/`d8`/`R8`）host 架构不匹配

- **原因**：项目锁定的 Build Tools 可能只提供与当前构建机不兼容的 host 二进制。
- **处理**：先检查当前版本的实际制品、可升级版本和远程/原生构建方案；只有必需工具仍无可执行 ARM64 版本且无替代构建路径时，才使用 `status=FAILED, failure_reason=ARCH_INCOMPATIBILITY`。

### Gradle daemon OOM（`Build daemon disappeared unexpectedly`）

- **原因**：大型 Gradle 项目，Docker VM 内存有限，Kotlin 编译进程 OOM
- **修复**：减少并发 `--parallel --max-workers=2`；排除不需要的模块 `-x :module:test`

### 构建成功但实为 mvn 失败（`exit 0` 但测试未执行）

- **原因**：使用了 `./mvnw install 2>&1 | tail -20`，管道吞掉退出码
- **修复**：去掉管道，改用 `-q` 安静模式：

```dockerfile
# 错误：管道吞掉退出码
RUN ./mvnw install 2>&1 | tail -20

# 正确
RUN ./mvnw install -DskipTests -T 2C -q
```

### `application not found`（dotnet restore）

- **原因**：`global.json` 锁定的 SDK 在目标环境不可用。
- **修复**：先安装匹配 SDK，或在项目允许时调整 `global.json` 的版本/rollForward 策略并保存 diff。删除 `global.json` 会改变 SDK 选择规则，禁止作为默认修复。

### Gradle / Maven 构建缓存清理（避免 ARM64 跨架构缓存污染）

- **原因**：宿主机 x86 构建产生的 Gradle/Maven 缓存被 COPY 到镜像内，ARM64 构建时读取导致二进制不兼容
- **修复**：在 Dockerfile 中清除跨架构缓存：

```dockerfile
# Gradle 缓存清理（放在 gradle build 层之前）
RUN find ~/.gradle/caches -name "*.lock" -delete \
    && find ~/.gradle/caches -name "*.bin" -delete 2>/dev/null || true

# Maven 本地仓库清理（放在 mvn install 层之前）
RUN find ~/.m2/repository -name "_maven.repositories" -delete \
    && find ~/.m2/repository -name "*.lastUpdated" -delete 2>/dev/null || true
```

### Gradle Kotlin 编译器 `Failed to create Kotlin daemon`

- **原因**：Kotlin daemon 在 ARM64 容器中 JVM 内存配置不足或守护进程超时
- **修复**：

```dockerfile
ENV GRADLE_OPTS="-Dorg.gradle.daemon=false -Dkotlin.daemon.jvm.options=-Xmx512m"
RUN ./gradlew build -x test --no-daemon
```

---

## 8. Node.js / npm 错误

### nodesource 安装后 apt 源被重置

- **修复**：绕过 nodesource，直接下载 arm64 tar 包（见 3 末尾模板）

### `deepEqual` 比较失败但数据"看起来完全相同"

- **原因**：ARM64 与 x86 浮点计算精度不同，末位数字有微小差异
- **修复**：使用 `REGEN=1` 重新生成测试预期值（见 9）

### `Snapshot mismatched`（esbuild / bundler 跨架构差异）

- **原因**：esbuild 等工具在 ARM64 和 x86 上代码生成策略不同
- **修复**：见 10

### `Test timed out in 30000ms`（ARM64 编译性能差异）

- **原因**：ARM64 上 WASM 编译等操作比 x86 慢 2-3 倍
- **修复**：见 11

### Node.js 各版本 ARM64 下载模板（npmmirror 加速）

`nodejs.org` 直连极慢，统一改用 `npmmirror.com`：

```dockerfile
# Node 12 ARM64（EOL，包格式为 tar.xz）
ENV NODE_VERSION=12.22.12
RUN curl -L --retry 3 --max-time 120 -o /tmp/node.tar.xz \
      "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz && node --version

# Node 14 / 16 / 18 / 20 / 22 通用模板（包格式为 tar.gz，大文件 --max-time 300）
ENV NODE_VERSION=<x.y.z>
RUN curl -fsSL --max-time 300 --retry 3 \
      -o /tmp/node.tar.gz \
      "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz" \
    && tar -xz -C /usr/local --strip-components=1 -f /tmp/node.tar.gz \
    && rm /tmp/node.tar.gz && node --version
```

### `npm install -g yarn` 在 Node 12 ARM64 失败（exit 1）

- **原因**：Node 12 EOL，npm 5/6 在 ARM64 下安装全局包存在 path 问题
- **修复**：从 yarnpkg.com 直接下载 tar 包安装：

```dockerfile
ENV YARN_VERSION=1.22.17
RUN curl -L -o /tmp/yarn.tar.gz \
      "https://yarnpkg.com/downloads/${YARN_VERSION}/yarn-v${YARN_VERSION}.tar.gz" \
    && tar -xzf /tmp/yarn.tar.gz -C /opt/ && rm /tmp/yarn.tar.gz \
    && ln -sf /opt/yarn-v${YARN_VERSION}/bin/yarn /usr/local/bin/yarn \
    && ln -sf /opt/yarn-v${YARN_VERSION}/bin/yarnpkg /usr/local/bin/yarnpkg \
    && yarn --version
```

### NVM 安装脚本（GitHub）在网络隔离环境下失败

- **原因**：`raw.githubusercontent.com` 或 `github.com` 不可达，`curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/vX/install.sh | bash` 卡死
- **修复**：绕过 NVM，直接解压 Node tar 包到 `$NVM_DIR/versions/node/v$VERSION/` 并设置软链：

```dockerfile
ENV NVM_DIR=/home/<user>/.nvm
ENV NODE_VERSION=<x.y.z>
RUN mkdir -p ${NVM_DIR}/versions/node/v${NODE_VERSION} \
    && curl -L --retry 3 -o /tmp/node.tar.xz \
       "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C ${NVM_DIR}/versions/node/v${NODE_VERSION} --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && mkdir -p ${NVM_DIR}/alias && echo "v${NODE_VERSION}" > ${NVM_DIR}/alias/default
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:${PATH}
```

> `nvm use` 命令仍然可用；`node`/`npm` 命令通过 `PATH` 直接指向已解压的 bin 目录。

### `npm ERR! code E407` / `407 Proxy Authentication Required`（构建容器内 npm install）

- **症状**：`docker build` 的 `RUN npm install` 经 `${BUILD_PROXY_ARGS}` 注入的代理访问 registry 时返回 `407 Proxy Authentication Required`，而同一代理对 `pip` / `apt` / `curl` 正常。

- **原因**：npm 不读取 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量做代理认证，且许多企业代理要求显式 `Proxy-Authorization` 头或 `user:pass@host` 形式凭据；`--build-arg` 注入的环境变量对 npm 无效或凭据无法传递，导致 407。npm 的代理走 `npm config set proxy / https-proxy`，与 pip/curl 机制不同。

- **修复方案 A（首选，代理认证无法穿透时）**：在宿主机（网络可达、可完成代理认证）安装依赖，构建时 `COPY` 进镜像，完全跳过容器内 npm 联网：

  ```bash
  # 宿主机：在构建上下文中安装与目标架构/Node 版本匹配的 node_modules
  cd <build_context>/<project>
  npm install            # 宿主机完成代理认证与下载
  # 若宿主机与目标架构不同，需在目标 ARM64 机或 QEMU 容器内安装含 native 模块的依赖
  ```

  ```dockerfile
  # Dockerfile：直接 COPY 已安装的 node_modules，容器内不再 npm install
  WORKDIR /<project>
  COPY <project>/package*.json ./
  COPY <project>/node_modules ./node_modules
  # 若有构建步骤（如 tsc/webpack），在容器内执行，但依赖已就位无需联网
  RUN npm run build --omit=dev || true
  ```

- **修复方案 B（代理支持无认证或凭据可配时）**：在 Dockerfile 内用 `npm config` 显式设置代理（凭据须用户确认）：

  ```dockerfile
  RUN npm config set proxy http://<user>:<pass>@<proxy_host>:<port> \
      && npm config set https-proxy http://<user>:<pass>@<proxy_host>:<port> \
      && npm install --registry <NPM_REGISTRY>
  ```

  > 凭据写入镜像层有泄漏风险，仅在临时构建且用户明确授权时使用；优先方案 A。

- **修复方案 C（改用无认证镜像源）**：若 `NPM_REGISTRY`（默认 `https://registry.npmmirror.com`）在 `--network=host` 下可直连无需代理，在 npm 命令中显式指定 registry 并排除代理：`npm install --registry <NPM_REGISTRY> --noproxy '*'`。

- **验证**：`docker run --rm <image> node -e "require('<main_module>')"` 成功加载即依赖就位。

- **适用条件**：仅当 `BUILD_PROXY` 非空且 npm 报 407 时适用；npm 直连镜像源无此问题。方案 A 中含 native 模块（如 `node-canvas`/`bcrypt`）的项目须在目标架构环境安装，否则二进制不兼容。

### `npm ERR! code UNABLE_TO_VERIFY_LEAF_SIGNATURE` / `SELF_SIGNED_CERT_IN_CHAIN`（企业代理 TLS 证书）

- **症状**：`docker build` 的 `RUN npm install` 报 `UNABLE_TO_VERIFY_LEAF_SIGNATURE` 或 `SELF_SIGNED_CERT_IN_CHAIN`，而 `pip` / `apt` / `curl` 经同一代理正常。

- **原因**：企业内网代理（如自签名或中间人 TLS 解密网关）用自签名/私有 CA 重签出网流量；npm 默认严格校验 TLS 证书链，不信任系统 `ca-certificates` 之外的私有 CA，故校验失败。pip/curl 走系统证书包故正常。

- **修复方案 A（首选，代理证书无法导入时）**：在 Dockerfile 内临时关闭 npm 的证书严格校验（仅限构建阶段，不写入运行时）：

  ```dockerfile
  RUN npm config set strict-ssl false \
      && npm install --registry <NPM_REGISTRY> \
      && npm config delete strict-ssl
  ```

  > `strict-ssl false` 会关闭 TLS 证书校验，存在中间人风险，**仅在企业内网受控代理环境且用户确认后使用**；安装完成后立即 `delete` 恢复默认，避免影响后续步骤。

- **修复方案 B（治本，有私有 CA 证书时）**：将企业私有 CA 证书导入构建容器信任链，保持严格校验：

  ```dockerfile
  COPY _build_context/company-ca.crt /usr/local/share/ca-certificates/
  RUN apt-get update && apt-get install -y ca-certificates \
      && update-ca-certificates \
      && npm install --registry <NPM_REGISTRY>
  ```

  > CA 证书需用户从代理管理员处获取并经确认；node 原生读取系统 CA 包（`update-ca-certificates` 生效后），无需额外配置 npm。

- **修复方案 C（宿主机安装后 COPY）**：与 npm 407 方案 A 相同，在宿主机（已信任企业 CA）`npm install` 后 `COPY node_modules`，完全跳过容器内 npm 联网。

- **验证**：`npm install` 不再报证书错误且依赖安装完成；方案 B 额外验证 `node -e "require('tls').createSecureContext()"` 不抛异常。

- **适用条件**：仅当 `BUILD_PROXY` 非空（企业代理环境）且 npm 报 TLS 证书错误时适用；npm 直连公网镜像源无此问题。优先 B（保持校验），无 CA 证书时用 A，native 模块项目用 C。

---

## 9. 浮点精度差异

> **背景**：ARM64（ARMv8 NEON）与 x86-64（x87/AVX）FPU 实现不同，超越函数（`Math.log`、`Math.sin`、地理坐标计算等）在末位精度（ULP）上有微小差异。这是 IEEE 754 标准允许的行为，不是 Bug。

### 识别浮点精度失败

```text
症状 1: expected:<2.0> but was:<2.0000000000000004>    ← 差值 < 1e-10
症状 2: deepEqual 比较失败，两边数据"看起来相同"
症状 3: 地理坐标计算精度断言失败，差异 < 1e-14
症状 4: AssertJ isEqualTo(double) 断言失败
```

### 修复方案（按语言）

**Java（AssertJ）**：

```java
// ARM64 上失败
assertThat(result).isEqualTo(2.0);

// 支持浮点容差
assertThat(result).isCloseTo(2.0, offset(1e-10));
// 需要导入：import static org.assertj.core.api.Assertions.offset;
```

**JavaScript / TypeScript（tape 框架）**：

```bash
# 用 REGEN=1 重新生成测试预期值
docker run --rm <image> bash -c "cd /path/to/project && REGEN=1 npm test"
# 再次运行测试验证通过
```

**Python（pytest）**：

```python
# 失败
assert result == 2.0

# 正确
import math
assert math.isclose(result, 2.0, rel_tol=1e-10)
```

**修改边界**：不使用固定文件数或百分比自动决定是否改测试。先证明差异来自跨平台浮点表示而非业务错误，再列出拟修改断言、容差依据和影响范围；超出用户允许的测试基线变更范围时使用 `status=FAILED, failure_reason=FLOAT_PRECISION`。

---

## 10. 测试快照不匹配

### 识别

```text
症状: Snapshot mismatched
症状: Expected value to equal: <Snapshot 1>
症状: snapshots obsolete
症状: 1 snapshot failed
```

### 修复：受控更新并复验快照

先确认差异只来自预期的平台无关输出变化，且用户允许更新测试基线。更新命令必须保留退出码，随后用不带更新参数的测试重新验证：

```dockerfile
# 示例：vitest / jest
RUN cd /testbed \
    && npm test -- --updateSnapshot \
    && npm test

# 示例：pytest + syrupy
RUN cd /testbed \
    && python -m pytest --snapshot-update \
    && python -m pytest
```

> 不要用 `|| true` 隐藏更新命令或复验失败。快照反映业务预期，无法解释的差异应保留为 `TEST_FAILURE`。

---

## 11. 测试/构建超时

> **背景**：跨架构模拟、构建机资源和实现差异都可能改变耗时。超时是待诊断信号，不能直接归因于 ARM64 性能。

### 区分构建超时与测试用例超时

- 整体构建超过 `BUILD_TIMEOUT_MIN`：保存当前步骤、资源使用和最后日志，按 `SKILL.md` 的失败判定红线使用 `status=FAILED, failure_reason=TIMEOUT`；不要写死另一套分钟阈值。
- 单个测试超时：先判断死锁、外部服务、模拟开销或资源不足；只有测试本身预期会更慢且上限有依据时才调整超时。

### 测试超时修复

对配置文件做结构化或精确修改，修改失败必须中断；修改后同时运行目标测试和原测试入口：

```dockerfile
RUN node -e "
  const fs = require('fs');
  const path = 'vitest.config.mts';
  let cfg = fs.readFileSync(path, 'utf8');
  const next = cfg.replace(/testTimeout:\s*30_?000/g, 'testTimeout: 90_000');
  if (next === cfg) throw new Error('testTimeout pattern not found');
  fs.writeFileSync(path, next);
" \
    && npm test -- <affected-test> \
    && npm test
```

超时值来自原基线、观测耗时和用户验收要求，不使用固定“ARM64 倍数”。

---

## 12. Rust / Cargo 错误

### `error: failed to fetch` / 下载速度 < 10 bytes/sec

- **原因**：crates.io 在国内访问慢
- **修复**：配置 rsproxy 镜像（见 2.2 cargo 模板）

### Rust 安装极慢：`static.rust-lang.org` 连接超时

- **原因**：`rustup-init` 默认从 `static.rust-lang.org` 下载工具链，国内访问极慢
- **修复**：在 `curl | sh` **之前**设置镜像环境变量：

```dockerfile
ENV RUSTUP_DIST_SERVER=https://rsproxy.cn
ENV RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
      -y --profile default --default-toolchain stable \
    && . $HOME/.cargo/env \
    && rustup --version && cargo --version
```

> 环境变量必须在 `curl | sh` 之前声明；rsproxy 镜像速度通常比默认源快百倍以上。

### `cargo fetch` 极慢：crates.io-index 下载卡死

- **原因**：crates.io 默认使用 git 协议克隆索引（几百 MB），国内网络不稳定时极慢
- **修复**：配置 sparse 索引（与 2.2 cargo 模板相同）：

```dockerfile
RUN mkdir -p ~/.cargo && cat > ~/.cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
```

> **sparse 协议只下载所需的依赖元数据**，相比 git clone 全量索引快得多。

### `cargo test` 下载外部数据超时

- **适用条件**：集成测试在运行时下载外部数据，且迁移验收允许先验证离线单元测试。
- **修复**：仅运行 library 单元测试，跳过依赖网络的集成测试：

```dockerfile
CMD ["cargo", "test", "--lib", "--", "--nocapture"]
```

- **验证**：记录被跳过的测试范围；不得用该结果宣称完整测试通过。

---

## 13. Ruby / Gem 错误

### `sqlite3 >= 1.6 requires ruby >= 2.7`

- **处理**：优先升级 Ruby 或选择项目声明支持的 sqlite3 版本。`force_ruby_platform` 只改变制品选择，不能解决语言版本约束；不得默认删除 `Gemfile.lock`。所有支持组合均不可用时才使用 `status=FAILED, failure_reason=VERSION_INCOMPATIBILITY`。

### `ffi requires Ruby >= 3.0`

- **处理**：读取 Gemfile/Gemfile.lock 和上游兼容矩阵，选择项目支持的 Ruby 升级或 ffi 版本。禁止用不解析语法的 `sed` 直接改依赖声明。

### Gemfile Ruby 版本约束不满足（如 `ruby '3.2.2'`）

- **处理**：使用满足约束的 ARM64 Ruby 基础镜像；只有项目维护者确认约束过严时才修改声明。删除版本约束不是默认迁移修复。

### `prism` / `psych` native 扩展编译失败

- **处理**：从错误日志确认缺失头文件或工具链，再安装对应开发包（例如 `libyaml-dev`）并用原 lockfile 重试。只有依赖解析本身需要变更时才评估更新 lockfile。

### `Gem::RemoteFetcher::FetchError`（rubygems.org 下载超时）

- **修复**：配置国内 Gem 镜像：

```dockerfile
RUN gem sources --add https://mirrors.aliyun.com/rubygems/ \
    --remove https://rubygems.org/ \
    && bundle config mirror.https://rubygems.org https://mirrors.aliyun.com/rubygems/
```

### Bundler 版本不兼容（`Your Gemfile requires Bundler version x.x.x`）

- **修复**：安装 lockfile 要求的精确 Bundler 版本并验证；不要在失败后静默安装任意最新版。

```dockerfile
RUN gem install bundler -v <locked_version> \
    && bundle _<locked_version>_ --version
```

删除 `Gemfile.lock` 会重解析全部依赖，属于依赖基线变更，只能在用户确认后执行并保存完整 diff。

### `cannot load such file -- atomic_reference`（Ruby C 扩展）

- **原因**：依赖可能加载了与目标架构不兼容的预编译扩展。
- **修复候选**：升级到提供 ARM64 制品的版本、从源码重编译，或在上游明确支持时启用纯 Ruby 实现。

```dockerfile
ENV CONCURRENT_RUBY_DISABLE_EXTENSIONS=1
RUN bundle exec ruby -e "require 'concurrent'" \
    && bundle exec rspec
```

禁止通过删除相关测试文件来获得通过结果。

---

## 14. C++ / CMake 错误

### `CMake 3.23 or higher is required. You are running version 3.16.3`

- **原因**：Ubuntu 20.04 apt 源 cmake 版本过旧
- **修复**：从 Kitware 下载 ARM64 安装包：

```dockerfile
RUN wget -q https://cmake.org/files/v3.28/cmake-3.28.6-linux-aarch64.sh \
    && chmod +x cmake-3.28.6-linux-aarch64.sh \
    && ./cmake-3.28.6-linux-aarch64.sh --skip-license --prefix=/usr/local \
    && rm cmake-3.28.6-linux-aarch64.sh
```

### `ambiguous template instantiation` / 符号冲突

- **原因**：手动安装的子依赖版本与项目期望版本不匹配
- **修复**：使用 `git clone --recursive`，让项目自管理子模块

### `fatal: could not read Username for 'https://github.com'`

- **原因**：Docker BuildKit 网络隔离，旧基础镜像无法访问外网
- **修复**：加 `--network=host`（由 `${BUILD_NET_ARG}` 注入，见 §20.1）；仍失败则判定 FAILED

---

## 15. PHP / Composer 错误

### `ext-bcmath * is missing` / `ext-gd * is missing`

- **修复**：

```dockerfile
RUN apt-get install -y libgd-dev \
    && docker-php-ext-install bcmath gd
```

### PHP 旧版本（7.4 / 8.0 / 8.1）ARM64 安装

官方 `php:7.4` Docker 镜像无 ARM64 manifest，需通过 `ppa:ondrej/php` 安装：

```dockerfile
RUN add-apt-repository ppa:ondrej/php \
    && apt-get update \
    && apt-get install -y php7.4 php7.4-cli php7.4-dev php7.4-mbstring \
         php7.4-xml php7.4-zip php7.4-mysql php7.4-curl \
    && php --version
```

> ondrej PPA 支持 Ubuntu 20.04/22.04 ARM64。查证：`apt-cache policy php7.4`

### `Composer: Do not run Composer as root/super user!`

- **原因**：部分 Composer 版本在 root 用户下拒绝运行
- **修复**：

```dockerfile
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN composer install --no-interaction
```

---

## 16. Docker / 环境错误

### `invalid character '#'`（config.json 警告）

- **修复**：`~/.docker/config.json` 中删除以 `#` 开头的行

### `content at ... not found`（前缀方式镜像仓内容缺失）

- **修复**：改用 `daemon.json` 的 `registry-mirrors` 配置

### `exit code 145`（SIGTERM）

- **原因**：旧的 kill 或超时命令杀掉了进程
- **修复**：等进程完全退出后再启动新构建；用 `kill -- -$pid` 杀整个进程树

### Docker daemon 无响应

- **处理**：先保存当前构建/容器证据并检查 daemon 状态、磁盘和并发任务。重启 Docker 或终止 daemon 会影响其他工作负载，必须获得用户确认；禁止默认执行 `kill -9`。

### Chrome 在 root 用户下无法启动（`--no-sandbox` 缺失）

```dockerfile
RUN node -e "
  const fs = require('fs');
  const conf = fs.readFileSync('/testbed/karma.conf.cjs', 'utf8');
  const fixed = conf.replace(
    'browsers: [\"Chrome\"]',
    \`customLaunchers: {
      ChromeHeadlessNoSandbox: {
        base: 'ChromeHeadless',
        flags: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu']
      }
    },
    browsers: ['ChromeHeadlessNoSandbox']\`
  );
  fs.writeFileSync('/testbed/karma.conf.cjs', fixed);
"
```

### 浏览器二进制与目标架构不匹配

- **识别**：项目指定的浏览器包、driver 或固定下载 URL 只提供源架构制品。
- **处理**：检查当前指定版本的实际制品和目标发行版仓库；存在可接受的 Chromium/Firefox 或供应商 ARM64 版本时再替换，并同步更新 driver、启动参数和测试配置。
- **验证**：执行 `--version`、无头启动和相关 UI/自动化测试。浏览器替换会改变渲染与兼容性，必须记录为行为变更，不能只凭名称相近认定等价。

### `Mysql2::Error` / `Connection refused`（外部服务依赖）

先区分“服务未启动/配置错误”和“迁移后不可用”。能够在测试环境启动依赖服务时，应恢复真实集成测试；无法提供外部服务时使用 `test_status=skip` 并记录缺口。只有外部服务是必需验收条件且无法提供时，才使用 `status=FAILED, failure_reason=EXTERNAL_SERVICE`；不按固定测试比例自动排除用例。

### `groupadd: group already exists` / `useradd: user already exists`

- **原因**：基础镜像内已有同名用户/组，或 UID/GID 被其他主体占用。
- **修复**：分别验证名称和 UID/GID，避免依赖 `&&`/`||` 混合优先级：

```dockerfile
RUN set -eu; \
    if ! getent group <group> >/dev/null; then \
      if getent group <GID> >/dev/null; then echo "GID <GID> is already used" >&2; exit 1; fi; \
      groupadd --gid <GID> <group>; \
    fi; \
    if ! getent passwd <user> >/dev/null; then \
      if getent passwd <UID> >/dev/null; then echo "UID <UID> is already used" >&2; exit 1; fi; \
      useradd --uid <UID> --gid <group> --create-home --shell /bin/bash <user>; \
    fi
```

### 工具安装目录权限不足

- **原因**：Dockerfile 已切换到普通用户，但安装动作仍写入 `/usr/local/bin` 等系统目录。
- **修复**：在最小范围内切回 `USER root`，安装经验证的 ARM64 制品并校验完整性/可执行性，然后恢复原用户。禁止创建“始终成功”的 stub 冒充必需工具。

```dockerfile
USER root
RUN curl -fL --max-time 60 --retry 2 -o /usr/local/bin/<tool> "<verified-arm64-url>" \
    && echo "<sha256>  /usr/local/bin/<tool>" | sha256sum -c - \
    && chmod +x /usr/local/bin/<tool> \
    && /usr/local/bin/<tool> --version
USER <original-user>
```

### Java 工具或 Selenium JAR

JAR 本身通常由 JVM 执行，但其依赖的浏览器、driver、JNI 库和外部文件可能与架构相关。确认 JRE 为目标架构，并分别验证 JAR 启动及所有 native/driver 依赖。下载失败时，必需组件必须中断；只有项目证据确认组件可选且用户允许功能缺失时才可跳过。

### 辅助工具下载失败

先从 ENTRYPOINT、启动脚本、健康检查和测试路径判断工具是否必需：

- **必需工具**：使用经验证的 ARM64 制品、发行版包或源码构建；失败必须中断。
- **可选工具**：仅在用户允许对应功能缺失时跳过，记录 `[WARN-OPTIONAL-TOOL-MISSING]` 并覆盖相关运行验证。
- **禁止**：使用 `|| true` 隐藏必需工具安装失败，或生成无真实功能的成功 stub。

---

## 17. 系统工具缺失

### 识别

```text
症状: executable file not found in $PATH: modprobe
症状: sudo: command not found
症状: vim: command not found
```

### 修复：在 apt 层追加缺失工具

```dockerfile
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    git curl ca-certificates make gcc g++ \
    kmod sudo vim nano \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

### Go 项目常用工具

- `TalosProvisioner` / `KindProvisioner` → 需要 `kmod`、`sudo`
- `EditorResolver` → 需要 `vim`、`nano`
- Root 用户权限检查失效（`TestLoadConfigFromFilePermissionError`）→ 记录 `TEST_FAILURE`，不强制修复

---

## 18. C 扩展 / native 库降级

### 识别

```text
症状 (Ruby):  cannot load such file -- atomic_reference (LoadError)
症状 (Python): ImportError: ... undefined symbol (ELF binary)
症状 (Python): binary incompatible with ARM64
```

### 修复

**Python**：

```dockerfile
ENV PURE_PYTHON=1
# 或卸载并重装无二进制版本
RUN pip install --no-binary :all: <package>
```

### 判断是否允许降级

不使用固定百分比替代业务判断。列出受影响功能、是否属于核心路径、替代实现和验证范围；仅在用户验收标准允许时降级。核心功能无法满足时使用 `status=FAILED, failure_reason=ARCH_INCOMPATIBILITY`。

---

## 19. Dockerfile 编写原则

### 层结构顺序（从上到下缓存命中率递减）

```dockerfile
FROM <base>                          # 缓存最稳定
RUN # 1. 镜像源替换                  # 很少变
RUN # 2. apt-get install 系统包      # 偶尔改
RUN # 3. pip/composer/npm 安装       # 中等频率
RUN # 4. git clone + checkout        # commit 变化就失效
RUN # 5. 编译/构建（mvn/go/cargo）   # 依赖上一层
WORKDIR /testbed
CMD ["<test_cmd>"]                   # 频繁改，放最后
```

### 最小化缓存破坏

```text
只缺少组件 → 在 git clone 之前新增独立 RUN 层（不改原有层）
包名错误   → 必须改原有层（需 --no-cache 重建）
依赖冲突   → 合并到同一 apt-get install 层
```

### 管道过滤与退出码

```dockerfile
# 错误：管道吞掉退出码
RUN ./mvnw install 2>&1 | tail -20

# 正确：用 -q 安静模式
RUN ./mvnw install -DskipTests -T 2C -q
```

### 内网包保护（失败时不中断构建）

```dockerfile
RUN pip3 install "internal-package==x.y.z" -i http://<INTERNAL_PYPI>/simple \
    || echo "WARNING: internal-package not available, skipping"
```

### 版本强制覆盖（末尾追加层）

```dockerfile
RUN pip3 install "networkx>=2.6" --quiet
```

**已知版本兼容性问题**：

| 包                     | 原版本问题                             | 修复方案                    |
| ---------------------- | -------------------------------------- | --------------------------- |
| `networkx` 2.2         | Python 3.10 移除 `collections.Mapping` | 升级到 `networkx>=2.6`      |
| `gym` ≤ 0.19.x         | 与 setuptools≥60 元数据不兼容          | 升级到 `gym==0.26.2`        |
| `golang:1.25-bookworm` | Go 1.25 尚未发布，镜像不存在           | 改用 `golang:1.24-bookworm` |

---

## 20. 构建命令速查

> **构建网络与代理**：`docker build` 的 `RUN` 步骤运行在独立容器网络命名空间，其 DNS 解析器（daemon.json 的 `dns`）在该命名空间未必可达——典型表现是 `docker pull` 正常但 `pip install` / `npm install` / `apt-get` 报 `Temporary failure in name resolution`。构建命令统一使用启动门禁生成的 `BUILD_NET_CTX`：
>
> - `${BUILD_NET_ARG}`：网络参数。`BUILD_NET_MODE=host` 时为 `--network=host`，`bridge` 时为空串。
> - `${BUILD_PROXY_ARGS}`：代理 build-arg。`BUILD_PROXY` 非空时展开为 `--build-arg HTTP_PROXY=<url> --build-arg HTTPS_PROXY=<url> --build-arg NO_PROXY=<no_proxy>`，否则为空串。
> - **不要在场景文件中重新探测或硬编码网络/代理**，一律取自 `BUILD_NET_CTX`。daemon.json 的 `http-proxy` 只作用于 docker daemon 拉镜像，不注入构建容器，故代理必须经 `--build-arg` 传入。

```bash
# 标准构建（${BUILD_NET_ARG} / ${BUILD_PROXY_ARGS} 由 BUILD_NET_CTX 注入）
docker build --platform linux/arm64 \
  ${BUILD_NET_ARG} ${BUILD_PROXY_ARGS} \
  -t <image>:latest \
  -f <path>/Dockerfile \
  <build_context>

# 强制无缓存构建
docker build --no-cache --platform linux/arm64 \
  ${BUILD_NET_ARG} ${BUILD_PROXY_ARGS} \
  -t <image>:latest \
  -f <path>/Dockerfile \
  <build_context>

# 验证镜像架构
docker inspect <image>:latest \
  | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print(d['Architecture'])"

# 检查基础镜像 ARM64 支持
docker manifest inspect <base_image> 2>&1 | grep -c "arm64\|aarch64"

# 磁盘检查
df -h / | awk 'NR==2 {print $5}'
docker system df
```

### Dockerfile 接收代理 build-arg 模板

当 `${BUILD_PROXY_ARGS}` 非空时，Dockerfile 必须声明对应 `ARG` 才能让 `RUN` 步骤中的包管理器识别代理（pip/npm/curl/apt 均自动读取 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` 环境变量）：

```dockerfile
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
# 之后所有 RUN 中的 pip install / npm install / apt-get / curl 自动走代理
```

> 这些 `ARG` 仅在构建阶段生效，不会写入最终镜像的环境变量，无需担心泄漏到运行时。

### 构建 `--network=host` 注意事项

- `--network=host` 让构建容器共享宿主机网络栈，绕开默认 bridge 网络中 DNS 不可达的问题，是「`docker pull` 正常但构建 RUN 报 DNS 解析失败」的首选修复。
- BuildKit/buildx 的 `docker build` 支持 `--network=host`；若使用极旧 Docker（如 18.09 的 legacy builder）不支持，退回到修复 daemon.json 的 `dns` 为容器网络路径可达的解析器（优先宿主机实际使用的内网 DNS，见下方条目），改后 `systemctl restart docker`。
- `--network=host` 下构建容器与宿主机共享端口空间，多项目并发构建若 Dockerfile 内有监听固定端口的 `RUN`（罕见）可能冲突；优先排查此类步骤而非回退网络模式。

---

## 20.1 容器 DNS 解析失败

### `Temporary failure in name resolution` / `Could not resolve host`（构建容器内）

- **症状**：`docker build` 的 `RUN pip install` / `npm install` / `apt-get update` 报 `Errno -3 Temporary failure in name resolution` 或 `Could not resolve host`；但同一台机器 `docker pull` / `docker manifest inspect` 正常。

- **原因**：`docker pull` 由宿主机上的 docker daemon 执行，用宿主机网络栈解析 DNS；而 `docker build` 的 `RUN` 步骤运行在独立的容器网络命名空间，使用 daemon.json 配置的 `dns`（如 `8.8.8.8` / `114.114.114.114` / `223.5.5.5`），这些 DNS 在容器网络路径上不可达（防火墙/路由限制）。daemon.json 的 `http-proxy` 只注入 daemon，不注入构建容器，故代理对构建 RUN 无效。

- **修复方案 A（首选，已在门禁固化）**：构建命令用 `--network=host`，让构建容器共享宿主机网络栈。门禁阶段已生成 `BUILD_NET_CTX`，直接用 `${BUILD_NET_ARG}` 注入：

  ```bash
  docker build --platform linux/arm64 ${BUILD_NET_ARG} ${BUILD_PROXY_ARGS} \
    -t <image>:latest -f <path>/Dockerfile <build_context>
  ```

- **修复方案 B（需出网代理时）**：宿主机只能经代理出网时，`--network=host` 之外再用 `${BUILD_PROXY_ARGS}` 注入代理 build-arg，并在 Dockerfile 中声明 `ARG HTTP_PROXY/HTTPS_PROXY/NO_PROXY`（模板见 §20）。代理地址须用户确认。

- **修复方案 C（治本，改默认 bridge DNS）**：把 daemon.json 的 `dns` 换成容器网络路径可达的解析器——优先宿主机实际在用的内网 DNS（`cat /etc/resolv.conf` 的 nameserver），改后 `systemctl restart docker`。留用不可达的公网 DNS 只会拖慢解析。

- **验证**：构建 RUN 中域名解析成功且包安装完成即修复生效；记录实际使用的方案到报告 `build_command`。

- **适用条件**：仅当 `BUILD_NET_CTX.build_net_mode=bridge` 且构建报 DNS 失败时回退到 A；门禁已判定 `host` 的项目无需重复处理。

---

## 21. 运行时测试分层策略

**按层次依次验证，前一层失败则不进入下一层**：

```bash
# 层次 0：真实 ENTRYPOINT/CMD 启动验证（不覆盖原始命令）
#   目的：确认镜像用自身 ENTRYPOINT/CMD 能正常启动，而非用 echo 等替换命令绕过
docker inspect <IMAGE> --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'

#   后台启动，不覆盖任何命令，等待数秒后检查进程存活
docker run -d --platform linux/arm64 --name test-real-<project> <IMAGE>
sleep 8
#   容器仍在运行 = 启动成功；已退出 = 启动崩溃
if docker ps -a --filter "name=test-real-<project>" --filter "status=running" | grep -q test-real-<project>; then
  echo "STARTUP_OK"
else
  echo "STARTUP_CRASH"
  docker logs test-real-<project> 2>&1 | tail -50
fi
docker rm -f test-real-<project> 2>/dev/null

# 层次 1：容器可启动
docker run --rm --platform linux/arm64 <IMAGE> echo "Container OK"

# 层次 2：核心模块可 import（Python 项目）
docker run --rm --platform linux/arm64 <IMAGE> \
  python3 -c "import <core_module>; print('OK')"

# 层次 3：进程探活（后台服务类）
docker run -d --platform linux/arm64 --name test-svc \
  -p <HOST>:<CONTAINER> <IMAGE>
sleep 5
docker ps | grep test-svc
docker logs test-svc 2>&1 | tail -30

# 层次 4：端口探活
docker exec test-svc ss -tlnp | grep <PORT>
curl -s --connect-timeout 5 http://localhost:<HOST>/health

# 层次 5：扫描常见 HTTP 路径
for path in / /health /monitor/alive /ping /api; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 http://localhost:<HOST>${path})
  echo "$path -> $CODE"
done
```

**常见运行时崩溃快速修复**：

| 错误                                                         | 修复方案                                           |
| ------------------------------------------------------------ | -------------------------------------------------- |
| `AttributeError: 'Env' object has no attribute 'seed'`       | 删除 `env.seed()` 调用，改用 `env.reset(seed=...)` |
| `ValueError: not enough values to unpack (expected 5, got 4)` | gym 0.26 step 返回 5-tuple，加兼容层               |
| `libGL.so.1: cannot open shared object file`                 | `apt-get install -y libgl1-mesa-dri libgl1`        |
| `cannot connect to X server :99`                             | 加 `sleep 3` 等 Xvfb 启动                          |
| `AttributeError: module 'collections' has no attribute 'Mapping'` | `pip install "networkx>=2.6"`                      |

**层次 0 启动崩溃处理流程**：

当 `STARTUP_CRASH` 发生时，按以下顺序诊断与修复：

1. `docker logs` 采集完整启动日志，提取 fatal/error/traceback 关键行
2. 按"常见运行时崩溃快速修复"表匹配已知错误模式
3. 匹配失败时检索本文件对应章节（如 native 库缺失查第 12 节、pip 包冲突查第 15 节）
4. 能通过增量 patch 修复时走第 22 节增量 patch 镜像；涉及基础镜像/系统包时回到 Dockerfile 重构阶段
5. 修复后必须重跑层次 0 确认 `STARTUP_OK`，才可继续后续层次验证

---

## 22. 增量 patch 镜像

运行时发现的 bug，**不重新全量构建**，使用增量 patch 镜像（速度极快，只添加一层）：

```dockerfile
# Dockerfile.patch
FROM <IMAGE>:latest

# [FIX-RTE-001] 修复说明
COPY _patches/fixed_server.py /app/server.py

# 清除字节码缓存
RUN find /app -name '*.pyc' -delete
```

```bash
docker build --platform linux/arm64 \
  -t <IMAGE>-patched:latest \
  -f Dockerfile.patch .
```

**热修复固化**：验证成功后，必须将修复写回原始 Dockerfile，否则下次全量构建会丢失：

```dockerfile
# 方式 A：COPY 修复文件
COPY _patches/server.py /app/server.py

# 方式 B：sed patch
RUN sed -i '/env\.seed(req\.seed)/d' /workspace/server.py
```

---

## 23. 磁盘管理

### 前置检查

```bash
DISK_USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
```

| 使用率  | 动作                             |
| ------- | -------------------------------- |
| < 80%   | 正常执行                         |
| 80%–90% | 先清理再构建                     |
| > 90%   | 强制暂停构建任务，提示必须先清理 |

### 清理顺序

1. 历史批次自建镜像（旧 tag）
2. 悬空镜像：`docker image prune -f`
3. BuildKit 缓存：`docker builder prune -f --filter "until=24h"`
4. 已验证完成的当前批次镜像

---

## 24. 大文件下载失败 / 构建容器 OOM（exit code 8 / 137）

### `wget/curl exit code 8 (Server error)` 或 `exit code 137 (SIGKILL)`

- **原因 A**：构建容器内 `wget`/`curl` 下载大文件（>100MB），网络不稳定导致超时或 OOM

- **原因 B**：并发构建时内存竞争，docker 系统资源不足

- **修复**：**预下载到构建上下文，改用 COPY**

```dockerfile
# 错误：构建时下载大文件
RUN curl -o /opt/big.tar.gz https://example.com/package-arm64.tar.gz \
    && tar -xzf /opt/big.tar.gz

# 正确：预先下载到 build context，构建时 COPY
# 构建前在宿主机执行：curl -o _build_context/big.tar.gz https://...
COPY _build_context/big.tar.gz /opt/
RUN tar -xzf /opt/big.tar.gz && rm /opt/big.tar.gz
```

> 适用场景：Elasticsearch aarch64 tarball（1.2GB）、Grafana arm64 tarball（329MB）、MySQL arm64 tarball（800MB+）等大文件。

### 预下载后 aarch64 tarball 缺少目录

- **症状**：`chown: cannot access 'data': No such file or directory`
- **原因**：官方 aarch64 tar.gz 不包含所有运行时目录（如 `data/`、`logs/` 等），这些在 Dockerfile 中通过 `mkdir` 创建
- **修复**：在 chown 前补充 `mkdir -p <missing_dir>`：

```dockerfile
COPY _build_context/elasticsearch.tar.gz /opt/
RUN tar -xzf /opt/elasticsearch.tar.gz -C /opt/ \
    && mkdir -p /opt/elasticsearch/data /opt/elasticsearch/logs \
    && chown -R esuser:root /opt/elasticsearch
```

## 25. ca-certificates 缺失 / apt HTTPS 源兜底

### `SSL certificate verify failed` 或 `The certificate is not trusted`

- **原因**：基础镜像（如 `debian:trixie`）初始不包含 `ca-certificates` 包，无法访问 HTTPS apt 源
- **修复方案 A（推荐）**：先用 HTTP 源安装 ca-certificates，再改 HTTPS

```dockerfile
RUN echo "deb http://mirrors.aliyun.com/debian trixie main" > /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get install -y ca-certificates \
    && sed -i 's|http://|https://|' /etc/apt/sources.list \
    && apt-get update -qq
```

- **修复方案 B（仅临时诊断且需用户明确授权）**：全程使用 HTTP。该方案缺少传输加密，不应用于正式构建或生产交付。

> Alpine 基础镜像通常已包含 `ca-certificates-bundle`，无此问题。

## 26. apt 镜像源替换不成功（403 / 404 / 不可用）

### `HTTP 403 Forbidden` (TUNA / 清华源)

- **症状**：TUNA 镜像（`mirrors.tuna.tsinghua.edu.cn`）返回 403
- **原因**：TUNA 对某些 IP 段 / User-Agent 有限制
- **修复**：切换到阿里云镜像：

```dockerfile
# Debian DEB822 格式用 sed 全局替换
RUN sed -i 's|mirrors.tuna.tsinghua.edu.cn|mirrors.aliyun.com|g' \
    /etc/apt/sources.list.d/debian.sources
```

### `apt-get update` 未在同一层执行导致 `apt-get install` 失败

- **症状**：`E: Unable to locate package` 或 `Package has no installation candidate`
- **原因**：`apt-get update` 在前一个 RUN 层执行，当前层 apt lists 为空（分层构建，每层 `rm -rf /var/lib/apt/lists/*` 是常见优化模式）
- **修复**：每个 RUN 层必须包含 `apt-get update`（或合并相关 apt 操作为一个 RUN）

```dockerfile
# 错误：update 和 install 在不同层
RUN apt-get update && apt-get install -y curl \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get install -y gnupg    # 失败！apt lists 已清除

# 正确：合并为一个 RUN
RUN apt-get update && apt-get install -y curl gnupg \
    && rm -rf /var/lib/apt/lists/*
```

## 27. keyserver 不可达 / GPG 密钥获取失败

### `keyserver receive failed: Connection timed out`

- **原因**：中国网络访问 `keyserver.ubuntu.com` 不稳定，`gpg --recv-keys` 超时
- **修复方案 A（推荐）**：从 x86 镜像提取 GPG 密钥文件

```bash
docker cp <x86_image>:/path/to/key.gpg _build_context/key.gpg
```

```dockerfile
COPY _build_context/key.gpg /tmp/
RUN gpg --batch --import /tmp/key.gpg && rm /tmp/key.gpg
```

- **密钥仍不可得时**：停止使用该来源。优先选择带固定校验和/签名的可信制品、组织内部制品库或发行版软件包。不得用 HTTPS 可达替代签名验证，也不得在无人确认时加入跳过校验的 Dockerfile 片段。

### `ha.pool.sks-keyservers.net` keyserver 已永久关闭

- **症状**：`gpg: keyserver receive failed: General error`
- **原因**：SKS keyserver pool 已全面关停。该 keyserver 广泛出现在老旧 Dockerfile 中
- **修复**：替换为 `keyserver.ubuntu.com`：

```dockerfile
# 已失效
gpg --keyserver ha.pool.sks-keyservers.net --recv-keys ABCD...

# 替换为
gpg --keyserver keyserver.ubuntu.com --recv-keys ABCD...
```

### 第三方仓库 GPG 端点不可用或需要额外授权

- **症状**：密钥下载返回 `401/402/403` 或持续不可达。
- **处理**：不要跳过 GPG 校验。改用发行版已签名软件包、可信内部镜像，或从供应方官方渠道获取并校验固定密钥；仍无法建立信任链时停止该安装路径。

## 28. Erlang / RabbitMQ 兼容性

### Erlang ABI 不匹配：`.beam` 文件无法加载

- **症状**：`Failed to start Elixir` 或 `{bad_dispatch, ...}` 运行时错误
- **原因**：RabbitMQ `.beam` 字节文件在 x86_64 上通过特定 Erlang/OTP 版本（如 OTP 26）编译，apt 仓库的 arm64 Erlang 是不同版本（如 OTP 25），ABI 不兼容
- **修复**：**多阶段构建从官方 Erlang 镜像提取匹配版本**

```dockerfile
# Stage 1: 获取 ARM64 Erlang/OTP 26
FROM --platform=linux/arm64 docker.m.daocloud.io/library/erlang:26 AS erlang

# Stage 2: 构建最终镜像
FROM --platform=linux/arm64 ubuntu:24.04
COPY --from=erlang /usr/local/lib/erlang /usr/local/lib/erlang
ENV PATH=/usr/local/lib/erlang/bin:$PATH
# ... COPY RabbitMQ 安装文件，启动服务
```

### OpenSSL 版本降级（3.1.x → 3.0.x）

- **原因**：Erlang 26 官方镜像使用 OpenSSL 3.0，而原镜像自编译了 OpenSSL 3.1；使用 apt 系统包会产生版本差异
- **修复候选**：可评估发行版提供的 `libssl3`，但必须验证 Erlang NIF/ABI、TLS 功能和安全策略；不得直接宣称完全等价或无风险

### GID 冲突（`GID '999' already exists`）

- **原因**：某些 apt 包（如 erlang）安装时会创建系统用户/组，占用了 GID 999
- **修复**：在 `groupadd -g 999` 前检查 GID 是否已占用：

```dockerfile
RUN if getent group 999; then \
        echo "GID 999 already exists, skipping groupadd"; \
    else \
        groupadd -g 999 rabbitmq; \
    fi
```

> 或使用多阶段构建（Erlang 在 stage 1，不会污染最终镜像的 GID 空间）。

## 29. Docker 18.09 兼容性约束

### 旧版 builder 不支持 `COPY --chmod`

- **原因**：可用性取决于 Dockerfile frontend、BuildKit 和 daemon 版本；不要仅凭 Docker CLI 主版本推断
- **修复**：拆分为 `COPY --chown` + `RUN chmod`：

```dockerfile
# Docker 18.09 失败
COPY --chmod=555 --chown=root:root entrypoint.sh /usr/local/bin/

# 兼容写法
COPY --chown=root:root entrypoint.sh /usr/local/bin/
RUN chmod 555 /usr/local/bin/entrypoint.sh
```

### 原生 ARM64 环境中的 `FROM --platform`

- **原则**：本 Skill 保留显式 `--platform=linux/arm64`；只有旧 builder 不支持且执行环境已固定时才评估省略。

## 30. 多阶段构建：替换架构依赖的 JDK / Erlang / 语言运行时

### 适用场景

当原镜像 COPY 了 x86_64 的 JDK/Erlang 等语言运行时（非 apt 安装），需要替换为 ARM64 版本时。

### 通用模式

```dockerfile
# Stage 1: 获取 ARM64 官方运行时
FROM --platform=linux/arm64 eclipse-temurin:17-jdk AS runtime
# 或: erlang:26 / golang:1.22 / node:20 等

# Stage 2: 构建最终镜像
FROM --platform=linux/arm64 debian:trixie

# 复制 ARM64 运行时
COPY --from=runtime /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

# 继续正常构建...
```

> 实际案例：
>
> - **Jenkins**：`COPY --from=eclipse-temurin:17-jdk` 替换 x86_64 JDK
> - **RabbitMQ**：`COPY --from=erlang:26 /usr/local/lib/erlang` 替换 x86_64 Erlang/OTP
> - **Elasticsearch**：`COPY --from=elasticsearch:8.11.1-arm64 /usr/share/elasticsearch` 替换整个 x86 发行版

## 31. 业务二进制替换：使用官方 aarch64 发行版替换整个应用

### 适用场景

当镜像内 COPY 了 x86_64 编译好的二进制（如 Elasticsearch、Grafana、MySQL、Node.js app），
且上游提供了官方 aarch64 版本时。

### 策略

| 策略             | 适用条件                           | 示例                                              |
| ---------------- | ---------------------------------- | ------------------------------------------------- |
| **整包替换**     | 官方有 aarch64 tar.gz/zip 发行版   | ES k8.11.1、Grafana 13.1.0、SonarQube 26.6.0      |
| **打包管理器**   | apt 仓库原生支持 arm64             | MongoDB 7.0、PostgreSQL 16、MySQL 8.0             |
| **apt 替代下载** | GitHub 下载失败，apt 有 arm64 版本 | gosu（重编为 arm64 或用 `apt install gosu` 替代） |

### 整包替换模式

```dockerfile
ARG VERSION=8.11.1

# 宿主机预下载 aarch64 包（避免构建容器的网络/OOM 问题）
# curl -o _build_context/app.tar.gz https://example.com/app-${VERSION}-linux-aarch64.tar.gz

COPY _build_context/app-${VERSION}-linux-aarch64.tar.gz /opt/
RUN tar -xzf /opt/app-${VERSION}-linux-aarch64.tar.gz -C /opt/ \
    && mv /opt/app-${VERSION} /opt/app \
    && rm /opt/app-${VERSION}-linux-aarch64.tar.gz
```

> aarch64 tar.gz 可能缺少特定的运行时目录（如 ES 的 `data/`），参考 24。

## 32. QEMU 模拟性能陷阱

### `microdnf` / `dnf` / `yum` 在 QEMU 下极慢

- **症状**：`microdnf install xxx` 卡在 "Downloading metadata" 阶段，数分钟无进展
- **原因**：QEMU 用户态对 RPM 数据库操作（`rpmdb` + `sqlite3`）模拟性能极差
- **修复**：从官方 ARM64 镜像提取全部依赖文件，用 COPY 注入，完全跳过包管理器

```bash
# 宿主机操作：从官方 ARM64 镜像提取文件
docker pull --platform=linux/arm64 mysql:8.0
container_id=$(docker create --platform=linux/arm64 mysql:8.0)
docker cp $container_id:/usr/sbin/mysqld _build_context/mysqld
docker cp $container_id:/usr/lib64/mysql _build_context/mysql-libs/
docker cp $container_id:/etc/my.cnf _build_context/my.cnf
docker cp $container_id:/usr/share/mysql-8.0 _build_context/mysql-share/
docker rm $container_id
```

```dockerfile
COPY _build_context/mysqld /usr/sbin/
COPY _build_context/mysql-libs/ /usr/lib64/mysql/
RUN ldconfig
# 完全跳过 microdnf / yum / dnf 操作
```

### 其他 QEMU 下已知慢操作

| 操作                         | 速度       | 建议                                                   |
| ---------------------------- | ---------- | ------------------------------------------------------ |
| `apt-get update` + `install` | 可接受     | 正常使用                                               |
| `pip install`                | 可接受     | 正常使用（纯 Python 无 C 扩展）                        |
| `rpmdb` 操作                 | 极慢       | **跳过**，用 COPY 替代                                 |
| `git clone`                  | 较慢       | 预下载或 COPY                                          |
| Go 程序（如 git-lfs）运行时  | 偶发 crash | **不要信任 QEMU 下的 crash 日志**，以原生 ARM 运行为准 |

## 33. 网络隔离环境下的二进制获取

### GitHub / 外网不可达时

| 缺失资源            | 获取方式                                                     |
| ------------------- | ------------------------------------------------------------ |
| `gosu`              | 从官方 ARM64 镜像提取（`docker cp` from `gosu:arm64`）或 `apt install gosu` |
| `js-yaml`           | 从 npmmirror.com 下载（`https://npmmirror.com/mirrors/js-yaml/`） |
| GPG 密钥            | 从 x86 镜像提取（`docker cp` `.gpg.asc` / `.asc` 文件）      |
| 架构无关的脚本/配置 | 从 x86 镜像提取（`docker cp` entrypoint.sh / config.conf 等） |
| Node.js / JDK       | 通过 DaoCloud 镜像拉取官方 ARM64 镜像                        |

### `gosu` 下载失败的兜底

```dockerfile
# 方案 A：apt 安装（推荐）
RUN apt-get install -y gosu && rm -rf /var/lib/apt/lists/*

# 方案 B：从官方 ARM64 镜像提取
# docker cp $(docker create --platform=linux/arm64 gosu:latest):/usr/local/bin/gosu _build_context/
# 或用 amd64 镜像：docker cp <x86_mysql_image>:/usr/local/bin/gosu _build_context/
COPY _build_context/gosu /usr/local/bin/gosu
RUN chmod +x /usr/local/bin/gosu
```

## 34. multi-stage 构建模式：处理不透明 COPY 层的 JDK 依赖

### 场景

Jenkins 镜像有 6 层不透明层，其中 JDK 层 `COPY /javaruntime /opt/java/openjdk (90.1MB x86_64)` 无法直接复用。

### 解决

```dockerfile
# Stage 1: ARM64 JDK
FROM --platform=linux/arm64 eclipse-temurin:17-jdk AS jdk

# Stage 2: 最终镜像
FROM --platform=linux/arm64 debian:trixie

# 用 ARM64 JDK 替换 x86_64 JDK
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=$JAVA_HOME/bin:$PATH

# 其他不透明层中架构无关的文件从 x86 镜像 docker cp 提取
COPY _build_context/jenkins.war /usr/share/jenkins/jenkins.war
COPY _build_context/jenkins.sh /usr/local/bin/jenkins.sh
```

> - `jenkins.war`（96MB）是纯 Java WAR 包，架构无关，可直接从 x86 镜像提取
> - `jenkins-plugin-manager.jar` 同理
> - JDK 是唯一的架构相关的大文件

## 35. 总结：IMAGE_RECONSTRUCTION 构建修复决策树

```text
构建失败
├─ 包管理器错误
│  ├─ SSL 错误               → 25 (ca-certificates)
│  ├─ mirror 403/404         → 26 (切换镜像源)
│  ├─ apt-get update 缺失    → 26 (同一 RUN 层确保 update)
│  ├─ npm 代理 407 认证失败  → 8 (宿主机装后 COPY node_modules)
│  ├─ npm SSL 自签名证书     → 8 (strict-ssl false / 导入私有 CA)
│  └─ microdnf 卡住          → 32 (QEMU 性能，COPY 替代)
├─ 二进制/库错误
│  ├─ JDK/Erlang x86 ELF     → 30 (多阶段构建，COPY --from)
│  ├─ 应用二进制 x86 ELF     → 31 (官方 aarch64 发行版)
│  └─ GPG key 获取失败       → 27 (从 x86 镜像提取或 skip)
├─ 网络/资源错误
│  ├─ 容器内 DNS 解析失败     → 20.1 (--network=host / 代理 build-arg / 改 daemon.json dns)
│  ├─ wget/curl 超时/OOM     → 24 (预下载到 build context)
│  ├─ GitHub 不可达          → 33 (从镜像提取或 apt 安装)
│  └─ gosu 下载失败          → 33 (apt install gosu 或 docker cp)
├─ Docker 版本限制
│  └─ COPY --chmod 不支持    → 29 (COPY --chown + RUN chmod)
└─ 运行时 ABI 不匹配
   └─ Erlang/OTP 版本        → 28 (多阶段构建 + 官方 erlang 镜像)
```

## 36. Dockerfile 语法陷阱

### FROM 行末尾的 `#` 注释导致 `docker build` 解析失败

- **症状**：`ERROR: dockerfile parse error on line N: FROM requires either one or three arguments`
- **原因**：部分 Docker 版本将 `FROM` 行末尾的 `#` 当作额外参数解析
- **修复**：将注释移到 FROM 上方独立一行：

```dockerfile
# 错误：
FROM --platform=linux/arm64 alpine:latest  # [FIX-PLATFORM]

# 正确：
# [FIX-PLATFORM] added --platform=linux/arm64
FROM --platform=linux/arm64 alpine:latest
```

> 此规则同样适用于多阶段构建中的其他 `FROM` 指令及 `COPY --from=` 行。

## 37. 闭源软件 ARM64 替代方案模式

> **通用原则**：当 x86_64-only 的闭源/商业软件在 ARM64 上无官方构建时，按以下优先级寻找替代。

### 37.1 替代策略优先级

| 优先级 | 策略                                                         | 示例                                                  |
| ------ | ------------------------------------------------------------ | ----------------------------------------------------- |
| 1      | apt 官方源中同名或等价的 ARM64 包                            | `google-chrome-stable` → `chromium`                   |
| 2      | 社区 fork / 开源替代（有原生 ARM64 构建）                    | `Atom` → `Pulsar Edit`、`Spotify` → `spotifyd`        |
| 3      | pip/npm 等语言包管理器提供的 ARM64 wheel                     | `yubikey-neo-manager` → `pip install yubikey-manager` |
| 4      | 标记 `status=FAILED, failure_reason=PROPRIETARY`，不能自动处理 | Skype、Slack、Zoom（纯闭源无替代）                    |

### 37.2 常见闭源 → 开源/原生 ARM64 替代映射

| x86_64 原软件          | ARM64 替代      | 安装方式                      |
| ---------------------- | --------------- | ----------------------------- |
| Google Chrome          | Chromium        | `apt-get install chromium`    |
| Spotify Client         | spotifyd        | GitHub ARM64 release tar.gz   |
| Atom Editor            | Pulsar Edit     | GitHub ARM64 `.deb`           |
| yubikey-neo-manager    | yubikey-manager | `pip install yubikey-manager` |
| Firefox (特定版本 tar) | firefox-esr     | `apt-get install firefox-esr` |

### 37.3 闭源软件的失败边界

下列名称仅作为历史示例，供应商支持可能变化，Agent 必须检查本次指定版本和当前制品。确认没有 ARM64 版本、可接受替代或远程服务方案，且该功能为必需时，才标记 `status=FAILED, failure_reason=PROPRIETARY`：

- 商业通讯软件：Skype、Slack、Zoom（仅发布 `_amd64.deb`）
- 已停更的商业服务：Plex Home Theater（PPA 仅 amd64）
- x86 虚拟化软件：VirtualBox（依赖 VT-x/AMD-V 硬件特性）

## 38. 版本升级解锁 ARM64 支持（Version Bump Strategy）

> **通用原则**：旧版本软件无 ARM64 构建不代表所有版本都没有。在放弃前先检查上游是否在更新版本或 alpha/beta 通道中首次发布了 ARM64。

### 38.1 识别方式

```text
Step 1  当前版本构建失败（无 ARM64 binary / x86 toolchain 依赖）
Step 2  搜索上游 GitHub Releases / 官网是否有更新的版本
Step 3  检查新版本的 assets 列表中是否出现 linux_arm64 / linux-aarch64 / arm64.deb
Step 4  有 → 升级到该版本；无 → 按 37 找替代方案或标记 FAILED
```

### 38.2 已知可通过升级解锁 ARM64 的案例

| 软件         | 旧版本（无 ARM）          | 新版本（有 ARM）              | 升级方式                   |
| ------------ | ------------------------- | ----------------------------- | -------------------------- |
| osquery      | v4.3.0 (x86 toolchain)    | v5.x (`linux_arm64.deb`)      | GitHub Release .deb        |
| Tor Browser  | v15.x (`linux64` only)    | v16.0a8+ (`linux-aarch64`)    | dist.torproject.org tar.xz |
| Sublime Text | build 3126 (`_amd64.deb`) | build 4180+ (`_arm64.tar.xz`) | download.sublimetext.com   |

> alpha/beta 版本也可用于迁移，在 Dockerfile 中注释说明，待 stable 发布后只需改版本号。

## 39. Debian 发行版兼容性问题

### 39.1 Debian bullseye 中 gnupg 与 gpgv 版本冲突

- **症状**：`gnupg : Depends: gpgv (< 2.2.27-2+deb11u2.1~) but 2.2.27-2+deb11u3 is to be installed`
- **原因**：bullseye 更新通道中 gpgv 版本已超过 gnupg 的依赖上限
- **修复**：

```dockerfile
# 方案 A：显式指定兼容版本
RUN apt-get update && apt-get install -y gpgv=2.2.27-2+deb11u3 gnupg \
    || apt-get install -y --allow-downgrades gnupg

# 方案 B：不需要 GPG 时直接跳过 gnupg 安装
# apt-get install -y <其他包>  # 不装 gnupg
```

### 39.2 Debian bullseye security 源 404

- **症状**：`404 Not Found` on `security.debian.org` for bullseye
- **修复**：`sed -i '/bullseye-security/d; /security.debian.org/d' /etc/apt/sources.list`
- 详见 3 已有覆盖；此处作为 bullseye 专项聚合

### 39.3 Debian buster EOL（归档源）

- 详见 2.1 / 3 已有覆盖；此处作为发行版生命周期聚合索引

## 40. 构建策略优化

### 40.1 大体积 git clone → 优化克隆深度

- **症状**：`git clone` 大仓库（Linux kernel、Chromium 等 2GB+）超时或 OOM
- **修复**：使用 `--depth 1` 浅克隆减少传输体积：

```dockerfile
RUN git clone --depth 1 --branch v5.4 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
```

> 适用于：Linux kernel、Chromium 源码、AOSP 等超大仓库。

> 限制：`--depth 1` 只拉取分支尖端单个 commit。若 Dockerfile 后续需要 `git checkout <特定commit>` 切换到非尖端 commit，浅克隆会失败（commit 不在历史中）。此时按以下优先级处理：
>
> 1. 用 `--branch` 直接指定目标 commit hash：`git clone --depth 1 --branch <commit-hash> <repo>`（部分 Git 服务器支持）
> 2. 增加 depth 使目标 commit 落在范围内：`git clone --depth 200 --branch <tag> <repo>`（当目标 commit 距 branch tip 不远时）
> 3. 放弃浅克隆，做全量克隆并接受大体积（最后手段）

### 40.2 `dpkg --add-architecture i386` 在 ARM64 上不可行

- **症状**：Wine/Docker 等镜像尝试添加 i386 架构失败
- **原因**：ARM64 不存在 32 位 x86 指令集支持，`dpkg --add-architecture i386` 无意义
- **修复**：

```dockerfile
# ARM64 上不可行
RUN dpkg --add-architecture i386 && apt-get install -y winehq-staging

# 使用原生 ARM64 包
RUN apt-get install -y wine wine64

# 如需运行 x86 Windows 程序，加 Box64 模拟层
RUN git clone --depth 1 https://github.com/ptitSeb/box64 && cd box64 \
    && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && make -j$(nproc) && make install
```

### 40.3 特定版本 x86_64 二进制下载 → apt 等效包

- **症状**：Dockerfile 中 `wget/curl` 下载特定版本的 x86_64 二进制（如 Firefox、Cura 等）
- **修复**：优先用 apt 官方源安装 ARM64 版本：

```dockerfile
# 下载 x86_64 特定版本
RUN wget https://ftp.mozilla.org/.firefox-60.0.tar.bz2

# 用 apt 安装 ARM64 原生版本
RUN apt-get install -y firefox-esr
```

### 40.4 QtWebKit 在 Debian bullseye+ 上已移除

- **症状**：`ModuleNotFoundError: No module named 'PyQt5.QtWebKit'`
- **原因**：QtWebKit 已从 Debian bullseye 及以上版本移除（上游停止维护）
- **修复选项**：
  1. 降级到 buster 基础镜像（有 QtWebKit 但已 EOL）— 慎用
  2. 将代码迁移到 QtWebEngine — 改动大
  3. 标记为 `BUILD_OK_RUNTIME_DEGRADED`，报告中记录为已知残缺功能
- **判断**：若为长期无人维护的废弃项目（如 scudcloud，2016 年停更），优先选方案 3

## 附录：failure_reason 枚举

| 值                           | 含义                                                         |
| ---------------------------- | ------------------------------------------------------------ |
| `NO_ARM64_SUPPORT`           | 基础镜像无 ARM64 版本                                        |
| `INTERNAL_IMAGE_UNAVAILABLE` | 内网镜像无可用 ARM64 tag，且无法降级到公开镜像               |
| `ARCH_INCOMPATIBILITY`       | native 库/工具链不兼容 ARM64（Android/Flutter/WebGL 等）     |
| `VERSION_INCOMPATIBILITY`    | 语言/框架版本不兼容                                          |
| `DEPENDENCY_CONFLICT`        | 依赖冲突无法解决                                             |
| `EXTERNAL_SERVICE`           | 依赖外部服务（MySQL/Redis 等）或外网，容器内无法连接         |
| `FLOAT_PRECISION`            | ARM64 浮点精度导致测试不通过且修复代价过高                   |
| `TIMEOUT`                    | 构建或测试超时（超大项目或网络慢）                           |
| `EXCEEDED_ATTEMPTS`          | 超过 MAX_RETRY 次尝试（[config_reference.md](references/config_reference.md) 默认 5） |
| `STALLED`                    | 超过 `WORKER_STALL_TIMEOUT_MIN` 仍无进展                     |
| `PROPRIETARY_X86_SO`         | 自研 x86 native 库无 aarch64 版本，无法自动处理              |
| `PROPRIETARY`                | 闭源/商业软件无 ARM64 版本且无替代方案（如 Skype、Slack、Zoom） |
| `INSUFFICIENT_DISK_SPACE`    | 磁盘空间不足且清理后仍不足 MIN_DISK_SPACE_GB                 |
| `TEST_FAILURE`               | 测试本身失败（无法快速归类）                                 |
| `REGISTRY_UNAUTHORIZED`      | registry 认证失败且无法 login                                |
| `DOCKER_UNAVAILABLE`         | docker daemon 不可用（仅 IMAGE_MIG_SKILLSET 场景）           |
| `ARCH_BLOCKED`               | 启动门禁判定当前环境不能执行 ARM64 构建；仅限门禁阶段使用    |
| `LAYER_NOT_COLLECTED`        | ARM64 主机未提供可用的 x86_64 采集路径，且任务要求 layer 证据 |
| `ERLANG_ABI_MISMATCH`        | Erlang/OTP 版本与 RabbitMQ .beam 字节码不兼容                |
| `X86_ENV_FAILURE`            | x86_64 采集机环境不满足要求（SSH 不可达 / Docker 安装失败且用户放弃 / 磁盘空间不足且未指定替代路径 / 工具包定位失败）且无法继续远程采集 |