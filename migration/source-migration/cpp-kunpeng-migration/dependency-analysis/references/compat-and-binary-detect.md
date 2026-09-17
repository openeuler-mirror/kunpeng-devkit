# 依赖 ARM 兼容性探测与二进制识别（通用共享模块）

> 本文件是**所有构建系统共用**的两块通用逻辑，由 [repo-analysis-flow.md](repo-analysis-flow.md) 按需调用：
> - **第一部分（ARM 兼容性探测）**：Step 3 调用，适用于 Git 类依赖（submodule、`git_repository`、`FetchContent` GIT 模式）。免检清单比对也在此执行，确保每个仓库分析时都能正确跳过已确认兼容的依赖。
> - **第二部分（预编译二进制识别与溯源）**：Step 4 调用，不直接由用户触发。覆盖仓库内置二进制与外部无源码依赖。

---

# 第一部分：ARM 兼容性探测

## 1.1 私有 URL 判断（公开平台免查分支名）

对每个依赖的 URL / remote，判断它是公开平台还是私有来源——这决定 1.2 的分支名分析是否需要执行：

| URL 特征 | 判断 | 处理 |
|----------|------|------|
| `github.com`、`gitlab.com`、`bitbucket.org` 等公开平台 | 开源 | **免查分支名**：跳过 1.2，仍执行 1.3 查提交历史（开源项目通常在主分支支持 ARM，不存在独立 ARM 分支，无需按分支名判断） |
| 私有域名（如 `*.internal`、组织内部对象存储域名、IP 地址形式） | 私有依赖 | **需查分支名**：执行 1.2 + 1.3 |
| 私有 Git（SSH 形式，域名非公开平台） | 私有依赖 | **需查分支名**：执行 1.2 + 1.3 |
| 无法判断（URL 缺失或为相对路径） | 不确定 | **保守处理，执行 1.2 + 1.3** |

> **「公开平台免查分支名」只免 1.2 分支名分析，不免 1.3 提交历史检查**：开源依赖仍需进入 1.3 看当前版本是否含 ARM 改动，再按 1.4 综合判定。（免检清单比对见 1.5，须在 1.2/1.3 之前先做。）

---

## 1.2 远端分支检查

对判定为**私有依赖**的 Git 仓库，检查远端是否有 ARM 相关分支：

```bash
# 列出远端所有分支，过滤 ARM 相关关键字
git ls-remote --heads <remote_url> | grep -iE "arm|aarch64|kunpeng"
```

| 结果 | 标记 |
|------|------|
| 存在匹配分支 | **「有 ARM 分支，需确认是否已切换」** |
| 无匹配分支 | 继续执行 1.3 检查提交历史 |

---

## 1.3 本地提交历史检查

对**已成功 clone 到本地**的依赖（submodule 或 FetchContent 已拉取），检查提交历史：

```bash
# 在依赖目录中执行
cd <依赖目录>
git log --oneline --all | grep -iE "arm|aarch64|cross.?compil|kunpeng" | head -5
```

| 结果 | 标记 |
|------|------|
| 存在匹配提交 | **「历史中有 ARM 相关改动，需确认是否已合入当前版本」** |
| 无匹配提交 | 进入综合判定 |

> 若依赖尚未 clone 到本地（如 `http_archive` 预编译包），跳过本节，直接进入 1.4 综合判定。

---

## 1.4 综合判定

根据 1.2 + 1.3 的探测结果，对每个依赖给出最终状态：

| 探测结果 | 状态标记 | 处理建议 |
|----------|---------|---------|
| 有 ARM 分支 + 有 ARM 提交历史 | 可能兼容 | 确认当前使用版本是否包含 ARM 改动 |
| 有 ARM 分支，无 ARM 提交历史 | 待确认 | 检查 ARM 分支内容是否可用 |
| 无 ARM 分支 + 无 ARM 提交历史 | 未知兼容性 | **需用户手动确认是否兼容 ARM** |
| 开源依赖（1.1 免查分支、未执行 1.2）+ 有 ARM 提交历史 | 可能兼容 | 确认当前使用版本是否包含 ARM 改动 |
| 开源依赖（1.1 免查分支、未执行 1.2）+ 无 ARM 提交历史 | 未知兼容性 | **需用户手动确认是否兼容 ARM**（或已在 1.5 免检清单中确认） |
| 预编译包（HTTP 下载，非 Git） | 架构绑定 | 必须获取 ARM 版本或重新编译，进入 第二部分 溯源 |
| 无法访问远端（网络受限） | 未知兼容性 | 在报告中注明「无法访问远端，无法检查 ARM 分支」，标为待确认 |

