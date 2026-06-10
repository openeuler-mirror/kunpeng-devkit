# ARM64 构建与修复知识库

> **定位**：通用构建知识

> **使用方式**：构建/修复阶段遇到问题时直接按关键词搜索本文件，无需翻阅业务文档。

---

## 目录

- [§ 1  快速失败判定（直接跳过，不修复）](#1-快速失败判定)
- [§ 2  镜像源替换（必做）](#2-镜像源替换)
- [§ 3  apt / 系统包错误](#3-apt--系统包错误)
- [§ 4  pip / Python 错误](#4-pip--python-错误)
- [§ 5  CUDA / GPU 包处理](#5-cuda--gpu-包处理)
- [§ 6  架构关键词与 native 库](#6-架构关键词与-native-库)
- [§ 7  Java / Maven / Gradle 错误](#7-java--maven--gradle-错误)
- [§ 8  Node.js / npm 错误](#8-nodejs--npm-错误)
- [§ 9  浮点精度差异（ARM64 特有）](#9-浮点精度差异)
- [§ 10 测试快照不匹配](#10-测试快照不匹配)
- [§ 11 测试/构建超时（ARM64 性能差异）](#11-测试构建超时)
- [§ 12 Rust / Cargo 错误](#12-rust--cargo-错误)
- [§ 13 Ruby / Gem 错误](#13-ruby--gem-错误)
- [§ 14 C++ / CMake 错误](#14-c--cmake-错误)
- [§ 15 PHP / Composer 错误](#15-php--composer-错误)
- [§ 16 Docker / 环境错误](#16-docker--环境错误)
- [§ 17 系统工具缺失](#17-系统工具缺失)
- [§ 18 C 扩展 / native 库降级](#18-c-扩展--native-库降级)
- [§ 19 Dockerfile 编写原则](#19-dockerfile-编写原则)
- [§ 20 构建命令速查](#20-构建命令速查)
- [§ 21 运行时测试分层策略](#21-运行时测试分层策略)
- [§ 22 增量 patch 镜像（避免全量重建）](#22-增量-patch-镜像)
- [§ 23 磁盘管理](#23-磁盘管理)

---

## § 1  快速失败判定

以下情况**立即标记 FAILED，不尝试修复**：

| 条件 | failure_reason | 判断方式 |
|------|---------------|---------|
| 基础镜像无 ARM64 manifest | `NO_ARM64_SUPPORT` | `docker manifest inspect <img> \| grep -c "arm64"` 返回 0 |
| Android 项目（aapt2/d8/R8 工具链） | `ARCH_INCOMPATIBILITY` | image_env 含 `ANDROID_HOME` 或 `build-tools/` |
| Ruby 项目要求高版本 Ruby 但基础镜像版本低（如 2.6） | `VERSION_INCOMPATIBILITY` | 依赖分析 |

> ⚠️ 网络超时会让 `manifest inspect` 返回空，误判为不支持。对 `python/node/ruby/golang/ubuntu/debian` 等官方镜像，超时时放行，让 `docker build` 决定。

---

## § 2  镜像源替换

### 镜像拉取优先级

**基础镜像（FROM 行）** 按以下顺序尝试，第一个成功则停止：

```
1. config.yaml 中配置的内部私有镜像仓库（INTERNAL_REGISTRIES）
2. Docker Hub 官方镜像（docker.io / hub.docker.com）
3. 公共加速镜像站（如阿里云 mirror.ccs.tencentyun.com 等兜底）
```

> ⚠️ 若 `AIRGAP_MODE: true`，跳过第 2/3 步，仅允许内部仓库。

**每个 ARM64 Dockerfile 的第一个 RUN 层必须替换语言/系统包源**，否则下载速度不可接受。

### 2.1 操作系统 apt 源

| OS | 必须替换为 |
|----|----------|
| Ubuntu 20.04 (focal) ARM | `mirrors.aliyun.com/ubuntu-ports` |
| Ubuntu 22.04 (jammy) ARM | `mirrors.aliyun.com/ubuntu-ports`（替换 `ports.ubuntu.com`） |
| Ubuntu 24.04 (noble) ARM | `ports.ubuntu.com/ubuntu-ports` → `mirrors.aliyun.com/ubuntu-ports` |
| Debian 12 (bookworm) | 清华源（DEB822 格式，见下方模板） |
| Debian 11 (bullseye) | 清华源；**必须删除 security 行** `sed -i '/security/d' /etc/apt/sources.list` |
| Debian 10 (buster) EOL | 阿里云归档源 + `Acquire::Check-Valid-Until false` |

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
RUN printf 'Types: deb\nURIs: https://mirrors.tuna.tsinghua.edu.cn/debian\nSuites: bookworm bookworm-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: https://mirrors.tuna.tsinghua.edu.cn/debian-security\nSuites: bookworm-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/debian.sources
```

**Debian 10 buster EOL 模板**：
```dockerfile
RUN echo "deb https://mirrors.aliyun.com/debian-archive/debian buster main contrib non-free" > /etc/apt/sources.list \
    && echo "deb https://mirrors.aliyun.com/debian-archive/debian-security buster/updates main contrib non-free" >> /etc/apt/sources.list \
    && echo "deb https://mirrors.aliyun.com/debian-archive/debian buster-updates main contrib non-free" >> /etc/apt/sources.list \
    && echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid
```

### 2.2 语言包源

| 语言 | 镜像源 |
|------|-------|
| Python (pip) | `https://mirrors.aliyun.com/pypi/simple/` |
| Node.js (npm) | `https://registry.npmmirror.com` |
| Rust (cargo) | `sparse+https://rsproxy.cn/index/` |
| PHP (Composer) | `https://mirrors.aliyun.com/composer/` |
| Java (Maven) | 阿里云 central mirror（见下方模板） |
| Ruby (gem) | `https://mirrors.aliyun.com/rubygems/` |

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

## § 3  apt / 系统包错误

### `E: Unable to locate package`
- **原因**：包名含 `:amd64` 后缀，或使用了 x86_64 专属包名
- **修复**：去掉 `:amd64` 后缀；`binutils-x86-64-linux-gnu` → `binutils`

**必须删除的 amd64 特有后缀/包名**：
```
:amd64                    → 删除后缀（apt 自动选 arm64 变体）
x86_64-linux-gnu          → 改为 aarch64-linux-gnu（或让 apt 自动选）
binutils-x86-64-linux-gnu → binutils
gcc-N-base:amd64          → gcc
libasan5:amd64            → libasan8（或对应 arm 版本）
```

### `Release file does not have a Release` / `404 Not Found` (apt update)
- **原因 A**：Debian buster EOL，默认源已下线
- **修复 A**：换阿里云归档源 + `Acquire::Check-Valid-Until false`（见 § 2.1 模板）
- **原因 B**：Debian bullseye security 源失效
- **修复 B**：`sed -i '/security/d' /etc/apt/sources.list`

### `No system certificates available` (apt update HTTPS 源)
- **原因**：容器初始无 ca-certificates，HTTPS 源不可用
- **修复**：先用 `http://` 源安装 ca-certificates，再换 HTTPS

### apt 源被 nodesource 脚本重置
- **原因**：安装 Node.js 时 nodesource 脚本重写 apt 源
- **修复**：不用 nodesource 脚本，直接下载官方 arm64 tar 包：
```dockerfile
RUN curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-arm64.tar.gz \
    | tar -xz -C /usr/local --strip-components=1
```

---

## § 4  pip / Python 错误

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

---

## § 5  CUDA / GPU 包处理

**ARM64 无 NVIDIA GPU，以下包必须在迁移时删除**：
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

| CUDA 版 | CPU-only 替代 |
|---------|-------------|
| `2.8.0+cu124` / `2.7.0+cu124` / `2.6.0+cu124` | `2.6.0` |
| `2.5.0+cu121` / `2.4.0+cu121` | `2.4.1` |
| `2.3.0+cu121` | `2.3.1` |
| `2.2.0+cu121` | `2.2.2` |
| `2.1.0+cu118` | `2.1.2` |
| `2.0.0+cu118` | `2.0.1` |
| 其他 `+cuXXX` 版本 | 去掉 `+cuXXX` 后缀，保留主版本号 |

**ENV 变量同步删除**：
```
CUDA_VERSION=*    → 删整行
NVIDIA_*=*        → 删整行
CUDNN_*=*         → 删整行
LD_LIBRARY_PATH 中含 cuda 路径 → 删整行
```

---

## § 6  架构关键词与 native 库

### x86 native `.so` / ELF 二进制识别

以下情形判定为「深度绑定 x86 的 native 库」：

```
A. COPY / ADD 的 src 文件名匹配：*.so* / *.a / *.o / *.dylib
B. RUN wget/curl 下载的 URL 含 x86_64 / amd64 / i686，且文件后缀为 .so/.tar.gz/.zip
C. RUN 命令中含 ldconfig / ln -s *.so / install *.so，且路径含 x86_64/amd64
D. 构建输出出现：ELF 64-bit LSB ... x86-64（file 命令输出）
E. 运行时报错：illegal instruction / SIGILL / UnsatisfiedLinkError
```

**处理动作**——按 .so 类型分三类处理（见 IMAGE_MIG_SKILLSET DOCKERFILE_MIGRATION.md § 1.3a）：

| 类型 | 判断方式 | 处理策略 |
|------|---------|----------|
| **功能无关 / 可选插件**（如调试工具、性能分析 so） | 去掉后容器核心功能不受影响 | 注释掉 COPY/RUN 行，追加 `# [WARN-X86-NATIVE-SO]`，报告中记录 |
| **功能相关 / 有公开替代版本**（如 LWJGL、sqlite、zstd） | 有已知 aarch64 release 或上游提供 arm64 包 | 替换为 aarch64 版本，追加 `# [FIXED-SO-REPLACED-AARCH64]`，报告中说明 |
| **自研 so / 无公开来源**（闭源二进制、内部 SDK） | 无法找到 arm64 等价物 | **分情况处理**：<br>• 有源码 → 在 Dockerfile 中补充 `RUN make / cmake` 重新编译，追加 `# [WARN-CUSTOM-SO-RECOMPILED]`<br>• 无源码 → **标记迁移失败** `FAILED: PROPRIETARY_X86_SO`，报告中注明该 so 路径和来源，不可自动处理 |

> ⚠️ **禁止将功能相关的 so 直接注释删除**——必须先评估影响，再按上表选择策略。

**JAR 内 native .so 检查与替换（Java 项目）**：
```bash
# 检查 JAR 内是否含 x86_64 native 库
unzip -l <path>.jar | grep -E "\.so|\.dll|linux"

# 替换（以 LWJGL 为例）
# 从 LWJGL 3.x aarch64 release 提取对应 .so
zip -j <jar_path> <aarch64_so_files>
```

---

## § 7  Java / Maven / Gradle 错误

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

### Android Build Tools（`aapt2`/`d8`/`R8`）无 ARM64 host
- **原因**：Android SDK Build Tools 只发布 x86_64 host 二进制
- **处理**：无法修复 → **直接判定 `ARCH_INCOMPATIBILITY`**

### Gradle daemon OOM（`Build daemon disappeared unexpectedly`）
- **原因**：大型 Gradle 项目，Docker VM 内存有限，Kotlin 编译进程 OOM
- **修复**：减少并发 `--parallel --max-workers=2`；排除不需要的模块 `-x :module:test`

### 构建成功但实为 mvn 失败（`exit 0` 但测试未执行）
- **原因**：使用了 `./mvnw install 2>&1 | tail -20`，管道吞掉退出码
- **修复**：去掉管道，改用 `-q` 安静模式：
```dockerfile
# ❌ 错误：管道吞掉退出码
RUN ./mvnw install 2>&1 | tail -20

# ✅ 正确
RUN ./mvnw install -DskipTests -T 2C -q
```

### `application not found`（dotnet restore）
- **原因**：`global.json` 锁定了精确 SDK patch 版本
- **修复**：`rm -f global.json`

---

## § 8  Node.js / npm 错误

### nodesource 安装后 apt 源被重置
- **修复**：绕过 nodesource，直接下载 arm64 tar 包（见 § 3 末尾模板）

### `deepEqual` 比较失败但数据"看起来完全相同"
- **原因**：ARM64 与 x86 浮点计算精度不同，末位数字有微小差异
- **修复**：使用 `REGEN=1` 重新生成测试预期值（见 § 9）

### `Snapshot mismatched`（esbuild / bundler 跨架构差异）
- **原因**：esbuild 等工具在 ARM64 和 x86 上代码生成策略不同
- **修复**：见 § 10

### `Test timed out in 30000ms`（ARM64 编译性能差异）
- **原因**：ARM64 上 WASM 编译等操作比 x86 慢 2-3 倍
- **修复**：见 § 11

### `cargo test` 下载外部数据超时
- **原因**：Rust 集成测试在运行时下载外部数据，网络隔离导致卡死
- **修复**：仅运行不依赖网络的单元测试：
```dockerfile
CMD ["cargo", "test", "--lib", "--", "--nocapture"]
```

---

## § 9  浮点精度差异

> **背景**：ARM64（ARMv8 NEON）与 x86-64（x87/AVX）FPU 实现不同，超越函数（`Math.log`、`Math.sin`、地理坐标计算等）在末位精度（ULP）上有微小差异。这是 IEEE 754 标准允许的行为，不是 Bug。

### 识别浮点精度失败

```
症状 1: expected:<2.0> but was:<2.0000000000000004>    ← 差值 < 1e-10
症状 2: deepEqual 比较失败，两边数据"看起来相同"
症状 3: 地理坐标计算精度断言失败，差异 < 1e-14
症状 4: AssertJ isEqualTo(double) 断言失败
```

### 修复方案（按语言）

**Java（AssertJ）**：
```java
// ❌ ARM64 上失败
assertThat(result).isEqualTo(2.0);

// ✅ 支持浮点容差
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
# ❌ 失败
assert result == 2.0

# ✅ 正确
import math
assert math.isclose(result, 2.0, rel_tol=1e-10)
```

**上限规则**：最多修改 2 处测试文件。超过 2 个文件时，判定 `FAILED(FLOAT_PRECISION)`。

---

## § 10  测试快照不匹配

### 识别

```
症状: Snapshot mismatched
症状: Expected value to equal: <Snapshot 1>
症状: snapshots obsolete
症状: 1 snapshot failed
```

### 修复：在 Dockerfile 构建阶段更新快照

```dockerfile
# vitest / jest
RUN cd /testbed && npm test -- --updateSnapshot 2>&1 || true

# jest（全量更新）
RUN cd /testbed && npx jest --updateSnapshot 2>&1 || true

# pytest（syrupy 快照库）
RUN cd /testbed && python -m pytest --snapshot-update 2>&1 || true

# 针对特定文件（pnpm + vitest）
RUN cd /testbed/packages/<pkg> && pnpm test <target.test.ts> -- -u 2>&1 || true
```

> ⚠️ 使用 `|| true` 确保快照更新步骤即使有不相关失败也不中断构建。快照更新只在构建期执行，不在 CMD 的测试命令中使用 `-u`。

---

## § 11  测试/构建超时

> **背景**：ARM64 在某些计算密集型任务上比 x86 慢 30-200%。测试超时可能是性能差异，不是 Bug。

### 区分构建超时 vs 测试用例超时

- 单次 `docker build` > 60 min → `TIMEOUT`，直接跳过
- 个别测试用例 timeout → 可修复，增加超时时间

### 测试用例超时修复

```dockerfile
# vitest 超时配置
RUN sed -i 's/testTimeout: 30_000/testTimeout: process.arch === "arm64" ? 90_000 : 30_000/' vitest.config.mts \
    && sed -i 's/hookTimeout: 30_000/hookTimeout: process.arch === "arm64" ? 90_000 : 30_000/' vitest.config.mts
```

**经验值**：

| 场景 | ARM64 超时倍数 |
|------|-------------|
| Node.js WASM 编译（如 Cloudflare Workers） | × 3 |
| Rust 大型项目编译 | × 2-3 |
| Java JIT 热身 | × 1.5 |
| Go 编译 | × 2 |
| Python PyPy/Cython | × 2 |

---

## § 12  Rust / Cargo 错误

### `error: failed to fetch` / 下载速度 < 10 bytes/sec
- **原因**：crates.io 在国内访问慢
- **修复**：配置 rsproxy 镜像（见 § 2.2 cargo 模板）

### `cargo test` 下载外部数据超时
- **修复**：仅运行单元测试，跳过集成测试（见 § 8）

---

## § 13  Ruby / Gem 错误

### `sqlite3 >= 1.6 requires ruby >= 2.7`
- **修复**：`bundle config set force_ruby_platform true` + 删 Gemfile.lock
- 若基础镜像是 Ruby 2.6 → 判定 `VERSION_INCOMPATIBILITY`

### `ffi requires Ruby >= 3.0`
- **修复**：`sed -i 's/gem "ffi"/gem "ffi", "< 1.17"/' Gemfile`

### Gemfile 硬写 Ruby 版本检查失败（`ruby '3.2.2'`）
- **修复**：`grep -v "^ruby " Gemfile > /tmp/Gemfile.new && mv /tmp/Gemfile.new Gemfile`

### `prism 0.19.0` / `psych 5.x` 编译失败
- **原因**：缺少 libyaml-dev
- **修复**：`apt-get install -y libyaml-dev` + 删 Gemfile.lock

### `Gem::RemoteFetcher::FetchError`（rubygems.org 下载超时）
- **修复**：配置国内 Gem 镜像：
```dockerfile
RUN gem sources --add https://mirrors.aliyun.com/rubygems/ \
    --remove https://rubygems.org/ \
    && bundle config mirror.https://rubygems.org https://mirrors.aliyun.com/rubygems/
```

### Bundler 版本不兼容（`Your Gemfile requires Bundler version x.x.x`）
- **修复**：
```dockerfile
RUN gem install bundler -v <locked_version> || gem install bundler
# 或删除 Gemfile.lock 重新解析
RUN rm -f /testbed/Gemfile.lock && bundle install
```

### `cannot load such file -- atomic_reference`（Ruby C 扩展）
- **原因**：x86 预编译的 C 扩展（如 `concurrent-ruby` 的 `CAtomic`）无法在 ARM64 加载
- **修复**：禁用 C 扩展，使用纯 Ruby 实现：
```dockerfile
ENV CONCURRENT_RUBY_DISABLE_EXTENSIONS=1
RUN sed -i '/CAtomic\|atomic_spec/d' /testbed/spec/atomic_spec.rb || true
```

---

## § 14  C++ / CMake 错误

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
- **修复**：加 `--network=host`；仍失败则判定 FAILED

---

## § 15  PHP / Composer 错误

### `ext-bcmath * is missing` / `ext-gd * is missing`
- **修复**：
```dockerfile
RUN apt-get install -y libgd-dev \
    && docker-php-ext-install bcmath gd
```

---

## § 16  Docker / 环境错误

### `invalid character '#'`（config.json 警告）
- **修复**：`~/.docker/config.json` 中删除以 `#` 开头的行

### `content at ... not found`（前缀方式镜像仓内容缺失）
- **修复**：改用 `daemon.json` 的 `registry-mirrors` 配置

### `exit code 145`（SIGTERM）
- **原因**：旧的 kill 或超时命令杀掉了进程
- **修复**：等进程完全退出后再启动新构建；用 `kill -- -$pid` 杀整个进程树

### Docker daemon 无响应
- **修复**：强制重启 Docker Desktop；`kill -9` 所有 dockerd 进程

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

### `Mysql2::Error` / `Connection refused`（外部服务依赖）
- **判定**：直接写 `FAILED(EXTERNAL_SERVICE)`
- **例外**：仅 ≤5% 的测试依赖外部服务时，可用 `--exclude` 跳过

---

## § 17  系统工具缺失

### 识别

```
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

## § 18  C 扩展 / native 库降级

### 识别

```
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

### 判断是否值得降级

- 降级后功能覆盖 > 80% → 值得，修复并在 notes 说明
- 降级后功能覆盖 < 50% → 不值得，直接判定 `ARCH_INCOMPATIBILITY`

---

## § 19  Dockerfile 编写原则

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

```
只缺少组件     → 在 git clone 之前新增独立 RUN 层（不改原有层）
包名错误       → 必须改原有层（需 --no-cache 重建）
依赖冲突       → 合并到同一 apt-get install 层
```

### 管道过滤与退出码

```dockerfile
# ❌ 错误：管道吞掉退出码，构建失败但 docker build 仍然成功
RUN ./mvnw install 2>&1 | tail -20

# ✅ 正确：用 -q 安静模式
RUN ./mvnw install -DskipTests -T 2C -q
```

### 内网包保护

```dockerfile
# 尝试安装，失败时打印 WARNING 但不中断构建
# 将 <YOUR_INTERNAL_PYPI> 替换为 config.yaml 中配置的 INTERNAL_PYPI_HOSTS[0]
RUN pip3 install "internal-package==x.y.z" \
    -i http://<YOUR_INTERNAL_PYPI>/simple \
    || echo "WARNING: internal-package not available, skipping"
```

### 版本强制覆盖（末尾追加层）

```dockerfile
# 防止依赖树把关键包降回旧版本
RUN pip3 install "networkx>=2.6" --quiet
```

**已知版本兼容性问题**：

| 包 | 原版本问题 | 修复方案 |
|----|---------|---------|
| `networkx` 2.2 | Python 3.10 移除 `collections.Mapping` | 升级到 `networkx>=2.6` |
| `gym` ≤ 0.19.x | 与 setuptools≥60 元数据不兼容 | 升级到 `gym==0.26.2` |
| `golang:1.25-bookworm` | Go 1.25 尚未发布，镜像不存在 | 改用 `golang:1.24-bookworm` |

---

## § 20  构建命令速查

```bash
# 标准构建
docker build --platform linux/arm64 \
  -t <image>:latest \
  -f <path>/Dockerfile \
  <build_context>

# 强制无缓存构建
docker build --no-cache --platform linux/arm64 \
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

---

## § 21  运行时测试分层策略

**按层次依次验证，前一层失败则不进入下一层**：

```bash
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

| 错误 | 修复方案 |
|------|---------|
| `AttributeError: 'Env' object has no attribute 'seed'` | 删除 `env.seed()` 调用，改用 `env.reset(seed=...)` |
| `ValueError: not enough values to unpack (expected 5, got 4)` | gym 0.26 step 返回 5-tuple，加兼容层 |
| `libGL.so.1: cannot open shared object file` | `apt-get install -y libgl1-mesa-dri libgl1` |
| `cannot connect to X server :99` | 加 `sleep 3` 等 Xvfb 启动 |
| `AttributeError: module 'collections' has no attribute 'Mapping'` | `pip install "networkx>=2.6"` |

---

## § 22  增量 patch 镜像

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

## § 23  磁盘管理

### 前置检查

```bash
DISK_USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
```

| 使用率 | 动作 |
|--------|------|
| < 80% | 正常执行 |
| 80%–90% | 先清理再构建 |
| > 90% | 强制暂停构建任务，提示必须先清理 |

### 清理顺序

1. 历史批次自建镜像（旧 tag）
2. 悬空镜像：`docker image prune -f`
3. BuildKit 缓存：`docker builder prune -f --filter "until=24h"`
4. 已验证完成的当前批次镜像

---

## 附录：failure_reason 枚举

| 值 | 含义 |
|----|------|
| `NO_ARM64_SUPPORT` | 基础镜像无 ARM64 版本 |
| `ARCH_INCOMPATIBILITY` | native 库/工具链不兼容 ARM64（Android/Flutter/WebGL 等） |
| `VERSION_INCOMPATIBILITY` | 语言/框架版本不兼容 |
| `DEPENDENCY_CONFLICT` | 依赖冲突无法解决 |
| `EXTERNAL_SERVICE` | 依赖外部服务（MySQL/Redis 等）或外网，容器内无法连接 |
| `FLOAT_PRECISION` | ARM64 浮点精度导致测试不通过且修复代价过高 |
| `TIMEOUT` | 构建或测试超时（超大项目或网络慢） |
| `EXCEEDED_ATTEMPTS` | 超过 5 次尝试 |
| `TEST_FAILURE` | 测试本身失败（无法快速归类） |
