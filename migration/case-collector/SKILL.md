---
name: arm-migration-case-collector
description: C/C++ 项目 x86→ARM 迁移知识采集技能。用于从迁移 diff 或迁移会话上下文中提取编译错误→解决方案，按"通用ARM适配 / 版本兼容性 / 项目特有"三类规范化写入可扩展案例库。支持：① 从 x86/ARM 分支自动生成 diff；② 从成功迁移的会话中批量提取错误样例；③ 主动问询分支路径并验证。触发场景：用户提到"整理迁移案例"、"采集编译错误"、"写入案例库"、"总结迁移经验"，或上下文中有一次完整迁移流程且最终编译成功。
---

# ARM 迁移知识采集 Skill

## 核心原则

- **脱敏优先**：所有文档中不得出现真实仓库地址、内网 IP、用户名、机器名、业务名称等敏感信息，统一用 `<your-repo>`、`<your-host>`、`<project-name>` 等占位符替代
- **可扩展案例库**：每类案例有独立文件，案例 ID 自增，新增案例追加到文件末尾，不修改已有案例
- **格式统一**：每条案例包含 **错误现象 → 根因分析 → 修复方法 → 验证方式** 四要素，与 `sourcecode-error-patterns.md` 格式保持一致
- **分类清晰**：按三类进行归档，不混淆；汇编/内存序问题归入"通用 ARM 适配"而非"源码改动"
- **diff 可校验**：保存的 diff patch 用于事后校验 AI 改动是否精确

---

## 整体流程

```
Step 1（diff 采集）  →  Step 2（AI 分析）  →  Step 3（案例入库）  →  Step 4（更新扫描规则）  →  Step 5（收集 ARM 分支信息）
```

- **Step 1**：从 x86 / ARM 分支（或当前迁移上下文）获取 diff，见 [diff-collection.md](diff-collection.md)
- **Step 2**：AI 主动分析 diff 中每处改动的"为什么"，归类到三类案例，并识别是否可加入自定义扫描规则
- **Step 3**：按三类规范写入对应案例库文件，见 [case-collection-guide.md](case-collection-guide.md)
- **Step 4**：（仅对通用 G- 案例）询问用户是否将此案例的匹配模式加入 `arm-scan-rules.json`
- **Step 5**：收集本次迁移成功使用的 ARM 分支/库版本信息，按主代码仓追加写入 `arm_confirmed.md`

**如果上下文是一次已完成迁移（最终编译成功）：**  
咨询用户当前是否已有 x86/ARM 分支可用，若无则跳过 Step 1，直接执行 Step 2 → Step 3：从对话历史提取所有"编译报错 → 解决方案"对，批量入库。见 [migration-session-summary.md](migration-session-summary.md)

---

## Step 1：信息收集 + Diff Patch 生成（必须先执行）

### 1.1 从用户输入获取路径

从用户输入中解析以下信息：
- **x86 项目路径**（本地绝对路径）
- **ARM 项目路径**（本地绝对路径，可能与 x86 同一仓库的不同分支）

若未获取到上述信息，**必须调用 `AskQuestion` 工具主动问询**：

```
question id="branch_info"
prompt="请提供迁移项目的路径信息（用于生成 diff）"
options:
  - id="local_paths" label="提供本地路径：x86 路径 和 ARM 路径"
  - id="git_branch"  label="提供 Git 信息：仓库路径 + x86分支名 + ARM分支名"
  - id="context_only" label="无本地路径，使用当前对话上下文"
```

### 1.2 生成并保存完整 Diff Patch（必须步骤）

获取到路径信息后，**立即生成完整 diff patch 并保存到迁移报告目录**（不放在 skill 目录下），后续案例写入时引用此文件路径。

**diff 内容无需脱敏，保留真实路径和内容。**

