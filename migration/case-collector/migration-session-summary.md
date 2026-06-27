# 迁移会话知识提取指南

**适用场景**：当前上下文是一次完整的 x86→ARM 迁移流程，且**最终编译成功**。本文档指导 AI 从对话历史中批量提取"编译报错 → 解决方案"样例，写入案例库。

---

## 1. 触发条件检测

满足以下任一条件时，主动提示用户可以执行知识提取：

- 上下文中出现"编译成功"、"build success"、"exit code 0"等字样
- 用户明确说"迁移完成了"、"跑通了"、"可以写案例了"
- 当前迁移流程已进入"阶段 E 成功后收尾"阶段

---

## 2. 提取步骤

### Step 2.1：扫描对话历史

从对话历史（上下文窗口）中，按时间顺序搜集所有"错误→修复"事件对：

**错误出现的特征：**
```
error: ...
fatal error: ...
undefined reference to ...
note: ...crosses initialization of...
warning: ... (treated as error)
collect2: error: ld returned 1 exit status
```

**修复出现的特征：**
- AI 执行文件编辑操作（`string_replace`、`write`）
- AI 说明了为什么要做某个修改
- 用户确认修改后重新编译

### Step 2.2：整理错误-修复对列表

以表格形式输出（给用户确认）：

| # | 错误现象（摘要） | 修复文件 | 修复方式 | 初步分类 |
|---|----------------|---------|---------|---------|
| 1 | `error: '-mf16c' is not supported` | `.bazelrc` | 移入 `linux_x86` 段 | G 系列 |
| 2 | `fatal error: immintrin.h not found` | `foo.cpp` | `#if defined(__x86_64__)` 保护 | G 系列 |
| ... | ... | ... | ... | ... |

**输出后暂停，等待用户确认**（通过 `AskQuestion`）：

```
question id="session_summary_confirm"
prompt="检测到本次迁移共处理了 N 个编译错误，是否将所有样例写入案例库？"
options:
  - id="all"     label="✅ 全部写入案例库"
  - id="select"  label="🔍 我来选择要写入哪些"
  - id="review"  label="⏸ 先让我看完整列表再决定"
  - id="skip"    label="❌ 本次不写入"
```

### Step 2.3：详细提取每个错误案例

对每个确认的错误-修复对，按以下模板提取完整信息：

**提取模板：**

```
案例 #N
=======
错误现象（完整报错）：
  <从对话历史中复制原始编译错误信息>

错误发生在：
  文件：<已脱敏的文件路径>
  构建系统：Bazel / CMake / Blade / Make

AI 分析的根因：
  <从 AI 的分析说明中提取，说明为什么 x86 正常但 ARM 出错>

修复方式：
  <修改前代码>
  <修改后代码>

验证方式：
  <下次编译不再出现此错误，或具体的验证命令>

分类：G- / V- / P-
理由：<为什么归入此类>
```

### Step 2.4：脱敏处理

提取完成后，批量替换所有敏感信息：

```
替换规则（按顺序执行）：
1. 真实仓库地址（ssh://git@xxx、https://xxx.xxx.com/...）→ ssh://git@<your-host>/<repo>.git 或 https://<your-package-repo>/...
2. 内网 IP（1.x、2.x、192.168.x）→ <internal-host>
3. /home/<真实用户名>/ → /home/<username>/
4. 具体业务名/服务名 → <project-name> 或 <service-name>
5. 具体机器名（hostname）→ <build-machine>
6. sha256 真实值 → <sha256-hash>
7. commit hash 真实值 → <arm-compatible-commit>
```

---

## 3. 批量写入案例库

对每个提取的案例，执行写入：

### 3.1 确定 ID

```bash
# 在对应文件中查找当前最大 ID
grep -E "^### (G|V|P)-[0-9]+" \
    migration-cases/01-generic-arm-migration.md \
    migration-cases/02-version-compatibility.md \
    migration-cases/03-project-specific.md | \
    awk -F'-' '{print $2}' | sort -n | tail -1
```

### 3.2 写入顺序建议

