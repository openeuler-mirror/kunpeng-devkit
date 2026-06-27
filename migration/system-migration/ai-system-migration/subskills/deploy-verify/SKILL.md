---
name: deploy-verify
summary: 启动目标端数据库、中间件和 Java 应用，执行健康检查，采集日志并按错误指纹自动修复。
description: |
  当中间件、数据库和应用改造完成后调用。该子 Skill 负责部署应用包到正确路径，启动服务，采集日志，判断启动失败原因，并在限制轮次内自动修复。
---

# deploy-verify 子 Skill

## 启动顺序

1. 启动目标数据库 DM。
2. 启动 Redis 等依赖组件。
3. 启动 Nginx，如仅做反向代理可放在应用启动后。
4. 启动东方通/Resin/Tomcat。
5. 部署应用包。
6. 启动应用。

## 健康检查

优先级：

1. 用户提供 HTTP URL。
2. 扫描结果中识别到的端口和上下文路径。
3. 进程检查。
4. 端口检查。
5. 日志关键字检查。

## 日志采集

- `catalina.out` 或东方通/Resin 对应日志。
- 应用日志。
- Nginx `error.log`。
- Redis 日志。
- DM 数据库日志。
- `systemctl status`。
- `journalctl -u <service>`。

## 自动修复规则

1. 同阶段最多 5 轮。
2. 同一错误指纹连续出现 3 次停止。
3. 全流程最多 10 轮。
4. 用户输入 `exit`、`quit`、`stop` 时停止。

## 常见错误分类

- 端口冲突。
- JDK 版本不兼容。
- JDBC Driver 缺失。
- 数据库连接失败。
- SQL 方言错误。
- 配置路径错误。
- 文件权限错误。
- 中间件配置格式错误。
- 应用依赖 Jar 缺失。

## 输出

```json
{
  "phase": "deploy-verify",
  "status": "success",
  "services": [],
  "health_checks": [],
  "fix_rounds": 0,
  "remaining_issues": [],
  "manual_next_steps": []
}
```
