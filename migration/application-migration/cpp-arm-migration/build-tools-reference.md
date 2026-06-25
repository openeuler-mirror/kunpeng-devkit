# 构建工具下载链接参考

本文档提供构建工具的版本号、官方下载链接和内部定制版下载链接。环境检测与安装流程优先使用内部定制版链接，如无内部定制版则使用官方链接。

> 下载链接格式说明：`<arch>` 需替换为实际架构（`arm64` 或 `x86_64`），`<version>` 需替换为实际版本号。

---

## Bazel

| 版本号 | 官方下载链接（arm64） | 内部定制版下载链接（arm64） |
|--------|----------------------|---------------------------|
| 0.24.1 | `https://github.com/bazelbuild/bazel/releases/download/0.24.1/bazel-0.24.1-linux-arm64` | <!-- 内部定制版链接待补充 --> |
| 4.0.0  | `https://github.com/bazelbuild/bazel/releases/download/4.0.0/bazel-4.0.0-linux-arm64` | <!-- 内部定制版链接待补充 --> |

**安装方式：**

```bash
BAZEL_VERSION="<版本号>"
# 优先使用内部定制版
DOWNLOAD_URL="<从上表选取链接>"
wget ${DOWNLOAD_URL} -O /tmp/bazel-${BAZEL_VERSION}
chmod +x /tmp/bazel-${BAZEL_VERSION}
sudo mv /tmp/bazel-${BAZEL_VERSION} /usr/local/bin/bazel-${BAZEL_VERSION}
sudo ln -sf /usr/local/bin/bazel-${BAZEL_VERSION} /usr/local/bin/bazel
bazel --version  # 验证
```

---

## Blade

| 版本号 | 官方下载链接 | 内部定制版下载链接 |
|--------|-------------|-------------------|
| 3.0（最新） | `https://github.com/blade-build/blade-build/releases/latest` | <!-- 内部定制版链接待补充 --> |
| 2.0（最新） | `https://github.com/blade-build/blade-build/releases/tag/v2.0` | <!-- 内部定制版链接待补充 --> |

> **注意**：Blade 2.0 起支持 arm64 架构和 Python3。如果项目使用 2.0 之前的旧版 Blade，**优先升级到 2.0**（而非直接跳到 3.0），以减少版本跨度过大导致的兼容性问题。仅当 2.0 不满足项目需求时再升级到 3.0。

**安装方式：**

```bash
# 优先使用内部定制版
DOWNLOAD_URL="<从上表选取链接>"
wget ${DOWNLOAD_URL} -O /tmp/blade.zip
# 替换项目中的 blade zip 包
cp /tmp/blade.zip <项目中的blade zip包路径>
# 验证
python3 -m blade --version
```

---

## SCons

| 版本号 | 官方下载链接 | 内部定制版下载链接 |
|--------|-------------|-------------------|
| 最新版 | `https://sourceforge.net/projects/scons/files/scons/latest/` | <!-- 内部定制版链接待补充 --> |

**安装方式：**

```bash
# 优先使用 pip 安装（推荐）
pip install scons

# 或使用包管理器
yum install scons    # CentOS/RHEL
apt install scons    # Ubuntu/Debian

# 或从下载链接手动安装
DOWNLOAD_URL="<从上表选取链接>"
pip install ${DOWNLOAD_URL}

scons --version  # 验证
```

---

## JDK（毕昇 JDK）

毕昇 JDK 是华为基于 OpenJDK 定制的高性能 OpenJDK 发行版，在 ARM 架构上进行了性能优化和稳定性增强，适用于 arm64 目标环境。毕昇 JDK 支持 JDK 8/11/17/21 四个 LTS 版本，支持 Linux/AArch64 和 Linux/x86_64 平台（本节仅列出 arm64 架构链接）。

> **注意**：毕昇 JDK 要求系统 glibc 版本不低于 2.18。安装前请使用 `ldd --version` 确认系统 glibc 版本满足要求。

### 下载链接

> 链接说明：`<version>` 需替换为下表对应的具体版本号字符串（如 `8u462-b11`、`11.0.24+10` 等）。

| JDK 大版本 | 具体版本 | 鲲鹏社区下载链接（arm64） |
|-----------|---------|---------------------------|
| JDK 8  | 8u462-b11  | `https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jdk-8u462-b11-linux-aarch64.tar.gz` |
| JDK 11 | 11.0.24+10 | `https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jdk-11.0.24+10-linux-aarch64.tar.gz` |
| JDK 17 | 17.0.12+10 | `https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jdk-17.0.12+10-linux-aarch64.tar.gz` |
| JDK 21 | 21.0.4+5   | `https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/bisheng-jdk-21.0.4+5-linux-aarch64.tar.gz` |

> **版本说明**：以上为参考版本，鲲鹏社区会持续更新补丁版本。如需获取最新版本，可访问鲲鹏开发者社区 JDK 下载页面或华为云镜像站 `https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/` 查看可用版本列表，并替换上表中的 `<version>` 部分。

### 安装方式

```bash
JDK_MAJOR="<jdk 大版本，如 8/11/17/21>"
JDK_PACKAGE_VERSION="<从上表选取的具体版本，如 8u462-b11>"
DOWNLOAD_URL="<从上表选取链接>"

# 1. 下载并解压到 /opt/bisheng-jdk${JDK_MAJOR}
wget ${DOWNLOAD_URL} -O /tmp/bisheng-jdk-${JDK_PACKAGE_VERSION}-linux-aarch64.tar.gz
sudo mkdir -p /opt/bisheng-jdk${JDK_MAJOR}
sudo tar -zxvf /tmp/bisheng-jdk-${JDK_PACKAGE_VERSION}-linux-aarch64.tar.gz -C /opt/bisheng-jdk${JDK_MAJOR} --strip-components=1

# 2. 配置环境变量（建议写入 /etc/profile.d/bisheng-jdk.sh 以便全局生效）
sudo tee /etc/profile.d/bisheng-jdk${JDK_MAJOR}.sh > /dev/null <<EOF
export JAVA_HOME=/opt/bisheng-jdk${JDK_MAJOR}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

# 3. 使环境变量生效
source /etc/profile.d/bisheng-jdk${JDK_MAJOR}.sh

# 4. 验证
java -version
javac -version
```

### 多版本共存

如需在同一台 arm64 机器上安装多个 JDK 版本，可将其分别安装到 `/opt/bisheng-jdk8`、`/opt/bisheng-jdk11`、`/opt/bisheng-jdk17`、`/opt/bisheng-jdk21`，并通过 `alternatives` 或修改 `/etc/profile.d/` 下对应脚本的方式切换默认 JDK：

```bash
# 示例：使用 alternatives 管理 java
sudo alternatives --install /usr/bin/java java /opt/bisheng-jdk17/bin/java 2
sudo alternatives --install /usr/bin/javac javac /opt/bisheng-jdk17/bin/javac 2
sudo alternatives --config java    # 交互式切换默认版本
```

---

## 链接选取规则

环境检测与安装流程按以下规则选取下载链接：

1. **优先使用内部定制版链接**：如果内部定制版链接已填写（非注释状态），使用内部定制版
2. **回退到官方链接**：如果内部定制版链接为空，使用官方下载链接
3. **链接不可用时的处理**：如果链接无法访问，记录错误并提示用户手动安装
