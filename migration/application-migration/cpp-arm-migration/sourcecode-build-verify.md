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

> **编译目标来源**：来自阶段 A setup.md 的检测结果（通常在 build.sh 中），或用户在阶段 C 确认的目标名。

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
    │  分析错误并修复                         │
    └─────────────────────────────────────────┘

    优先查询 sourcecode-error-patterns.md 中的已知案例
    若找到匹配案例 → 按案例方法修复
    若未找到匹配 → 按 E.4 速查表处理

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

## E.5 常见错误快速修复速查表

> **优先查询 [sourcecode-error-patterns.md](sourcecode-error-patterns.md) 中的完整案例库**，以下为高频错误速查。

### 编译标志类错误

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `'-mf16c' is not supported by this configuration` | x86 标志残留在全局 .bazelrc | 将 .bazelrc 全局段的 `-mf16c/-msse/-mavx/-mpopcnt` 移到 `build:linux_x86` 段 |
| `unrecognized option '-mssse3'` | 同上 | 同上 |
| `error: option '-mpopcnt' cannot be specified` | 同上 | 同上 |

**修复命令参考：**
```bash
# 定位 .bazelrc 中需要移动的行
grep -n "mf16c\|msse\|mavx\|mpopcnt\|mssse3\|march=.*86" $PROJECT_ROOT/.bazelrc

# 用编辑工具将 "build --cxxopt=..." 改为 "build:linux_x86 --cxxopt=..."
```

### 头文件找不到

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `'immintrin.h' file not found` | x86 intrinsics 头文件未隔离 | 用 `#if defined(__x86_64__)` 包裹 `#include` |
| `'emmintrin.h' file not found` | 同上 | 同上 |
| `'sys/sysctl.h': No such file` | ARM Linux 无该头文件 | 用 `#if !defined(__aarch64__)` 包裹 |
| `fatal error: xxx.h: No such file or directory` (来自第三方库) | BUILD 文件缺少 `hdrs` 或 `includes` | 在对应 BUILD 文件中补 `hdrs = glob(["**/*.h"])` 和 `includes = ["."]` |

### 类型/符号未定义

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `'__m256i' was not declared` | AVX 类型未定义 | 用架构宏保护整个使用块，参考 sourcecode-error-patterns.md |
| `'_mm256_loadu_si256' undeclared` | AVX intrinsics 函数未定义 | 同上 |
| `expected unqualified-id before '__attribute__'` | `-D__const__=` 破坏 ARM glibc | 改为 `select()` 架构区分，见 sourcecode-error-patterns.md 案例 C-04 |
| `'proto_common' is not defined` | Bazel rules_proto 版本不兼容 | 在 .bazelrc 全局段加 `--incompatible_blacklisted_protos_requires_proto_info=false` |

### 链接错误

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `error adding symbols: File in wrong format` | x86 `.so`/`.a` 被 ARM 链接器处理 | 确认 WORKSPACE_arm 中的 URL 已替换为 ARM 版本；检查对应 `.so` 文件架构 |
| `undefined reference to 'xxx'` | ARM 版库未链接或 ABI 不匹配 | 检查 WORKSPACE_arm 库路径，确认 ARM `.so`/`.a` 已就位，符号签名一致 |

### Bazel 构建系统错误

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `no such target '//platforms:is_aarch64'` | platforms/BUILD 未定义 ARM 平台 | 补全 platforms/BUILD，见 sourcecode-devkit-scan.md D.2.4 节 |
| `no such target '//platforms:linux_aarch64'` | 同上 | 同上 |
| `Unrecognized option: --incompatible_...` | 系统 Bazel 版本过旧 | 确认使用项目内置 Bazel（software.sh 中的 PATH 设置） |
| `Host key verification failed` | SSH 克隆私有仓库失败（ARM 环境无 SSH 密钥） | 改用 `new_local_repository` 指向本地桩 |
| `incompatible with your Protocol Buffer headers` | protoc 版本与 .pb.h 不匹配 | 重新生成 .pb.h，或对齐 protobuf 版本（见 setup.md 1.6 节） |

### 编译严格性差异

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `jump to case label` | case 块中有局部变量，ARM GCC 更严格 | 给 case 块加花括号 `{}`，见 sourcecode-error-patterns.md 案例 C-05 |
| `cannot convert 'const string' to 'const char*'` | 桩头文件签名与调用方不匹配 | 重新扫描调用方并修正桩签名 |
| `missing binary operator before token "("` | Boost 版本过旧 | 使用系统新版 Boost 或升级 Boost 版本 |
| `-Werror` 将警告升级为错误 | ARM GCC 产生 x86 GCC 没有的警告 | 在 ARM 配置段中添加对应的 `-Wno-xxx`，或修复源码中的警告 |

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
参考案例：<sourcecode-error-patterns.md 中的案例编号，若有>
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
- [ ] 已优先查询 `sourcecode-error-patterns.md` 匹配已知案例
- [ ] 每次修复均已记录到 `fix_history.txt`
- [ ] 最终编译成功（退出码 0，无 `error:` 行）
- [ ] 临时 WORKSPACE 文件已清理
- [ ] 最终修改清单已保存
- [ ] 已提示进行 x86 双架构兼容性验证
