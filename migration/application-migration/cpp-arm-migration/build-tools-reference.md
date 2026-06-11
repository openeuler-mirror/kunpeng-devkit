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

## 链接选取规则

环境检测与安装流程按以下规则选取下载链接：

1. **优先使用内部定制版链接**：如果内部定制版链接已填写（非注释状态），使用内部定制版
2. **回退到官方链接**：如果内部定制版链接为空，使用官方下载链接
3. **链接不可用时的处理**：如果链接无法访问，记录错误并提示用户手动安装
