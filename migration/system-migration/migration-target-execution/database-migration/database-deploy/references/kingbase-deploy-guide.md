# 金仓 KingbaseES V8R6 部署参考指南

> 本文档是金仓数据库在鲲鹏 ARM (aarch64) 平台静默部署的完整参考，整合安装脚本、响应模板的使用说明。
> Agent 执行部署时应以本文件为准。
> **强制约束**：执行本指南前必须先读并遵守 [../database-deploy.md](../database-deploy.md) 的全局规则——目标数据库已存在检测与用户确认、失败后回滚与清理（cleanup 脚本调用须经确认）、默认密码明文展示、安装报告 JSON 字段与防火墙端口放行；本指南仅承载金仓专属参数与步骤。

---

## 资产清单

| 文件 | 路径 | 用途 |
|------|------|------|
| `kingbase_silent_install.sh` | `database-migration/database-deploy/scripts/kingbase/` | 静默安装主脚本：解压 zip、挂载 ISO、MD5 校验、渲染 silent.cfg、install.bin 静默安装、sys_ctl 直接启动、SQL 验证 |
| `kingbase_silent.cfg` | `database-migration/database-deploy/assets/kingbase/` | 静默安装响应文件模板（envsubst 渲染全部官方 silent.cfg 参数） |
| `kingbase_cleanup.sh` | `database-migration/database-deploy/scripts/kingbase/` | 卸载清理脚本：停服务、杀进程、卸ISO残留、删目录、还原limits.conf、删用户 |
| `kingbase-deploy-guide.md` | `database-migration/database-deploy/references/` | 本文档 |

> 卸载清理使用专属脚本 `database-migration/database-deploy/scripts/kingbase/kingbase_cleanup.sh`。

---

## 前置条件

| 项目 | 要求 |
|------|------|
| 架构 | aarch64（鲲鹏 920 / ARMv8） |
| OS | openEuler 22.03 / 麒麟 V10 |
| 依赖命令 | `unzip` `mount` `md5sum` `envsubst`（gettext） |
| 执行权限 | root 执行脚本（解压/挂载/目录创建/chown）；install.bin 与数据库进程由脚本自动 su 切换至 kingbase 用户 |
| 安装包 | `kingbase_install.zip`（内含 `KingbaseES_V008R006C*_Kunpeng64_install.iso`） |
| 用户/组 | 前置流程创建 `kingbase:kingbase` |
| License | 可选；未提供时安装后自动生成试用 license |

---

## 参数说明

### 环境配置文件 (install_env.conf)

阶段1生成，脚本通过 `--env-conf` 加载，关键字段：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `INSTALL_PATH` | 软件安装目录 | `/opt/Kingbase/ES/V8` |
| `DATA_PATH` | 数据目录 | `$INSTALL_PATH/data` |
| `INSTANCE_NAME` | 节点名 | `kingbase` |
| `DB_USER` | 数据库初始用户（非 OS 用户） | `system` |
| `DB_PASSWORD` | 初始密码（>=8位，大小写+数字） | `Kingbase123`（脚本未提供时从本文件表格兜底读取） |
| `PORT_NUM` | 监听端口 | `54321` |
| `ENCODING_PARAM` | 字符集 UTF8/GBK/GB18030/GB2312/default | `UTF8` |
| `LOCALE_PARAM` | 区域设置 | `zh_CN.UTF-8` |
| `DATABASE_MODE_PARAM` | 兼容模式 ORACLE/PG/MySQL | `ORACLE` |
| `CASE_SENSITIVE_PARAM` | 大小写敏感 YES/NO | `YES` |
| `BLOCK_SIZE_PARAM` | 块大小 8k/16k/32k | `8k` |
| `AUTHENTICATION_METHOD_PARAM` | 认证方式 scram-sha-256/scram-sm3/sm4/sm3 | `scram-sha-256` |
| `CHOSEN_INSTALL_SET` | 安装集 Full/Client/Custom | `Full` |
| `CHOSEN_FEATURE_LIST` | 组件清单 | `SERVER,KSTUDIO,KDTS,INTERFACE,DEPLOY,KINGBASEHA` |
| `KB_LICENSE_PATH` | license 文件路径 | 空 |

### 命令行参数

| 参数 | 必选 | 说明 |
|------|:----:|------|
| `--env-conf=FILE` | 是 | 环境配置文件 |
| `--package=FILE` | 是 | kingbase_install.zip 路径 |
| `--license=FILE` | 否 | license 文件 (.dat) |
| `--cfg-template=FILE` | 否 | silent.cfg 模板（默认自动定位 `assets/kingbase/kingbase_silent.cfg`） |
| `--db-pass=PWD` | 否 | 数据库管理员密码（命令行优先于 env-conf 的 `DB_PASSWORD`；两者均未提供时从本文件上方表格的默认值兜底读取） |
| `--extract-dir=DIR` | 否 | 解压临时目录 |
| `--log-dir=DIR` | 否 | 日志目录 |

> `INSTALL_PATH`/`DATA_PATH`/`PORT_NUM`/`DB_USER` 等安装参数统一由 `--env-conf` 提供；`DB_PASSWORD` 可由 `--db-pass` 命令行覆盖，未提供时从本文件表格兜底读取默认值。密码使用完毕后脚本自动 `unset`。

---

