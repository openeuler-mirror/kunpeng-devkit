---
name: credential
summary: 非阻断收集目标机 SSH、源库/目标库、应用账号和模型凭据，并保证敏感信息只进入 credentials.yaml。
description: |
  当主流程需要目标机传输、数据库迁移、数据库创建、模型调用或应用验证账号时调用。该子 Skill 生成凭据收集任务，不在报告和日志中输出明文密码。
---

# credential 子 Skill

## 原则

1. 所有敏感信息统一写入 `/opt/ai-system-migration/config/credentials.yaml`。
2. 文件权限建议 `chmod 600 credentials.yaml`。
3. `execution-log.jsonl`、`migration-report.md`、`migration-report.json` 必须脱敏。
4. 不得把密码写进命令行日志。必须使用配置文件、环境变量、临时文件或安全输入方式。

## 收集内容

- 目标 ARM 机器 SSH：host、port、root、password 或 private_key。
- 手动上传目录：无需 SSH 时提供。
- 源数据库：类型、host、port、database、schema、username、password、service_name/sid。
- 目标 DM：host、port、dba、业务用户、业务密码。
- 外部模型：base_url、api_key、model。

## 非阻断策略

- 目标机凭据缺失：SCP 阶段等待；手动上传模式可继续。
- 源库凭据缺失：动态数据库迁移等待；中间件安装和应用分析可继续。
- 目标库 DBA 凭据缺失：DM 初始化和建用户等待；应用改造可先生成 patch 草案。
- 模型凭据缺失：退化为 `agent-native` 或 `manual-review`。

## 输出

```json
{
  "phase": "credential",
  "status": "partially_success",
  "available_credentials": ["target_ssh", "target_dm"],
  "missing_credentials": ["source-db-1"],
  "redaction_enabled": true
}
```
