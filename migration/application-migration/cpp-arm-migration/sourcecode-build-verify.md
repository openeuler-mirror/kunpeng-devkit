# 阶段 E：编译验证与循环修复

本文档描述阶段 E 的完整执行步骤：循环执行 ARM 编译验证，分析编译错误，查阅案例库，修复后重试，直到编译成功或达到人工介入条件。

> **前置条件**：阶段 D 完成，DevKit 扫描问题已处理，构建配置已适配。

---

## E.1 确定编译命令

在第一次编译前，根据构建系统类型确定正确的编译命令。

### Bazel 项目

```bash
# 确认架构
ARCH=$(uname -m)
echo "当前架构：$ARCH"

# 确认 WORKSPACE 已切换到 arm（若 build.sh 不自动处理，手动切换）
[ ! -e "$PROJECT_ROOT/WORKSPACE" ] && cp $PROJECT_ROOT/WORKSPACE_arm $PROJECT_ROOT/WORKSPACE

# 确认 software.sh 已运行（设置 PATH 中的 Bazel 路径）
cd $PROJECT_ROOT && source ./software.sh

# 确认 Bazel 可用
bazel version 2>&1 | head -3

# 编译命令（ARM 配置）
COMPILE_CMD="bazel build <主编译目标> --verbose_failures --config=linux_aarch64"

# 若使用 build.sh 封装，则
COMPILE_CMD="bash $PROJECT_ROOT/build.sh"
```

> **编译目标来源**：来自阶段 A environment-prepare.md 的检测结果（通常在 build.sh 中），或用户在阶段 C 确认的目标名。

### CMake 项目

```bash
BUILD_DIR=$WORK_DIR/build/cmake-aarch64
mkdir -p $BUILD_DIR

cmake -B $BUILD_DIR -S $PROJECT_ROOT \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSTEM_NAME=Linux

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

## E.2 循环编译修复主流程

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
        → ✅ 编译成功，跳到 E.5 收尾

    ┌─────────────────────────────────────────┐
    │  提取关键错误信息                       │
    └─────────────────────────────────────────┘

    current_errors = E.3 节的错误提取方法
    current_error_hash = hash(current_errors)

    if current_error_hash == last_error_hash:
        → ⛔ 连续相同错误，修复无效，跳到 E.6 人工介入

    last_error_hash = current_error_hash

    ┌─────────────────────────────────────────┐
    │  分析错误并修复（两级查询）             │
    └─────────────────────────────────────────┘

    【第1级】查 build-error-quickfix.md 速查表
    路径：$SKILL_DIR/build-error-quickfix.md（扁平关键字表，扫描快）
    若速查表命中 → 按「修复」列描述修复

    【第2级】速查表未命中 → 查 migration-cases 案例库（详细兜底）
    路由：$SKILL_DIR/migration-cases/ 下 01/02/03 路由索引 → G/V/P-cases 案例库
    若案例库命中 → 按案例修复方法修复

    ⚠️ 每次执行第2级案例库查询时，必须在交互界面输出醒目标识（格式见 E.5 节），
       便于核验 skill 是否实际使用了案例库知识

    记录修复操作到 $WORK_DIR/reports/fix_history.txt

    if 判断无法自动修复:
        → ⛔ 跳到 E.6 人工介入

    ATTEMPT += 1

if ATTEMPT > MAX_ATTEMPTS:
    → ⛔ 跳到 E.6 人工介入
```

---

## E.3 执行编译命令（详细）

```bash
ATTEMPT=1  # 每次循环递增

LOG_FILE="$WORK_DIR/logs/build_${ATTEMPT}.log"
mkdir -p $WORK_DIR/logs

echo "=== 第 ${ATTEMPT} 次编译 [$(date)] ===" | tee -a $WORK_DIR/reports/fix_history.txt

# 执行编译（Bazel 示例）
cd $PROJECT_ROOT

# 确保 WORKSPACE 已就位
[ ! -e "WORKSPACE" ] && cp WORKSPACE_arm WORKSPACE

source ./software.sh  # 确保 Bazel PATH 已设置

bazel build <主目标> \
  --verbose_failures \
  --config=linux_aarch64 \
  2>&1 | tee $LOG_FILE

BUILD_EXIT_CODE=${PIPESTATUS[0]}

# 清理临时 WORKSPACE
[ -e "WORKSPACE" ] && rm WORKSPACE

echo "编译退出码：$BUILD_EXIT_CODE"
echo "日志：$LOG_FILE"
```

### 判断编译成功的标准

```bash
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    # 退出码 0，但需确认日志中无真实 error 行
    REAL_ERRORS=$(grep -cE "^ERROR |: error:|error: " $LOG_FILE 2>/dev/null || echo 0)
    if [ "$REAL_ERRORS" -eq 0 ]; then
        echo "✅ 编译成功（第 ${ATTEMPT} 次尝试）"
        # 进入 E.5 收尾
    else
        echo "⚠️ 退出码为 0 但日志中仍有 ${REAL_ERRORS} 条 error，继续分析"
    fi
fi
```

---

## E.4 提取关键错误信息

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

## E.5 错误修复查询（两级）

> **修复优先级（两级查询）**：
> 1. **第1级 — 速查表**：查 [build-error-quickfix.md](build-error-quickfix.md)（扁平关键字表，扫描快）；命中则按「修复」列描述修复
> 2. **第2级 — 案例库**：速查表未命中时，查 [migration-cases/](migration-cases/) 案例库（结构化教案，详细兜底）；命中则按案例修复方法修复
>
> ⚠️ **醒目标识要求（强制）**：每次执行第2级案例库查询时，**必须**在 agent 交互界面输出醒目标识，便于核验 skill 是否实际使用了案例库知识。无论命中与否都要输出，格式如下：
>
> ```
> 🔍 [案例库查询] 错误关键字：<从日志提取的关键字>
>    查询路由：<01-generic / 02-version / 03-project> → <G-cases / V-cases / P-cases>
>    查询结果：<命中 G-XX / V-XX / P-XX，将按案例修复> 或 <未命中，需人工介入或新增案例>
> ```

