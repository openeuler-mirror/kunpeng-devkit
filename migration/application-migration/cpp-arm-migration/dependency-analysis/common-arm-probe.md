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

## Section 5：与已确认清单比对（按依赖库 + 当前版本匹配）

> 这是「查到分支 → 用户确认 → 阶段 C 末尾切换」闭环的查询端。`arm_confirmed.md` 按**依赖库**索引，每个依赖库下用「项目当前引用的版本」作为匹配键记录已验证的 ARM 适配分支/commit/路径。同一仓库可能有多个版本的多条记录（不同项目引用不同分支），逐行匹配。

**在执行 Section 2/3 探测之前**，先读本清单，命中的依赖免探测、免询问，并记下 ARM 适配信息供阶段 C 末尾切换使用：

```bash
# 读取已确认清单（skill 目录下）
cat "<cpp-arm-migration skill目录>/arm_confirmed.md" 2>/dev/null
```

### 比对方法

对当前依赖，取其**依赖库名**与**项目当前引用的版本**（git 类依赖的 commit/tag/分支名，预编译包的版本号），在清单中按两步匹配：

| 步骤 | 操作 |
|------|------|
| ① 定位区块 | 在清单中查找 `## <依赖库名>` 区块；不存在 → 未命中，继续 Section 2/3 探测 |
| ② 匹配版本 | 在该区块表格中，用项目当前引用的版本匹配「项目引用版本 (x86)」列；无匹配行 → 未命中，继续 Section 2/3 探测 |

### 命中后的处理

| 命中情况 | 处理 |
|---------|------|
| 匹配到行，且该依赖的构建配置**尚未**切换到记录的 ARM 分支/commit/URL | 标记「✅ 已知 ARM 适配」，**从报告中省略**该依赖；同时把匹配行的「ARM 适配分支/commit」「ARM URL/路径」「备注」记入该依赖，**供阶段 C 末尾经用户确认后切换使用**（不要在阶段 B 自行切换，切换动作统一在阶段 C 末尾且必须先经用户确认） |
| 匹配到行，且项目当前配置**已经**是记录的 ARM 版本 | ✅ 已确认且已切换，从报告中完全省略 |
| 「备注」列含特殊操作（如「需先注释自动签出」「ABI=0」） | 一并记入该依赖备注，阶段 C 末尾切换前必须先完成这些前置操作 |

> 命中即免探测、免询问：不再执行 Section 2/3 远端/历史探测，也不进入报告末尾的「待用户手动确认清单」。但**「免询问」仅限阶段 B 的探测环节**——阶段 C 末尾真正切换分支前仍必须经用户逐项确认（见 [arm-confirmed-write.md](arm-confirmed-write.md) 步骤 5「切换前必须用户确认」）。
>
> 未命中（清单无该依赖库区块，或区块内无匹配版本行）的依赖，继续走 Section 2/3 正常探测流程。

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
