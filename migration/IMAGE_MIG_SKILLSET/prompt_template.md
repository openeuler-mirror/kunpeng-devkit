# Prompt 模板：Dockerfile → ARM64 迁移

> 本文件提供各场景的 prompt 模板。`<>` 内容需替换为实际值。

---

## 输入格式说明

### 输入 1：镜像列表（必需）

```
# migration_list.txt
registry.yourcompany.com/project-a:v1.0
registry.yourcompany.com/project-b:v2.3
```

### 输入 2：Dockerfile 索引

```yaml
# dockerfile_index.yaml
registry.yourcompany.com/project-a:v1.0:
  dockerfile: projects/project-a/Dockerfile
  context:    projects/project-a/

registry.yourcompany.com/project-b:v2.3:
  dockerfile: projects/project-b/Dockerfile
  context:    projects/project-b/
```

> 若路径有规律（如 `<项目名>/Dockerfile`），可直接在 prompt 中描述，无需索引文件。

---

## 场景 1：批量迁移（标准场景）

```
将一批 x86_64 Docker 镜像迁移到 linux/arm64，ARM 执行机对内网源码仓和镜像仓有直接访问权限。

【必读文件】执行前先读取：
1. DOCKERFILE_MIGRATION.md   ← 完整执行流程
2. config.yaml               ← 环境参数 ★ 确认已填写
3. BUILD_KNOWLEDGE.md        ← 构建/修复知识库

【输入文件】
- 待迁移镜像列表：<migration_list.txt 路径>
- Dockerfile 索引：<dockerfile_index.yaml 路径>

【执行方式】
按 config.yaml WORKER_COUNT 决定：
  = 1：逐一迁移，每项完成后立即写报告
  ≥ 2：主 Agent 调度，并发执行

【规则】
- 每个项目完成后立即写报告，不等全部完成
- 已有 build_reports/<project>.json 的跳过
- 严格按 PHASE 1 → 2 → 3 → 4 → 5 执行

【断点续跑规则】
- 若中途中断（Context 超限/进程重启）：检查已有报告，跳过已完成项目
- 若某项目停在 PHASE 3（Dockerfile 已生成，报告未写）：直接从 PHASE 4 继续构建，不重走 PHASE 1-3
- 若 Worker 上下文超限返回空：按 SKILL.md § ④ 规则 3 执行 resume 或重启

【报告路径】
config.yaml REPORT_DIR（默认 arm_builds_<YYYYMMDD>/build_reports/）
并发模式还生成：_summary.json
```

---

## 场景 2：单个镜像迁移（调试/验证）

```
将以下 x86_64 镜像迁移到 linux/arm64。

【必读文件】
1. DOCKERFILE_MIGRATION.md
2. config.yaml    ← 先确认已填写实际仓库地址
3. BUILD_KNOWLEDGE.md

【迁移目标】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- Dockerfile：<path/to/Dockerfile>
- 构建上下文：<path/to/build_context/>

【执行顺序】
PHASE 1: 读 config.yaml，解析 Dockerfile，对每条指令分类标记
PHASE 2: 输出决策表（若有 [WARN-*] 先列出等确认）
PHASE 3: 生成 ARM64 Dockerfile，保存到 OUTPUT_DOCKERFILE_DIR
PHASE 4: docker build --platform linux/arm64，失败按 BUILD_KNOWLEDGE.md 修复
PHASE 5: 基础存活验证 + 写报告到 REPORT_DIR

【约束】
- 最多重试 5 次（MAX_RETRY），超过写 FAILED(EXCEEDED_ATTEMPTS)
- 构建超过 60 min 写 FAILED(TIMEOUT)
- 遇到新错误修复后，先写项目报告，再追加到 BUILD_KNOWLEDGE.md
```

---

## 场景 3：仅生成决策表（不构建）

```
分析下面的 x86_64 Dockerfile，输出 ARM64 迁移决策表，不构建镜像。

【必读文件】
1. DOCKERFILE_MIGRATION.md
2. config.yaml

【迁移目标】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- Dockerfile：<path/to/Dockerfile>

【任务】
仅执行 PHASE 1 + PHASE 2，**不构建，不生成新 Dockerfile**。

【输出要求】
1. 完整决策表（DOCKERFILE_MIGRATION.md PHASE 2 格式）
2. 逐条说明每个 FROM/RUN/ENV 的处理动作及原因
3. 特别列出：
   - 所有 [WARN-*] 项
   - 内网基础镜像推断结果列表（需确认 ARM64 tag 实际存在）
   - 保留的 git clone 和内网 pip（确认 ARM 机权限）
   - COPY/wget 引入的外部资源及获取方式
4. 给出：预计变更数、保留数、需人工确认项数
```

---

## 场景 4：修复单次构建失败（重试）

```
以下 ARM64 构建失败，阅读错误日志并修复。

【必读文件】
1. config.yaml
2. BUILD_KNOWLEDGE.md

【任务】
修复 <project_name> 的 ARM64 构建失败。

【当前状态】
- 镜像名：<registry.yourcompany.com/project-name:tag>
- ARM64 Dockerfile：<path/to/Dockerfile.arm64>
- 已尝试次数：<N>（≥ 5 次则写 FAILED(EXCEEDED_ATTEMPTS)，不再尝试）
- 失败错误：
  <粘贴 docker build 错误输出，至少最后 30 行>

【执行规则】
1. 先查 BUILD_KNOWLEDGE.md 是否有匹配方案
2. 修复 Dockerfile（修改处追加 # [FIX-<N>] 说明）
3. 重新 docker build --platform linux/arm64
4. 成功后基础存活验证
5. 立即更新 build_reports/<project_name>.json
6. 若修复了新问题，追加到 BUILD_KNOWLEDGE.md
```

