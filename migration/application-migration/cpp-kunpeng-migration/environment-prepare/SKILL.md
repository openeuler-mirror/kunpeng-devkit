---
name: environment-prepare
description: C/C++ 项目鲲鹏迁移的阶段 1 子 Skill，专注于环境检测与编译环境准备环节。提供检测鲲鹏目标环境的编译器（GCC）、构建工具（Make/CMake/Bazel/Blade/SCons）和基础依赖（Protobuf）的能力，对不满足要求的项自动修复（安装/升级），准备编译环境。在作为 cpp-kunpeng-migration 主 Skill 的阶段 1 子 Skill 被调用时触发，当用户需要单独执行环境检测、检查构建工具版本兼容性、准备鲲鹏编译环境、或处理 Blade/Bazel 版本不匹配时也应直接触发。适用于 C/C++ 项目的 x86→鲲鹏架构迁移的环境准备。
use_when: 适用c/c++语言的鲲鹏迁移。
do_not_ues_when: 不适用于非 C/C++ 语言的鲲鹏迁移、非鲲鹏架构的迁移。
---

# 阶段 1：环境检测、修复与准备编译环境

本阶段用于检测鲲鹏目标环境的编译器、构建工具和基础依赖，对不满足要求的项自动修复（安装/升级），准备编译环境，确保项目在鲲鹏上具备编译条件。

> **执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段 1 子 Skill 调用，由主编排以子 agent 模式拉起执行（调起方式见主 SKILL 文末「调起约定与跨助手适配」）。当用户需要单独执行环境检测、检查构建工具版本兼容性、准备鲲鹏编译环境、或处理 Blade/Bazel 版本不匹配时也可直接调用本子 Skill。
>
> **子 agent 边界**：子 agent **不向用户提问**，检测到的版本不一致项按「子 agent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_1_pending_items.md`，由主编排在阶段 3 统一提问。

> 构建工具的下载链接参见 [build-tools-reference.md](references/build-tools-reference.md)，安装时优先使用内部定制版链接，无内部定制版时使用官方链接。

## 输入参数

主编排读取本文件全文，将下列占位符替换为实际值后作为子 agent 提示词传入：

- `<项目绝对路径>` → `PROJECT_ROOT`
- `<工作目录绝对路径>` → `WORK_DIR`
- `<skill目录绝对路径>` → `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

参数定义：

- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <cpp-kunpeng-migration skill 目录绝对路径>（主编排传入）

## 1.1 收集系统环境信息

在 **x86_64 源环境** 和 **鲲鹏目标环境** 分别执行以下命令，收集基线信息：

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

记录两个环境的 gcc 版本、glibc 版本、内核版本和操作系统版本，这些信息将在阶段 4（DevKit 扫描）中用于识别潜在的兼容性问题。

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

在 **鲲鹏目标环境** 检查构建工具版本：

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

# JDK（毕昇 JDK）
java -version
javac -version
echo $JAVA_HOME
```

如果构建工具未安装或版本不满足要求，**自动尝试安装**（安装流程见下方各构建系统章节），安装时按 [build-tools-reference.md](references/build-tools-reference.md) 中的链接选取规则下载：
1. 优先使用内部定制版下载链接
2. 如无内部定制版，使用官方下载链接

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

### 1.4.2 检查 Blade 的 鲲鹏 和 Python3 兼容性

如果 blade 以 zip 包形式存放在代码仓库中：

1. 解压 zip 包并检查 blade 版本：
   ```bash
   unzip -l blade*.zip | head -20
   # 或者解压后检查
   unzip blade*.zip -d blade_extracted
   cat blade_extracted/blade/__init__.py  # 或类似的版本文件
   ```

2. 检查 blade 版本是否支持鲲鹏架构。**2.0 之前**的 blade 版本不支持鲲鹏和 Python3。如果版本不支持鲲鹏，**优先升级到 Blade 2.0**（而非直接跳到 3.0），以减少版本跨度过大导致的兼容性问题：
   - 从 [build-tools-reference.md](references/build-tools-reference.md) 中查找对应版本的下载链接，优先使用内部定制版
   - 下载并替换项目中的 blade zip 包：
     ```bash
     # 从 reference 文档获取下载链接
     DOWNLOAD_URL="<从 references/build-tools-reference.md 选取链接>"
     wget ${DOWNLOAD_URL} -O /tmp/blade-upgrade.zip
     cp /tmp/blade-upgrade.zip <项目中的blade zip包路径>
     ```
   - 验证新版本可以在 Python3 下工作：`python3 -m blade --version`
   - 如果 Blade 2.0 仍不满足项目需求，再考虑升级到 3.0

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

在 **鲲鹏目标环境** 上：

```bash
bazel --version
```

如果 Bazel 未安装，输出类似 `bazel: command not found`，需要安装。

### 1.5.3 安装或切换 Bazel 版本

如果项目所需的 Bazel 版本与系统安装的版本不一致，或系统未安装 Bazel，**自动尝试安装**匹配版本：

1. 从 [build-tools-reference.md](references/build-tools-reference.md) 中查找对应版本的下载链接，优先使用内部定制版：
   ```bash
   BAZEL_VERSION="<项目所需版本>"
   # 从 reference 文档获取下载链接，优先内部定制版
   DOWNLOAD_URL="<从 references/build-tools-reference.md 选取链接>"
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

在 **鲲鹏环境** 检查protoc版本：

```bash
protoc --version
```

### 1.6.3 处理 Protobuf 版本不一致

如果系统 protoc 版本与项目所需的 protobuf 版本不一致，**自动尝试编译安装**：

1. 下载匹配版本的 protobuf 源码：
   ```bash
   # 以 protobuf 3.6.1 为例
   git clone -b v3.6.1 https://github.com/protocolbuffers/protobuf.git
   cd protobuf
   git submodule update --init --recursive
   ```

2. 在**鲲鹏目标环境**编译 protoc：
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

**重要**：即使鲲鹏系统安装了更高版本的 protobuf，也**绝不能**升级项目使用的 protobuf 版本。项目必须使用其原始 protobuf 版本以保持兼容性。只需为鲲鹏编译安装匹配版本的 protoc 二进制文件即可。

## 1.7 生成环境检测与修复报告

完成以上所有检查和修复后，生成汇总报告。

**报告模板**

见 [environment-check-report-template.md](assets/environment-check-report-template.md)。

将此报告保存到工作目录中，文件名为 `$WORK_DIR/reports/environment_check_report.md`。

---

## 输出要求（硬性约束）

1. **必须**将环境检测报告写入文件 `$WORK_DIR/reports/environment_check_report.md`
2. **必须**将待确认项写入文件 `$WORK_DIR/reports/stage_1_pending_items.md`（格式见下方）
3. 即使无待确认项，也必须写入空清单并标注"无待确认项"
4. **严禁**向用户提问（你没有向用户提问的权限，需用户决策的项一律写入待确认项文件，由主编排在阶段 3 统一提问）
5. **严禁**修改项目源码或构建配置（你只做检测和报告）
6. 完成后，在你的最终回复中输出：
   - 环境检测结论（是否具备编译条件）
   - 识别到的构建系统类型
   - 待确认项数量
   - 报告文件路径

## 待确认项格式

见 [pending-items-template.md](assets/pending-items-template.md)。

现在开始执行阶段 1 环境检测。
