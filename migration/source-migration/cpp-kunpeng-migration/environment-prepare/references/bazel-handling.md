# Bazel 构建系统处理

> **何时加载**：项目使用 Bazel 作为构建系统时，由 environment-prepare 主文档按需加载本参考文档，执行额外处理步骤。

---

检测项目依赖的 Bazel 版本与系统安装的版本是否一致，不一致时需要安装匹配版本。

## Step 1：确定项目所需的 Bazel 版本

在项目中搜索 Bazel 版本约束：

```bash
# 搜索 .bazelversion 文件（Bazel 版本管理标准方式）
cat .bazelversion

# 搜索 WORKSPACE/MODULE.bazel 中的版本约束
grep -r "bazel_version\|minimum_bazel\|BAZEL_VERSION" WORKSPACE MODULE.bazel .bazelversion 2>/dev/null

# 搜索 .bazelrc 中的版本相关配置
grep -r "bazel_version" .bazelrc 2>/dev/null

# 搜索 CI/CD 配置中的 Bazel 版本
grep -r "bazel" --include="*.yml" --include="*.yaml" --include="Jenkinsfile" --include="Dockerfile" .
```

版本确定优先级：
1. `.bazelversion` 文件中指定的版本（最高优先级）
2. WORKSPACE/MODULE.bazel 中声明的版本约束
3. CI/CD 配置中使用的版本
4. 如果以上均未找到，使用系统当前安装的 Bazel 版本

## Step 2：检查系统 Bazel 版本

在 **鲲鹏目标环境** 上：

```bash
bazel --version
```

如果 Bazel 未安装，输出类似 `bazel: command not found`，需要安装。

## Step 3：安装或切换 Bazel 版本

如果项目所需的 Bazel 版本与系统安装的版本不一致，或系统未安装 Bazel，**自动尝试安装**匹配版本：

1. 从 [build-tools-reference.md](build-tools-reference.md) 中查找对应版本的下载链接，优先使用内部定制版下载链接，若无内部定制版，使用官方下载链接：
   ```bash
   BAZEL_VERSION="<项目所需版本>"
   # 从 reference 文档获取下载链接，优先内部定制版
   DOWNLOAD_URL="<从 build-tools-reference.md 选取链接>"
   wget ${DOWNLOAD_URL} -O /tmp/bazel-${BAZEL_VERSION}
   chmod +x /tmp/bazel-${BAZEL_VERSION}
   sudo mv /tmp/bazel-${BAZEL_VERSION} /usr/local/bin/bazel-${BAZEL_VERSION}
   sudo ln -sf /usr/local/bin/bazel-${BAZEL_VERSION} /usr/local/bin/bazel
   ```

2. 如果需要多版本共存，可以将不同版本安装到不同路径并创建符号链接：
   ```bash
   sudo ln -sf /usr/local/bin/bazel-${BAZEL_VERSION} /usr/local/bin/bazel
   ```

3. 验证安装版本是否匹配：
   ```bash
   bazel --version
   ```

**注意**：Bazel 版本不一致可能导致构建规则不兼容、远程缓存失效等问题，必须确保项目使用的 Bazel 版本与鲲鹏环境安装的版本一致。
