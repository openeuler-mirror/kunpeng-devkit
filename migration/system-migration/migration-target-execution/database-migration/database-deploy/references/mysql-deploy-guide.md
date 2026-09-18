# MySQL 8.0 部署参考指南

> 本文档是 MySQL 在鲲鹏 ARM (aarch64) 平台二进制包静默部署的完整参考，整合安装脚本、配置模板的使用说明。
> Agent 执行部署时应以本文件为准。
> **强制约束**：执行本指南前必须先读并遵守 [../database-deploy.md](../database-deploy.md) 的全局规则——目标数据库已存在检测与用户确认、失败后回滚与清理（cleanup 脚本调用须经确认）、默认密码明文展示、安装报告 JSON 字段与防火墙端口放行；本指南仅承载 MySQL 专属参数与步骤。

---

## 资产清单

| 文件 | 路径 | 用途 |
|------|------|------|
| `mysql_silent_install.sh` | `scripts/mysql/` | 静默安装主脚本：解压二进制包、拷贝安装、渲染 my.cnf、`mysqld --initialize-insecure` 初始化、直接启动、设置 root 密码、SQL 验证 |
| `mysql_silent.cnf` | `assets/mysql/` | mysql_silent.cnf 配置文件模板（envsubst 渲染） |
| `mysql_cleanup.sh` | `scripts/mysql/` | 卸载清理脚本：停服务、杀进程、删目录、移除/etc/my.cnf、还原limits.conf、删用户 |
| `mysql-deploy-guide.md` | `references/` | 本文档 |

> 卸载清理使用专属脚本 `scripts/mysql/mysql_cleanup.sh`。

---

## 前置条件

| 项目 | 要求 |
|------|------|
| 架构 | aarch64（鲲鹏 920 / ARMv8） |
| OS | 通用 ARM64 Linux 发行版 |
| 依赖命令 | `tar`（.tar.xz 需 `xz`） `envsubst`（gettext） |
| 执行权限 | mysql 用户执行初始化；资源限制/服务注册需 root/sudo |
| 安装包 | `mysql-8.0.xx-linux-glibc2.12-aarch64.tar.gz`（官方 ARM64 二进制包） |
| 用户/组 | 前置流程创建 `mysql:mysql` |
| 密码策略 | MySQL 8.0 默认 MEDIUM：>=8位，大小写+数字+特殊字符 |

---

## 参数说明

### 环境配置文件 (install_env.conf)

阶段1生成，脚本通过 `--env-conf` 加载，关键字段：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `INSTALL_PATH` | 软件安装目录 | `/opt/mysql` |
| `DATA_PATH` | 数据目录 | `$INSTALL_PATH/data` |
| `INSTANCE_NAME` | 实例名 | `mysqld` |
| `DB_PASSWORD` | root 密码（MEDIUM 策略） | `MySQL_123!`（脚本未提供时从本文件表格兜底读取） |
| `PORT_NUM` | 监听端口 | `3306` |
| `SERVER_ID` | 复制 server-id | `1` |
| `CHARACTER_SET_SERVER` | 字符集 | `utf8mb4` |
| `COLLATION_SERVER` | 排序规则 | `utf8mb4_general_ci` |
| `DEFAULT_STORAGE_ENGINE` | 默认存储引擎 | `InnoDB` |
| `MAX_CONNECTIONS` | 最大连接数 | `500` |
| `INNODB_BUFFER_POOL_SIZE` | InnoDB 缓冲池(MB) | 系统内存 1/2 |
| `SOCKET_PATH` | socket 文件路径 | `$INSTALL_PATH/mysql.sock` |
| `PID_FILE_PATH` | pid 文件路径 | `$INSTALL_PATH/mysqld.pid` |
| `LOG_ERROR_PATH` | 错误日志路径 | `$INSTALL_PATH/logs/mysqld.err` |

### 命令行参数

| 参数 | 必选 | 说明 |
|------|:----:|------|
| `--env-conf=FILE` | 是 | 环境配置文件 |
| `--package=FILE` | 是 | MySQL 二进制包路径 |
| `--cnf-template=FILE` | 否 | mysql_silent.cnf 模板（默认自动定位 `assets/mysql/mysql_silent.cnf`） |
| `--root-pwd=PWD` | 否 | root 管理员密码（命令行优先于 env-conf 的 `DB_PASSWORD`；两者均未提供时从本文件上方表格的默认值兜底读取） |
| `--extract-dir=DIR` | 否 | 解压临时目录 |
| `--log-dir=DIR` | 否 | 日志目录 |

> `INSTALL_PATH`/`DATA_PATH`/`PORT_NUM` 等安装参数统一由 `--env-conf` 提供；`DB_PASSWORD`（即 `ROOT_PWD`）可由 `--root-pwd` 命令行覆盖，未提供时从本文件表格兜底读取默认值。密码使用完毕后脚本自动 `unset`，包括后备提取的临时密码 `_TEMP_PWD`。

---

## 部署流程

### 1. 前置检查
- 在脚本内执行前置检查

### 1. 资源限制
安装脚本不再处理，Agent 在运行脚本前以 root 追加 `/etc/security/limits.conf` 标记块（幂等，先备份原文件到 `$WORK_DIR/backup/`）：
```bash
# mysql-limits-begin
mysql soft nproc unlimited
mysql hard nproc unlimited
mysql soft stack unlimited
mysql hard stack unlimited
mysql soft nofile 65536
mysql hard nofile 65536
# mysql-limits-end
```
> 已存在 `# mysql-limits-begin` 标记时跳过；该标记块同时被 `mysql_cleanup.sh` 用于还原。

