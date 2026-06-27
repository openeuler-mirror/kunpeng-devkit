---
name: middleware
summary: 在目标 ARM 机器安装 OpenJDK ARM、东方通、Resin ARM、Nginx ARM、Redis ARM 等中间件并迁移配置。
description: |
  当路线确认并且目标机可访问后调用。该子 Skill 负责安装中间件、迁移运行配置、记录安装包来源和 SHA256。默认 Tomcat 迁移到东方通，Resin 保持 Resin ARM，JDK 使用 OpenJDK ARM。
---

# middleware 子 Skill

## 安装源优先级

1. 用户提供安装包：`/opt/ai-system-migration/packages`。
2. 华为云鲲鹏归档仓：`https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/`。
3. 官方站点 ARM 版本。使用官方站点时必须记录 URL、版本、SHA256 和下载时间。

## 默认组件路线

- JDK：OpenJDK ARM，保持源端 Java 大版本。
- Tomcat：东方通。
- 宝兰德：仅自定义路线。
- Resin：Resin ARM。
- Nginx：Nginx ARM。
- Redis：Redis ARM。

## 配置迁移

- Tomcat/东方通：迁移 `server.xml`、`context.xml`、`web.xml`、应用部署目录、端口、JVM 参数。
- Resin：迁移 `resin.xml`、`web-app root-directory`、JVM 参数。
- Nginx：迁移 `nginx.conf`、`conf.d`、证书路径、反向代理配置。
- Redis：迁移 `redis.conf`，注意 bind、protected-mode、requirepass、dir、appendonly。

## 安全要求

1. 覆盖前必须备份。
2. 安装包必须记录来源和 SHA256。
3. 配置中的密码必须脱敏展示，但原配置迁移时保留真实值。
4. 端口冲突时生成建议，不得静默改动业务端口，除非用户授权。

## 输出

```json
{
  "phase": "middleware",
  "status": "success",
  "installed": [],
  "config_migrated": [],
  "package_sources": [],
  "risks": []
}
```


## 增强版强制策略

当 `route_plan.yaml` 中存在：

```json
{"source": "tomcat", "target": "tongweb"}
```

本子 Skill 必须执行以下策略：

1. 查找 TongWeb 安装包，不得直接安装 Apache Tomcat。
2. 查找 TongWeb license，默认要求 `license.dat`、`*.lic` 或 `*.license`。
3. 查找顺序：本地包目录 -> 华为云鲲鹏归档仓 -> 配置的厂商官方 URL。
4. 如果缺少安装包或 license，返回 `waiting_input`，不得继续假装完成 middleware 阶段。
5. 只有当配置中存在 `middleware.fallback_to_apache_tomcat: true` 时才允许降级，并且必须在最终报告中标记 fallback。

可执行入口：

```bash
python3 bin/ai_system_migration.py phase middleware   --config /opt/ai-system-migration/config/migration_config.yaml   --credentials /opt/ai-system-migration/config/credentials.yaml   --execute
```

输出中必须包含：

- `package_resolution`
- `license_resolution`
- `package_sources`
- `fallback_to_apache_tomcat`
- `blocked`