### 第1级：速查表

速查表已独立为 [build-error-quickfix.md](build-error-quickfix.md)，按错误类别分表（头文件 / 类型符号 / 链接 / Bazel / 编译严格性），扁平关键字匹配，扫描快。命中即按「修复」列描述修复，未命中进入第2级。

### 第2级：案例库路由查询流程

案例库位于 `$SKILL_DIR/migration-cases/`，按错误类别分三系列，每系列有「路由索引 + 案例库」两文件：

| 系列 | 路由索引文件 | 案例库文件 | 适用错误 |
|------|------------|----------|---------|
| G 系列 | [01-generic-arm-migration.md](migration-cases/01-generic-arm-migration.md) | [G-cases.md](migration-cases/G-cases.md) | 通用 ARM 适配（编译标志、intrinsics、头文件等架构无关问题） |
| V 系列 | [02-version-compatibility.md](migration-cases/02-version-compatibility.md) | [V-cases.md](migration-cases/V-cases.md) | 版本兼容性（依赖库版本冲突、ABI 不匹配、头文件版本不一致） |
| P 系列 | [03-project-specific.md](migration-cases/03-project-specific.md) | [P-cases.md](migration-cases/P-cases.md) | 项目特有（部署流水线、manifest、so 路径等项目级问题） |

**查询步骤**：

1. 从编译错误日志（`$WORK_DIR/logs/build_<N>.log`）提取关键字（如 `immintrin.h not found`、`File in wrong format`、`undefined reference`）
2. 按错误类别选路由索引文件，扫描「摘要」列匹配关键字 → 定位案例 ID（如 `G-01`）
3. 跳到对应案例库文件，按 ID 查看完整修复方法（错误现象 / 根因 / 修复方法 / 验证方式）
4. **输出醒目标识**（见上方格式），命中与否都要输出
5. 命中 → 按案例修复方法执行；未命中 → 跳到 E.6 记录后进入 E.7 人工介入

> **类别判定速查**：
> - 错误含 x86 编译标志 / intrinsics 头文件 / 内联汇编 → **G 系列**
> - 错误含依赖库版本 / ABI / 头文件版本不一致 → **V 系列**
> - 错误含部署 / manifest / so 路径 / 流水线 → **P 系列**
> - 不确定时三个路由索引都扫一遍

> **新增修复方法的归属**：速查表未覆盖的新错误，若修复方法具备通用性，应补录到 [migration-cases/](migration-cases/) 案例库（按 G/V/P 系列格式新增案例并更新路由索引），而非扩充速查表——速查表仅承载扁平关键字映射，结构化教案归案例库。

---

## E.6 记录修复历史

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

## E.7 人工介入报告

当出现以下情况时，**停止自动修复**并输出人工介入报告：

**触发条件：**
- 连续两次编译出现完全相同的错误（修复无效）
- 已达到最大重试次数（10 次）
- 遇到无法自动判断的错误类型

**人工介入报告格式：**

```
⛔ 自动修复已达到极限，需要人工介入

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

## E.8 编译成功后收尾

```bash
# 1. 清理临时 WORKSPACE（避免误提交到版本库）
[ -e "$PROJECT_ROOT/WORKSPACE" ] && {
    rm $PROJECT_ROOT/WORKSPACE
    echo "✅ 临时 WORKSPACE 已清理"
}

# 2. 保存最终修改清单
FINAL_CHANGES="$WORK_DIR/reports/final_changes_$(date +%Y%m%d).txt"
git -C $PROJECT_ROOT diff --stat 2>/dev/null > $FINAL_CHANGES
git -C $PROJECT_ROOT diff 2>/dev/null >> $FINAL_CHANGES
echo "修改清单已保存：$FINAL_CHANGES"

# 3. 记录成功信息
echo "✅ ARM 编译成功（第 ${ATTEMPT} 次）：$(date)" >> $WORK_DIR/reports/build_summary.txt

# 4. 统计修改概要
echo "=== 修改概要 ==="
git -C $PROJECT_ROOT diff --stat 2>/dev/null | tail -5

# 5. 提示 x86 双架构验证
echo ""
echo "⚠️  请验证 x86 编译未被破坏："
echo "   在 x86 机器上执行以下命令之一："
echo "   - 方式1：使用项目的构建脚本（若已添加架构自动检测，在 x86 上会自动走 x86 路径）"
echo "   - 方式2：cd $PROJECT_ROOT && bazel build <target> --verbose_failures --config=linux_x86"
```

---

## E.9 快速检查清单

编译验证阶段完成后，确认以下所有项均已完成：

- [ ] 已确定正确的编译命令（含 --config=linux_aarch64 或等效参数）
- [ ] 第 1 次编译已执行，日志已保存到 `$WORK_DIR/logs/build_1.log`
- [ ] 若失败，已提取并分析关键错误信息
- [ ] 已查询速查表 / migration-cases 案例库匹配已知问题（两级查询）
- [ ] 每次修复均已记录到 `fix_history.txt`
- [ ] 最终编译成功（退出码 0，无 `error:` 行）
- [ ] 临时 WORKSPACE 文件已清理
- [ ] 最终修改清单已保存
- [ ] 已提示进行 x86 双架构兼容性验证
