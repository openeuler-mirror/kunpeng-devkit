# 编译错误快速修复速查表

> 本文件是阶段 E 编译验证循环的**第一级错误修复查询源**：扁平表格，按错误关键字快速匹配常见问题。
> 由 [sourcecode-build-verify.md](sourcecode-build-verify.md) E.2 主循环调用。
>
> **查询顺序**：本速查表（第1级，快）→ [migration-cases/](migration-cases/) 案例库（第2级，详细兜底）。
> 速查表是扁平关键字表，扫描快；案例库是结构化教案，适合速查表未命中的复杂问题深入查询。

---

## 使用方式

1. 从编译错误日志（`$WORK_DIR/logs/build_<N>.log`）提取错误关键字
2. 按错误类别扫下方对应表格，匹配「错误信息」列
3. **命中** → 按「修复」列描述修复
4. **未命中** → 回落 [migration-cases/](migration-cases/) 案例库（第2级，查询流程见 [sourcecode-build-verify.md](sourcecode-build-verify.md) E.5 节）

> ℹ️ x86 专属编译标志类错误（`-mf16c`/`-mssse3`/`-mpopcnt` 等在 ARM 不支持）已由案例库 [G-01](migration-cases/G-cases.md) 覆盖，不再列入本表，请直接查 G 系列。

---

## 头文件找不到

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `'immintrin.h' file not found` | x86 intrinsics 头文件未隔离 | 用 `#if defined(__x86_64__)` 包裹 `#include` |
| `'emmintrin.h' file not found` | 同上 | 同上 |
| `'sys/sysctl.h': No such file` | ARM Linux 无该头文件 | 用 `#if !defined(__aarch64__)` 包裹 |
| `fatal error: xxx.h: No such file or directory` (来自第三方库) | BUILD 文件缺少 `hdrs` 或 `includes` | 在对应 BUILD 文件中补 `hdrs = glob(["**/*.h"])` 和 `includes = ["."]` |

## 类型/符号未定义

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `'__m256i' was not declared` | AVX 类型未定义 | 用 `#if defined(__x86_64__)` 包裹整个使用块，ARM 路径提供 NEON 替代或标量退化（参考 sourcecode-devkit-scan.md D.2.2） |
| `'_mm256_loadu_si256' undeclared` | AVX intrinsics 函数未定义 | 同上 |
| `expected unqualified-id before '__attribute__'` | `-D__const__=` 破坏 ARM glibc | 在 .bazelrc / Makefile 中改为 `select()` / 架构判断分支，仅 x86 段保留该宏 |
| `'proto_common' is not defined` | Bazel rules_proto 版本不兼容 | 在 .bazelrc 全局段加 `--incompatible_blacklisted_protos_requires_proto_info=false` |

## 链接错误

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `error adding symbols: File in wrong format` | x86 `.so`/`.a` 被 ARM 链接器处理 | 确认 WORKSPACE_arm 中的 URL 已替换为 ARM 版本；检查对应 `.so` 文件架构 |
| `undefined reference to 'xxx'` | ARM 版库未链接或 ABI 不匹配 | 检查 WORKSPACE_arm 库路径，确认 ARM `.so`/`.a` 已就位，符号签名一致 |
| `undefined reference to 'std::__cxx11::basic_string'` / `_ZNSt7__cxx11*` | CXX ABI 不一致（新/旧 ABI 混用） | 全局加 `-D_GLIBCXX_USE_CXX11_ABI=0` 并重编译所有依赖库，详见 [V-02](migration-cases/V-cases.md) |

## Bazel 构建系统错误

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `no such target '//platforms:is_aarch64'` | platforms/BUILD 未定义 ARM 平台 | 补全 platforms/BUILD，见 bazel-dual-arch-pattern.md 层1 |
| `no such target '//platforms:linux_aarch64'` | 同上 | 同上 |
| `Unrecognized option: --incompatible_...` | 系统 Bazel 版本过旧 | 确认使用项目内置 Bazel（software.sh 中的 PATH 设置） |
| `Host key verification failed` | SSH 克隆私有仓库失败（ARM 环境无 SSH 密钥） | 向用户提问获取地址 |
| `incompatible with your Protocol Buffer headers` | protoc 版本与 .pb.h 不匹配 | 重新生成 .pb.h，或对齐 protobuf 版本（见 environment-prepare.md 1.6 节） |

## 编译严格性差异

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `jump to case label` | case 块中有局部变量，ARM GCC 更严格 | 给 case 块加花括号 `{}` 形成独立作用域 |
| `missing binary operator before token "("` | Boost 版本过旧 | 使用系统新版 Boost 或升级 Boost 版本 |
| `-Werror` 将警告升级为错误 | ARM GCC 产生 x86 GCC 没有的警告 | 在 ARM 配置段中添加对应的 `-Wno-xxx`，或修复源码中的警告 |
