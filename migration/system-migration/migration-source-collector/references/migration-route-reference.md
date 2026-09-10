# X86 → ARM 迁移路线参考

> 用途：根据源环境采集结果，为 `migration-plan.json` 生成候选迁移路线。中间件优先精确匹配源产品和版本；数据库目标产品由用户选择。所有路线都必须由用户二次确认，模型不得自主选择。

## 1. 表格与 URL 约定

- `{version}`、`{major}`、`{os}`：分别替换为目标版本、主版本和目标操作系统。
- `*` 表示构建号等无法确认的文件名片段。把该模式原样写入 `packages[].file_name` 和 HTTPS `download_url`，状态使用 `PENDING_DOWNLOAD`；目标预检从 URL 父目录解析唯一匹配，零个或多个匹配都不得猜测。
- `目标版本=待确认` 或 `0` 时，输出 `ROUTE_CONFIRM_REQUIRED`，不得自动确定路线。

## 2. 数据库迁移路线

| 目标产品 | 目标版本 | License | URL 模板 | 备注 |
|---|---|---|---|---|
| DM | 8 | 是 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/dm8_20240508_HWarm_kylin10_64_ent_8.1.3.140_pack3.zip` | Kylin 10 |
| DM | 8 | 是 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/dm8_20240517_HWarm_centos7_64.zip` | CentOS 7 |
| KINGBASE | V008R006C008B0020 | 是 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/kingbase_install.zip` | 需授权安装包 |
| MySQL | 8.0 | 否 | `https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.46-linux-glibc2.28-aarch64.tar.xz` | 官方 ARM64 安装包 |

不得根据源数据库产品自主推断目标数据库。用户未说明数据库目标路线时，先询问同产品迁移或国产化迁移：同产品迁移展示与源产品相同且本表支持的候选；国产化迁移展示 DM、Vastbase 候选。只在用户明确选择后写入目标产品和版本，不能因为源库是 MySQL 就默认选择 DM。

同一目标数据库存在多个目标 OS 安装包时（如 DM8 同时提供 Kylin 10 与 CentOS 7 包），推荐项必须按目标迁移机器的操作系统匹配：目标机 OS 已知时直接匹配对应包做推荐；未知时不提供推荐直接展示可选包。不得把表中排列顺序（Kylin 包在前）当作默认推荐，也不得在未确认目标机 OS 的情况下替用户推荐。

### 应用 SQL 改造默认路线

| 源数据库 | 默认候选目标数据库 |
|---|---|
| MySQL | DM |
| MySQL | Vastbase |
| Oracle | MySQL |
| Oracle | GoldenDB |
| DB2 | GoldenDB |
| DB2 | MySQL |
| DB2 | TDSQL |
| SQL Server | DM |

- 本次包含数据库迁移时，优先把应用对应的数据库迁移目标作为默认推荐；仍须展示该源数据库的其他默认候选，并允许用户选择其他路线或自定义输入。
- 本次不包含数据库迁移时，展示该源数据库的全部默认候选，由用户选择，并允许自定义输入；不得替用户选择。
- 源数据库不在表中或无法确认时，先让用户确认源数据库，再接受自定义路线，不得猜测。
- 用户确认后将路线按 `<源数据库> -> <目标数据库>` 写入 `application_sql_migration.selected_route`。

## 3. 中间件与运行时迁移路线

| 源产品 | 源版本 | 目标产品 | 目标版本 | License | URL 模板 | 备注 |
|---|---|---|---|---|---|---|
| RabbitMQ | 1.x–3.x | RabbitMQ | 3.9.29 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/rabbitmq-server-3.9.29-1.el8.noarch.rpm` | 同产品迁移，el8 rpm（noarch），Erlang 依赖可用同目录 `erlang-*.aarch64.rpm` |
| Redis | 2.x | Redis | 2.8.24 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/redis-2.8.24.tar.gz` | 同产品迁移 |
| Redis | 3.x | Redis | 3.2.13 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/redis-3.2.13.tar.gz` | 同产品迁移 |
| Redis | 4.x | Redis | 4.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/redis-4.0.14.tar.gz` | 同产品迁移 |
| Redis | 5.x、6.x | Redis | 6.2.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/redis-6.2.14.tar.gz` | 5.x 为跨版本迁移 |
| Redis | 7.0.x | Redis | 7.0.15 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/redis-7.0.15.tar.gz` | 同主版本迁移 |
| Nginx | 1.11.x–1.12.x | Nginx | 1.12.2 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.12.2.tar.gz` | 同产品迁移 |
| Nginx | 1.13.x–1.18.0 | Nginx | 1.18.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.18.0.tar.gz` | 同产品迁移 |
| Nginx | 1.19.x–1.24.x | Nginx | 1.24.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.24.0.tar.gz` | 同产品迁移 |
| Nginx | 1.25.x | Nginx | 1.26.3 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.26.3.tar.gz` | 跨次版本迁移 |
| Nginx | 1.26.1 | Nginx | 1.26.1 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.26.1.tar.gz` | 保持版本 |
| Nginx | 其他 1.26.x | Nginx | 1.26.3 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/nginx-1.26.3.tar.gz` | 同次版本迁移 |
| Tomcat | 5.5 | Tomcat | 5.5.36 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-5.5.36.tar.gz` | 保持主版本 |
| Tomcat | 6.0 | Tomcat | 6.0.53 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-6.0.53.tar.gz` | 保持主版本 |
| Tomcat | 7.0 | Tomcat | 7.0.109 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-7.0.109.tar.gz` | 保持主版本 |
| Tomcat | 8.0 | Tomcat | 8.0.53 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-8.0.53.tar.gz` | 保持主版本 |
| Tomcat | 8.5 | Tomcat | 8.5.100 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-8.5.100.tar.gz` | 保持主版本 |
| Tomcat | 9.0 | Tomcat | 9.0.65 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/apache-tomcat-9.0.65.tar.gz` | 保持主版本 |
| Tomcat | 6.x–8.x | 东方通TongWeb | 7.0.4.9_M3 | 是 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/TongWeb7.0.4.9_M3_Enterprise_with_tool.tar.gz` | 国产化候选 |
| Tomcat | 7.x–9.x | BES AppServer Standard | 9.5.5.7266 | 是 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/BES-AppServer-Standard-With-Tool-devkit-ver-9.5.5.7266.tar.gz` | 国产化候选 |
| JDK / JRE | Java 6、7、8 | OpenJDK | 1.8.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK8U-jdk_aarch64_linux_hotspot_8u422b05.tar.gz` | 保持 Java 8 兼容级别 |
| JDK / JRE | Java 6、7、8 | OpenJRE | 1.8.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK8U-jre_aarch64_linux_hotspot_8u432b06.tar.gz` | 保持 Java 8 兼容级别 |
| JDK / JRE | Java 6、7、8 | 毕昇JDK | 1.8.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jdk-8u412-linux-aarch64.tar.gz` | 保持 Java 8 兼容级别 |
| JDK / JRE | Java 6、7、8 | 毕昇JRE | 1.8.0 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jre-8u422-linux-aarch64.tar.gz` | 保持 Java 8 兼容级别 |
| JDK / JRE | Java 11 | OpenJDK | 11.0.26 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK11U-jdk_aarch64_linux_hotspot_11.0.26_4.tar.gz` | 保持主版本 |
| JDK / JRE | Java 11 | OpenJRE | 11.0.26 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK11U-jre_aarch64_linux_hotspot_11.0.26_4.tar.gz` | 保持主版本 |
| JDK / JRE | Java 11 | 毕昇JDK | 11.0.26 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jdk-11.0.26-b12-linux-aarch64.tar.gz` | 保持主版本 |
| JDK / JRE | Java 11 | 毕昇JRE | 11.0.26 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jre-11.0.26-b12-linux-aarch64.tar.gz` | 保持主版本 |
| JDK / JRE | Java 17 | OpenJDK | 17.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.14_7.tar.gz` | 保持主版本 |
| JDK / JRE | Java 17 | OpenJRE | 17.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/OpenJDK17U-jre_aarch64_linux_hotspot_17.0.14_7.tar.gz` | 保持主版本 |
| JDK / JRE | Java 17 | 毕昇JDK | 17.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jdk-17.0.14-b12-linux-aarch64.tar.gz` | 保持主版本 |
| JDK / JRE | Java 17 | 毕昇JRE | 17.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jre-17.0.14-b12-linux-aarch64.tar.gz` | 保持主版本 |
| JDK | Java 8 | 毕昇JDK | 17.0.14 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jdk-17.0.14-b12-linux-aarch64.tar.gz` | 跨大版本候选，必须确认 |
| JDK | Java 8 | 毕昇JDK | 21.0.6 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/bisheng-jdk-21.0.6-b12-linux-aarch64.tar.gz` | 跨大版本候选，必须确认 |
| Elasticsearch | 6.0.x–6.8.x（规则已列版本） | Elasticsearch | 与源版本一致 | 否 | `https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-{version}.tar.gz` | 包名未标注 aarch64，需确认 ARM 可用性 |
| Elasticsearch | 7.7.x–7.17.x、8.0.x–8.14.x（规则已列版本） | Elasticsearch | 与源版本一致 | 否 | `https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-{version}-linux-aarch64.tar.gz` | 仅匹配规则已列版本 |
| Elasticsearch | 版本未知 | Elasticsearch | — | 否 | — | 先补充源版本，不得默认升级 |
| Docker | 1.13、18、20 | Docker | 26.1.3 | 否 | `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/docker.tar.gz` | 检查 Dockerfile、Compose、镜像和参数兼容性 |
| Resin | 4.x | Resin | 4.0.58 | 否 | `https://www.caucho.com/download/resin-4.0.58.tar.gz` | GPL 版官方包，Java 包跨架构通用 |
| Nacos | 2.4.x | Nacos | 2.4.0 | 否 | `https://github.com/alibaba/nacos/releases/download/2.4.0/nacos-server-2.4.0.tar.gz` | 官方 GitHub Release，Java 包跨架构通用 |
| RocketMQ | 5.2.x | RocketMQ | 5.2.0 | 否 | `https://archive.apache.org/dist/rocketmq/5.2.0/rocketmq-all-5.2.0-bin-release.zip` | Apache 官方归档，Java 包跨架构通用 |
| Nacos / RocketMQ | 版本未知或未命中 | 原产品 | — | 否 | — | 先向用户确认源版本，不得生成虚假待选版本 |
| CustomDirectory / JavaMiddleware | 0 | 原产品 | 0 | 待确认 | — | 占位映射，不代表已有兼容路线 |

