## 1. 报告写入规则

- 单项目完成后立即写 `build_reports/<project>.json`；主 Agent 最后写 `_summary.json`。
- 报告只记录实际执行结果；建议、候选动作和未执行命令不得写入 `changes_applied`。
- JSON 必须可解析，数值和布尔值不得写成字符串。
- 路径使用任务实际路径；时间使用 ISO 8601。
- 状态一致性遵守主 Skill 全局约束。

### 状态不变量

| 条件                 | 必须满足                                                  |
| ------------------ | ----------------------------------------------------- |
| `status=SUCCESS`   | `build_status=success` 且 `test_status ∈ {pass, skip}` 且 `startup_status=ok` |
| `status=FAILED`    | 必须填写 `failure_reason`；失败证据写入 `notes`                  |
| 构建前失败              | `build_status=fail` 或在 `notes` 明确“未进入构建”              |
| `test_status=skip` | `notes` 说明未执行原因和剩余风险                                  |
| 有 warning          | `warnings` 保留证据、影响和后续动作，即使已缓解                         |
| native 标记          | 所有 `WARN-X86-NATIVE-SO` warning 与 `FIXED-SO-REPLACED-AARCH64` 变更条目均有非空 `evidence_source`；仅有文件名/路径关键词不构成证据 |

## 2. 单项目报告

### 2.1 公共字段

```json
{
  "project": "<project>",
  "status": "SUCCESS|FAILED",
  "failure_reason": "<成功时省略；枚举见 references/build_knowledge_reference.md 附录>",
  "image": "<OUTPUT_TAG_PREFIX>-<project>:latest",
  "build_status": "success|fail",
  "docker_version": "<docker --version 输出；不可用时说明>",
  "buildkit_enabled": true,
  "build_command": "<实际执行的 docker build 命令；未执行时为空字符串>",
  "test_status": "pass|fail|skip",
  "startup_status": "ok|crash|skip",
  "migration_mode": "IMAGE_RECONSTRUCTION",
  "retry_count": 0,
  "changes_applied": [
    {
      "action": "<实际执行的修复动作>",
      "target": "<Dockerfile 行、依赖或文件>",
      "fix_source": "BUILD_KNOWLEDGE|NOVEL|MANUAL",
      "knowledge_section": "<仅 BUILD_KNOWLEDGE 来源时填写>",
      "evidence_source": "<仅 native 库替换/移除类动作必填；pkg-mig JSON 路径或解压后 file 输出>"
    }
  ],
  "warnings": [
    {
      "type": "WARN-X86-NATIVE-SO",
      "file": "libs/librender_x86_64.so",
      "original_cmd": "COPY libs/librender_x86_64.so /usr/lib/librender.so",
      "evidence_source": "devkit-pkg-mig:/tmp/pkg_mig_reports/<name>.json 或 fallback-file:<file输出摘要>",
      "impact": "x86_64 native .so 未迁移，相关功能不可用",
      "action_required": "提供 aarch64 版本并更新 COPY 路径"
    }
  ],
  "notes": "<关键证据、未执行验证和剩余风险>",
  "x86_env": {
    "host": "<user>@<host> | null",
    "ssh_ok": true,
    "ai_migration_ok": true,
    "ai_migration_dir": "<X86_AI_MIGRATION_DIR> | \"\"",
    "docker_ok": true,
    "docker_version": "2x.x.x | \"\"",
    "docker_daemon_running": true,
    "docker_run_ok": true,
    "disk_free_mb": 4096,
    "target_images_available": ["<image>:<tag>", "..."],
    "target_images_missing": ["<image>:<tag>", "..."],
    "check_passed": true,
    "auto_fixed": ["<item>", "..."],
    "warnings": ["disk_space_low", "..."]
  },
  "timestamp": "<ISO8601>"
}
```

说明：

- `warnings` 无内容时写 `[]`。`type` 使用不带方括号的稳定值（如 `WARN-X86-NATIVE-SO`）；Dockerfile 注释中才写 `[WARN-X86-NATIVE-SO]`。
- native 相关 warning 与 `FIXED-SO-REPLACED-AARCH64` 变更必须填写 `evidence_source`（`devkit-pkg-mig:<JSON路径>` 或 `fallback-file:<file输出摘要>`）；仅有文件名/归档内路径关键词不得作为证据，缺 `evidence_source` 的报告不得提交。
- `changes_applied` 无变更时写 `[]`。
- `fix_source` 无法确定时使用 `MANUAL`，后续知识沉淀进入人工复核。

### 2.2 本场景扩展字段

```json
{
  "migration_mode": "IMAGE_RECONSTRUCTION",
  "source_image": "<原 x86_64 镜像名>",
  "reconstruction_info": {
    "history_layers": 0,
    "opaque_layers": 0,
    "opaque_layer_resolved": true,
    "layout_mode_used": "rebuild|full"
  }
}
```

`layer.json` 缺失时，在 `warnings` 中记录 `LAYER_NOT_COLLECTED`，并在 `notes` 说明重构信息缺口。

推荐 warning 类型（按需使用）：

- `LAYER_NOT_COLLECTED`
- `LAYOUT_NOT_COLLECTED`
- `WARN-OPAQUE-LAYER`
- `WARN-OPAQUE-LAYER-UNRESOLVED`
- `WARN-X86-NATIVE-SO`

## 3. 总览报告

```json
{
  "total": 7,
  "success": 5,
  "failed": 2,
  "worker_count": 3,
  "elapsed_min": 83,
  "projects": [
    { "project": "projectA", "status": "SUCCESS", "worker_id": 1 },
    { "project": "projectB", "status": "FAILED", "worker_id": 2, "reason": "STALLED" }
  ],
  "interventions": [
    {
      "worker_id": 2,
      "project": "projectB",
      "trigger": "WARN-X86-NATIVE-SO",
      "action": "<实际干预动作>",
      "resolved": true
    }
  ],
  "timestamp": "<ISO8601>"
}
```

汇总校验：

- `total = success + failed`。
- `projects` 数量等于 `total`。
- 每个项目状态来自对应单项目报告，不根据日志重新推断。
- `interventions` 只记录实际发生的主 Agent 干预；无干预时写 `[]`。
- 总览报告中的项目状态必须与对应单项目报告完全一致。
