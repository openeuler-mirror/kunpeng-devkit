# Blade 构建系统依赖分析

> ⚠️ **按需加载**：仅当阶段 A 环境检测报告识别到构建系统为 **Blade** 时加载本文件，否则跳过。
> 对应主流程「第三步：Blade」中的专用命令。

---

## 扫描 BLADE_ROOT 全局配置

```bash
cat <项目根目录>/BLADE_ROOT
```

BLADE_ROOT 中声明的全局依赖项：

| 配置字段 | 含义 | ARM 迁移关注点 |
|----------|------|---------------|
| `cc_config.extra_incs` | 全局头文件搜索路径 | 检查路径是否指向目标架构版本的目录 |
| `cc_config.cxxflags` | 全局编译标志 | 检查是否含 x86 专属标志（如 `-mavx`），是否缺少 ARM 必需标志（如 `-fsigned-char`） |
| 代码生成工具路径（protoc/thrift 等） | 代码生成工具二进制路径 | 检查是否指向目标架构版本 |
| 代码生成工具头文件路径 | 生成代码依赖的头文件路径 | 检查是否指向目标架构版本 |

---

## 扫描 thirdparty 目录下的 BUILD 文件

```bash
# 列出 thirdparty 下所有组件
ls <项目根目录>/thirdparty/

# 每个组件的 BUILD 文件决定了依赖来源
cat <项目根目录>/thirdparty/<组件名>/BUILD
```

Blade thirdparty 依赖的三种模式：

| 模式 | BUILD 特征 | 依赖来源 | ARM 适配方式 |
|------|-----------|---------|-------------|
| **聚合代理** | `deps = ['//thirdparty/X/X_arm:lib']` | 指向子目录 | 修改 BUILD 中 deps 指向 `_arm` 版本 |
| **预编译库** | `prebuilt = 1` + `srcs`/自动查找 | `lib64_release/*.so`/`*.a` | 需存在 ARM 版预编译文件（同名目录含 `_arm` 后缀） |
| **源码编译** | `srcs = ['*.cc', '*.cpp']` | 仓库内源码 | 检查源码中是否含 x86 专属指令（SSE/AVX/内联汇编） |

### ARM 库查找路径

当 `thirdparty/<组件名>/` 下不存在 `*_arm` 子目录时，需检查统一管理目录 `thirdparty_arm/`：

```bash
# 优先在 thirdparty 下查找 ARM 子目录
find <项目根目录>/thirdparty -maxdepth 2 -type d -name "*_arm*"

# 若未找到，则在 thirdparty_arm 下查找
find <项目根目录>/thirdparty_arm -maxdepth 2 -type d -name "*_arm*"
```

> `thirdparty_arm/` 是 ARM 库的统一管理目录，结构与 `thirdparty/` 一致（`thirdparty_arm/<组件名>/<ARM子目录>`）。
> 构建前需将所需库从 `thirdparty_arm/` 回迁到 `thirdparty/` 对应位置，详见 [arm-confirmed-write.md](arm-confirmed-write.md)「Blade 项目：thirdparty_arm 回迁」。

---

## 识别 BUILD/BUILD.x86 双架构分离

```bash
# 检测 thirdparty 下的 BUILD.x86 文件（说明项目已做 x86/ARM 分离）
find <项目根目录>/thirdparty -name "BUILD.x86" -type f | sort

# 对比 BUILD 与 BUILD.x86 的差异
diff <项目根目录>/thirdparty/<组件名>/BUILD \
     <项目根目录>/thirdparty/<组件名>/BUILD.x86
```

> Blade 项目常见的 ARM 适配策略：当前 `BUILD` 为 ARM 版（指向 `*_arm` 子目录），
> `BUILD.x86` 为 x86 版（指向原 x86 子目录）。切换架构时替换 BUILD 文件即可。

---

## 识别系统库依赖

```bash
# Blade 中 # 前缀表示系统库
grep -rn '"#.*"' <项目根目录>/thirdparty/*/BUILD <项目根目录>/*/BUILD \
  2>/dev/null | grep -o '"#[^"]*"' | sort -u
```

系统库（`#pthread`, `#dl`, `#ssl`, `#crypto` 等）由系统包管理器提供，
在 ARM Linux 上通常直接可用，无需额外适配。

---

## Blade thirdparty 组件智能分组

> 分析时将 so 文件按**组件名**聚合，而非逐个列出 so 文件名。例如 `libxxx1.so`, `libxxx2.so` → 统一归为 **boost** 组件。

当 thirdparty 下组件较多时，按以下维度分组输出报告：

| 分组 | 判定条件 | 报告展示方式 |
|------|---------|-------------|
| **预编译库（有 ARM 版）** | 存在 `*_arm` 子目录且 BUILD 已指向 | ✅ 列表展示组件名，省略 so 文件名 |
| **预编译库（无 ARM 版）** | 仅有 x86 so/a，无 `_arm` 子目录 | 🔴 逐个展示组件名 + 缺失说明 |
| **源码编译库** | BUILD 中有 `srcs` 字段 | 🟡 列出组件名，标注需检查 x86 专属指令 |
| **纯头文件库** | BUILD 中仅有 `export_incs` | ✅ 列表展示组件名，标注无需适配 |

---

## Blade 项目私有依赖补充

对 Blade 项目，[common-arm-probe.md](common-arm-probe.md) 识别私有依赖时还需检查 thirdparty 目录下预编译包（`prebuilt = 1`）的来源。若 thirdparty 中某组件只有 x86 二进制（无 `*_arm` 子目录），且该组件来自内部对象存储（如 `*.internal-storage.example.com` 等内部域名），则标记为私有预编译依赖，需获取 ARM 版本。

## 预编译二进制识别与溯源

> Blade 项目中 `prebuilt = 1` 组件的架构判断和源码溯源逻辑已统一移入 [common-binary-detect.md](common-binary-detect.md)，此处不再重复。
> 由 [analyze-one-repo.md](analyze-one-repo.md) Step 4 统一调用 `common-binary-detect.md` 执行。
>
> 特别说明：Blade 项目的 `lib64_release/*.so`/`*.a` 文件会在 `common-binary-detect.md` Section 1 的 `find` 命令中被扫描到，Section 2 判断架构，若为 x86 则进入 Section 3 溯源（第一优先级会检查 `BUILD` 文件中的源码来源字段）。

---

## Blade 注意事项

- thirdparty 目录下组件较多时，按组件名聚合输出（而非逐个 so 文件名）
- 关注 `prebuilt = 1` 标记的预编译库是否含 `*_arm` 版本
- BLADE_ROOT 中 `extra_incs`/`cxxflags` 是否指向 ARM 版路径
- 检查 BUILD/BUILD.x86 双架构分离是否完整（每个有 BUILD.x86 的组件都应有 ARM 版 BUILD）
- ARM 库查找顺序：先查 `thirdparty/<组件名>/` 下是否有 `*_arm` 子目录，若无则查 `thirdparty_arm/<组件名>/`；找到后需回迁到 `thirdparty/` 下构建系统才能识别
- 若项目目录下同时存在 `SConstruct` 文件，需额外检查其中的 x86 编译标志（`-msse`/`-mavx`/`-m64`）；参考 [dependency-analysis-scons.md](dependency-analysis-scons.md) 中「SCons 关键检查项」一节
