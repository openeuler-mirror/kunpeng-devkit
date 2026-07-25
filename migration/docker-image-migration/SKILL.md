---
name: docker-image-migration
description: >-
  docker-image-migration Skill 主调度文件。用于将 x86_64 Docker 镜像迁移到 linux/arm64（鲲鹏）环境，覆盖有 Dockerfile 的直接迁移与无 Dockerfile 的镜像逆向重构两类场景。负责场景选择、启动门禁、受控并发、构建与运行验证、知识沉淀及中断恢复。不适用范围：Windows 容器迁移、非 Docker 场景（裸机或 VM）、仅需人工替换单行 `FROM` 的极简任务、history 完全不可读且镜像不可运行的场景。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
---

# Docker 镜像 X86 到 Kunpeng 迁移主控 Skill

## Skill 说明

本 Skill 用于将 x86_64 Docker 镜像迁移到 linux/arm64（鲲鹏）平台，支持两种迁移路径：

- **有 Dockerfile 场景**：基于源码和 Dockerfile 重新构建 ARM64 镜像，适用于可访问源码和构建上下文的项目
- **无 Dockerfile 场景**：基于镜像逆向分析（manifest / history / layer）重构 ARM64 Dockerfile，适用于仅能访问镜像本身的场景

核心能力包括：启动门禁（环境 / 网络 / 配置校验）、受控并发执行、构建与运行验证、失败自动修复（知识库驱动）、知识沉淀及中断恢复。

## 核心原则

- **单一事实来源**：全局调度、告警和失败规则以 `SKILL.md` 为准；场景文件只定义该场景特有的阶段和动作
- **非侵入式探测**：不主动安装 QEMU，不修改 `binfmt_misc`，不改写系统软件源；需要系统级变更时必须先获得用户明确确认
- **有证据才判定**：所有失败判定都必须附证据，失败前必须先检索 `references/build_knowledge_reference.md`

## 全局执行红线

- **阶段记录与恢复**：若已存在该任务的完整阶段记录文件，则直接跳过；若仅有中间阶段记录，则从“最后一个完整阶段”之后继续；单任务超过 `WORKER_STALL_TIMEOUT_MIN` 仍无进展，标记为 `status=FAILED` 且 `failure_reason=STALLED`。
- **并发写入边界**：任务执行器（worker/子 Agent）只能写入本任务输出文件；汇总文件与知识库统一由主 Agent 串行写入，避免并发覆盖。

## 执行质量约束

- **warning 记录最小字段**：必须记录证据位置、影响、已执行动作、后续要求；无证据不得改写
- **失败前证据最小集**：必须记录失败命令与退出码、关键日志、尝试次数、检索章节、失败理由；无证据不得改写
- **失败原因只使用以下 4 个固定值**：`TIMEOUT`（超时）、`EXCEEDED_ATTEMPTS`（重试次数超限）、`NO_ARM64_SUPPORT`（无 ARM64 支持）、`STALLED`（长时间无进展）
---

## 整体流程

> **迁移场景选择** → **启动门禁检查** → **注入任务上下文信息** → **场景阶段执行** → **报告生成与知识沉淀**
>
> **关键约束**：
> - 门禁全部通过后才能进入场景阶段；任一门禁未通过时不得跳过
> - 全局调度、告警和重试统一遵守 `SKILL.md`，不在场景文件重复定义

## 迁移场景选择

**信息不足时**：必须以交互方式提示用户按“最小输入清单”补齐信息；在信息补齐前，不得推测路径、凭据或镜像标签。

最小输入清单：
- 必填：待迁移镜像（可多镜像）与目标输出镜像名 + 镜像tag
- 可选：Registry / Git / 软件源访问凭据（仅在需要认证时提供）
- 场景必填（二选一）：
  - 有 Dockerfile 场景：Dockerfile 路径 + 构建上下文路径
  - 无 Dockerfile 场景：已采集产物路径（manifest/history/layer）；若未提供采集产物，需提供可访问源镜像以便自动采集

**信息充分时**：

- 存在可访问的 Dockerfile 和源码 → 读取 `dockerfile-migration/SKILL.md`，执行 阶段 1–5
- 无 Dockerfile，且已提供采集产物或可访问源镜像（用于自动采集）→ 读取 `image-reconstruction/SKILL.md`，执行 阶段 1–6

场景选择优先级：若同时提供 Dockerfile/源码与采集产物，默认优先走 `dockerfile-migration/SKILL.md`；仅在 Dockerfile 不可访问或无法形成可用构建上下文时，转入 `image-reconstruction/SKILL.md`。

---

## 启动门禁检查

所有门禁按顺序执行，每个门禁记录「输入、检查结果、后续决策」并注入任务上下文。

### 1. 输入与配置

| 检查 | 通过条件 | 未通过时 |
|---|---|---|
| 任务输入 | 镜像列表、Dockerfile/源码或采集产物足以确定场景 | 请求缺失信息，不推测路径或凭据 |
| 配置文件 | `GIT_HOSTS`、`INTERNAL_REGISTRIES`、`WORKER_COUNT` 等不含未替换的 `<...>` | 按对应场景的 `*/templates/prompt_template.md` 配置初始化模板补齐 |
| 隔离模式 | `AIRGAP_MODE=true` 时已配置内网源 | 停止公网访问动作并请求补充配置 |

> 配置参数的完整说明见 `references/config_reference.md`。

### 2. Docker、架构与磁盘

检查 Docker CLI、daemon 和构建权限，生成 `DOCKER_CTX`。检查 `uname -m`、Buildx 和 binfmt/QEMU，生成 `ARCH_COMPAT`：

