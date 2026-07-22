---
name: sourcecode-build-verify
description: C/C++ 鲲鹏迁移的编译验证子 Skill。作为 cpp-kunpeng-migration 阶段 5 被调用，或用户需要在鲲鹏（aarch64）环境编译 C/C++ 项目、排查编译错误或查询鲲鹏迁移案例时使用。负责执行编译、提取关键错误，并依次查询 build-error-quickfix 速查表和 migration-cases 案例库完成修复与重试，直至编译成功。不负责前置环境准备、依赖分析和源码迁移扫描与适配。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
---

# 编译验证与循环修复功能描述
本阶段用于循环执行鲲鹏编译验证，分析编译错误，查阅案例库，修复后重试，直到编译成功。

**执行方式**：作为 cpp-kunpeng-migration 主 Skill 的阶段5 子 Skill 调用。

**前置条件**：阶段 4 完成，DevKit 扫描问题已处理，构建配置已适配。

**输入参数**：

本子 Skill 接收以下三个路径变量作为输入：

- `<项目绝对路径>` -> `PROJECT_ROOT`
- `<工作目录绝对路径>` -> `WORK_DIR`
- `<skill目录绝对路径>` -> `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

- `SKILL_DIR`：本 skill 自知（cpp-kunpeng-migration 目录 = 本子 skill 目录的上一层）。
- `PROJECT_ROOT`、`WORK_DIR`：主编排调用时由主编排传入；独立调用时优先从用户提示词取，未提供则向用户提问获取。

---

# 使用流程

## 1. 确定编译命令

在第一次编译前，先查阅项目的 README、`build.sh` 等构建脚本确定正确的编译命令，不要盲目猜测。根据构建系统类型，参考以下方式：

### Bazel 项目

```bash
# 确认架构
ARCH=$(uname -m)

# 确认 WORKSPACE 已切换到 arm（若 build.sh 不自动处理，手动切换）
# 仅在项目无 WORKSPACE 且存在 WORKSPACE_arm 时临时复制，避免误删项目原有 WORKSPACE
if [ ! -e "$PROJECT_ROOT/WORKSPACE" ] && [ -e "$PROJECT_ROOT/WORKSPACE_arm" ]; then
    cp $PROJECT_ROOT/WORKSPACE_arm $PROJECT_ROOT/WORKSPACE
fi

# 确认 software.sh 已运行（设置 PATH 中的 Bazel 路径）
cd $PROJECT_ROOT && source ./software.sh

# 确认 Bazel 可用
bazel version 2>&1 | head -3

# 编译命令（ARM 配置）
COMPILE_CMD="bazel build <主编译目标> --verbose_failures --config=linux_aarch64"

# 若使用 build.sh 封装，则
COMPILE_CMD="bash $PROJECT_ROOT/build.sh"
```

> **编译目标来源**：来自阶段 1 environment-prepare/SKILL.md 的检测结果（通常在 build.sh 中），或用户在阶段 3 确认的目标名。

### CMake 项目

```bash
BUILD_DIR=$WORK_DIR/build/cmake-aarch64
mkdir -p $BUILD_DIR

cmake -B $BUILD_DIR -S $PROJECT_ROOT \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DAUTO_SUBMODULE=OFF
# 注：-DAUTO_SUBMODULE=OFF 仅当项目按 dependency-analysis/references/build-systems.md（CMake 章节）「子模块自动签出检查」
# 改造了 AUTO_SUBMODULE 开关时才需要传；未改造的项目 cmake 会忽略未知 option 的警告。
# 作用：阻止 cmake 配置期 git submodule update 重置已钉定的 ARM 分支（见该文档第 1/2 步）。

COMPILE_CMD="cmake --build $BUILD_DIR -j$(nproc) 2>&1"
```

### Make 项目

```bash
COMPILE_CMD="cd $PROJECT_ROOT && make -j$(nproc) 2>&1"
```

### Blade 项目

```bash
# 确认 blade 可用（版本需 >= 3.0 以支持 arm64）
blade --version 2>/dev/null