> **所有标记为「警告」的依赖，必须出现在报告末尾的「待用户手动确认清单」中**。

---

## 1.5 与已确认清单比对（按依赖库名匹配）

> 这是「查到分支 → 用户确认 → 阶段 3 末尾切换」闭环的查询端。`$WORK_DIR/kunpeng_confirmed.md` 按**依赖库**索引，每个依赖库一条 ARM 适配记录（分支/commit/路径）。

**在执行 1.2/1.3 探测之前**，先读本清单，命中的依赖免探测、免询问，并记下 ARM 适配信息供阶段 3 末尾切换使用：

```bash
# 实例不存在时从 skill 模板复制（首次使用）；读取 $WORK_DIR 下的可写实例
[ -f "$WORK_DIR/kunpeng_confirmed.md" ] || \
  cp "$SKILL_DIR/dependency-analysis/assets/kunpeng_confirmed_template.md" "$WORK_DIR/kunpeng_confirmed.md"
cat "$WORK_DIR/kunpeng_confirmed.md" 2>/dev/null
```

### 比对方法

对当前依赖，按**依赖库名**在清单中查找 `## <依赖库名>` 区块：

| 情况 | 处理 |
|------|------|
| 清单中**无**该依赖库区块 | 未命中，继续 1.2/1.3 探测 |
| 有区块，且该依赖的构建配置**尚未**切换到记录的 ARM 分支/commit/URL | 命中 → 标记「已知 ARM 适配」，在报告中**展示一条**并标注「待阶段 3 末尾切换」；把区块记录的「ARM 适配分支/commit」「ARM URL/路径」「备注」记入该依赖，**供阶段 3 末尾经用户确认后切换使用**（不要在阶段 2 自行切换，切换统一在阶段 3 末尾且必须先经用户确认） |
| 有区块，且项目当前配置**已经**是记录的 ARM 版本 | 已确认且已切换，从报告中完全省略 |
| 「备注」列含特殊操作（如「需先注释自动签出」「ABI=0」） | 一并记入该依赖备注，阶段 3 末尾切换前必须先完成这些前置操作 |

> 命中即免探测、免询问：不再执行 1.2/1.3 远端/历史探测，也不进入报告末尾的「待用户手动确认清单」。但**「免询问」仅限阶段 2 的探测环节**——阶段 3 末尾真正切换分支前仍必须经用户逐项确认（见 [kunpeng-confirmed-write.md](kunpeng-confirmed-write.md) 步骤 4「切换前必须用户确认」）。

---

# 第二部分：预编译二进制识别与源码溯源

> 覆盖两类来源：
> - **仓库内置二进制**：直接 `git commit` 到代码仓的 `.so`/`.a`/可执行文件
> - **外部无源码依赖**：`http_archive`/`ExternalProject_Add`/脚本下载的预编译包（依赖扫描阶段已识别）

## 2.1 扫描仓库内置二进制

在 `$REPO_PATH` 下执行：

```bash
# 查找直接提交的 .so/.a/.dylib 文件
find "$REPO_PATH" -not -path "*/.git/*" \
  \( -name "*.so" -o -name "*.so.*" -o -name "*.a" -o -name "*.dylib" \) | sort

# 查找无扩展名但具有可执行权限的二进制文件（排除脚本）
find "$REPO_PATH" -not -path "*/.git/*" -type f -executable \
  ! -name "*.sh" ! -name "*.py" ! -name "*.pl" | sort
```

---

## 2.2 判断二进制文件的目标架构

对每个发现的二进制文件执行 `file` 命令：

```bash
# 单文件检测
file <binary_file>

# 批量检测所有 .so/.a
find "$REPO_PATH" -not -path "*/.git/*" \
  \( -name "*.so" -o -name "*.so.*" -o -name "*.a" \) \
  -exec sh -c 'echo "--- $1 ---"; file "$1"' _ {} \;

# 对 .a 静态库检查内部第一个目标文件的架构
for f in $(find "$REPO_PATH" -name "*.a" -not -path "*/.git/*"); do
  echo "--- $f ---"
  ar t "$f" 2>/dev/null | head -1 | xargs -I{} sh -c \
    'ar x "'$f'" {} --output /tmp/ar_check 2>/dev/null && file /tmp/ar_check/{}'
done
```

架构判定规则：