## 部署流程

### 1. 资源限制
Agent 在运行脚本前以 root 追加 `/etc/security/limits.conf` 标记块（幂等，先备份原文件到 `$WORK_DIR/backup/`）：
```bash
# kingbase-limits-begin
kingbase soft nproc unlimited
kingbase hard nproc unlimited
kingbase soft stack unlimited
kingbase hard stack unlimited
kingbase soft nofile 65536
kingbase hard nofile 65536
# kingbase-limits-end
```
> 已存在 `# kingbase-limits-begin` 标记时跳过；该标记块同时被 `kingbase_cleanup.sh` 用于还原。

### 2. 执行静默安装脚本
`kingbase_silent_install.sh`分模块负责：
- 前置检查-> 解压安装包和挂载-> 创建配置文件-> 静默安装-> 启动验证
- 通过下文脚本调用示例执行。

### 3. 环境变量与服务注册

安装脚本完成后，Agent 按以下步骤收尾：

**环境变量**（写入 kingbase 用户 `~/.bashrc`，已存在 `KINGBASE_HOME=` 则跳过）：
```bash
export KINGBASE_HOME=<sys_ctl 所在的 Server 目录>   # 即 $INSTALL_PATH/current
export KINGBASE_DATA=$DATA_PATH
export PATH=$KINGBASE_HOME/Server/bin:$PATH
export LD_LIBRARY_PATH=$KINGBASE_HOME/Server/lib:$LD_LIBRARY_PATH
```

**systemd 服务**（root 创建 `/etc/systemd/system/kingbased.service`）：
```ini
[Unit]
Description=KingbaseES Database Service
After=network.target

[Service]
Type=forking
User=kingbase
Group=kingbase
ExecStart=$KINGBASE_HOME/Server/bin/sys_ctl start -D $DATA_PATH -l $DATA_PATH/sys_log/startup.log
ExecStop=$KINGBASE_HOME/Server/bin/sys_ctl stop -D $DATA_PATH -m fast
ExecReload=$KINGBASE_HOME/Server/bin/sys_ctl reload -D $DATA_PATH
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload && systemctl enable kingbased
# 服务接管前先停掉脚本直接启动的实例
$KINGBASE_HOME/Server/bin/sys_ctl stop -D $DATA_PATH -m fast
systemctl start kingbased
```

---

## 调用示例

```bash
# 完整流水线模式（阶段1已生成 install_env.conf，以 root 执行）
#   密码：--db-pass 优先于 env-conf 的 DB_PASSWORD；两者均未提供时从本文件表格兜底读取
sh scripts/kingbase/kingbase_silent_install.sh \
  --env-conf=$WORK_DIR/build/install_env.conf \
  --package=$MIGRATION_WORK_DIR/packages/kingbase_install.zip \
  --log-dir=$WORK_DIR/logs \
  ${DB_PASSWORD:+"--db-pass=$DB_PASSWORD"}

# 指定 license 与显式模板
sh scripts/kingbase/kingbase_silent_install.sh \
  --env-conf=$WORK_DIR/build/install_env.conf \
  --package=$MIGRATION_WORK_DIR/packages/kingbase_install.zip \
  --license=/path/to/license.dat \
  --cfg-template=assets/kingbase/kingbase_silent.cfg \
  --extract-dir=$WORK_DIR/tmp/kingbase \
  --log-dir=$WORK_DIR/logs \
  ${DB_PASSWORD:+"--db-pass=$DB_PASSWORD"}
```

---

## 卸载清理

### kingbase_cleanup.sh（金仓专属卸载）

执行流程：
1. 停止并卸载 `kingbased` systemd 服务
2. 杀死残留 `kingbase`/`sys_ctl` 进程
3. 卸载 ISO 挂载残留（`$WORK_DIR/tmp/kingbase` 下的 iso_mount）
4. 删除安装目录、数据目录
5. 移除 limits.conf 中 `kingbase-limits` 标记块
6. 删除 `kingbase` 用户和组

```bash
sudo sh scripts/kingbase/kingbase_cleanup.sh
```

---

## 安装日志产物

| 日志文件 | 内容 |
|----------|------|
| `extract_<ts>.log` | zip 解压输出 |
| `mount_<ts>.log` | ISO 挂载输出 |
| `md5_<ts>.log` | install.bin MD5 校验 |
| `install_<ts>.log` | install.bin 静默安装输出 |
| `start_<ts>.log` | sys_ctl 直接启动输出 |
| `verify_<ts>.log` | SQL 验证输出 |

---

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| ISO 挂载失败 | 非 root 或 loop 设备不足 | 以 root 执行或增加 loop 设备 |
| MD5 校验失败 | 安装包损坏 | 重新获取安装包 |
| install.bin 拒绝执行 | 脚本未以 root 入口运行 | 以 root 执行脚本，install.bin 自动 su 切换 kingbase |
| 密码校验失败 | 低于官方策略（>=8位，大小写+数字） | 使用合规密码 |
| 未找到 sys_ctl | 安装目录结构变化 | 检查 `$INSTALL_PATH/KESRealPro` 下实际版本目录 |
| 端口 54321 被占用 | 冲突 | `--port` 指定其他端口 |
| ksql 登录失败 | 实例未启动/密码错误 | 检查进程、端口、DB_PASS |

---