COMPILE_CMD="cd $PROJECT_ROOT && blade build <目标> --toolchain-prefix=<prefix> 2>&1"
```

---

## 2. 循环编译修复主流程

```
ATTEMPT = 1

while true:

    ┌─────────────────────────────────────────┐
    │  执行编译，输出重定向到日志              │
    └─────────────────────────────────────────┘

    LOG_FILE = $WORK_DIR/logs/build_${ATTEMPT}.log
    执行 $COMPILE_CMD 并 tee 到 $LOG_FILE
    BUILD_EXIT_CODE = $?

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
    │  代码仓权限问题检测（特殊分支）         │
    └─────────────────────────────────────────┘

    if current_errors 命中代码仓权限问题关键字（见 2.1 节）:
        → 跳到 2.1 节权限问题处理（向用户提问）
        → 用户提供代码仓路径后，更新构建配置并继续编译
        → ATTEMPT += 1，继续循环

    ┌─────────────────────────────────────────┐
    │  分析错误并修复（两级查询）             │
    └─────────────────────────────────────────┘

    【第1级】查 build-error-quickfix.md 速查表
    路径：references/build-error-quickfix.md（扁平关键字表，扫描快）
    若速查表命中 → 按「修复」列描述修复

    【第2级】速查表未命中 → 查 migration-cases 案例库（详细兜底）
    路由：references/migration-cases/ 下 01/02/03 路由索引 → G/V/P-cases 案例库
    若案例库命中 → 按案例修复方法修复

    每次执行第2级案例库查询时，必须在交互界面输出醒目标识（格式见第 5 节），
       便于核验 skill 是否实际使用了案例库知识

    记录修复操作到 $WORK_DIR/reports/fix_history.txt

    ATTEMPT += 1
```

---

## 2.1. 代码仓权限问题处理（向用户提问分支）

> **硬性约束**：遇到代码仓无权限访问时，**严禁在服务器其他目录查找相关代码仓**，**必须**向用户提问，由用户提供已下载好的代码仓路径。

### 2.1.1. 权限错误关键字识别

编译日志中出现以下任一关键字时，判定为代码仓权限问题：

| 关键字 | 典型场景 |
|--------|---------|
| `Permission denied (publickey)` | SSH 密钥未授权 |
| `could not read Username` / `Authentication failed` | HTTPS 仓库鉴权失败 |
| `Access denied` / `Repository not found` | 无仓库访问权限 |
| `fatal: unable to access` + `403`/`401` | HTTP 鉴权失败 |
| `ERROR: error cloning` + 权限相关字样 | Bazel `git_repository` 拉取失败 |
| `fatal: could not clone` + 权限相关字样 | CMake `FetchContent` / submodule 拉取失败 |

### 2.1.2. 向用户提问流程

检测到权限问题后，**立即停止自动修复**，**必须**向用户提问：

```
question:
  header: "代码仓权限"
  question: "编译过程中检测到代码仓 <仓库名/URL> 无访问权限（错误：<错误摘要>）。请提供已下载好的代码仓本地路径，或选择处理方式："
  options:
    - label: "提供本地路径"
      description: "我已在本地下载好该代码仓，将在后续提供路径"
    - label: "跳过该依赖"
      description: "暂不处理该依赖，继续编译其他目标（可能导致后续链接错误）"
    - label: "中止迁移"
      description: "中止整个迁移流程"
  multiSelect: false
```

### 2.1.3. 用户提供路径后的处理

1. **校验路径**：确认用户提供的路径存在且包含代码仓内容（检查 `.git` 目录或关键文件如 `CMakeLists.txt` / `WORKSPACE` / `Makefile`）
2. **更新构建配置**：将构建配置中该依赖的远程仓库引用替换为本地路径
   - **Bazel**：`git_repository` → `local_repository`，或修改 `url` 为 `file://` 本地路径
   - **CMake**：`FetchContent_Declare` 的 `GIT_REPOSITORY` + `GIT_TAG` → `SOURCE_DIR` 本地路径
   - **Make/Blade/SCons**：更新依赖路径变量指向本地目录