1. 先写 G- 系列（通用 ARM 适配，最具参考价值）
2. 再写 V- 系列（版本兼容，有一定普适性）
3. 最后写 P- 系列（项目特有，参考范围窄）

### 3.3 写入后验证

```bash
# 确认格式正确：每条案例都有四要素
grep -c "错误现象" migration-cases/01-generic-arm-migration.md
grep -c "根因分析" migration-cases/01-generic-arm-migration.md
grep -c "修复方法" migration-cases/01-generic-arm-migration.md
grep -c "验证方式" migration-cases/01-generic-arm-migration.md
# 四个数字应相等

# 确认没有敏感信息残留
grep -nE "(ssh://git@[a-z0-9.-]+/[a-z]|10\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+|/home/[a-z_][a-z0-9_]+/)" \
    migration-cases/*.md && echo "⚠️ 发现敏感信息，需要脱敏" || echo "✅ 脱敏通过"
```

---

## 4. 会话总结报告输出格式

写入案例库完成后，向用户输出总结报告：

```
📚 迁移知识提取完成

本次迁移共处理 N 个编译错误，已提取 M 个案例写入案例库：

【通用 ARM 适配（G 系列）】新增 X 条
  - G-XX：<标题>
  - G-XX：<标题>
  ...

【版本兼容性（V 系列）】新增 Y 条
  - V-XX：<标题>
  ...

【项目特有（P 系列）】新增 Z 条
  - P-XX：<标题>
  ...

案例库位置：
  migration-cases/01-generic-arm-migration.md
  migration-cases/02-version-compatibility.md
  migration-cases/03-project-specific.md

规律总结：
  <一段话说明本次迁移中最常见的问题类型，以及值得注意的 ARM 迁移规律>
```

---

## 5. 规律提炼（自动执行）

写入案例库后，AI 自动分析本次迁移的规律，输出规律总结：

**分析维度：**
1. 本次遇到的错误，哪类最多？（G / V / P）
2. 错误主要集中在哪类源码？（构建文件、C++ 源码、脚本、解析器文件）
3. 最快定位和修复的是哪类问题？
4. 哪些改动已在 `sourcecode-error-patterns.md` 中有对应案例（直接引用），哪些是新增的？
5. 有没有出现"相同错误、不同原因"的情况（需要特别标注）？

**规律写法示例：**

```
本次迁移（<脱敏项目名>，Bazel 构建系统）共处理 12 个错误：

- 最多的是 G 系列（8 个，67%），主要集中在：
  ① 编译标志隔离（.bazelrc 全局段含 x86 标志）
  ② 头文件隐式包含差异（ARM GCC 不隐式包含 <functional>、<atomic>）
  ③ char 符号性（需全局添加 -fsigned-char）

- V 系列 2 个：Bison 3.x API 变更（已有完整案例模板）

- P 系列 2 个：特定内部框架 BUILD 文件欠债，高度项目特有

建议：本项目的 G-XX（汇编指令替换）案例值得写入通用案例库，
因为项目包含手写位操作汇编，其他有类似代码的项目可直接参考。
```

---

## 6. 与 diff 校验结合

如果 Step 1 已生成 reference diff，此处执行最终校验：

```bash
# 对比 AI 本次修改与参考 diff 的差异
git diff HEAD > /tmp/session_changes.diff

echo "=== 案例库写入内容核对 ==="
echo "参考 diff 改动了的文件，AI 本次是否都处理了："
comm -23 \
    <(git apply --stat /tmp/arm_migration_full.diff 2>/dev/null | awk '{print $1}' | sort) \
    <(git diff --name-only HEAD | sort) \
    | sed 's/^/  ⚠️ 遗漏：/'

echo ""
echo "AI 额外改动的文件（参考 diff 中没有的）："
comm -13 \
    <(git apply --stat /tmp/arm_migration_full.diff 2>/dev/null | awk '{print $1}' | sort) \
    <(git diff --name-only HEAD | sort) \
    | sed 's/^/  ℹ️ 额外：/'
```

若发现遗漏或额外改动，在案例的"根因分析"中注明：
> **注意**：此案例对应的改动在参考 diff 中 **存在 / 不存在**，可能是 AI 独立发现的额外修复，需人工验证。