Tomcat 有多个目标产品；有国产化要求时提供 TongWeb、BES 候选，否则优先保持 Tomcat。JDK/JRE 默认保持 Java 主版本，跨大版本升级必须确认。

## 4. 路线决策规则

1. 数据库先由用户选择目标产品，再匹配安装路线；中间件（包括JDK/JRE）按 `classification → 源产品 → 源版本` 匹配表格。
2. 仅有一个明确目标时生成待确认的推荐路线；有多个候选时列出实际产品和版本，不得只写“待选版本”。
3. 未命中、源版本未知、目标版本未定义、占位映射或跨大版本迁移时，标记 `ROUTE_CONFIRM_REQUIRED`，先补充源版本或用户选择，不得臆测版本。
4. 用户明确确认目标产品、目标版本、License、ARM/aarch64 安装包来源和目标 OS 后，再写入 `migration-plan.json`。
5. `detection_method` 为 `rpm-owner`、`rpm-package`、`deb-owner` 或 `deb-package` 的系统包安装组件不要求用户确认版本；无论本表是否有对应版本或只列URL，都必须把目标系统仓库安装作为第一项和默认推荐，同时允许用户改选表中的URL下载路线。选择系统仓库时写入 `SYSTEM_REPOSITORY`，优先回填精确匹配的版本和URL，无法精确匹配时回填同一目标产品的最高具体版本及URL作为备用来源；选择URL时写入 `OFFICIAL`。

最小输出示例：

```json
{
  "source": {"product": "Tomcat", "version": "8.0.x"},
  "target": {"product": "东方通TongWeb", "version": "7.0.4.9_M3"},
  "package_url": "https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/TongWeb7.0.4.9_M3_Enterprise_with_tool.tar.gz"
}
```
