---
name: sourcecode-build-verify
description: C/C++ 项目 ARM 迁移的阶段 5 子 Skill，专注于编译验证与循环修复环节。提供在 ARM（aarch64）环境循环执行编译的能力，提取关键错误，按两级查询（build-error-quickfix 速查表 → migration-cases 案例库）定位修复方案，修复后重试，直到编译成功或触发人工介入，处理代码仓权限问题、连续相同错误检测、最大重试次数（10 次）收尾。在作为 cpp-kunpeng-migration 主 Skill 的阶段 5 子 Skill 被调用时触发，当用户需要单独进行 ARM 编译验证、排查编译错误、或查询 ARM 迁移案例库时也应直接触发。适用于 C/C++ 项目的 x86→ARM（鲲鹏）架构迁移的编译验证。不适用于非 C/C++ 语言的 ARM 迁移、非鲲鹏架构的迁移。
---

# 阶段 5：编译验证与循环修复

本文档描述阶段 5 的完整执行步骤：循环执行 ARM 编译验证，分析编译错误，查阅案例库，修复后重试，直到编译成功或达到人工介入条件。

> **前置条件**：阶段 4 完成，DevKit 扫描问题已处理，构建配置已适配。

---

## 5.1 确定编译命令

在第一次编译前，根据构建系统类型确定正确的编译命令。

### Bazel 项目

```bash
# 确认架构
ARCH=$(uname -m)
echo "当前架构：$ARCH"

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

## 5.2 循环编译修复主流程

```
ATTEMPT = 1
MAX_ATTEMPTS = 10
last_error_hash = ""

while ATTEMPT <= MAX_ATTEMPTS:

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
        → 编译成功，跳到 5.8 收尾

    ┌─────────────────────────────────────────┐
    │  提取关键错误信息                       │
    └─────────────────────────────────────────┘

    current_errors = 5.3 节的错误提取方法
    current_error_hash = hash(current_errors)

    if current_error_hash == last_error_hash:
        → 连续相同错误，修复无效，跳到 5.7 人工介入

    last_error_hash = current_error_hash

    ┌─────────────────────────────────────────┐
    │  代码仓权限问题检测（特殊分支）         │
    └─────────────────────────────────────────┘

    if current_errors 命中代码仓权限问题关键字（见 5.2.1）:
        → 跳到 5.2.1 权限问题处理（向用户提问）
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

    每次执行第2级案例库查询时，必须在交互界面输出醒目标识（格式见 5.5 节），
       便于核验 skill 是否实际使用了案例库知识

    记录修复操作到 $WORK_DIR/reports/fix_history.txt

    if 判断无法自动修复:
        → 跳到 5.7 人工介入

    ATTEMPT += 1

if ATTEMPT > MAX_ATTEMPTS:
    → 跳到 5.7 人工介入
```

---

## 5.2.1 代码仓权限问题处理（向用户提问分支）

> **硬性约束**：遇到代码仓无权限访问时，**严禁在服务器其他目录查找相关代码仓**，**必须**向用户提问，由用户提供已下载好的代码仓路径。

### 权限错误关键字识别

编译日志中出现以下任一关键字时，判定为代码仓权限问题：

| 关键字 | 典型场景 |
|--------|---------|
| `Permission denied (publickey)` | SSH 密钥未授权 |
| `could not read Username` / `Authentication failed` | HTTPS 仓库鉴权失败 |
| `Access denied` / `Repository not found` | 无仓库访问权限 |
| `fatal: unable to access` + `403`/`401` | HTTP 鉴权失败 |
| `ERROR: error cloning` + 权限相关字样 | Bazel `git_repository` 拉取失败 |
| `fatal: could not clone` + 权限相关字样 | CMake `FetchContent` / submodule 拉取失败 |

```bash
# 权限错误检测命令
LOG_FILE="$WORK_DIR/logs/build_${ATTEMPT}.log"
PERM_ERR=$(grep -iE "Permission denied|could not read Username|Could not read from remote repository|Authentication failed|Access denied|Repository not found|unable to access.*(403|401)|error cloning|could not clone" "$LOG_FILE" | head -5)
if [ -n "$PERM_ERR" ]; then
    echo "检测到代码仓权限问题"
    echo "$PERM_ERR"
    # 进入下方提问流程