3. **记录到修复历史**：在 `$WORK_DIR/reports/fix_history.txt` 记录权限问题、用户提供的路径、配置变更
4. **继续编译循环**：`ATTEMPT += 1`，重新执行编译

> **禁止行为**：
> - **不得**在服务器 `/home`、`/tmp`、`/opt` 等其他目录搜索同名代码仓
> - **不得**尝试修改 SSH 密钥或 git credentials 配置以绕过权限
> - **不得**跳过权限问题继续编译（会导致后续链接错误更难排查）

---

## 3. 执行编译命令（详细）

```bash
ATTEMPT=1  # 每次循环递增

LOG_FILE="$WORK_DIR/logs/build_${ATTEMPT}.log"
mkdir -p $WORK_DIR/logs

echo "=== 第 ${ATTEMPT} 次编译 [$(date)] ===" | tee -a $WORK_DIR/reports/fix_history.txt

# 执行编译（Bazel 示例）
cd $PROJECT_ROOT

# 确保 WORKSPACE 已就位（仅在项目无 WORKSPACE 且存在 WORKSPACE_arm 时临时复制）
WORKSPACE_COPIED_MARKER="$PROJECT_ROOT/.arm_migration_workspace_copied"
if [ ! -e "WORKSPACE" ] && [ -e "WORKSPACE_arm" ]; then
    cp WORKSPACE_arm WORKSPACE
    touch "$WORKSPACE_COPIED_MARKER"
fi

source ./software.sh  # 确保 Bazel PATH 已设置

bazel build <主目标> \
  --verbose_failures \
  --config=linux_aarch64 \
  2>&1 | tee $LOG_FILE

BUILD_EXIT_CODE=${PIPESTATUS[0]}

# 仅清理本次临时复制的 WORKSPACE
if [ -e "$WORKSPACE_COPIED_MARKER" ]; then
    [ -e "WORKSPACE" ] && rm WORKSPACE
    rm "$WORKSPACE_COPIED_MARKER"
fi
```

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
# 1. 清理临时 WORKSPACE（仅当由本 Skill 临时复制时才删除，避免误删项目原有文件）
WORKSPACE_COPIED_MARKER="$PROJECT_ROOT/.arm_migration_workspace_copied"
if [ -e "$WORKSPACE_COPIED_MARKER" ] && [ -e "$PROJECT_ROOT/WORKSPACE" ]; then
    rm "$PROJECT_ROOT/WORKSPACE"
    rm "$WORKSPACE_COPIED_MARKER"
fi

# 2. 记录成功信息到 build_summary.txt
echo "ARM 编译成功（第 ${ATTEMPT} 次）：$(date)" >> $WORK_DIR/reports/build_summary.txt
```

编译成功后还需向用户提示：

- **x86 双架构验证**：提示用户在 x86 机器上验证编译未被破坏--方式1 用项目构建脚本（若已加架构自动检测，x86 上自动走 x86 路径），方式2 执行 `cd $PROJECT_ROOT && bazel build <target> --verbose_failures --config=linux_x86`。

---

## 8. 快速检查清单

编译验证阶段完成后，确认以下所有项均已完成：

- [ ] 已确定正确的编译命令（含 --config=linux_aarch64 或等效参数）
- [ ] 第 1 次编译已执行，日志已保存到 `$WORK_DIR/logs/build_1.log`
- [ ] 若失败，已提取并分析关键错误信息
- [ ] 遇到代码仓权限问题时，已向用户提供本地路径（未在服务器其他目录查找代码仓）
- [ ] 已查询速查表 / migration-cases 案例库匹配已知问题（两级查询）
- [ ] 每次修复均已记录到 `fix_history.txt`
- [ ] 最终编译成功（退出码 0，无 `error:` 行）
- [ ] 临时 WORKSPACE 文件已清理
- [ ] 已提示进行 x86 双架构兼容性验证
- [ ] 已记录阶段 5 结束时间戳到 timeline.log
