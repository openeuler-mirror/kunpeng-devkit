# Diff 采集与校验指南

本文档说明如何从 x86 和 ARM 分支中生成高质量 diff，并用于事后校验 AI 改动是否精确。

---

## 1. 路径信息收集

### 1.1 场景 A：同一仓库不同分支

```bash
# 用户提供：仓库路径 + x86 分支 + ARM 分支
REPO_PATH=<仓库本地绝对路径>
X86_BRANCH=<x86分支名，如 master / main>
ARM_BRANCH=<ARM分支名，如 arm64 / kunpeng / aarch64>

cd $REPO_PATH
git fetch --all
git diff $X86_BRANCH $ARM_BRANCH > /tmp/arm_migration_$(date +%Y%m%d).diff
```

### 1.2 场景 B：两个独立本地目录

```bash
# 用户提供：x86 目录路径 + ARM 目录路径
X86_DIR=<x86项目本地路径>
ARM_DIR=<ARM项目本地路径>

diff -ruN --exclude=".git" $X86_DIR $ARM_DIR > /tmp/arm_migration_$(date +%Y%m%d).diff
```

### 1.3 场景 C：通过 git log 查找 ARM 适配提交

若用户不确定哪个分支是 ARM 版本，先搜索：

```bash
cd <仓库路径>

# 1. 搜索含 ARM 关键词的提交
git log --oneline --all | grep -iE "arm|aarch64|kunpeng|鲲鹏" | head -30

# 2. 搜索含 ARM 适配关键词的文件改动
git log --all --oneline --follow -p -- ".bazelrc" | grep -E "aarch64|arm64" | head -10

# 3. 列出最近 30 天内的分支活动，找到 ARM 相关分支
git for-each-ref --sort=-committerdate refs/heads refs/remotes \
    --format='%(refname:short) %(committerdate:relative)' | head -20
```

确认分支后，按场景 A 生成 diff。

---

## 2. 生成高质量 Diff

### 2.1 推荐命令（git diff）

```bash
cd $REPO_PATH

# 完整 diff（包含所有文件改动）
git diff $X86_BRANCH..$ARM_BRANCH \
    --stat \
    > /tmp/arm_migration_stat.txt

git diff $X86_BRANCH..$ARM_BRANCH \
    -U5 \
    --ignore-all-space \
    > /tmp/arm_migration_full.diff

echo "Diff 统计："
cat /tmp/arm_migration_stat.txt

echo ""
echo "改动文件列表："
git diff --name-only $X86_BRANCH..$ARM_BRANCH
```

### 2.2 过滤无关文件（精简 diff）

```bash
# 排除自动生成文件、二进制文件、日志等
git diff $X86_BRANCH..$ARM_BRANCH \
    -U5 \
    -- \
    ":(exclude)*.pb.cc" \
    ":(exclude)*.pb.h" \
    ":(exclude)*.generated.*" \
    ":(exclude)bazel-*" \
    ":(exclude)*.log" \
    ":(exclude)*.a" \
    ":(exclude)*.so" \
    > /tmp/arm_migration_clean.diff
```

### 2.3 按类型分别提取（方便分类分析）

```bash
# 只看构建文件（BUILD/WORKSPACE/.bazelrc/CMakeLists.txt 等）
git diff $X86_BRANCH..$ARM_BRANCH -- \
    "*.bazelrc" "*/BUILD" "*/BUILD.bazel" "WORKSPACE*" "*CMakeLists.txt" "BLADE_ROOT" \
    > /tmp/diff_build_files.diff

# 只看源码文件（.cpp/.h/.cc/.cxx）
git diff $X86_BRANCH..$ARM_BRANCH -- \
    "*.cpp" "*.h" "*.cc" "*.cxx" "*.c" \
    > /tmp/diff_source_files.diff

# 只看脚本文件（.sh/.py）
git diff $X86_BRANCH..$ARM_BRANCH -- \
    "*.sh" "*.py" \
    > /tmp/diff_scripts.diff

# 只看 Bison/Flex 文件
git diff $X86_BRANCH..$ARM_BRANCH -- \
    "*.yy" "*.ll" "*.y" "*.l" \
    > /tmp/diff_parser_files.diff
```

---

## 3. Diff 校验（事后验证 AI 改动精确性）

保存 diff patch 后，可用于校验 AI 后续迁移时的改动是否正确：

### 3.1 与已知 diff 对比

