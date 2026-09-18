# 中间件迁移常见问题

## Nginx

| 问题 | 解决方案 |
|------|---------|
| 自定义模块需要重新编译 | 使用官方预编译二进制 + 动态模块 |
| SSL 证书路径差异 | 检查 /etc/nginx/ssl/ 目录 |
| worker_connections 参数 | ARM 建议不超过 4096 |
| systemd Type=simple 立即退出 | 二进制默认 `daemon on` 会 fork 后父进程退出，systemd 误判崩溃；需在 nginx.conf 首行注入 `daemon off;` |
| 二进制使用相对配置路径 `conf/nginx.conf` | systemd ExecStart 需带 `-p <deploy_dir>/` 指定 prefix 目录 |
| `nginx -t` 验证报 `../../nginx/conf/nginx.conf` 失败 | 默认 prefix 为相对路径，验证命令需 `${DEPLOY_DIR}/sbin/nginx -t -p ${DEPLOY_DIR}/` |
| 启动报 `module ... version ... instead of ...` 且 Service 反复 failed | 目标机 `/etc/nginx` 里的 `include /usr/share/nginx/modules/*.conf` 加载了系统自带 nginx 的动态模块，其编译版本与迁移目标 nginx 二进制版本不一致，`nginx -t` 失败导致 systemd 重启风暴。修复：注释掉 nginx.conf 中的 `include /usr/share/nginx/modules/*.conf;`（如确需第三方动态模块，应为目标版本重新编译并单独 `load_module`） |
| 配置恢复从目标机 `/etc/nginx` 复制导致不兼容 | registry 已移除 nginx `config_dir`（原为 `/etc/nginx` 绝对路径），避免 `migrate_package.sh` 从目标机本地复制含系统模块 include 的旧配置。迁移后使用安装包自带默认 nginx.conf；如需恢复源端自定义配置（server 块、upstream 等），从采集包 `artifact_paths` 中的 nginx.conf 手动复制到 `${DEPLOY_DIR}/conf/` 并确认不含不兼容的 `include /usr/share/nginx/modules/*.conf` |

## Redis

| 问题 | 解决方案 |
|------|---------|
| RDB/AOF 文件兼容性 | 同一主版本内兼容，跨版本需先升级 |
| maxmemory 参数 | ARM 建议设置合理值 |
| 持久化目录权限 | chown redis:redis /var/lib/redis |
| 源码编译报 `libhiredis_ssl.a: No such file` | 默认 `BUILD_TLS=yes` 但 hiredis SSL 库未构建，需设置 `BUILD_TLS=no` 规避 |
| 降版本迁移配置指令不兼容 | 源端高版本（如 7.2.x）的 `locale-collate`、`set-max-listpack-*` 等在低版本（7.0.x）不存在或更名，需注释或改为旧指令名 |

## Tomcat

| 问题 | 解决方案 |
|------|---------|
| 数据源配置 | 检查 server.xml JNDI 配置 |
| JAVA_HOME 路径 | 更新 setenv.sh 配置 |
| 内存泄漏检查 | 调整 JVM 参数 |
| 验证阶段 HTTP 探测失败但服务实际正常 | Java 中间件启动较慢，start_service 通过 wait_service_ready 轮询服务状态与端口（最长 120s），就绪后才进入验证 |
| 验证 `curl 127.0.0.1:8080` 失败但服务 active | 源端 server.xml 因端口被占用把 HTTP Connector 改为非 8080 端口（如 18080），恢复配置后服务监听该端口，与 registry 验证探测端口 8080 不一致。registry 已修复：functional 验证命令从 server.xml 动态解析 Connector port，不再硬编码 8080 |

## Elasticsearch

| 问题 | 解决方案 |
|------|---------|
| 堆内存配置 | 修改 jvm.options，不超过物理内存 50% |
| 集群发现 | 调整 discovery.seed_hosts |
| 索引恢复 | 使用 reindex API |

## RabbitMQ