```bash
# 报告目录（迁移工作目录下的 reports/）
REPORT_DIR=<迁移工作目录>/reports   # 例：/path/to/rec-rs-x86-arm-migration/reports
mkdir -p $REPORT_DIR
PATCH_FILE=$REPORT_DIR/arm_migration_$(date +%Y%m%d_%H%M%S).patch

# 场景 A：同一仓库不同分支
REPO_PATH=<仓库本地绝对路径>
X86_BRANCH=<x86分支名，如 master / main>
ARM_BRANCH=<ARM分支名，如 arm64 / kunpeng / aarch64>

cd $REPO_PATH
git fetch --all
git diff $X86_BRANCH..$ARM_BRANCH -U5 > $PATCH_FILE
echo "✅ Diff patch 已保存到：$PATCH_FILE"
echo "改动文件数：$(git diff --name-only $X86_BRANCH..$ARM_BRANCH | wc -l)"
git diff --stat $X86_BRANCH..$ARM_BRANCH

# 场景 B：两个独立本地目录
X86_DIR=<x86项目本地路径>
ARM_DIR=<ARM项目本地路径>

diff -ruN --exclude=".git" $X86_DIR $ARM_DIR > $PATCH_FILE
echo "✅ Diff patch 已保存到：$PATCH_FILE"
```

> ⚠️ **必须确认 patch 文件非空**：`wc -l $PATCH_FILE`，若为 0 行说明路径或分支有误，需重新问询用户。

**PATCH_FILE 的绝对路径将在 Step 3 写入案例时作为 `diff patch` 字段引用（仅记录路径，不将 diff 内容写入案例库文件）。**

### 1.3 Git 分支扫描（可选，用于定位 ARM 分支）

若用户不确定哪个分支是 ARM 版本：

```bash
# 在仓库中搜索最近是否有 ARM 适配相关提交
cd <仓库路径>
git log --oneline --all | grep -iE "arm|aarch64|鲲鹏|kunpeng" | head -20

# 找到目标分支后，按 1.2 步骤生成 diff
```

详细步骤见 [diff-collection.md](diff-collection.md)。

---

## Step 2：AI 主动分析

读取 diff 后，对每处改动执行：

1. **识别改动类型**：是编译标志、头文件、源码、构建文件、脚本还是链接配置？
2. **判断错误触发原因**：改动是为了解决什么编译报错（或运行时问题）？
3. **归类**：按 [case-collection-guide.md](case-collection-guide.md) 的三类分类规则归类
4. **提炼规律**：不只记录“改了什么”，而是分析“为什么改”、“什么情况下会遇到”
5. **识别扫描可行性**：判断该改动是否可用正则表达式匹配（见下方 Step 4）

**分析输出格式**（给用户确认）：

```
改动文件：<脱敏文件路径>
分类：通用ARM适配 / 版本兼容性 / 项目特有
错误现象：<编译报错信息或运行时错误>
根因：<为什么 x86 正常但 ARM 出错>
修复：<改动摘要>
建议入库 ID：<G-XX / V-XX / P-XX>
可加入扫描规则：<是 / 否 / DevKit 已覆盖>
```

---

## Step 3：写入案例库

按分类写入对应文件：

| 分类 | 文件 | ID 前缀 |
|------|------|---------|
| 通用 ARM 适配（含汇编、内存序、char 符号性等） | `migration-cases/01-generic-arm-migration.md` | `G-` |
| 版本兼容性（工具链版本升级导致） | `migration-cases/02-version-compatibility.md` | `V-` |
| 项目特有（业务特定依赖组合、历史欠债） | `migration-cases/03-project-specific.md` | `P-` |

每条案例中必须包含 **`diff patch`** 字段，内容为该案例对应的实际改动片段（从 Step 1 生成的 patch 文件中提取相关部分，已脱敏）。  
写入格式见 [case-collection-guide.md](case-collection-guide.md)。

---

---

## Step 4：更新自定义扫描规则（仅通用 G- 案例）

### 4.1 判断是否适合加入扫描规则

以下情况**不**加入扫描规则：
- DevKit 已完整覆盖该类型（如汇编、intrinsics、immintrin 系头文件、类型大小、内存对齐）
- 错误现象无法用正则表达式匹配（如纯适配逻辑问题、运行时崩溃）
- V-（版本兼容）或 P-（项目特有）类型案例

以下情况**适合**加入扫描规则：
- 属于 G-（通用 ARM 适配）案例
- 错误模式可用正则表达式匹配（如特定头文件、宣娊模式、特定字符串）
- DevKit 未覆盖或仅部分覆盖（`devkit_covered: false` 或 `partial`）

### 4.2 必须询问用户确认

**对每个通用 G- 案例，AI 必须调用 `AskQuestion` 询问用户**，不得自行判断是否加入扫描规则：

