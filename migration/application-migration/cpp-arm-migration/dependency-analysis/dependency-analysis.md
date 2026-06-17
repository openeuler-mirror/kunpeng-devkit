
# C++ 项目依赖分析（主编排）

支持以下 C++ 构建系统的依赖分析：

| 系统 | 关键文件 | 依赖声明方式 |
|------|----------|-------------|
| **Bazel** | `WORKSPACE`, `*.BUILD` | `http_archive`, `git_repository`, `new_local_repository` |
| **CMake** | `CMakeLists.txt`, `cmake/*.cmake` | `FetchContent_Declare`, `ExternalProject_Add`, `find_package` |
| **Blade** | `BLADE_ROOT`, `BUILD`（每个目录） | `cc_library(prebuilt=1)`, `deps=[//thirdparty/...]`, `#系统库` |
| **SCons** | `SConstruct`, `SConscript` | `Program()`, `SharedLibrary()`, `env.Library()` |
| **Git Submodule** | `.gitmodules` | `[submodule]` |
| **手动脚本** | `*.sh`（`wget`/`curl`） | 直接下载 URL |
| **系统包管理** | `*.sh`（`yum`/`apt`） | `yum install`, `apt-get install` |

---

## 模块架构

本目录按职责拆分为以下文件，各司其职：

| 文件 | 职责 |
|------|------|
| **本文件** | 全局编排：免检清单读取、驱动主循环、聚合结果、生成报告 |
| [analyze-one-repo.md](analyze-one-repo.md) | **单仓库分析闭环**：检测构建系统 → 分发依赖扫描 → 调用通用模块 → 递归子模块 |
| [common-arm-probe.md](common-arm-probe.md) | 通用共享：私有URL判断、远端分支检查、提交历史检查、免检清单比对 |
| [common-binary-detect.md](common-binary-detect.md) | 通用共享：预编译二进制扫描、架构判断、四级源码溯源、截断策略 |
| [dependency-analysis-bazel.md](dependency-analysis-bazel.md) | Bazel 专用：WORKSPACE 依赖扫描、`http_archive` 预编译包识别 |
| [dependency-analysis-cmake.md](dependency-analysis-cmake.md) | CMake 专用：`FetchContent`/`ExternalProject_Add`/`find_package` 扫描、ABI=0 工具链、子模块自动签出检查 |
| [dependency-analysis-blade.md](dependency-analysis-blade.md) | Blade 专用：thirdparty 组件扫描、BUILD/BUILD.x86 双架构分离、ARM 库查找路径 |
| [dependency-analysis-scons.md](dependency-analysis-scons.md) | SCons 专用：x86 编译标志检查、Python 版本兼容性 |
| [arm-confirmed-write.md](arm-confirmed-write.md) | 阶段 C/D：写入 ARM 确认清单、执行真实切换操作 |
| [dependency-analysis-report-template-example.md](dependency-analysis-report-template-example.md) | 报告输出模板示例 |

---

## 主流程

### 第一步：从环境检测报告读取构建系统

> **从阶段 A 环境检测报告中读取**，不再重复检测。

```bash
REPORT="$WORK_DIR/reports/environment_check_report.md"
cat "$REPORT"
```

> ⚠️ **若环境检测报告不存在**（用户跳过阶段 A 直接执行阶段 B），则回退到自行检测：
> ```bash
> find <项目根目录> -maxdepth 3 \
>   \( -name "WORKSPACE" -o -name "CMakeLists.txt" \
>   -o -name "BLADE_ROOT" -o -name "SConstruct" \
>   -o -name ".gitmodules" -o -name "*.sh" \) | sort
> ```

---

### 第二步：读取免检清单（全局去重）

**在启动任何仓库分析之前**，先读取全局免检清单，避免对已确认兼容的依赖重复探测：

```bash
cat "<cpp-arm-migration skill目录>/arm_confirmed.md" 2>/dev/null
```

将免检清单的内容缓存在上下文中，供后续每次调用 [common-arm-probe.md](common-arm-probe.md) 时使用（Section 5 比对）。

> ✅ **在清单中命中（依赖库名 + 项目当前引用版本匹配到 ARM 适配行）的依赖，在整个报告的所有章节中完全省略**；命中时把该行的 ARM 分支/commit/URL/备注记下供阶段 C 末尾切换，不再探测、不再询问用户。

---

### 第三步：主循环 — 递归分析所有仓库

加载 [analyze-one-repo.md](analyze-one-repo.md)，对**主仓库**执行完整分析：

```
输入：
  REPO_PATH  = <项目根目录绝对路径>
  REPO_NAME  = <项目名>
  REPO_DEPTH = 0
  MAX_DEPTH  = 2

执行：analyze-one-repo.md（Step 1 → Step 2 → Step 3 → Step 4 → Step 5 → Step 6）
```

`analyze-one-repo.md` 内部会自动：
- 检测主仓构建系统，加载对应专用分析文件
- 调用 [common-arm-probe.md](common-arm-probe.md) 执行 ARM 兼容性探测
- 调用 [common-binary-detect.md](common-binary-detect.md) 执行预编译二进制识别与溯源
- 递归处理所有子模块（最多 `MAX_DEPTH` 层），每个子仓**独立检测构建系统**

最终返回包含所有层级信息的结构化结果，用于第四步聚合。