```bash
# 将 AI 迁移后的改动生成 diff
git diff HEAD > /tmp/ai_migration.diff

# 对比 AI 改动与已知正确 diff 的差异
diff /tmp/arm_migration_full.diff /tmp/ai_migration.diff | head -100

# 统计 AI 多改了哪些文件、少改了哪些文件
comm -23 \
    <(git diff --name-only $X86_BRANCH..$ARM_BRANCH | sort) \
    <(git diff --name-only HEAD | sort) \
    | sed 's/^/【未改动】/'

comm -13 \
    <(git diff --name-only $X86_BRANCH..$ARM_BRANCH | sort) \
    <(git diff --name-only HEAD | sort) \
    | sed 's/^/【额外改动】/'
```

### 3.2 关键改动核对清单

校验时重点关注以下高风险改动：

| 改动类型 | 校验要点 |
|---------|---------|
| 编译标志（`.bazelrc`/`BLADE_ROOT`）| x86 标志是否已移入 `linux_x86` 段，全局段是否清洁 |
| 汇编代码（`__asm__ volatile`）| x86 汇编是否有 `__x86_64__` 宏保护，ARM 汇编是否正确 |
| 内存屏障（`atomic_thread_fence`）| `memory_order` 是否选择正确，是 acquire 还是 release |
| 预编译库替换 | ARM 库文件确实是 aarch64 格式（用 `file` 命令确认） |
| 头文件补充 | 新增的 `#include` 是否在正确的位置 |
| ABI 标志 | `_GLIBCXX_USE_CXX11_ABI` 是否全项目一致 |

### 3.3 自动化核对脚本

```bash
#!/bin/bash
# 快速核对脚本：对比 AI 改动与参考 diff
REFERENCE_DIFF=/tmp/arm_migration_full.diff
AI_DIFF=/tmp/ai_migration.diff

echo "=== 改动文件对比 ==="
echo "--- 参考 diff 改动文件数：$(git apply --stat $REFERENCE_DIFF 2>/dev/null | wc -l)"
echo "--- AI 改动文件数：$(cat $AI_DIFF | grep '^+++' | wc -l)"

echo ""
echo "=== 高风险改动检查 ==="
echo "1. 全局段中是否还有 x86 标志："
grep -n "^build --.*-m\(f16c\|sse\|avx\|popcnt\)" .bazelrc 2>/dev/null \
    && echo "  ⚠️ 发现全局 x86 标志" || echo "  ✅ 全局段已清洁"

echo "2. x86 汇编是否有宏保护："
grep -n "__asm__" $(git diff --name-only HEAD | grep -E "\.cpp|\.h") 2>/dev/null | \
    grep -v "__x86_64__\|__aarch64__" \
    && echo "  ⚠️ 存在未保护汇编" || echo "  ✅ 汇编已有架构宏保护"

echo "3. 预编译库架构检查："
find . -name "*.a" -newer /tmp/arm_migration_full.diff 2>/dev/null | \
    while read f; do
        arch=$(file "$f" | grep -o "x86-64\|aarch64")
        [ -n "$arch" ] && echo "  $arch  $f"
    done
```

---

## 4. Diff 归档

校验完成后，将 diff 归档到工作目录：

```bash
ARCHIVE_DIR=/tmp/arm_migration_archive/$(date +%Y%m%d_%H%M%S)
mkdir -p $ARCHIVE_DIR

cp /tmp/arm_migration_full.diff $ARCHIVE_DIR/reference.diff
cp /tmp/arm_migration_stat.txt  $ARCHIVE_DIR/stat.txt

# 记录基本信息
cat > $ARCHIVE_DIR/meta.txt <<EOF
项目：<project-name>（已脱敏）
x86 分支：$X86_BRANCH
ARM 分支：$ARM_BRANCH
生成时间：$(date)
改动文件数：$(git diff --name-only $X86_BRANCH..$ARM_BRANCH | wc -l)
EOF

echo "Diff 已归档至：$ARCHIVE_DIR"
```

---

## 5. 注意事项

- diff 中涉及**真实仓库地址** （写入案例库前必须替换为 `ssh://git@<your-host>/<repo-path>.git`
- diff 中涉及**内网 IP**（`10.x.x.x`、`172.x.x.x`）时，替换为 `<internal-host>`
- diff 中涉及**具体业务名称/服务名**时，替换为 `<service-name>`、`<project-name>`
- 预编译库的 URL替换为 `https://<your-package-repo>/...`
