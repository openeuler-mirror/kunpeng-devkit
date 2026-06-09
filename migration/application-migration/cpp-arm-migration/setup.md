# 步骤一：环境检测与准备编译环境

本步骤用于检测 arm64 目标环境的编译器、构建工具和基础依赖，准备编译环境，确保项目在 arm64 上具备编译条件。执行本步骤前，请确认已满足 SKILL.md 中的前置条件。

## 1.1 收集系统环境信息

在 **x86_64 源环境** 上执行以下命令，收集基线信息：

```bash
# 获取 gcc 版本
gcc --version

# 获取 glibc 版本
ldd --version

# 获取内核版本
uname -r

# 获取操作系统发行版信息
cat /etc/os-release
```

记录 gcc 版本、glibc 版本和操作系统版本，这些信息将在步骤三中用于识别潜在的兼容性问题。

## 1.2 识别构建系统

扫描项目根目录，识别项目使用的构建系统。查找以下标志文件：

| 标志文件                              | 构建系统  |
| --------------------------------- | ----- |
| `Makefile`、`makefile`、`*.mk`      | Make  |
| `CMakeLists.txt`、`*.cmake`        | CMake |
| `WORKSPACE`、`BUILD`、`BUILD.bazel` | Bazel |
| `BLADE_ROOT`、`BUILD`、`BLADE`      | Blade |
| `SConstruct`、`SConscript`         | SCons |

如果检测到多个构建系统，根据根目录级别的文件判断主构建系统。

## 1.3 检查构建工具版本和可用性

在 **arm64 目标环境** 上检查构建工具版本：

```bash
# Make
make --version

# CMake
cmake --version

# Bazel
bazel --version

# SCons
scons --version

# Blade - 需要检查项目中是否以zip包形式提供
find . -name "blade*.zip" -o -name "blade-*.zip"
```

如果构建工具未安装或版本不满足要求，需要安装或升级：

- **Make**：`yum install make` 或 `apt install make`
- **CMake**：从 https://cmake.org/download/ 下载或通过包管理器安装
- **Bazel**：参见 1.5 节的 Bazel 版本检测与安装流程
- **SCons**：`pip install scons` 或 `yum install scons`

## 1.4 处理 Blade 构建系统（特殊情况）

如果项目使用 Blade 作为构建系统，需要执行额外的步骤：

### 1.4.1 检查项目中的 Blade 来源

在项目中搜索 blade zip 包或 blade 目录：

```bash
# 搜索 blade zip 包
find . -name "blade*.zip" -o -name "blade-*.zip"

# 搜索 blade 目录
find . -type d -name "blade"

# 搜索 blade 入口脚本
find . -name "blade" -type f
find . -name "blade.py"
```

### 1.4.2 检查 Blade 的 arm64 和 Python3 兼容性

如果 blade 以 zip 包形式存放在代码仓库中：

1. 解压 zip 包并检查 blade 版本：
   ```bash
   unzip -l blade*.zip | head -20
   # 或者解压后检查
   unzip blade*.zip -d blade_extracted
   cat blade_extracted/blade/__init__.py  # 或类似的版本文件
   ```

2. 检查 blade 版本是否支持 arm64 架构。**3.0 之前**的 blade 版本通常不支持 arm64。如果版本不支持 arm64：
   - 从 https://github.com/chen3feng/blade/releases 下载支持 arm64 和 Python3 的新版本 blade
   - 验证新版本可以在 Python3 下工作：`python3 -m blade --version`
   - 将升级后的 blade 重新打包为与原始 zip 包同名的 zip 文件
   - 替换代码仓库中的原始 zip 包

3. 检查 Python 版本兼容性：
   ```bash
   python --version
   python3 --version
   ```
   如果 blade 需要 Python3 但系统默认使用 Python2，确保构建脚本使用 `python3` 调用 blade。

## 1.5 处理 Bazel 构建系统（特殊情况）

如果项目使用 Bazel 作为构建系统，需要检测项目依赖的 Bazel 版本与系统安装的版本是否一致，不一致时需要安装匹配版本。

### 1.5.1 确定项目所需的 Bazel 版本

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

### 1.5.2 检查系统 Bazel 版本

在 **arm64 目标环境** 上：

```bash
bazel --version
```

如果 Bazel 未安装，输出类似 `bazel: command not found`，需要安装。

### 1.5.3 安装或切换 Bazel 版本

如果项目所需的 Bazel 版本与系统安装的版本不一致，或系统未安装 Bazel，需要安装匹配版本：

