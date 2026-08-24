# 阶段 5：编译验证与循环修复
本阶段用于循环执行鲲鹏编译验证，分析编译错误，查阅案例库，修复后重试，直到编译成功。

**执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段5 子 Skill 调用。

**前置条件**：阶段 4 完成，DevKit 扫描问题已处理，构建配置已适配。

**输入参数**：

本子 Skill 接收以下三个路径变量作为输入：

- `<项目绝对路径>` -> `PROJECT_ROOT`
- `<工作目录绝对路径>` -> `WORK_DIR`
- `<skill目录绝对路径>` -> `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

- `SKILL_DIR`：本 skill 自知（cpp-kunpeng-migration 目录 = 本子 skill 目录的上一层）。
- `PROJECT_ROOT`、`WORK_DIR`：主 agent 调用时由主 agent 传入；独立调用时优先从用户提示词取，未提供则向用户提问获取。

---

# 使用流程

## 1. 确定编译命令

在第一次编译前，先查阅项目的 README、`build.sh` 等构建脚本确定正确的编译命令，不要盲目猜测。阶段 1 已识别构建系统类型，按类型确定 `COMPILE_CMD`（执行见第 3 节）。

---

## 2. 循环编译修复主流程

```
ATTEMPT = 1

while true:

    ┌─────────────────────────────────────────┐
    │  执行编译，输出重定向到日志              │
    └─────────────────────────────────────────┘

    执行编译命令并将输出保存到 $WORK_DIR/logs/build_${ATTEMPT}.log，
    通过执行工具获取编译命令自身的退出码判断成败

    ┌─────────────────────────────────────────┐
    │  判断编译结果                           │
    └─────────────────────────────────────────┘

    if BUILD_EXIT_CODE == 0 && 日志中无 "error:" 行:
        → 编译成功，跳到第 7 节收尾

    ┌─────────────────────────────────────────┐
    │  提取关键错误信息                       │
    └─────────────────────────────────────────┘

    current_errors = 第 4 节的错误提取方法

    ┌─────────────────────────────────────────┐
    │  阻塞性问题检测（特殊分支）             │
    └─────────────────────────────────────────┘

    if current_errors 命中阻塞性问题关键字（代码仓权限 / 依赖版本严重不符 / 编译环境严重不符，见 2.1 节）:
        → 跳到 2.1 节阻塞性问题处理（向用户提问）
        → 用户提供处理方案后，更新配置并继续编译
        → ATTEMPT += 1，继续循环

    ┌─────────────────────────────────────────┐
    │  分析错误并修复（两级查询）             │
    └─────────────────────────────────────────┘

    【第1级】查 build-error-quickfix.md 速查表
    路径：references/build-error-quickfix.md（扁平关键字表，扫描快）
    若速查表命中 → 按「修复」列描述修复

    【第2级】速查表未命中 → 查 migration-cases 案例库（详细兜底）
    路由：references/migration-cases/ 下 generic-kunpeng-migration-index / version-compatibility-index / project-specific-index → 对应 cases 案例库
    若案例库命中 → 按案例修复方法修复

    每次执行第2级案例库查询时，必须在交互界面输出醒目标识（格式见第 5 节），
       便于核验 skill 是否实际使用了案例库知识

    记录修复操作到 $WORK_DIR/reports/fix_history.txt

    ATTEMPT += 1
```

---

## 2.1. 阻塞性问题处理（向用户提问分支）

> **硬性约束**：以下三类问题**无法通过速查表/案例库自动修复**，遇到时必须**停止自动修复**、**向用户提问**：
> 1. **代码仓权限问题**：远程仓库无访问权限
> 2. **依赖库版本严重不符**：项目需求版本与可获取版本存在破坏性差异（ABI/API 不兼容）
> 3. **编译环境严重不符**：编译器/工具链/系统库与项目要求严重不匹配，无法在当次编译中自动兼容

### 2.1.1. 阻塞性问题关键字识别

编译日志中出现以下任一关键字时，判定为阻塞性问题，进入提问分支：

| 场景 | 关键字 | 典型场景 |
|------|--------|---------|
| 权限 | `Permission denied (publickey)` | SSH 密钥未授权 |
| 权限 | `Authentication failed` / `could not read Username` | HTTPS 仓库鉴权失败 |
| 权限 | `Access denied` / `Repository not found` | 无仓库访问权限 |
| 权限 | `403`/`401`、`error cloning`、`could not clone` | HTTP 鉴权失败或克隆拉取失败 |
| 版本不符 | `undefined reference to` + `@GLIBCXX`/`@CXXABI` | ABI 不兼容，库版本与编译器/项目不符 |
| 版本不符 | `version 'GLIBCXX_3.4.x' not found` | 依赖库要求更高版本系统库 |
| 版本不符 | `No rule to make target` / `not found` + 库版本号 | 找不到匹配版本的依赖 |
| 环境不符 | `unsupported GNU version` / `compiler too old` | 编译器版本低于项目要求 |
| 环境不符 | `unrecognized command line option` / `-std=c++17 not supported` | 编译器不支持项目所用标准/选项 |
| 环境不符 | `fatal error: 'xxx' file not found` + 系统级头文件 | 系统库/工具链缺失或版本过旧 |

### 2.1.2. 向用户提问流程

检测到阻塞性问题后，**立即停止自动修复**，**必须**向用户提问，使用统一模板（`<问题类型>` 填 代码仓权限 / 依赖版本不符 / 编译环境不符）：

```
question:
  header: "阻塞性问题"
  question: "编译过程中检测到<问题类型>：<错误摘要>。请提供所需资源，或选择处理方式："
  options:
    - label: "提供本地路径"
      description: "请通过自定义输入（Other）填写所需本地路径（代码仓 / 匹配版本依赖库 / 工具链）"
    - label: "调整到环境可用"
      description: "允许按环境现有资源调整构建配置或源码兼容点（改动需架构宏保护）"
    - label: "跳过该依赖"
      description: "暂不处理该依赖，继续编译其他目标（可能导致后续链接错误）"
  multiSelect: false