| `file` 输出关键字 | 架构 | ARM 可用性 |
|-----------------|------|----------|
| `x86-64` / `x86_64` / `Intel 80386` / `amd64` | x86 | 不可用，需替换，**进入 2.3 溯源** |
| `aarch64` / `ARM aarch64` / `ARM64` | ARM64 | 可直接使用 |
| `ARM` (32-bit) | ARM32 | 需确认是否兼容 64-bit 环境 |
| `universal binary` / `fat binary` | 多架构 | 含 ARM，可使用 |
| `current ar archive` | 静态库（需进一步检查内部） | 按上述规则检查内部 `.o` 文件 |

> 所有判定为 **x86 架构**的二进制文件，必须进入 2.3 执行源码溯源。

---

## 2.3 四级源码溯源（针对所有 x86 架构二进制）

对每个确认为 **x86 架构**的预编译文件，按以下优先级依次尝试，找到即停止：

---

### 第一优先级：构建配置中已指定源码地址

检查 `WORKSPACE` / `CMakeLists.txt` / 脚本中是否已有对应的源码 URL 或 Git 地址：

```bash
# 在主构建配置中搜索该依赖名（适配 Bazel/CMake/Shell 脚本）
grep -rn "<依赖名>" \
  "$REPO_PATH/WORKSPACE" \
  "$REPO_PATH/CMakeLists.txt" \
  "$REPO_PATH"/cmake/*.cmake \
  "$REPO_PATH"/*.sh \
  "$REPO_PATH"/scripts/ \
  2>/dev/null | grep -E "http|https|git@|ssh://"
```

若找到 → 记录「**第1级**：可从构建配置中指定的源码地址 `<url>` 重新编译」。

> 各构建系统在该优先级会命中的位置：Bazel 在 `$REPO_PATH/WORKSPACE` 的 `git_repository`/`http_archive`；CMake 在 `$REPO_PATH/CMakeLists.txt` 与 `$REPO_PATH/cmake/*.cmake` 的 `FetchContent_Declare`/`ExternalProject_Add`；Blade 在 `BUILD` 文件的源码来源字段。

---

### 第二优先级：项目目录内存在对应源码

检查项目自身目录树是否携带了该库的源码（vendor/third_party 等目录）：

```bash
# 搜索与该依赖同名的源码文件或目录
find "$REPO_PATH" -not -path "*/.git/*" \
  \( -name "<依赖名>" -type d \
  -o -name "<依赖名>.cc" -o -name "<依赖名>.cpp" -o -name "<依赖名>.c" \)

# 常见源码目录
ls "$REPO_PATH"/{third_party,vendor,deps,external,contrib}/ 2>/dev/null
```

若找到 → 记录「**第2级**：项目内已包含源码，路径 `<路径>`，可直接用于 ARM 编译」。

---

### 第三优先级：当前工作目录下存在源码

检查当前工作目录（通常包含多个子项目的根目录）下是否有该库的源码：

```bash
find . -not -path "*/.git/*" -maxdepth 5 \
  \( -name "<依赖名>" -type d \
  -o -iname "*<依赖名>*" -name "*.cmake" \
  -o -iname "*<依赖名>*" -name "CMakeLists.txt" \) 2>/dev/null
```

若找到 → 记录「**第3级**：工作区中存在源码，路径 `<路径>`，可复用」。

---

### 第四优先级：从公开来源获取

前三步均未找到时，给出公开获取建议：

**（A）判断是否为开源项目**：

| 检查项 | 操作 |
|--------|------|
| GitHub/GitLab 同名开源项目 | 手动搜索 `https://github.com/search?q=<依赖名>` |
| 系统包管理器 | `yum search <依赖名>` / `apt-cache search <依赖名>` |
| 系统镜像源 ARM 版本 | `yum --releasever=<ver> --forcearch=aarch64 info <包名>` |

**（B）查询鲲鹏软件仓（HiKunpeng）**：

```bash
# 1. 浏览器手动搜索（需网络）
#    https://www.hikunpeng.com/developer/software → 搜索 <依赖名>

# 2. 若已配置鲲鹏 repo
yum --enablerepo=kunpeng search <依赖名> 2>/dev/null

# 3. openEuler 镜像源（aarch64 版本）
#    https://repo.openeuler.org/openEuler-<ver>/everything/aarch64/Packages/
```

根据查询结果给出结论：

