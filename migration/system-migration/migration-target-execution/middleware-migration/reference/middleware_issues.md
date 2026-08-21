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

## Elasticsearch

| 问题 | 解决方案 |
|------|---------|
| 堆内存配置 | 修改 jvm.options，不超过物理内存 50% |
| 集群发现 | 调整 discovery.seed_hosts |
| 索引恢复 | 使用 reindex API |

## RabbitMQ

| 问题 | 解决方案 |
|------|---------|
| Erlang 版本依赖 | 安装对应 aarch64 版本 Erlang |
| 队列持久化 | 检查 /var/lib/rabbitmq/ |
| 镜像队列 | 重新配置策略 |

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

## RocketMQ

| 问题 | 解决方案 |
|------|---------|
| JAVA_HOME 依赖 | 确保 JDK 已安装，检查 runserver.sh/runbroker.sh |
| NameServer/Broker 分离 | 检查 namesrvAddr 配置 |
| Topic 迁移 | 使用 admin 工具导出导入 Topic |
| 数据目录权限 | chown -R rocketmq:rocketmq /opt/rocketmq/store |