fi
```

### 向用户提问流程

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

### 用户提供路径后的处理

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

## 5.3 执行编译命令（详细）

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

echo "编译退出码：$BUILD_EXIT_CODE"
echo "日志：$LOG_FILE"
```

### 判断编译成功的标准

```bash
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    # 退出码 0，但需确认日志中无真实 error 行
    REAL_ERRORS=$(grep -cE "^ERROR |: error:|error: " $LOG_FILE 2>/dev/null || echo 0)
    if [ "$REAL_ERRORS" -eq 0 ]; then
        echo "编译成功（第 ${ATTEMPT} 次尝试）"
        # 进入 5.8 收尾
    else
        echo "退出码为 0 但日志中仍有 ${REAL_ERRORS} 条 error，继续分析"
    fi
fi
```

---

## 5.4 提取关键错误信息

每次编译失败后，使用以下命令提取关键错误：

```bash
LOG_FILE="$WORK_DIR/logs/build_${ATTEMPT}.log"

# 方法1：提取所有 error: 行（去除常见误报）
echo "--- 所有错误行 ---"
grep -n "error:\|ERROR:\|FAILED:" $LOG_FILE \
  | grep -v "^Binary\|Werror\|is error\|no error\|zero error" \
  | head -30

# 方法2：获取第一个错误的上下文（通常是根因）
echo "--- 第一个错误的上下文 ---"
FIRST_ERROR_LINE=$(grep -n ": error:" $LOG_FILE \
  | grep -v "Werror\|is error" | head -1 | cut -d: -f1)
if [ -n "$FIRST_ERROR_LINE" ]; then
    sed -n "$((FIRST_ERROR_LINE-5)),$((FIRST_ERROR_LINE+15))p" $LOG_FILE
fi

# 方法3：获取日志末尾（Bazel 的 FAILED 摘要通常在最后）
echo "--- 编译日志末尾 100 行 ---"
tail -100 $LOG_FILE

# 方法4：若有多个错误，按文件分组
echo "--- 错误文件分布 ---"
grep ": error:" $LOG_FILE | grep -v "Werror" \
  | awk -F':' '{print $1}' | sort | uniq -c | sort -rn | head -20
```

---

## 5.5 错误修复查询（两级）

> **修复优先级（两级查询）**：
> 1. **第1级 — 速查表**：查 [build-error-quickfix.md](references/build-error-quickfix.md)（扁平关键字表，扫描快）；命中则按「修复」列描述修复
> 2. **第2级 — 案例库**：速查表未命中时，查 [migration-cases/](references/migration-cases/) 案例库（结构化教案，详细兜底）；命中则按案例修复方法修复
>
> **醒目标识要求（强制）**：每次执行第2级案例库查询时，**必须**在 agent 交互界面输出醒目标识，便于核验 skill 是否实际使用了案例库知识。无论命中与否都要输出，格式如下：
>
> ```
> [案例库查询] 错误关键字：<从日志提取的关键字>
>    查询路由：<generic-index / version-index / project-index> → <generic-cases / version-cases / project-cases>
>    查询结果：<命中 GENERIC-XX / VERSION-XX / PROJECT-XX，将按案例修复> 或 <未命中，需人工介入或新增案例>
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
5. 命中 → 按案例修复方法执行；未命中 → 跳到 5.6 记录后进入 5.7 人工介入

> **类别判定速查**：
> - 错误含 x86 编译标志 / intrinsics 头文件 / 内联汇编 → **通用 ARM 适配系列**
> - 错误含依赖库版本 / ABI / 头文件版本不一致 → **版本兼容性系列**
> - 错误含部署 / manifest / so 路径 / 流水线 → **项目特有系列**
> - 不确定时三个路由索引都扫一遍

> **新增修复方法的归属**：速查表未覆盖的新错误，若修复方法具备通用性，应补录到 [migration-cases/](references/migration-cases/) 案例库（按通用/版本/项目系列格式新增案例并更新路由索引），而非扩充速查表——速查表仅承载扁平关键字映射，结构化教案归案例库。

---

## 5.6 记录修复历史

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

## 5.7 人工介入报告

当出现以下情况时，**停止自动修复**并输出人工介入报告：

**触发条件：**
- 连续两次编译出现完全相同的错误（修复无效）
- 已达到最大重试次数（10 次）
- 遇到无法自动判断的错误类型

**人工介入报告格式：**

```
自动修复已达到极限，需要人工介入