---

### 第四步：生成报告（写入文件 + 输出到客户端）

> **输出方式**：报告以 Markdown 格式**写入** `$WORK_DIR/reports/dependency_analysis_<项目名>.md`，同时将完整内容**输出到客户端对话界面**。
>
> ```bash
> # 报告写入路径
> REPORT_FILE="$WORK_DIR/reports/dependency_analysis_<项目名>.md"
> # 使用 write 工具将报告内容写入该路径
> ```

#### 报告精简原则

以下情况判定为「必定兼容」，从整个报告的所有章节中**完全省略**：

| 判定条件 | 说明 |
|----------|------|
| `arm_confirmed.md` 命中（依赖库 + 当前版本匹配到 ARM 适配行） | 已知 ARM 适配，从报告省略；ARM 分支供阶段 C 末尾切换 |
| 开源库源码已内嵌于仓库（`deps/`/`third_party/` 目录），且无 x86 专有汇编或平台宏 | 有完整 C/C++ 源码，直接重编译即可 |
| 系统通用包（gflags、zlib、openssl、lz4、zstd、curl、leveldb、pthread 等）通过 `find_package`/`yum`/`apt` 安装 | 主流 Linux ARM 发行版均有对应包 |
| 仓库内置二进制确认全部为**测试数据**（仅被测试框架引用，不链接进生产代码） | 不影响移植 |
| 通用跨平台工具脚本（Perl/Python 脚本，如 lcov）确认无二进制依赖 | 脚本类工具无架构绑定 |

**只要符合上述任意一条，对应依赖在报告的所有章节中完全不出现。**

#### 报告末尾必须输出「待用户手动确认清单」

**只要存在任何待确认项，此章节不可省略**：

```markdown
## ⚠️ 待用户手动确认清单

> 🚀 **移植提速建议：优先推动私有子仓库完成 ARM 适配，再编译主仓库**
>
> 当项目存在私有仓库依赖时，应优先联系各子仓库维护团队完成 ARM 适配并发布稳定版本，
> 主仓库只需更新构建配置中对应的版本号即可直接构建，无需在主仓库侧做任何代码改动。

以下依赖为**私有地址**且**未发现任何 ARM 兼容性证据**，请逐条确认：

- [ ] `<依赖名>` (`<url>`) — 未发现 ARM 分支或相关提交历史，请确认该库是否兼容 ARM/aarch64
- [ ] `<依赖名>` (`<url>`) — 预编译二进制，架构未知，请提供 ARM 版本或源码
```

> 强制要求：
> - 所有 🔴 标记的依赖**必须**出现在此清单中
> - 「配置与 `arm_confirmed.md` 不一致」的依赖也**必须**在此清单中提示
> - 建议按依赖深度标注优先级（P0 = 基础通信/IO 库，P1 = 核心基础设施客户端，P2 = 通用工具类库）

#### 报告模板

见 [dependency-analysis-report-template-example.md](dependency-analysis-report-template-example.md)。

---

## 用户确认后写入清单并在阶段 C 末尾切换分支

依赖的 ARM 适配信息有两条来源，都按 [arm-confirmed-write.md](arm-confirmed-write.md) 处理：

- **阶段 B 命中清单**的依赖（common-arm-probe.md Section 5 已查到 ARM 适配行）：无需用户再确认，直接把命中的 ARM 分支/commit 纳入阶段 C 末尾的待切换清单
- **阶段 C 用户新确认**的依赖（清单中无记录、探测后由用户提供 ARM 分支/包路径）：登记到 `arm_confirmed.md`

**阶段 C 末尾（登记 + 确认切换 + 校验，一次性完成）**：
1. **登记**：在 `arm_confirmed.md` 中按**依赖库名**找到或新建区块（`## <依赖库名>`，不按主仓、不写全局配置），追加一行（匹配键填「项目当前引用版本」，来源项目填当前主仓名）
2. **确认切换**：把待切换清单逐项调用 `AskUserQuestion` 让用户确认后，立即把构建配置分支/commit/URL 切换为清单记录的 ARM 版本（回迁 thirdparty_arm、修改 WORKSPACE、切换子模块分支等）
3. **校验**：逐项核对分支是否真切到 ARM 版，再进入阶段 D

---

## 全局注意事项

- **子仓库优先适配策略**：存在私有仓库依赖时，明确提示用户优先推动这些子仓库完成 ARM 适配；子仓库适配完成后，主仓库只需修改构建配置中的版本号，可显著降低整体移植成本
- **子仓库协调优先级**：基础通信/IO 库（P0）> 核心基础设施客户端库（P1）> 业务模块专用 SDK（P2）> 通用工具类库（P3）
- **最大分析深度**：默认 `MAX_DEPTH=2`（主仓 depth=0，直接子模块 depth=1，子仓的子仓 depth=2），超过此深度注明「超过最大分析深度，跳过」
- **开源判定豁免**：`github.com`/`gitlab.com` 等公开平台的依赖默认跳过 ARM 检查，但若版本超过 2 年未更新仍建议确认
- **私有对象存储地址**（如组织内部 S3/OSS）：需要在私有网络环境中访问，报告中需注明
- **输出方式**：报告以 Markdown 格式写入 `$WORK_DIR/reports/dependency_analysis_<项目名>.md`，同时输出到客户端对话界面