---

## 场景 5：纯镜像重构（无 Dockerfile）

```
将一批 x86_64 镜像逆向重建为 linux/arm64，没有 Dockerfile，需通过 docker history + layout + manifest 分析重建。

【必读文件】
1. IMAGE_RECONSTRUCTION.md   ← 完整六阶段流程
2. config.yaml               ← ★ 确认已填写
3. BUILD_KNOWLEDGE.md

【输入文件】
- 待迁移镜像列表：<migration_list.txt 路径>

【执行方式】
六阶段：
  PHASE 0: 逆向信息采集（docker history + layout + manifest）
  PHASE 1: 分析结论汇总（决策矩阵）
  PHASE 2: 离线资源提取（docker cp）
  PHASE 3: 重建 ARM64 Dockerfile
  PHASE 4: 构建验证
  PHASE 5: 运行时测试 + 固化报告

按 config.yaml WORKER_COUNT：
  = 1：逐一迁移
  ≥ 2：主 Agent 调度，并发执行

【规则】
- 每个镜像完成后立即写报告
- 已有 build_reports/<project>.json 的跳过
- 不透明层（CreatedBy 为空/以 #(nop) 开头/为 /bin/bash 无命令且 Size > 0）必须 layout --mode full
- 断点续跑：停在 PHASE 3（Dockerfile 已生成，报告未写）时直接从 PHASE 4 继续，不重走 PHASE 0-3
```

---

## 场景 6：config.yaml 初始化

```
初始化 IMAGE_MIG_SKILLSET 的 config.yaml 配置文件。

【文件路径】
IMAGE_MIG_SKILLSET/config.yaml

【我的环境信息】
- 内网 Git 仓库域名：<例：git.mycompany.com>
- 内网 Docker 镜像仓：<例：registry.mycompany.com>
- 内网 PyPI 地址：<例：pypi.mycompany.com，无则填 无>
- 是否启用内网隔离模式：<是/否>
- 并发子 Agent 数量：<例：3，资源少则填 1>

【任务】
根据以上信息修改 config.yaml 字段：
  WORKER_COUNT
  GIT_HOSTS
  INTERNAL_REGISTRIES
  INTERNAL_PYPI_HOSTS
  AIRGAP_MODE

其余字段保持默认值。修改后输出完整 config.yaml。
```

---

## 使用技巧

### 1. 先确认 config.yaml 已填写

```
执行前先读 config.yaml，确认 GIT_HOSTS、INTERNAL_REGISTRIES
已按实际环境填写，若有 <...> 占位符则停下告诉我。
```

### 2. PHASE 2 决策表后暂停

```
执行 PHASE 1 和 PHASE 2 后，先输出决策表等我确认，
确认后再继续 PHASE 3 和 PHASE 4。
```

### 3. 指定基础镜像替换方式

```
FROM 行替换规则：
  registry.company.com/base:v1.0 → registry.company.com/base-arm64:v1.0
直接使用上述替换，无需自动推断。
```

### 4. 限制输出 Dockerfile 格式

```
生成的 ARM64 Dockerfile：
- 每处修改必须附行内注释 # [标记] 原因
- 保留原 Dockerfile 层结构（不合并/不拆分 RUN 层）
- 文件头注释块列出所有变更
```

### 5. dockerfile_index.yaml 规律替代

```
Dockerfile 路径规律：projects/{镜像名最后一段}/Dockerfile
构建上下文规律：projects/{镜像名最后一段}/
```

### 6. 从指定 PHASE 恢复（已生成 Dockerfile，构建失败）

```
<project_name> 的 ARM64 Dockerfile 已生成（PHASE 3 完成），
在 PHASE 4 构建阶段失败，直接从 PHASE 4 恢复：

【必读文件】
1. BUILD_KNOWLEDGE.md    ← 先查对应错误

【已完成的 PHASE】
PHASE 1-3 已完成，Dockerfile 在 <Dockerfile.arm64 路径>

【当前失败】
错误日志（最后 50 行）：
<粘贴错误输出>

【执行规则】
- 直接修复 Dockerfile，追加 # [FIX-<N>] 注释说明
- 重新 docker build --platform linux/arm64 构建
- 成功后执行 PHASE 5 基础存活验证
- 已尝试次数：<N>（≥ MAX_RETRY 则写 FAILED(EXCEEDED_ATTEMPTS)）
```

### 7. 并发模式下单个 Worker 失败恢复

```
并发迁移中 Worker-<N> 的以下镜像构建失败，需单独补跑：

【镜像列表】
<失败镜像 1>
<失败镜像 2>

【状态】
- 其他 Worker 已完成，报告在 <REPORT_DIR>
- 上述镜像无 build_reports，需重新迁移

【执行方式】
按场景 1 单 Worker 模式（WORKER_COUNT=1）处理上述列表，
其余已有报告的镜像直接跳过。
```