【当前编译错误（最近 50 行）】
<粘贴 $WORK_DIR/logs/build_N.log 末尾 50 行>

【错误分析】
- 错误类型：<类型，如"链接错误/头文件缺失/类型不兼容">
- 可能根因：<分析>
- 已排除的原因：<列出已尝试但无效的修复方向>

【已完成的修改清单（共 N 项）】
<文件路径>：<修改说明>

【已尝试的修复记录（共 N 次）】
第1次：<修复内容> → 结果：<下次编译的变化>
第2次：<修复内容> → 结果：<下次编译的变化>
...

【建议人工排查方向】
<基于错误类型的具体建议>

【相关文件路径】
- 工作目录：$WORK_DIR
- 最近编译日志：$WORK_DIR/logs/build_N.log
- 修复历史：$WORK_DIR/reports/fix_history.txt
- 修改清单：$WORK_DIR/reports/source_changes.txt
- DevKit 报告：$WORK_DIR/reports/devkit-<时间戳>/
```

---

## 5.8 编译成功后收尾

```bash
# 1. 清理临时 WORKSPACE（仅当由本 Skill 临时复制时才删除，避免误删项目原有文件）
WORKSPACE_COPIED_MARKER="$PROJECT_ROOT/.arm_migration_workspace_copied"
if [ -e "$WORKSPACE_COPIED_MARKER" ] && [ -e "$PROJECT_ROOT/WORKSPACE" ]; then
    rm "$PROJECT_ROOT/WORKSPACE"
    rm "$WORKSPACE_COPIED_MARKER"
    echo "临时 WORKSPACE 已清理"
fi

# 2. 保存最终修改清单
FINAL_CHANGES="$WORK_DIR/reports/final_changes_$(date +%Y%m%d).txt"
git -C $PROJECT_ROOT diff --stat 2>/dev/null > $FINAL_CHANGES
git -C $PROJECT_ROOT diff 2>/dev/null >> $FINAL_CHANGES
echo "修改清单已保存：$FINAL_CHANGES"

# 3. 记录成功信息
echo "ARM 编译成功（第 ${ATTEMPT} 次）：$(date)" >> $WORK_DIR/reports/build_summary.txt

# 4. 统计修改概要
echo "=== 修改概要 ==="
git -C $PROJECT_ROOT diff --stat 2>/dev/null | tail -5

# 5. 提示 x86 双架构验证
echo ""
echo " 请验证 x86 编译未被破坏："
echo "   在 x86 机器上执行以下命令之一："
echo "   - 方式1：使用项目的构建脚本（若已添加架构自动检测，在 x86 上会自动走 x86 路径）"
echo "   - 方式2：cd $PROJECT_ROOT && bazel build <target> --verbose_failures --config=linux_x86"

# 6. 引导进入阶段 6
echo ""
echo "阶段 5 完成，进入阶段 6：生成迁移总结报告"
echo "   报告将保存到 $WORK_DIR/reports/migration_summary_report.md"
```

---

## 5.9 快速检查清单

编译验证阶段完成后，确认以下所有项均已完成：

- [ ] 已确定正确的编译命令（含 --config=linux_aarch64 或等效参数）
- [ ] 第 1 次编译已执行，日志已保存到 `$WORK_DIR/logs/build_1.log`
- [ ] 若失败，已提取并分析关键错误信息
- [ ] 遇到代码仓权限问题时，已向用户提供本地路径（未在服务器其他目录查找代码仓）
- [ ] 已查询速查表 / migration-cases 案例库匹配已知问题（两级查询）
- [ ] 每次修复均已记录到 `fix_history.txt`
- [ ] 最终编译成功（退出码 0，无 `error:` 行）
- [ ] 临时 WORKSPACE 文件已清理
- [ ] 最终修改清单已保存
- [ ] 已提示进行 x86 双架构兼容性验证
- [ ] 已记录阶段 5 结束时间戳到 timeline.log
