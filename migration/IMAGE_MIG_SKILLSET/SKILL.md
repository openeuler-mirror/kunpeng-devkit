---
name: image-mig-skillset
description: x86_64 Docker 镜像迁移到 linux/arm64。支持两种场景：① 有 Dockerfile + 内网仓库访问权限（直接迁移）；② 只有现成镜像、没有 Dockerfile（逆向重构）。包含主从 Agent 并发编排、内网隔离模式、外部资源自动获取、x86 native 库兼容性治理、构建修复知识库。当用户提到 ARM64 迁移、镜像迁移、Dockerfile 改 arm、docker 构建失败修复、逆向重建镜像时使用此技能。
---

# IMAGE_MIG_SKILLSET · ARM64 镜像迁移

## 第一步：判断场景，选择对应流程文件

```
有 Dockerfile？
  YES → 读 DOCKERFILE_MIGRATION.md
    触发词：有 Dockerfile 迁移 / dockerfile to arm64 / 有源码仓权限迁移

  NO（只有现成镜像）→ 读 IMAGE_RECONSTRUCTION.md
    触发词：只有镜像没有 Dockerfile / 逆向重建镜像 / image reconstruction
```

## 第二步：必读文件（每次任务启动前）

| 文件 | 用途 | 何时读 |
|------|------|--------|
| `DOCKERFILE_MIGRATION.md` | 有 Dockerfile 场景的完整执行流程（五阶段） | 场景 ① |
| `IMAGE_RECONSTRUCTION.md` | 纯镜像逆向重构流程（六阶段，含 history/layout 采集） | 场景 ② |
| `config.yaml` | 环境参数（内网仓库地址、并发数、隔离模式）★ 启动前确认已填写 | 两种场景 |
| `BUILD_KNOWLEDGE.md` | 构建/修复知识库（23 类错误，遇到问题先查这里） | 两种场景 |

## 快速决策

```
config.yaml 是否已填写实际仓库地址（无 <...> 占位符）？
  NO → 先按 prompt_template.md 场景 6 完成 config.yaml 初始化
  YES → 继续

WORKER_COUNT = 1？
  YES → 单任务模式，主 Agent 直接执行全部 PHASE
  NO  → 并发模式，主 Agent 调度 + 子 Agent 并行执行

遇到构建报错？
  → 先查 BUILD_KNOWLEDGE.md（按关键词搜索）
  → 未收录 → 自行修复 → 修复后追加到 BUILD_KNOWLEDGE.md
```

## 关键约束（两种场景通用）

- 同一问题最多重试 `MAX_RETRY`（默认 5）次，超出写 `FAILED(EXCEEDED_ATTEMPTS)`
- 构建超过 `BUILD_TIMEOUT_MIN`（默认 60min）写 `FAILED(TIMEOUT)`
- 每个项目完成后**立即写报告**，不等全部完成
- 已有 `build_reports/<project>.json` 的项目**直接跳过**
- 遇到新错误：先写报告，再追加到 `BUILD_KNOWLEDGE.md`