1. 从 Bazel GitHub Releases 下载对应版本的 arm64 二进制文件：
   ```bash
   # 以安装 Bazel 6.4.0 为例
   BAZEL_VERSION="6.4.0"
   wget https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-linux-arm64
   chmod +x bazel-${BAZEL_VERSION}-linux-arm64
   sudo mv bazel-${BAZEL_VERSION}-linux-arm64 /usr/local/bin/bazel
   ```

2. 如果需要多版本共存，可以将不同版本安装到不同路径并创建符号链接：
   ```bash
   # 安装到版本化路径
   sudo mv bazel-${BAZEL_VERSION}-linux-arm64 /usr/local/bin/bazel-${BAZEL_VERSION}
   # 创建符号链接指向所需版本
   sudo ln -sf /usr/local/bin/bazel-${BAZEL_VERSION} /usr/local/bin/bazel
   ```

3. 验证安装版本是否匹配：
   ```bash
   bazel --version
   ```

**注意**：Bazel 版本不一致可能导致构建规则不兼容、远程缓存失效等问题，必须确保项目使用的 Bazel 版本与 arm64 环境安装的版本一致。

## 1.6 识别 Protobuf 版本

### 1.6.1 确定项目使用的 Protobuf 版本

在项目中搜索 protobuf 版本标识：

```bash
# 在构建文件中搜索 protobuf 版本
grep -r "protobuf" --include="CMakeLists.txt" --include="Makefile" --include="BUILD" --include="WORKSPACE" --include="*.cmake" --include="*.blade" .

# 在依赖文件中搜索 protobuf 版本
grep -r "protobuf" --include="*.dep" --include="*.lock" --include="requirements.txt" --include="conanfile.txt" --include="conanfile.py" .

# 搜索 protobuf 头文件版本
find . -name "protobuf-version.h" -exec cat {} \;

# 搜索 .proto 文件确认 protobuf 使用情况
find . -name "*.proto" | head -20
```

检查以下位置的显式版本指定：

- CMake：`find_package(Protobuf ...)` 或 `protobuf-version.h` 中的版本
- Blade：BUILD 文件中的 `protobuf` 库引用
- Bazel：WORKSPACE/MODULE.bazel 中的 `protobuf` 依赖版本
- Make：`pkg-config --modversion protobuf`

### 1.6.2 检查系统 protoc 版本

在 **arm64 目标环境** 上：

```bash
protoc --version
```

### 1.6.3 处理 Protobuf 版本不一致

如果系统 protoc 版本与项目所需的 protobuf 版本不一致：

1. 下载匹配版本的 protobuf 源码：
   ```bash
   # 以 protobuf 3.6.1 为例
   git clone -b v3.6.1 https://github.com/protocolbuffers/protobuf.git
   cd protobuf
   git submodule update --init --recursive
   ```

2. 为 arm64 编译 protoc：
   ```bash
   ./autogen.sh  # 如果需要
   ./configure
   make -j$(nproc)
   sudo make install
   sudo ldconfig
   ```

3. 验证安装版本是否匹配：
   ```bash
   protoc --version
   ```

**重要**：即使 arm64 系统安装了更高版本的 protobuf，也**绝不能**升级项目使用的 protobuf 版本。项目必须使用其原始 protobuf 版本以保持兼容性。只需为 arm64 编译安装匹配版本的 protoc 二进制文件即可。

## 1.7 生成环境检测报告

完成以上所有检查后，生成汇总报告：

```
=== 环境检测报告 ===

--- 系统环境 ---
源环境（x86_64）：
  - 操作系统：<操作系统信息>
  - GCC：<版本>
  - glibc：<版本>

目标环境（arm64）：
  - 操作系统：<操作系统信息>
  - GCC：<版本>
  - glibc：<版本>

--- 构建系统 ---
  - 构建工具：<make/cmake/bazel/blade/scons>
  - 版本：<版本>
  - 状态：<已安装/需安装/需升级>

--- Blade 相关（如适用）---
  - Blade 版本：<版本>
  - arm64 支持：<是/否>
  - Python3 支持：<是/否>
  - 需要的操作：<无/需升级>
  - Zip 包位置：<路径>

--- Bazel 相关（如适用）---
  - 项目所需 Bazel 版本：<版本>
  - 系统 Bazel 版本：<版本/未安装>
  - 是否匹配：<是/否>
  - 需要的操作：<无/需安装指定版本>

--- Protobuf ---
  - 项目 protobuf 版本：<版本>
  - 系统 protoc 版本：<版本>
  - 是否匹配：<是/否>
  - 需要的操作：<无/需源码编译>

--- 下一步 ---
  - 进入步骤二：依赖分析
```

将此报告保存到项目目录中，文件名为 `migration-analysis-report.md`。