### 2. 执行静默安装脚本
`mysql_silent_install.sh` 脚本内分模块负责：
- 前置检查-> 解压安装包-> 创建配置文件-> 初始化数据目录-> 安装以及启动验证
- 通过下文脚本调用示例执行。

### 3. 环境变量与服务注册（Agent 执行）

静默安装脚本完成后，Agent 按以下步骤收尾：

**环境变量**（写入 mysql 用户 `~mysql/.bashrc`，已存在 `MYSQL_HOME=` 则跳过）：
```bash
export MYSQL_HOME=$INSTALL_PATH
export PATH=$MYSQL_HOME/bin:$PATH
export LD_LIBRARY_PATH=$MYSQL_HOME/lib:$LD_LIBRARY_PATH
```

**systemd 服务**（root 创建 `/etc/systemd/system/mysqld.service`）：
```ini
[Unit]
Description=MySQL 8.0 Database Server
After=network.target
After=syslog.target

[Service]
User=mysql
Group=mysql
Type=forking
PIDFile=$INSTALL_PATH/mysqld.pid

ExecStart=$INSTALL_PATH/bin/mysqld --defaults-file=$INSTALL_PATH/my.cnf --user=mysql --daemonize
ExecStop=$INSTALL_PATH/bin/mysqladmin --defaults-file=$INSTALL_PATH/my.cnf shutdown
Restart=on-failure
LimitNOFILE=65536
RuntimeDirectory=mysql
RuntimeDirectoryMode=755

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload && systemctl enable mysqld
# 服务接管前先停掉脚本直接启动的实例
$INSTALL_PATH/bin/mysqladmin --socket=$INSTALL_PATH/mysql.sock -u root -p shutdown
systemctl start mysqld
```

**SSL 证书（可选）**：
```bash
$INSTALL_PATH/bin/mysql_ssl_rsa_setup --datadir=$DATA_PATH --user=mysql
```

---

## 调用示例

```bash
# 完整流水线模式（阶段1已生成 install_env.conf）
#   密码：--root-pwd 优先于 env-conf 的 DB_PASSWORD；两者均未提供时从本文件表格兜底读取
sh scripts/mysql/mysql_silent_install.sh \
  --env-conf=$WORK_DIR/build/install_env.conf \
  --package=$MIGRATION_WORK_DIR/packages/mysql-8.0.xx-linux-glibc2.12-aarch64.tar.gz \
  --log-dir=$WORK_DIR/logs \
  ${DB_PASSWORD:+"--root-pwd=$DB_PASSWORD"}

# 显式指定模板
sh scripts/mysql/mysql_silent_install.sh \
  --env-conf=$WORK_DIR/build/install_env.conf \
  --package=$MIGRATION_WORK_DIR/packages/mysql-8.0.xx-linux-glibc2.12-aarch64.tar.gz \
  --cnf-template=assets/mysql/mysql_silent.cnf \
  --extract-dir=$WORK_DIR/tmp/mysql \
  --log-dir=$WORK_DIR/logs \
  ${DB_PASSWORD:+"--root-pwd=$DB_PASSWORD"}
```

---

## 卸载清理

### mysql_cleanup.sh（MySQL专属卸载）

```bash
sudo sh scripts/mysql/mysql_cleanup.sh
```

---

## 安装日志产物

| 日志文件 | 内容 |
|----------|------|
| `extract_<ts>.log` | tar 解压输出 |
| `install_<ts>.log` | 软件拷贝输出 |
| `init_<ts>.log` | mysqld --initialize-insecure 输出 |
| `start_<ts>.log` | mysqld --daemonize 启动输出 |
| `verify_<ts>.log` | SQL 验证输出 |

---

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 解压后未找到基目录 | 非官方命名包 | 使用官方 aarch64 二进制包 |
| MD5 校验失败 | 安装包损坏 | 重新获取安装包 |
| 初始化失败 | 非 mysql 用户/数据目录权限错误 | 以 mysql 用户执行，检查 750 权限 |
| 密码设置失败 | 低于 MEDIUM 策略 | 使用 >=8位大小写+数字+特殊字符密码 |
| systemctl 启动失败 | my.cnf 路径或 PIDFile 错误 | 检查 `--defaults-file` 与 `pid-file` 一致 |
| 端口 3306 被占用 | 冲突 | `--port` 指定其他端口 |
| libaio 缺失 | glibc 二进制包依赖 | 提前安装 `libaio` |
| 脚本误报"数据库启动失败"但实例实际已启动 | 进程检测用 `pgrep -f "mysqld.*$DATA_PATH"`，而 `--daemonize` 命令行不含 datadir（datadir 在 my.cnf 中） | 脚本已修复为匹配 `--defaults-file=$MY_CNF` + socket/SQL 兜底；若遇旧版本脚本，核对 `mysqld.err` 中 `ready for connections` 即为实际启动成功 |
| `su - mysql` 告警 "无法更改到 /home/mysql" | mysql 用户无 home 目录 | 脚本已修复：root 执行时自动创建 mysql home；或前置 `useradd -m -d /home/mysql mysql` |

---
