# Bazel 构建系统依赖分析

> ⚠️ **按需加载**：仅当 [analyze-one-repo.md](../analyze-one-repo.md) Step 1 识别到构建系统为 **Bazel** 时加载本文件，否则跳过。

---

## 解析 WORKSPACE 依赖声明

```bash
# 读取 WORKSPACE 文件，提取所有外部依赖声明
cat <项目根目录>/WORKSPACE
```

Bazel 通过 `WORKSPACE` 文件声明外部依赖，三种规则对应不同来源：

| 规则 | 依赖来源 | ARM 迁移关注点 |
|------|---------|---------------|
| `git_repository` / `new_git_repository` | 远端 Git 仓库（有源码） | 检查是否有 ARM 分支或 ARM 相关提交历史 |
| `http_archive` | HTTP 下载（可能是预编译包） | ⚠️ 需检查下载的包是否为预编译二进制（见 3a-2） |
| `new_local_repository` | 本地系统路径 | 检查路径在 ARM 系统上是否存在 |

**各规则需提取的关键字段**：

| 规则 | 关键字段 | 说明 |
|------|---------|------|
| `git_repository` | `name`, `remote`, `tag`/`commit` | 定位依赖名称和版本 |
| `http_archive` | `name`, `url`, `sha256` | 定位下载地址和完整性校验 |
| `new_local_repository` | `name`, `path` | 定位本地路径 |

---

## 识别 `http_archive` 预编译包

`http_archive` 下载的包可能是**源码包**也可能是**预编译二进制包**，需检查对应的 `.BUILD`（或 `BUILD`）文件来判断：

| `.BUILD` 文件特征 | 判定结果 | ARM 迁移影响 |
|------------------|---------|-------------|
| `srcs = glob(["lib/**/*.so*"])` 或 `glob(["lib64/lib*.a*"])` | 🔴 **预编译库** | 需获取 ARM 版本或从源码重新编译 |
| `filegroup` 指向 `bin/` 目录 | 🔴 **预编译可执行文件** | 同上 |
| 无 `.cc`/`.cpp` srcs，仅有 `.h` | 🟡 **纯头文件库** | 通常无需适配，检查是否有平台宏 |
| 有 `.cc`/`.cpp` srcs | ✅ **源码编译** | 可直接在 ARM 上编译，检查是否有 x86 专有代码 |

**检查命令**：

```bash
# 查看 http_archive 对应的 BUILD 文件内容
# 方式 1：若 BUILD 文件内联在 WORKSPACE 中
grep -A20 'name = "<依赖名>"' <项目根目录>/WORKSPACE

# 方式 2：若使用独立 BUILD 文件（通常在 third_party/ 或 .bazel 版本管理目录下）
find <项目根目录> -name "<依赖名>.BUILD" -o -name "BUILD.bazel" | xargs grep -l "<依赖名>"
```

---

## Bazel 源码溯源

> 预编译二进制的源码溯源逻辑已统一移入 [common-binary-detect.md](../common-binary-detect.md)，此处不再重复。
> 由 [analyze-one-repo.md](../analyze-one-repo.md) Step 4 统一调用 `common-binary-detect.md` 执行。
>
> 对于 Bazel 项目，`common-binary-detect.md` Section 3「第一优先级」会在 `$REPO_PATH/WORKSPACE` 中搜索依赖名，自动找到 `git_repository`/`http_archive` 中的源码地址。

---

## Bazel 子模块依赖分析

> 子模块递归逻辑已统一由 [analyze-one-repo.md](../analyze-one-repo.md) Step 5 处理。
> 当子模块被识别为 Bazel 项目时，[analyze-one-repo.md](../analyze-one-repo.md) 会重新加载本文件对该子模块执行依赖扫描，无需在此重复定义。

---

## Bazel 注意事项

| 注意事项 | 说明 | 建议操作 |
|---------|------|---------|
| **重复 `http_archive` 名称** | 同一 `name` 多次声明时 Bazel 使用第一个 | 检查 WORKSPACE 中是否有重复声明 |
| **`git_repository` ARM 分支** | 私有 Git 仓库可能存在 ARM 适配分支 | 执行 `git ls-remote --heads <remote>` 检查远端分支 |
| **`http_archive` 预编译包架构** | 下载的包可能仅含 x86 二进制 | 用 `file` 命令验证架构，或检查 URL 中是否含 `x86`/`amd64` 等关键字 |
| **私有 `git_repository`** | SSH 形式指向内部 Git 域名的依赖 | 标记为需 ARM 兼容性检查，检查提交历史中的 ARM 关键字 |
| **`strip_prefix` 与目录结构** | `http_archive` 的 `strip_prefix` 影响包解压后路径 | 确认 ARM 版本的包目录结构一致 |
| **`build_file` 指向** | `http_archive` 通过 `build_file` 指定外部 BUILD 文件 | 切换 ARM 版本时需同步更新 BUILD 文件中的 srcs 路径 |
