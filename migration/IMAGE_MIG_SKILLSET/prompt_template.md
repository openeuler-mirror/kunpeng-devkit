# Prompt 模板：Dockerfile → ARM64 迁移

> 本文件提供各场景的 prompt 模板，直接复制粘贴到对话框使用。
> `<>` 内的内容需替换为实际值，`[可选]` 内容按需填写。

---

## 输入格式说明

本 Skill 需要两个输入文件，**在使用任何场景模板前先准备好**：

### 输入 1：镜像列表文件（必需）

列出所有待迁移的镜像名，每行一条，格式如下：

```
# migration_list.txt（每行一个镜像名，# 开头为注释）
registry.yourcompany.com/project-a:v1.0
registry.yourcompany.com/project-b:v2.3
registry.yourcompany.com/project-c:latest
```

### 输入 2：Dockerfile 索引文件

描述每个镜像对应的 Dockerfile 路径和构建上下文，格式如下：

```yaml
# dockerfile_index.yaml
registry.yourcompany.com/project-a:v1.0:
  dockerfile: projects/project-a/Dockerfile
  context:    projects/project-a/

registry.yourcompany.com/project-b:v2.3:
  dockerfile: projects/project-b/Dockerfile
  context:    projects/project-b/

registry.yourcompany.com/project-c:latest:
  dockerfile: projects/project-c/Dockerfile
  context:    projects/project-c/
```

> 若所有 Dockerfile 命名规律一致（如都在 `<项目名>/Dockerfile`），也可直接在 prompt 中描述规律，无需单独文件。

---

## 场景 1：批量迁移（标准场景，推荐入口）

```
将一批 x86_64 Docker 镜像迁移到 linux/arm64，ARM 执行机对内网源码仓和镜像仓有直接访问权限。

【必读文件】执行任何操作前，先读取以下文件：
1. <工作目录>/IMAGE_MIG_SKILLSET/DOCKERFILE_MIGRATION.md   ← 完整执行流程
2. <工作目录>/IMAGE_MIG_SKILLSET/config.yaml               ← 环境参数（仓库地址等）★ 启动前确认已填写
3. <工作目录>/IMAGE_MIG_SKILLSET/BUILD_KNOWLEDGE.md         ← 构建/修复知识库

【输入文件】
- 待迁移镜像列表：<migration_list.txt 路径>
- Dockerfile 索引：<dockerfile_index.yaml 路径>

【执行方式】
按 config.yaml § 0 WORKER_COUNT 决定并发度：
  WORKER_COUNT = 1：逐一迁移，每项完成后立即写报告
  WORKER_COUNT ≥ 2：主 Agent 调度，并发执行迁移任务

【通用规则】
- 每个项目完成后立即写报告，不等全部完成
- 已有 build_reports/<project>.json 的项目直接跳过
- 每个项目严格按 PHASE 1 → 2 → 3 → 4 → 5 顺序执行

【报告路径】
config.yaml REPORT_DIR（默认：arm_builds_<YYYYMMDD>/build_reports/）
并发模式还会生成总览报告：_summary.json
```

---

## 场景 2：单个镜像迁移（调试/验证单个）

```
将以下 x86_64 镜像迁移到 linux/arm64，ARM 执行机对内网源码仓和镜像仓有直接访问权限。

【必读文件】
1. <工作目录>/IMAGE_MIG_SKILLSET/DOCKERFILE_MIGRATION.md
2. <工作目录>/IMAGE_MIG_SKILLSET/config.yaml    ← 先确认已填写实际仓库地址
3. <工作目录>/IMAGE_MIG_SKILLSET/BUILD_KNOWLEDGE.md

【迁移目标】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- Dockerfile：<path/to/Dockerfile>
- 构建上下文：<path/to/build_context/>

【执行顺序】
严格按 DOCKERFILE_MIGRATION.md PHASE 1 → 2 → 3 → 4 → 5 执行：
  PHASE 1: 读取 config.yaml，解析 Dockerfile，对每条指令分类标记
  PHASE 2: 输出迁移决策表（若有 [WARN-*] 项，先列出等我确认）
  PHASE 3: 生成 ARM64 Dockerfile，保存到 config.yaml OUTPUT_DOCKERFILE_DIR
  PHASE 4: docker build --platform linux/arm64，失败按 BUILD_KNOWLEDGE.md 修复
  PHASE 5: 基础存活验证 + 写报告到 config.yaml REPORT_DIR

【约束】
- 同一问题最多重试 5 次（config.yaml MAX_RETRY），超过写 FAILED(EXCEEDED_ATTEMPTS) 报告
- 构建超过 60 分钟写 FAILED(TIMEOUT) 报告
- git clone 内网仓和内网 pip 直接保留（ARM 机有权限），不要改为 COPY 或跳过
- 遇到新错误修复后，先写项目报告，再追加到 BUILD_KNOWLEDGE.md 对应章节
```

---

