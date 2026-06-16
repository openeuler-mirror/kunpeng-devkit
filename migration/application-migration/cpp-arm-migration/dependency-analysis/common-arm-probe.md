# ARM 兼容性探测（通用共享模块）

> 本文件是**所有构建系统共用**的 ARM 兼容性探测逻辑。
> 由 [analyze-one-repo.md](analyze-one-repo.md) 的 Step 3 调用，适用于 Git 类依赖（submodule、`git_repository`、`FetchContent` GIT 模式）。
>
> **免检清单比对也在本文件执行**，确保每个仓库分析时都能正确跳过已确认兼容的依赖。

---

## Section 1：私有 URL 判断（公开平台豁免）

对每个依赖的 URL / remote，按以下规则判断是否需要 ARM 兼容性探测：

| URL 特征 | 判断 | 处理 |
|----------|------|------|
| `github.com`、`gitlab.com`、`bitbucket.org` 等公开平台 | ✅ 开源 | **豁免**，跳过 ARM 探测（若版本超过 2 年未更新，建议在备注中提示确认） |
| 私有域名（如 `*.internal`、组织内部对象存储域名、IP 地址形式） | ⚠️ 私有依赖 | **需执行 ARM 探测**（Section 2 + Section 3） |
| 私有 Git（SSH 形式，域名非公开平台） | ⚠️ 私有依赖 | **需执行 ARM 探测** |
| 无法判断（URL 缺失或为相对路径） | ⚠️ 不确定 | **保守处理，执行 ARM 探测** |

> ✅ **已被豁免的开源依赖无需进入 Section 2/3，直接跳到 Section 4 做免检清单比对即可**。

---

## Section 2：远端分支检查

对判定为**私有依赖**的 Git 仓库，检查远端是否有 ARM 相关分支：

```bash
# 列出远端所有分支，过滤 ARM 相关关键字
git ls-remote --heads <remote_url> | grep -iE "arm|aarch64|kunpeng"
```

| 结果 | 标记 |
|------|------|
| 存在匹配分支 | **「有 ARM 分支，需确认是否已切换」** |
| 无匹配分支 | 继续执行 Section 3 检查提交历史 |

---

## Section 3：本地提交历史检查

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

> ⚠️ 若依赖尚未 clone 到本地（如 `http_archive` 预编译包），跳过本节，直接进入 Section 4 综合判定。

---

## Section 4：综合判定

根据 Section 2 + Section 3 的结果，对每个非开源依赖给出最终状态：

| 探测结果 | 状态标记 | 处理建议 |
|----------|---------|---------|
| 有 ARM 分支 + 有 ARM 提交历史 | 🟡 可能兼容 | 确认当前使用版本是否包含 ARM 改动 |
| 有 ARM 分支，无 ARM 提交历史 | 🟡 待确认 | 检查 ARM 分支内容是否可用 |
| 无 ARM 分支 + 无 ARM 提交历史 | 🔴 未知兼容性 | **⚠️ 需用户手动确认是否兼容 ARM** |
| 预编译包（HTTP 下载，非 Git） | 🔴 架构绑定 | 必须获取 ARM 版本或重新编译，进入 [common-binary-detect.md](common-binary-detect.md) 溯源 |
| 无法访问远端（网络受限） | 🔴 未知兼容性 | 在报告中注明「⚠️ 无法访问远端，无法检查 ARM 分支」，标为待确认 |

> **所有 🔴 标记的依赖，必须出现在报告末尾的「待用户手动确认清单」中**。

---

## Section 5：与免检清单比对

在执行 Section 2/3 探测之前，**先读取免检清单**，已确认兼容的依赖直接跳过探测：

```bash
# 读取免检清单（skill 目录下）
cat "<cpp-arm-migration skill目录>/arm_confirmed.md" 2>/dev/null
```

`arm_confirmed.md` 中每个依赖记录了 ARM 适配方式，按以下逻辑处理：

| 情况 | 处理 |
|------|------|
| `arm_confirmed.md` 中**不存在**该依赖名 | 继续执行 Section 2/3 探测 |
| 存在且项目当前配置**已与**记录的 ARM 适配方式一致 | ✅ 已确认兼容，**从报告中完全省略**（包括所有章节的表格） |
| 存在但项目当前配置**未采用**记录的 ARM 适配方式 | ⚠️ 在待确认清单中提示：「已知该依赖的 ARM 适配方案：`<记录内容>`，当前未采用，是否执行切换？」 |

**比对方法**——根据 `arm_confirmed.md` 中记录的字段与项目当前构建配置逐项对比：

| `arm_confirmed.md` 字段 | 对比的项目配置 | 对比方式 |
|-------------------------|--------------|---------|
| `依赖库` | WORKSPACE/`.gitmodules`/BUILD 中的 `name` | 精确匹配 |
| `ARM name` | 当前构建配置中该依赖的 `name` 值 | 若 `ARM name` ≠ `—`，检查当前 name 是否已切换 |
| `ARM url` | 当前构建配置中该依赖的 URL | 若 `ARM url` ≠ `—`，检查当前 URL 是否已替换 |
| `ARM commit/tag` | 当前构建配置中该依赖的 commit/tag | 若 ≠ `—`，检查当前值是否匹配 |
| `备注` | 对应的特殊操作是否已执行 | 按备注内容逐条检查 |

> 配置不一致时**不做自动修改**，仅在报告中提示用户，由用户决定是否切换。

---

## 调用示例（从 analyze-one-repo.md 的视角）

```
# Step 3 伪代码（在 analyze-one-repo.md 中执行）
for dep in $deps_list:
  if dep.type in [git_repository, submodule, FetchContent_GIT]:
    read common-arm-probe.md
    probe_result = execute_arm_probe(dep.url, dep.local_path)
    dep.arm_status = probe_result.status    # 🟡 / 🔴 / ✅
    dep.arm_note   = probe_result.note
  else:
    # http_archive/预编译包 → 交由 common-binary-detect.md 处理
    dep.arm_status = "🔴 架构绑定"
```
