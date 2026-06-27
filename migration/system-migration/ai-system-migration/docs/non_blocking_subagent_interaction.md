# 子 Skill 非阻断交互机制

## 1. 问题背景

端到端迁移过程中需要多次交互，例如：

- 是否允许动态版本探测。
- 是否使用默认国产化迁移路线。
- 目标机 SSH 信息。
- 源库和目标库账号密码。
- 是否允许数据库导出。
- 是否允许源码和配置发送给模型。
- 是否授权无源码反编译。

如果主流程每次都停下来等待用户，CLI 体验会很差，也容易形成断点。因此交互由子 Skill 负责，主流程通过交互队列协调。

## 2. 交互任务

交互任务写入：

```text
/opt/ai-system-migration/state/interaction_tasks.jsonl
```

示例：

```json
{
  "task_id": "route-confirm-001",
  "phase": "route",
  "type": "confirmation",
  "blocking_scope": "middleware_install_and_database_migration",
  "default_action": "use_default_route",
  "question": "是否确认使用默认国产化迁移路线？",
  "options": ["confirm", "customize", "skip"],
  "expires_policy": "use_default_if_safe"
}
```

## 3. 用户答案

用户或子 Skill 将答案写入：

```text
/opt/ai-system-migration/state/interaction_answers.json
```

示例：

```json
{
  "route-confirm-001": "confirm",
  "source-dynamic-version-probe-confirm": "allow"
}
```

## 4. 阻断范围

不是所有问题都阻塞全流程。每个任务都有 `blocking_scope`：

| blocking_scope | 含义 |
|---|---|
| `none` | 不阻塞任何阶段，仅记录建议。 |
| `dynamic_version_probe_only` | 仅影响动态版本探测，不影响基础扫描。 |
| `database_static_export` | 仅影响源端数据库静态导出。 |
| `middleware_install_and_database_migration` | 影响真实安装和迁移执行。 |
| `model_external_send` | 仅影响源码/配置是否发送外部模型。 |
| `decompile` | 仅影响无源码反编译。 |

## 5. 默认值策略

- 有安全默认值：用户未回复时可以使用默认值继续非破坏性阶段。
- 无安全默认值：对应阶段等待，但主流程可以继续其他不依赖阶段。
- 涉及敏感或破坏性动作：不能使用默认允许。

## 6. 推荐交互原则

1. 问题要少而明确。
2. 优先给推荐默认值。
3. 每个问题必须标注影响范围。
4. 每个问题必须进入最终报告。
5. 不要在日志里打印密码或 Token。
