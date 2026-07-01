---
name: image-mig-skillset
description: x86_64 Docker 镜像迁移到 linux/arm64。支持两种场景：① 有 Dockerfile + 内网仓库访问权限（直接迁移）；② 只有现成镜像、没有 Dockerfile（逆向重构）。包含主从 Agent 并发编排、内网隔离模式、外部资源自动获取、x86 native 库兼容性治理、构建修复知识库。当用户提到 ARM64 迁移、镜像迁移、Dockerfile 改 arm、docker 构建失败修复、逆向重建镜像时使用此技能。
---

# IMAGE_MIG_SKILLSET · ARM64 镜像迁移

> **入口文件**：本文件仅做场景路由与全局约束，执行细节见各子文件。

---

## ① 场景路由（首先执行）

```
有 Dockerfile 且可访问源码仓？
  YES → 读 DOCKERFILE_MIGRATION.md，执行五阶段流程
  NO  → 读 IMAGE_RECONSTRUCTION.md，执行六阶段流程（含 PHASE 0 逆向采集）
```

**子文件速查**：

| 文件 | 用途 |
|------|------|
| `DOCKERFILE_MIGRATION.md` | 场景 ①：五阶段执行流程 + Agent 编排 |
| `IMAGE_RECONSTRUCTION.md` | 场景 ②：六阶段执行流程 + 逆向采集 |
| `config.yaml` | 环境参数 ★ 启动前必须确认所有 `<...>` 占位符已替换 |
| `BUILD_KNOWLEDGE.md` | 构建/修复知识库（23 类错误，构建失败先查此处） |
| `prompt_template.md` | 各场景用户 prompt 模板 |

---

## ② 启动前检查（每次任务必做，顺序执行）

```
Step 1  config.yaml 校验
        检查 GIT_HOSTS / INTERNAL_REGISTRIES / WORKER_COUNT 是否含 <...> 占位符
        → 有占位符：按 prompt_template.md 场景 6 完成初始化后再继续

Step 2  磁盘空间检查（对每个独立容器任务）
        df -h / | awk 'NR==2 {print $4}'
        可用空间 < MIN_DISK_SPACE_GB（默认 10 GB）？
          YES → 清理旧镜像/容器/无用文件后重新检查
                仍不足 → 写 FAILED(INSUFFICIENT_DISK_SPACE)，停止本任务
          NO  → 继续

Step 3  网络连通性探测（★ 分发子 Agent 任务前必须完成，结果注入所有子 Agent 上下文）
        探测顺序（curl -sI --max-time 10 <url>，200/301/302 视为可达）：

        ① DockerHub 官方
            https://registry-1.docker.io/v2/      → DOCKERHUB_OFFICIAL=reachable/unreachable
            https://hub.docker.com                 → DOCKERHUB_WEB=reachable/unreachable

        ② 内源仓库（读自 config.yaml INTERNAL_REGISTRIES，逐条探测）
            对每条 registry：curl -sI --max-time 10 https://<registry>/v2/
            → INTERNAL_REGISTRY_STATUS={registry: reachable/unreachable, ...}

        ③ 若 DockerHub 官方不可达，依次探测以下国产镜像站（取第一个可达的作为主备用源）：
            https://mirror.ccs.tencentyun.com      阿里云 / 腾讯云
            https://docker.mirrors.ustc.edu.cn     中科大
            https://hub-mirror.c.163.com           网易
            https://registry.cn-hangzhou.aliyuncs.com  阿里云 ACR
            → DOCKERHUB_MIRRORS=[{url, status}, ...]   # 按探测顺序排列，第一个 reachable 优先

        探测完成后输出汇总（后续子 Agent 和干预流程直接使用，不重复探测）：
        NETWORK_CTX = {
          dockerhub_official:  reachable | unreachable,
          dockerhub_web:       reachable | unreachable,
          internal_registries: {<name>: reachable | unreachable},
          primary_mirror:      <url> | null,          # null 表示官方可达，无需镜像站
          mirrors_checked:     [{url, status}, ...]
        }

Step 4  调度模式判断
        WORKER_COUNT = 1 → 单任务模式：主 Agent 直接执行全部 PHASE（携带 NETWORK_CTX）
        WORKER_COUNT ≥ 2 → 并发模式：详见所选子文件 § Agent 编排（每个子 Agent 均携带 NETWORK_CTX）
```

---

## ③ 全局约束（两种场景通用）

| 约束 | 行为 |
|------|------|
| 重试上限 | 同一问题最多重试 `MAX_RETRY`（默认 5）次，超出 → `FAILED(EXCEEDED_ATTEMPTS)` |
| 构建超时 | 超过 `BUILD_TIMEOUT_MIN`（默认 60 min）→ `FAILED(TIMEOUT)` |
| 报告时机 | 每个项目完成后**立即写报告**，不等全批完成 |
| 幂等跳过 | 已有 `build_reports/<project>.json` 的项目**直接跳过** |
| 知识沉淀 | 遇到 `BUILD_KNOWLEDGE.md` 未收录的错误：先写项目报告，再追加到知识库 |

---

## ④ 并发模式下子 Agent 调度与上下文管理

> 完整调度伪代码见 `IMAGE_RECONSTRUCTION.md § 主 Agent 调度伪代码`

```
规则 1  均分任务列表（启动时一次性分配，不做批次轮转）
  · 主 Agent 将所有任务按 WORKER_COUNT 均分，每个子 Agent 拿到一个任务列表
  · 子 Agent 顺序执行自己列表内的全部任务，全部完成后退出
  · 每完成一个 PHASE 立即写出中间工件（Dockerfile 草稿等）作为检查点

规则 2  并行执行
  · 主 Agent 同时启动全部 WORKER_COUNT 个子 Agent（一次性，不分批）
  · 子 Agent 之间完全独立，互不等待，各自速度不影响其他 Worker

规则 3  上下文超限补救（子 Agent 返回 "did not return any content" 时）
  step 1: 检查该 Worker 对应任务列表的报告文件
           所有报告已写出 → 标记整个 Worker 成功
           部分已写出     → 找到第一个未写报告的任务，执行 resume（携带原 agentId）
  step 2: resume prompt 说明"跳过已有报告的任务，从 <下一个任务名> 继续"
  step 3: resume 仍返回空 → 全新会话重启，prompt 中列出该 Worker 剩余任务列表
           和已存在的工件路径，已完成的任务直接跳过
```