```

> 用户选择「提供本地路径」后，通过提问工具的**自定义输入（Other）**填写具体路径，子 agent 收到后按 2.1.3 校验并使用。
> 「跳过该依赖」仅适用于代码仓权限 / 依赖版本不符场景；编译环境不符场景无此选项。

### 2.1.3. 用户回复后的处理

1. **场景 1：校验路径**：确认用户提供的路径存在且包含代码仓内容（检查 `.git` 目录或关键文件如 `CMakeLists.txt` / `WORKSPACE` / `Makefile`），然后更新构建配置：
   - **Bazel**：`git_repository` → `local_repository`，或修改 `url` 为 `file://` 本地路径
   - **CMake**：`FetchContent_Declare` 的 `GIT_REPOSITORY` + `GIT_TAG` → `SOURCE_DIR` 本地路径
   - **Make/Blade/SCons**：更新依赖路径变量指向本地目录
2. **场景 2：按用户选择处理**：提供匹配版本库则校验路径并更新构建配置指向该版本；允许调整到环境可用版本则修改构建配置/源码兼容点（改动需架构宏保护）
3. **场景 3：按用户选择处理**：提供工具链路径则更新 `CC`/`CXX`/`PATH` 等环境变量指向该工具链；用户自行处理则等待用户完成环境修复后继续
4. **记录到修复历史**：在 `$WORK_DIR/reports/fix_history.txt` 记录阻塞性问题类型、用户提供的路径/方案、配置变更
5. **继续编译循环**：`ATTEMPT += 1`，重新执行编译

> **禁止行为**：
> - **不得**尝试修改 SSH 密钥或 git credentials 配置以绕过权限
> - **不得**跳过阻塞性问题继续编译（会导致后续链接错误更难排查）
> - **不得**在依赖库版本不匹配、API 函数不存在时自行构造 API 绕过（如手写同名函数、伪造库接口），必须按用户选择处理或询问用户

---

## 3. 执行编译命令

执行第 1 节确定的 $COMPILE_CMD，输出 tee 到日志 $WORK_DIR/logs/build_${ATTEMPT}.log，捕获退出码用于判断。

### 判断编译成功的标准

退出码为 0 且日志中无真实 `error:` 行才算成功（部分构建系统即使编译失败也返回 0，故需双重判断）：

```bash
REAL_ERRORS=$(grep -cE "^ERROR |: error:|error: " $LOG_FILE 2>/dev/null || echo 0)
# BUILD_EXIT_CODE -eq 0 且 REAL_ERRORS -eq 0 -> 编译成功，进入第 7 节收尾
# 否则进入第 4 节提取错误、第 5 节修复
```

---

## 4. 提取关键错误信息

每次编译失败后，从 `$WORK_DIR/logs/build_${ATTEMPT}.log` 提取关键错误。日志可能很大，不要整篇读，按以下策略定位：

- **第一个 `: error:` 通常是根因**：后续错误常是连锁反应。定位第一个错误行，看其前后上下文（错误往往由上一行引起）。
- **Bazel 的 FAILED 摘要在日志末尾**：Bazel 会在最后汇总失败目标和原因，看末尾即可拿到概览。
- **多错误按文件分组找热点**：报错最集中的文件往往是根因所在。
- **过滤误报**：`-Werror` 升级、含 `is error`/`no error`/`zero error` 的描述性文字不是真实错误，提取时排除。
- **退出码为 0 也要查**：部分构建系统即使编译失败也返回 0，最终靠日志里的 `error:` 行判断（见第 3 节）。

---

## 5. 错误修复查询（两级）

> **修复优先级（两级查询）**：
> 1. **第1级 — 速查表**：查 [build-error-quickfix.md](references/build-error-quickfix.md)（扁平关键字表，扫描快）；命中则按「修复」列描述修复
> 2. **第2级 — 案例库**：速查表未命中时，查 [migration-cases/](references/migration-cases/) 案例库（结构化教案，详细兜底）；命中则按案例修复方法修复
>
> **醒目标识要求（强制）**：每次执行第2级案例库查询时，**必须**在 agent 交互界面输出醒目标识，便于核验 skill 是否实际使用了案例库知识。无论命中与否都要输出，格式如下：
>
> ```
> [案例库查询] 错误关键字：<从日志提取的关键字>
>    查询路由：<generic-index / version-index / project-index> → <generic-cases / version-cases / project-cases>
>    查询结果：<命中 GENERIC-XX / VERSION-XX / PROJECT-XX，将按案例修复> 或 <未命中，尝试推理修复>
> ```

