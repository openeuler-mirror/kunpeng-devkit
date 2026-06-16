# 单仓库分析入口（analyze-one-repo）

> 本文件是**单个仓库的分析闭环**。主仓库和所有子模块（含嵌套子模块）均通过此文件执行分析，由 [dependency-analysis.md](dependency-analysis.md) 的主循环驱动调用。
>
> **不要直接修改此文件中的通用能力逻辑**——二进制识别见 [common-binary-detect.md](common-binary-detect.md)，ARM 探测见 [common-arm-probe.md](common-arm-probe.md)。

---

## 调用参数

每次调用本文件时，需确定以下上下文变量：

| 参数 | 含义 | 示例值 |
|------|------|--------|
| `REPO_PATH` | 仓库根目录绝对路径 | `/path/to/project` 或 `/path/to/project/deps/grpc` |
| `REPO_NAME` | 仓库标识（主仓用项目名，子模块用其 displaypath） | `my-service` 或 `deps/grpc` |
| `REPO_DEPTH` | 当前递归深度，0 = 主仓，1 = 直接子模块，2 = 子仓的子仓 | `0` / `1` / `2` |
| `MAX_DEPTH` | 最大递归深度，默认 `2` | `2` |

> `REPO_DEPTH >= MAX_DEPTH` 时不再递归，记录「超过最大分析深度，跳过」。

---

## 执行步骤

### Step 1：检测当前仓库的构建系统

```bash
# 在 REPO_PATH 下检测构建系统标志文件（maxdepth 1 只看顶层，避免误判子目录）
[ -f "$REPO_PATH/BLADE_ROOT" ]      && echo "Blade"
[ -f "$REPO_PATH/WORKSPACE" ]       && echo "Bazel"
[ -f "$REPO_PATH/CMakeLists.txt" ]  && echo "CMake"
[ -f "$REPO_PATH/SConstruct" ]      && echo "SCons"
```

判定规则（优先级从高到低）：

| 标志文件 | 构建系统 | 备注 |
|---------|---------|------|
| `BLADE_ROOT` | **Blade** | Blade 内含 SCons，有 `SConstruct` 时以 Blade 为主，不单独执行 SCons 分析 |
| `WORKSPACE` | **Bazel** | — |
| `CMakeLists.txt`（无 `BLADE_ROOT`） | **CMake** | — |
| `SConstruct`（无 `BLADE_ROOT`） | **SCons** | 纯 SCons 项目 |
| 均未找到 | **未知** | 记录「[$REPO_NAME] 未识别到构建系统，跳过依赖扫描」，直接进入 Step 3 |

> 若多种标志文件并存（如 CMake + Bazel），则**全部启用**，对应分析步骤均执行。

---

### Step 2：按构建系统加载依赖扫描文件

根据 Step 1 的结果，**按需** `read_file` 对应的专用分析文件，执行依赖声明扫描，收集 `deps_list`：

| 构建系统 | 加载文件 | 输出内容 |
|---------|---------|---------|
| Blade | [dependency-analysis-blade.md](dependency-analysis-blade.md) | thirdparty 组件列表（预编译/源码/聚合代理），BLADE_ROOT 全局配置 |
| Bazel | [dependency-analysis-bazel.md](dependency-analysis-bazel.md) | `git_repository`/`http_archive`/`new_local_repository` 依赖列表 |
| CMake | [dependency-analysis-cmake.md](dependency-analysis-cmake.md) | `FetchContent_Declare`/`ExternalProject_Add`/`find_package` 依赖列表 |
| SCons | [dependency-analysis-scons.md](dependency-analysis-scons.md) | 库链接声明、x86 编译标志、Python 版本问题 |
| 未知 | — | 跳过，deps_list 为空 |

> ⚠️ **CMake 特别注意**：加载 `dependency-analysis-cmake.md` 前，必须先检查 `$REPO_PATH/CMakeLists.txt` 中是否存在子模块自动签出逻辑（`execute_process(git submodule update ...)`）。若存在，需在报告中警告用户，并建议注释该逻辑后再切换子模块到 ARM 分支。详见 [dependency-analysis-cmake.md](dependency-analysis-cmake.md)「子模块自动签出检查」。

**扫描结束后，同时收集 Shell 脚本下载依赖（所有构建系统通用）**：

```bash
# 手动下载（wget/curl）
grep -rn "wget\|curl" "$REPO_PATH"/*.sh "$REPO_PATH"/scripts/ 2>/dev/null

# 系统包管理（yum/apt）
grep -rn "yum install\|apt-get install\|apt install" "$REPO_PATH"/*.sh "$REPO_PATH"/scripts/ 2>/dev/null
```

---

### Step 3：对 deps_list 执行 ARM 兼容性探测

加载 [common-arm-probe.md](common-arm-probe.md)，对 Step 2 收集的每个依赖执行：

1. 私有 URL 判断（公开平台直接豁免）
2. 远端分支检查（`git ls-remote --heads`）
3. 本地提交历史检查（`git log grep arm/aarch64`）
4. 与 `arm_confirmed.md` 免检清单比对

输出每个依赖的 `arm_status`（✅ 已确认 / 🟡 待确认 / 🔴 未知）。