| 查询结果 | 溯源结论 |
|----------|---------|
| 系统包管理器中存在 ARM 包 | **第4级**：`yum/apt install <包名>` 直接安装 ARM 版本 |
| 鲲鹏软件仓中存在 ARM 二进制 | **第4级**：从鲲鹏软件仓下载，链接：`<url>` |
| 开源仓库存在源码，无预编译包 | **第4级**：需从源码自行交叉编译，参考上游构建文档 |
| 均未找到 | **第4级**：需联系该库维护团队，确认是否支持 ARM/aarch64 |

---

## 2.4 RPM spec 文件检查

在执行第四优先级前，先检查项目内是否存在对应 `.spec` 文件，若有可直接自助打包：

```bash
# 在项目根目录及子模块中搜索 .spec 文件
find "$REPO_PATH" -not -path "*/.git/*" -name "*.spec" | sort

# 快速提取 spec 文件关键字段
for f in $(find "$REPO_PATH" -not -path "*/.git/*" -name "*.spec"); do
  echo "=== $f ==="
  grep -E "^Name:|^Version:|^Source0:|%ifarch" "$f"
done
```

判定规则：

| spec 文件情况 | 降级 | 处理建议 |
|-------------|------|---------|
| Source0 为公开 URL，且含 `%ifarch aarch64` 适配段 | 可自助打包 | 在 aarch64 上直接 `rpmbuild -ba <name>.spec` |
| Source0 为公开 URL，无 `%ifarch aarch64` 段 | 大概率可打包 | 在 aarch64 上尝试 `rpmbuild -ba <name>.spec` |
| Source0 为私有地址 | 需确认源码可访问性 | 确认私有源码地址在 aarch64 环境可访问后再执行 |
| 未找到对应 spec 文件 | 不变 | 继续走第四优先级公开来源查询 |

> 找到 spec 且 `Source0` 为公开 URL 的，在报告中标注「spec 已就绪，可在 aarch64 上自助 `rpmbuild -ba <name>.spec` 打包」。

---

## 2.5 截断策略（大量二进制文件时）

当代码仓扫描到的预编译二进制文件数量较多时，按以下规则截断以保持报告可读性：

### 截断阈值

| 报告章节 | 每个目录分组最大展示条数 | 超出处理方式 |
|---------|----------------------|------------|
| 第 6 节「仓库内置二进制」 | 10 条 | 折叠，末尾注明「共 N 个文件，仅展示前 10 条，完整列表见附录」 |
| 第 4.2 节「预编译二进制包」 | 20 条 | 同上 |
| 第 9.1 节「架构移植 — 预编译二进制」溯源表 | 15 条 | 同上 |

### 分组与截断步骤

1. **按一级目录前缀分组**：如 `lib/`、`third_party/`、`deps/grpc/lib/` 各为一组
2. **每组最多展示 10 条**，x86 架构的文件优先展示，不截断
3. **报告末尾新增附录章节**，列出完整清单（使用 `<details>` 折叠块）

### 示例截断格式

```markdown
## 6. 仓库内置二进制（直接提交的 .so/.a）

> 共发现 **87** 个预编译二进制文件，按目录分组展示，每组最多 10 条。完整列表见「附录 A」。

### 来自 `lib/`（共 52 个，展示前 10 条）

| 文件路径 | 架构 | 用途 | 溯源结果 |
|----------|------|------|---------|
| `lib/libfoo.so` | x86-64 | ... | 第1级 |
| *(省略 42 条，见附录 A)* | | | |
```

附录格式：

```markdown
## 附录 A：完整预编译二进制清单

<details>
<summary>展开完整列表（共 87 个文件）</summary>

| 文件路径 | 架构 |
|----------|------|
| `lib/libfoo.so` | x86-64 |

</details>
```

---

## 调用示例（从 repo-analysis-flow.md 的视角）

```
# Step 3（ARM 兼容性探测）+ Step 4（二进制识别）伪代码
for dep in $deps_list:
  if dep.type in [git_repository, submodule, FetchContent_GIT]:
    read compat-and-binary-detect.md 第一部分
    probe_result = execute_arm_probe(dep.url, dep.local_path)   # 1.1 → 1.5
    dep.arm_status = probe_result.status    # 已确认 / 可能兼容 / 待确认 / 未知兼容性
    dep.arm_note   = probe_result.note
  else:
    # http_archive/预编译包 → 交由 第二部分 处理
    dep.arm_status = "架构绑定"

# Step 4：对所有仓库执行二进制扫描（无论构建系统）
read compat-and-binary-detect.md 第二部分
binary_list = scan_and_trace($REPO_PATH)   # 2.1 → 2.5
```