| 值 | 含义 |
|---|---|
| `full` | ARM64 原生环境 |
| `emulated` | x86_64 + Buildx + QEMU |
| `noemu` | x86_64 + Buildx，但未确认 QEMU；仅在最小 ARM64 探测构建成功后继续 |
| `blocked` | 当前环境不能执行 ARM64 构建 |

`blocked` 时的处置：
- `dockerfile_migration + blocked`：经用户确认可只执行 阶段 1–3；状态标记为 `FAILED` 且 `failure_reason=ARCH_BLOCKED`，不得写成迁移成功。具体字段写法见“报告生成”。
- `image_reconstruction + blocked`：停止本地重构构建，提示切换到可用的 ARM64 或模拟构建机；可在当前环境继续完成采集与分析（阶段 1–2），状态标记为 `FAILED` 且 `failure_reason=ARCH_BLOCKED`，不得写成迁移成功。具体字段写法见“报告生成”。

对每个独立任务检查可用磁盘空间；低于 `MIN_DISK_SPACE_GB` 时按 `references/build_knowledge_reference.md` 23 节清理并复查。

### 3. Registry 与镜像源

使用 `curl` 或 Docker manifest 命令探测端点，生成 `NETWORK_CTX`：

| 响应 | 判定 |
|---|---|
| `200` 或 `401` | 可达（`401` 表示需要认证） |
| `301/302` | 继续验证跳转目标 |
| `manifest unknown` / `not found` / `name unknown` | 镜像不存在：必须暂停并交互提示用户确认镜像名和 tag，或提供替代镜像；未确认前不得继续迁移 |
| 超时 / 连接失败 / 持续 `5xx` | 不可达 |

探测对象：Docker Hub、`INTERNAL_REGISTRIES` 以及配置中的备用镜像站。

```yaml
NETWORK_CTX:
  dockerhub_official: reachable | unreachable
  dockerhub_web: reachable | unreachable
  internal_registries: {"<registry>": reachable | unreachable}
  primary_mirror: "<url>" | null
  mirrors_checked: []
```

> 不要把镜像站路径拼接规则当作通用事实；只有在目标镜像站已验证支持该路径时才改写镜像名。

### 4. 软件包源

仅探测 Dockerfile 或采集结果实际使用的软件源，记录三种状态：`2xx/3xx`（可达）、`401/403`（受限）、不可达。

```yaml
NETWORK_CTX.package_sources:
  ubuntu: reachable | restricted | unreachable | not_used
  debian: reachable | restricted | unreachable | not_used
  ubuntu_ports: reachable | restricted | unreachable | not_used
  pypi: reachable | restricted | unreachable | not_used
  npm: reachable | restricted | unreachable | not_used
  maven: reachable | restricted | unreachable | not_used
```

> 官方源经重试仍不可达时，才按 `references/config_reference.md` 的已配置备用源替换；在执行记录中保留原始源、探测证据和替换结果。

---

## 注入任务上下文信息

启动检查通过后，多 Agent 模式下，主 Agent 在下发任务时必须同时下发：TASK_CTX、核心原则、全局执行红线、执行质量约束；子 Agent 在进入场景阶段前必须先读取并确认这些规则，未确认前不得开始执行，执行过程中不得违背。

```yaml
TASK_CTX:
  config_path: references/config_reference.md
  network_ctx: "<NETWORK_CTX>"
  docker_ctx:
    docker_available: true | false
    docker_privileged: true | false
    buildkit_enabled: true | false
    arch_compat: full | emulated | noemu | blocked
  collected_data: {}  # 仅 image_reconstruction 使用
  report_dir: "<REPORT_DIR>"
```

---

## 场景阶段执行

1. 按选定场景文件的阶段顺序执行，不跨阶段写最终结论
2. 每个阶段完成后写阶段记录文件，并输出统一日志：`[{worker_id}] 阶段 {阶段} DONE target={target} elapsed={seconds}s`
3. 调度模式：
   - `WORKER_COUNT = 1`：主 Agent 串行执行所有镜像任务
   - `WORKER_COUNT >= 2`：主 Agent 启动 `WORKER_COUNT` 数量的子 Agent 并发执行，每个子 Agent 按主 Skill 的执行步骤独立完成各自分配的容器镜像迁移，并且只能写入各自任务的输出文件；汇总文件由主 Agent 在所有子 Agent 完成后串行写入
   - 当平台不支持子 Agent 时，退化为单会话顺序执行，不改变阶段顺序和阶段记录格式
4. 告警处理、重试、超时、失败判定和会话恢复统一遵守 `SKILL.md`
5. 失败判定遵循“有证据才判定”（见核心原则）；`NO_ARM64_SUPPORT` 需提供 manifest 或同等平台证明

---

## 报告生成与知识沉淀

1. **阶段内记录证据**：每个阶段完成后，记录关键命令、输出路径、失败重试信息
 
2. **单项目报告落盘**：任务结束立即写 `build_reports/<project>.json`，不得延后到批次结束

3. **状态一致性自检**：
  - `status=SUCCESS` 必须满足 `build_status=success` 且 `test_status!=fail`
  - `status=FAILED` 必须包含 `failure_reason`，并在 `notes` 写清失败证据与边界
  - `test_status=skip` 必须说明跳过原因和剩余风险

4. **批次汇总与知识沉淀**
  - 全部项目完成后再写 `build_reports/_summary.json`，主 Agent 统一汇总
  - 仅对已成功且具备复用价值的 `NOVEL` 修复进入知识沉淀流程
  - 未经用户确认，不直接改写知识库

> 报告字段结构以场景模板为准：`dockerfile-migration/templates/report_template.md` 与 `image-reconstruction/templates/report_template.md`。