---

### Step 4：预编译二进制识别与源码溯源

加载 [common-binary-detect.md](common-binary-detect.md)，对 `$REPO_PATH` 执行：

1. 扫描仓库内置 `.so`/`.a`/可执行文件
2. `file` 命令判断架构（x86-64 / aarch64 / ARM32 等）
3. 对所有 x86 架构二进制执行四级源码溯源
4. 同时检查脚本下载的 RPM 包是否有对应 `.spec` 文件（`find $REPO_PATH -name "*.spec"`）

输出 `binary_list`（文件路径 + 架构 + 溯源级别 + 处理建议）。

---

### Step 5：递归处理子模块（循环体）

```bash
# 检查当前仓库是否有子模块定义
[ -f "$REPO_PATH/.gitmodules" ] && HAS_SUBMODULES=true || HAS_SUBMODULES=false
```

**根据深度和子模块存在情况分支处理**：

#### 情况 A：`REPO_DEPTH < MAX_DEPTH` 且 `HAS_SUBMODULES=true`

```bash
# 只初始化当前层的子模块（不加 --recursive，避免深层网络不通时卡死）
# 每层循环体各自负责初始化一层，整体效果等同于 --recursive
cd "$REPO_PATH"
git submodule update --init

# 获取当前层所有子模块信息
git submodule status
```

> ⚠️ 若某个子模块 clone 失败（网络受限 / 权限不足），在结果中记录「⚠️ [$submodule_name] 无法克隆，跳过子仓依赖分析」，**不中止整体分析**，继续处理其余子模块。

对每个**已成功初始化**的子模块，获取其信息后**递归调用本文件**：

```
输入：
  REPO_PATH   = <子模块绝对路径>
  REPO_NAME   = <子模块 displaypath>
  REPO_DEPTH  = $REPO_DEPTH + 1
  MAX_DEPTH   = $MAX_DEPTH

递归执行：Step 1 → Step 2 → Step 3 → Step 4 → Step 5 → Step 6
```

同时检查每个子模块的 ARM 兼容性（加载 `common-arm-probe.md` 即可，此处无需重复写命令）。

#### 情况 B：`REPO_DEPTH >= MAX_DEPTH`（已达最大深度）

```
记录：「[$REPO_NAME] 子模块嵌套深度已达上限（MAX_DEPTH=$MAX_DEPTH），跳过更深层子仓分析」
不再递归，直接进入 Step 6。
```

#### 情况 C：`HAS_SUBMODULES=false`

```
无子模块，直接进入 Step 6。
```

---

### Step 6：汇总并返回分析结果

将本仓库（及其子模块的递归结果）按以下结构汇总，供主编排文件聚合：

```
结果结构：
  repo_name:      $REPO_NAME
  repo_depth:     $REPO_DEPTH
  build_system:   Blade / Bazel / CMake / SCons / 未知
  deps_list:      [ { name, url/path, type, arm_status } ... ]
  binary_list:    [ { path, arch, source_trace_level, suggestion } ... ]
  submodule_results: [ <递归返回的子仓结果> ... ]
  warnings:       [ "⚠️ 子模块 xxx 无法克隆" ... ]
```

#### 子模块结果合并规则

子仓返回的结果，由主编排文件按以下规则合并到最终报告的对应章节，注明来源仓库：

| 子仓结果类型 | 合并到报告章节 | 注明来源方式 |
|------------|-------------|------------|
| `deps_list` 中的 Git 依赖 | 第 3 节「远端 Git 仓库依赖」 | 在备注栏标注「来自子模块 `$REPO_NAME`」 |
| `deps_list` 中的 HTTP 预编译包 | 第 4.2 节「预编译二进制包」 | 同上 |
| `deps_list` 中的 `find_package`/系统库 | 第 5 节「本地/系统依赖」 | 同上 |
| `binary_list` 中的内置 `.so`/`.a` | 第 6 节「仓库内置二进制」 | 同上 |

---

## 深度控制示意

```
analyze_repo(主仓, depth=0)
  ├─ 分析主仓依赖
  ├─ 扫描主仓二进制
  └─ 主仓有 .gitmodules → 初始化一层子模块
       ├─ analyze_repo(deps/xxx, depth=1)
       │    ├─ 分析 xxx 依赖（CMake）
       │    ├─ 扫描 xxx 二进制
       │    └─ xxx 有 .gitmodules → 初始化一层子模块
       │         ├─ analyze_repo(deps/xxx/third_party/absyyy, depth=2)
       │         │    ├─ 分析 absyyy 依赖
       │         │    ├─ 扫描 absyyy 二进制
       │         │    └─ absyyy 有 .gitmodules，但 depth=2 = MAX_DEPTH → 跳过
       │         └─ analyze_repo(deps/grpc/third_party/zzz, depth=2)
       │              └─ ... 同上，不再递归
       └─ analyze_repo(deps/internal-sdk, depth=1)
            └─ 分析 internal-sdk 依赖（Blade，构建系统与主仓不同）
```

> 每层调用本文件时，Step 1 独立检测该仓库的构建系统，**不依赖父仓的构建系统**，天然支持各层使用不同构建系统。