```
AskQuestion({
  title: "扫描规则确认",
  questions: [{
    id: "add_scan_rule",
    prompt: "案例 [G-XX: <标题>] 已入库。
该问题可用正则匹配：<简述匹配模式>。
是否将此案例的扫描规则加入 arm-scan-rules.json，
以便未来新项目迁移时快速扫描定位该问题？",
    options: [
      { id: "yes",    label: "是，将该案例的匹配规则加入 arm-scan-rules.json" },
      { id: "no",     label: "否，此问题较特殊，不适合通用扫描" },
      { id: "devkit", label: "DevKit 已覆盖此类型，无需加入" }
    ]
  }]
})
```

### 4.3 用户确认后执行

**用户选择「是」时**，将新规则写入 `arm-scan-rules.json`：

```json
{
  "id": "SCAN-G<NN>-01",
  "case_ref": "G-<NN>",
  "title": "<案例标题，不含项目名>",
  "description": "<问题简述，说明为什么 x86 正常但 ARM 出错>",
  "file_types": ["<扫描的文件后缀列表，如 .cpp .h .cc>"],
  "patterns": [
    {
      "regex": "<匹配模式的正则表达式>",
      "description": "<该正则匹配的语义>",
      "severity": "<error|warning|info>"
    }
  ],
  "fix_suggestion": "<修复建议，一行文字，供 AI 修复时参考>",
  "devkit_covered": false
}
```

**用户选择「否”或「DevKit 已覆盖」时**，不操作 JSON，案例仅保入案例库。

### 4.4 扫描脚本使用方法

扫描脚本和规则文件均保存在 skill 目录下（与本 SKILL.md 同级）：

```bash
# skill 目录位置：<项目路径>/<skill-dir>/case-collector/
# arm_scan.py          —扫描脚本（不需修改）
# arm-scan-rules.json  —扫描规则（新增案例后追加到此文件）

SKILL_DIR=<项目路径>/<skill-dir>/case-collector

# 扫描整个项目，输出文本报告
python3 $SKILL_DIR/arm_scan.py <项目根目录>

# 扫描并生成 JSON 报告（供 AI 读取定位修复）—保存到报告目录
python3 $SKILL_DIR/arm_scan.py <项目根目录> \
    --rules $SKILL_DIR/arm-scan-rules.json \
    --output <迁移工作目录>/reports/scan-result.json

# 仅显示 error 级别
python3 $SKILL_DIR/arm_scan.py <项目根目录> --severity error

# 排除构建产物目录
python3 $SKILL_DIR/arm_scan.py <项目根目录> --exclude build64_release,bazel-out
```

> ⚠️ **重要：** 扫描结果仅为辅助定位，**扫描到的每个问题需由 AI 逐条确认再修复**，不得直接批量修改。

---

## Step 5：收集 ARM 分支信息（迁移成功后执行）

### 5.1 收集目标

迁移编译成功后，将本次迁移中**实际验证可用**的 ARM 依赖版本信息记录下来，供后续同类项目迁移时直接复用，避免重复探查。

**收集内容包括：**
- 依赖库的 ARM 版本路径 / URL / commit / tag
- ABI 设置（ABI0/ABI1/纯C）
- 全局编译配置（BLADE_ROOT / .bazelrc 中的 ARM 段）
- 工具版本（Bison、GCC、Blade、Bazel 等）

**不收集：** 尚未验证可用的候选版本、已排除的版本。

---

### 5.2 按主代码仓分割记录

**以主代码仓（项目根仓库）为单位**，在 `arm_confirmed.md` 中用 `---` 分隔区分不同项目的记录。

**写入位置：**
- 若 `arm_confirmed.md` 中**已有该主仓的区域**（通过 `## <仓库名>` 标题匹配）→ 在该区域内**追加新行**，不重复已有条目
- 若**没有该主仓的区域** → 在文件末尾追加新的 `## <仓库名（脱敏）>` 区域

**主仓识别方式（按优先级）：**
1. 从 diff 中读取仓库路径（`--- a/` 行的顶层目录名）
2. 从 Step 1 中用户提供的项目路径中取末级目录名
3. 若无法自动识别，调用 `AskQuestion` 询问用户

---

### 5.3 从 diff / 迁移上下文提取 ARM 信息

**自动提取来源（按优先级）：**