## 场景 3：仅生成决策表（不构建，供人工审核）

```
分析下面的 x86_64 Dockerfile，输出 ARM64 迁移决策表，不构建镜像。

【必读文件】
1. <工作目录>/IMAGE_MIG_SKILLSET/DOCKERFILE_MIGRATION.md
2. <工作目录>/IMAGE_MIG_SKILLSET/config.yaml

【迁移目标】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- Dockerfile：<path/to/Dockerfile>

【任务】
仅执行 PHASE 1 + PHASE 2（分析阶段），**不构建镜像，不生成新 Dockerfile**。

【输出要求】
1. 完整的迁移决策表（DOCKERFILE_MIGRATION.md PHASE 2 格式）
2. 逐条说明每个 FROM / RUN / ENV 的处理动作及原因
3. 特别列出：
   - 所有 [WARN-*] 项（需人工确认）
   - 内网基础镜像的推断结果列表（需确认推断的 ARM64 tag 实际存在）
   - 所有被保留的 git clone 和内网 pip（确认 ARM 机权限）
   - COPY/wget 引入的外部资源及其获取方式
4. 最后给出：预计变更总数、预计保留总数、需人工确认项数
```

---

## 场景 4：修复单次构建失败（重试）

```
以下 ARM64 构建失败，阅读错误日志并修复。

【必读文件】
1. <工作目录>/IMAGE_MIG_SKILLSET/config.yaml
2. <工作目录>/IMAGE_MIG_SKILLSET/BUILD_KNOWLEDGE.md

【任务】
修复 <project_name> 的 ARM64 构建失败。

【当前状态】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- ARM64 Dockerfile 路径：<path/to/Dockerfile.arm64>
- 已尝试次数：<N>（若 ≥ 5 次则直接写 FAILED(EXCEEDED_ATTEMPTS) 报告，不再尝试）
- 失败错误（粘贴报错信息）：
  <粘贴 docker build 错误输出，至少包含最后 30 行>

【执行规则】
1. 先查 BUILD_KNOWLEDGE.md 是否有匹配的错误处理方案
2. 修复 Dockerfile（在修改处追加 # [FIX-<N>] 说明）
3. 重新 docker build --platform linux/arm64
4. 成功后执行基础存活验证
5. 立即更新 build_reports/<project_name>.json
6. 若修复了新问题，追加到 BUILD_KNOWLEDGE.md 对应章节
```

---

## 场景 5：config.yaml 初始化向导

```
初始化 IMAGE_MIG_SKILLSET 的 config.yaml 配置文件。

【文件路径】
<工作目录>/IMAGE_MIG_SKILLSET/config.yaml

【我的环境信息】
- 内网 Git 仓库域名：<例：git.mycompany.com>
- 内网 Docker 镜像仓：<例：registry.mycompany.com>
- 内网 PyPI 地址：<例：pypi.mycompany.com，无则填 无>
- 是否启用内网隔离模式：<是/否>
- 并发子 Agent 数量：<例：3，资源少则填 1>

【任务】
根据以上信息，修改 config.yaml 中的以下字段：
  WORKER_COUNT
  GIT_HOSTS
  INTERNAL_REGISTRIES
  INTERNAL_PYPI_HOSTS
  AIRGAP_MODE

其余字段保持默认值不变。修改后输出完整的 config.yaml 内容。
```

---

## 使用技巧

### 技巧 1：先确认 config.yaml 已填写

在 prompt 中明确要求 Agent 先读 config.yaml，并确认关键字段：
```
执行前先读取 config.yaml，确认 GIT_HOSTS、INTERNAL_REGISTRIES
已按实际环境填写，若有 <...> 占位符则停下来告诉我。
```

### 技巧 2：在 PHASE 2 决策表后暂停

若想人工审核决策表再执行构建：
```
执行 PHASE 1 和 PHASE 2 后，先输出决策表等我确认，
确认后再继续 PHASE 3（生成 Dockerfile）和 PHASE 4（构建）。
```

### 技巧 3：指定基础镜像替换方式

若已知 ARM64 镜像 tag，直接在 prompt 中说明，减少 Agent 猜测：
```
FROM 行的基础镜像替换规则：
  registry.company.com/base:v1.0 → registry.company.com/base-arm64:v1.0
直接使用上述替换，无需自动推断。
```

### 技巧 4：限制输出 Dockerfile 格式

```
生成的 ARM64 Dockerfile：
- 每处修改必须附行内注释 # [标记] 原因
- 保留原 Dockerfile 的层结构（不合并/不拆分 RUN 层）
- 文件头注释块必须列出所有变更
```

### 技巧 5：dockerfile_index.yaml 规律替代

若 Dockerfile 路径有规律，可直接描述，不需要索引文件：
```
Dockerfile 路径规律：所有项目的 Dockerfile 均位于 <projects/{镜像名最后一段}/Dockerfile>
构建上下文规律：<projects/{镜像名最后一段}/>
```
