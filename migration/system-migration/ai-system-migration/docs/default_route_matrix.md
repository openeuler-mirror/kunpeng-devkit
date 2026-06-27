# 默认迁移路线矩阵

| 源端组件 | 默认目标 | 自定义选项 | 说明 |
|---|---|---|---|
| JDK 8 | OpenJDK 8 ARM | 毕昇 JDK 8、其他 JDK 8 ARM | 默认保持原大版本。 |
| JDK 11 | OpenJDK 11 ARM | 毕昇 JDK 11、其他 JDK 11 ARM | 默认保持原大版本。 |
| JDK 17 | OpenJDK 17 ARM | 毕昇 JDK 17、其他 JDK 17 ARM | 默认保持原大版本。 |
| Tomcat | 东方通 | 宝兰德、Tomcat ARM | 默认国产化路线。 |
| Resin | Resin ARM | 其他用户提供版本 | 不默认改东方通。 |
| Nginx | Nginx ARM | 用户提供版本、OS repo 版本 | 迁移配置文件。 |
| Redis | Redis ARM | 用户提供版本、OS repo 版本 | 迁移 redis.conf。 |
| MySQL | 达梦 DM | openGauss、原类型 ARM、其他国产库 | 默认动态迁移优先；静态用 mysqldump。 |
| Oracle | 达梦 DM | openGauss、原类型 ARM、其他国产库 | 默认 DTS 动态迁移。 |
| SQL Server | 达梦 DM | 其他国产库 | 默认 DTS 动态迁移。 |
| DB2 | 达梦 DM | 其他国产库 | 默认 DTS 动态迁移。 |

## 安装包来源优先级

1. 用户提供安装包。
2. 华为云鲲鹏归档仓。
3. 官方站点 ARM 版本。

所有下载或使用的安装包都必须记录来源、版本、SHA256。

## 增强版执行约束

- Tomcat -> 东方通 是默认路线，不等于“找不到东方通就自动安装 Apache Tomcat”。
- Apache Tomcat 只允许作为显式 fallback：`middleware.fallback_to_apache_tomcat: true`。
- DM 是默认目标数据库；未安装时必须先进入 `database-install` 搜索/安装 DM，找不到包则停止，不得继续标记数据库迁移成功。
- 所有安装包必须记录来源和 SHA256。