```bash
# 1. 从 WORKSPACE_arm 提取 http_archive / git_repository 的 ARM URL/commit
grep -A5 "http_archive\|git_repository\|new_git_repository" $PROJECT_ROOT/WORKSPACE_arm \
  | grep -E "urls|url|commit|tag|strip_prefix|name" | head -60

# 2. 从 BUILD 文件提取 ARM 预编译库路径（Blade 项目）
grep -rn "thirdparty_arm\|arm_nocxx\|arm_ABI\|_arm\"" $PROJECT_ROOT \
  --include="BUILD" --include="*.BUILD" | head -40

# 3. 从 BLADE_ROOT 提取全局 ARM 编译配置
grep -A30 "aarch64\|arm64\|ARM" $PROJECT_ROOT/BLADE_ROOT 2>/dev/null | head -40

# 4. 从 .bazelrc 提取 linux_aarch64 段
grep -A3 "linux_aarch64\|aarch64" $PROJECT_ROOT/.bazelrc 2>/dev/null | head -30
```

---

### 5.4 写入格式规范

**Blade 项目依赖表（追加到已有表格或新建）：**

```markdown
## <主仓名（脱敏，如 project-a / project-b）>

| 依赖库 | ARM 路径 / URL | ABI | 备注 |
|--------|---------------|-----|------|
| `<lib>` | `<ARM 本地路径或 URL>` | ABI0 / ABI1 / 纯C | <简要说明，如版本、特殊配置> |
```

**Bazel 项目依赖表（追加到已有表格或新建）：**

```markdown
## <主仓名（脱敏）>（Bazel）

| 依赖库 | ARM URL / commit | 备注 |
|--------|-----------------|------|
| `<name>` | `<url>` / `commit = "<hash>"` | <简要说明> |
```

**全局编译配置（BLADE_ROOT / .bazelrc，每个主仓单独记录）：**

```markdown
### <主仓名> 全局编译配置

```python
# BLADE_ROOT ARM 关键配置（仅 ARM 相关差异部分）
cxxflags = ['-D_GLIBCXX_USE_CXX11_ABI=0', '-fsigned-char', ...]
extra_incs = ['<ARM boost 路径>/include', ...]
protoc = '<ARM protoc 路径>'
```
```

**工具版本（每个主仓单独记录）：**

```markdown
### <主仓名> 工具版本

| 工具 | ARM 版本 | 备注 |
|------|---------|------|
| Bison | 3.8.2 | openEuler 22.03 系统自带 |
| GCC | 10.3.1 | 系统 GCC |
| Blade | 1.1.3 | — |
```

---

### 5.5 脱敏要求

`arm_confirmed.md` 中的信息**不强制脱敏**（本文件仅存储在 skill 目录下，非公开），但写入时：
- **本地绝对路径**保留（如 `/home/.../thirdparty/xxx/...`），供后续项目直接复用
- **内网 URL / SSH 地址**保留，仅替换无法复用的用户名部分（`/home/<username>/` → 保留其余）
- **commit hash** 完整保留，不替换

---

### 5.6 写入后验证

写入完成后，执行以下检查：

```bash
# 确认新增行已写入
grep -n "<lib_name>" <skill-dir>/case-collector/arm_confirmed.md

# 确认主仓区域存在
grep -n "^## " <skill-dir>/case-collector/arm_confirmed.md
```

---

## 案例库文件索引

- **通用 ARM 适配问题案例库**：[migration-cases/01-generic-arm-migration.md](migration-cases/01-generic-arm-migration.md)
- **版本兼容性问题案例库**：[migration-cases/02-version-compatibility.md](migration-cases/02-version-compatibility.md)
- **项目特有问题案例库**：[migration-cases/03-project-specific.md](migration-cases/03-project-specific.md)
- **diff 采集与校验指南**：[diff-collection.md](diff-collection.md)
- **迁移会话知识提取指南**：[migration-session-summary.md](migration-session-summary.md)
- **案例采集规范**：[case-collection-guide.md](case-collection-guide.md)
- **自定义扫描规则**：[arm-scan-rules.json](arm-scan-rules.json)
- **自定义扫描脚本**：[arm_scan.py](arm_scan.py)
- **ARM 分支信息库（按主仓分割）**：[arm_confirmed.md](arm_confirmed.md)
