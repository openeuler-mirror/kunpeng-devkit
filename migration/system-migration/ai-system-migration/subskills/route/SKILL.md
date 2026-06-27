---
name: route
summary: 基于扫描结果生成默认国产化迁移路线或自定义迁移路线，并以非阻断方式提交用户确认。
description: |
  当部署结构和组件清单识别完成后调用。该子 Skill 生成迁移路线卡片，默认路线为 OpenJDK ARM、Tomcat -> 东方通、Resin -> Resin ARM、数据库 -> 达梦 DM、动态迁移优先。用户可选择自定义路线。确认结果写入 route_plan.yaml。
---

# route 子 Skill

## 默认路线

| 源组件 | 默认目标 |
|---|---|
| JDK | 保持原大版本，OpenJDK ARM |
| Tomcat | 东方通 |
| Tomcat 自定义 | 东方通 / 宝兰德 / Tomcat ARM |
| Resin | Resin ARM |
| Nginx | Nginx ARM |
| Redis | Redis ARM |
| MySQL | 达梦 DM，MySQL 兼容路线 |
| Oracle | 达梦 DM，Oracle 兼容路线 |
| SQL Server | 达梦 DM，SQL Server 兼容路线 |
| DB2 | 达梦 DM，DB2 兼容路线 |

## 非阻断交互

生成交互任务：

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

主流程在用户未回复时可以继续执行传输、安装包检测、报告草稿生成等非破坏性任务；真正安装或修改前必须使用已确认路线或默认安全路线。

## 输出

写入：

- `/opt/ai-system-migration/config/route_plan.yaml`
- `/opt/ai-system-migration/workspace/route/route-summary.json`
- `manual-confirm-items.json`