### 第1级：速查表

速查表已独立为 [build-error-quickfix.md](references/build-error-quickfix.md)，按错误类别分表（头文件 / 类型符号 / 链接 / Bazel / 编译严格性），扁平关键字匹配，扫描快。命中即按「修复」列描述修复，未命中进入第2级。

### 第2级：案例库路由查询流程

案例库位于 `references/migration-cases/`，按错误类别分三系列，每系列有「路由索引 + 案例库」两文件：

| 系列 | 路由索引文件 | 案例库文件 | 适用错误 |
|------|------------|----------|---------|
| 通用 ARM 适配 | [generic-kunpeng-migration-index.md](references/migration-cases/generic-kunpeng-migration-index.md) | [generic-kunpeng-migration-cases.md](references/migration-cases/generic-kunpeng-migration-cases.md) | 通用 ARM 适配（编译标志、intrinsics、头文件等架构无关问题） |
| 版本兼容性 | [version-compatibility-index.md](references/migration-cases/version-compatibility-index.md) | [version-compatibility-cases.md](references/migration-cases/version-compatibility-cases.md) | 版本兼容性（依赖库版本冲突、ABI 不匹配、头文件版本不一致） |
| 项目特有 | [project-specific-index.md](references/migration-cases/project-specific-index.md) | [project-specific-cases.md](references/migration-cases/project-specific-cases.md) | 项目特有（部署流水线、manifest、so 路径等项目级问题） |

**查询步骤**：

1. 从编译错误日志（`$WORK_DIR/logs/build_<N>.log`）提取关键字（如 `immintrin.h not found`、`File in wrong format`、`undefined reference`）
2. 按错误类别选路由索引文件，扫描「摘要」列匹配关键字 → 定位案例 ID（如 `GENERIC-01`）
3. 跳到对应案例库文件，按 ID 查看完整修复方法（错误现象 / 根因 / 修复方法 / 验证方式）
4. **输出醒目标识**（见上方格式），命中与否都要输出
5. 命中 → 按案例修复方法执行；未命中 → 基于错误信息与 ARM 迁移知识推理修复，继续循环

> **类别判定速查**：
> - 错误含 x86 编译标志 / intrinsics 头文件 / 内联汇编 → **通用 ARM 适配系列**
> - 错误含依赖库版本 / ABI / 头文件版本不一致 → **版本兼容性系列**
> - 错误含部署 / manifest / so 路径 / 流水线 → **项目特有系列**
> - 不确定时三个路由索引都扫一遍

> **新增修复方法的归属**：速查表未覆盖的新错误，若修复方法具备通用性，应补录到 [migration-cases/](references/migration-cases/) 案例库（按通用/版本/项目系列格式新增案例并更新路由索引），而非扩充速查表——速查表仅承载扁平关键字映射，结构化教案归案例库。

---

## 6. 记录修复历史

每次修复后，立即追加记录到修复历史文件：

```bash
FIX_LOG="$WORK_DIR/reports/fix_history.txt"

cat >> $FIX_LOG << EOF
=== 第 ${ATTEMPT} 次尝试 ===
时间：$(date)
错误摘要：<错误类型，如 "immintrin.h not found in xxx.cpp">
错误根因：<根因分析，如 "x86 头文件未用架构宏保护">
修复操作：<具体修改，如 "在 src/util/simd.cpp:23 前后添加 #if defined(__x86_64__) 宏">
参考案例：<速查表表名 / migration-cases 案例ID（如 G-01），若有>
修改文件：<文件路径>
修改范围：<行号>

EOF
```

---

## 7. 编译成功后收尾

```bash
# 记录成功信息到 build_summary.txt
echo "ARM 编译成功（第 ${ATTEMPT} 次）：$(date)" >> $WORK_DIR/reports/build_summary.txt
```

编译成功后还需向用户提示：

- **x86 双架构验证**：提示用户在 x86 机器上验证编译未被破坏--方式1 用项目构建脚本（若已加架构自动检测，x86 上自动走 x86 路径）。

---

## 8. 快速检查清单

编译验证阶段完成后，确认以下所有项均已完成：

- [ ] 已确定正确的编译命令（含 --config=linux_aarch64 或等效参数）
- [ ] 第 1 次编译已执行，日志已保存到 `$WORK_DIR/logs/build_1.log`
- [ ] 若失败，已提取并分析关键错误信息
- [ ] 遇到代码仓权限问题时，已向用户提供本地路径
- [ ] 已查询速查表 / migration-cases 案例库匹配已知问题（两级查询）
- [ ] 每次修复均已记录到 `fix_history.txt`
- [ ] 最终编译成功（退出码 0，无 `error:` 行）
- [ ] 已提示进行 x86 双架构兼容性验证
- [ ] 已记录阶段 5 结束时间戳到 timeline.log
