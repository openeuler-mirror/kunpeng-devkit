# Protobuf 版本检查与匹配安装

> **做什么**：识别项目使用的 protobuf 版本，检查鲲鹏环境 protoc 是否匹配，不一致时为鲲鹏编译安装匹配版本的 protoc 二进制（**绝不升级项目 protobuf 版本**）。

---

## Step 1：确定项目使用的 Protobuf 版本

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

---

## Step 2：检查系统 protoc 版本

在 **鲲鹏环境** 检查 protoc 版本：

```bash
protoc --version
```

---

## Step 3：处理 Protobuf 版本不一致

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