| 问题 | 解决方案 |
|------|---------|
| Erlang 版本依赖 | 安装对应 aarch64 版本 Erlang（如 erlang-24.3.4.15） |
| 队列持久化 | 检查 /var/lib/rabbitmq/ |
| 镜像队列 | 重新配置策略 |
| `require_env CURRENT_VERSION` 报缺少环境变量，脚本无法重装 | 计划 `route.middleware[].source.version` 为空（采集时未确认版本）时，`transform_plan.py` 已修复：空版本降级为 `unknown` 占位符，使 `require_env CURRENT_VERSION` 通过，不再硬退出。若目标已有健康实例可直接接受现有实例 |
| rpm 已安装但迁移脚本报「安装来源全部失败」 | `source_type=OFFICIAL` 的 .rpm 被当归档解压（`rpm --prefix`），而该 rpm 实为系统包应 `rpm -ivh` 或 `yum install`。目标机 `rpm -q rabbitmq-server` 已装 3.9.29 时无需重装，直接 `systemctl enable --now rabbitmq-server` 并 `rabbitmqctl status` 验证 |
| 配置恢复 | `/etc/rabbitmq/rabbitmq.conf` 需与采集品一致（listeners / management / log.dir 等） |

## Docker

| 问题 | 解决方案 |
|------|---------|
| 多架构镜像 | 使用 --platform linux/arm64 |
| Dockerfile 适配 | 修改基础镜像架构 |
| 镜像仓库 | 使用支持多架构的 registry |

## Nacos

| 问题 | 解决方案 |
|------|---------|
| JAVA_HOME 依赖 | 确保 JDK 已安装，检查 setenv.sh |
| 数据库配置 | application.properties 中 DB 连接检查 |
| 集群配置 | cluster.conf 中节点 IP 更新为目标主机 |
| 端口冲突 | 8848/9848/9849 端口检查与防火墙 |
| `require_env CURRENT_VERSION` 报缺少环境变量，脚本无法重装 | 计划 `source.version` 为空时 `transform_plan.py` 已修复：空版本降级为 `unknown` 占位符，使 `require_env` 通过。若目标已有健康实例可直接接受现有实例 |
| 服务 203/EXEC 失败且 Restart 风暴 | systemd `ExecStart` 指向的 `bin/startup-foreground.sh` 不在官方 tar 包内（旧实例自建的目标机产物），重新解压重建目录后脚本缺失，`Type=simple` 立即 203/EXEC，`Restart=on-failure` 触发快速重试风暴。修复：按 nacos 官方 `startup.sh` 参数补回 `startup-foreground.sh`（standalone 前台以 `exec java ... -jar target/nacos-server.jar` 启动），`reset-failed` 后启动 |

## RocketMQ

| 问题 | 解决方案 |
|------|---------|
| JAVA_HOME 依赖 | 确保 JDK 已安装，检查 runserver.sh/runbroker.sh |
| NameServer/Broker 分离 | 检查 namesrvAddr 配置 |
| Topic 迁移 | 使用 admin 工具导出导入 Topic |
| 数据目录权限 | chown -R rocketmq:rocketmq /opt/rocketmq/store |

## ZooKeeper（系统仓库包）

| 问题 | 解决方案 |
|------|---------|
| systemd 启动失败，`journalctl -u zookeeper` 报 `logs/...out: 权限不够` | 系统包 `zookeeper.service` 以 `zookeeper` 用户运行，日志目录属 root 导致写不进。修复：`chown -R zookeeper:zookeeper /opt/zookeeper/logs`（以及 `dataDir` 目录，如 `/data/middleware-lab/zookeeper`）后 `systemctl restart zookeeper` |
| 目标仓库版本与 plan 目标版本不一致 | 系统仓库（如 `@ks10-adv-updates`）可能只提供 3.6.x 而非 plan 的 3.8.6；以目标机 `dnf list --installed zookeeper` 实际版本为准，必要时向用户确认是否接受仓库版本 |
| dataDir 无 `myid` | 单机模式可不配置，集群模式需在 `dataDir` 写节点 id |

## Kafka（未登记，走通用流程）

| 问题 | 解决方案 |
|------|---------|
| 只完成解压，未注册 systemd 服务（GENERIC 警告） | 按采集 `server.properties` 恢复配置，注册 `/etc/systemd/system/kafka.service`（`ExecStart=/opt/kafka-*/bin/kafka-server-start.sh .../config/server.properties`），`After=zookeeper.service` 并 `Requires=zookeeper.service`，再 `systemctl enable --now kafka` |
| 启动用 JDK 版本 | 复用迁移后的毕昇 JDK（如 `/opt/bisheng-jdk-11.0.26`），在 service 中设置 `Environment=JAVA_HOME=...` |
| 数据目录 | `server.properties` 中 `log.dirs` 指向的目标目录需存在，如 `/data/middleware-lab/kafka` |
