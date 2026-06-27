# 预编译二进制识别与源码溯源（通用共享模块）

> 本文件是**所有构建系统共用**的预编译二进制识别与溯源逻辑。
> 由 [analyze-one-repo.md](analyze-one-repo.md) 的 Step 4 调用，不直接由用户触发。
>
> 覆盖两类来源：
> - **仓库内置二进制**：直接 `git commit` 到代码仓的 `.so`/`.a`/可执行文件
> - **外部无源码依赖**：`http_archive`/`ExternalProject_Add`/脚本下载的预编译包（依赖扫描阶段已识别）

---

## Section 1：扫描仓库内置二进制

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

## Section 2：判断二进制文件的目标架构

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
| `x86-64` / `x86_64` / `Intel 80386` | x86 | ❌ 不可用，需替换，**进入 Section 3 溯源** |
| `aarch64` / `ARM aarch64` / `ARM64` | ARM64 | ✅ 可直接使用 |
| `ARM` (32-bit) | ARM32 | ⚠️ 需确认是否兼容 64-bit 环境 |
| `universal binary` / `fat binary` | 多架构 | ✅ 含 ARM，可使用 |
| `current ar archive` | 静态库（需进一步检查内部） | 按上述规则检查内部 `.o` 文件 |

> 所有判定为 **x86 架构**的二进制文件，必须进入 Section 3 执行源码溯源。

---

## Section 3：四级源码溯源（针对所有 x86 架构二进制）

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
| 系统包管理器中存在 ARM 包 | ✅ **第4级**：`yum/apt install <包名>` 直接安装 ARM 版本 |
| 鲲鹏软件仓中存在 ARM 二进制 | ✅ **第4级**：从鲲鹏软件仓下载，链接：`<url>` |
| 开源仓库存在源码，无预编译包 | 🟡 **第4级**：需从源码自行交叉编译，参考上游构建文档 |
| 均未找到 | 🔴 **第4级**：需联系该库维护团队，确认是否支持 ARM/aarch64 |

---

## Section 4：RPM spec 文件检查

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
| Source0 为公开 URL，且含 `%ifarch aarch64` 适配段 | ✅ 可自助打包 | 在 aarch64 上直接 `rpmbuild -ba <name>.spec` |
| Source0 为公开 URL，无 `%ifarch aarch64` 段 | 🟡 大概率可打包 | 在 aarch64 上尝试 `rpmbuild -ba <name>.spec` |
| Source0 为私有地址 | 🟡 需确认源码可访问性 | 确认私有源码地址在 aarch64 环境可访问后再执行 |
| 未找到对应 spec 文件 | 🔴 不变 | 继续走第四优先级公开来源查询 |

> ✅ 找到 spec 且 `Source0` 为公开 URL 的，在报告中标注「spec 已就绪，可在 aarch64 上自助 `rpmbuild -ba <name>.spec` 打包」。

---

## Section 5：截断策略（大量二进制文件时）

当单个仓库扫描到的预编译二进制文件数量较多时，按以下规则截断以保持报告可读性：

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

> ⚠️ 共发现 **87** 个预编译二进制文件，按目录分组展示，每组最多 10 条。完整列表见「附录 A」。

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
