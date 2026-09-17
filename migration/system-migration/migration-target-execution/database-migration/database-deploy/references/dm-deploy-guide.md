# 达梦 DM8 部署参考指南

> 本文档是达梦数据库在鲲鹏 ARM (aarch64) 平台静默部署的完整参考，整合安装脚本、响应模板、清理脚本的使用说明。
> Agent 执行部署时应以本文件为准。
> **强制约束**：执行本指南前必须先读并遵守 [../database-deploy.md](../database-deploy.md) 的全局规则——目标数据库已存在检测与用户确认、失败后回滚与清理（cleanup 脚本调用须经确认）、默认密码明文展示、安装报告 JSON 字段与防火墙端口放行；本指南仅承载达梦专属参数与步骤。

---

## 资产清单

| 文件 | 路径 | 用途 |
|------|------|------|
| `dm_silent_install.sh` | `scripts/dm/` | 静默安装主脚本：解包、安装软件、dminit 初始化实例、注册 systemd 服务、验证 |
| `dm_silent.xml` | `assets/dm/` | 仅安装软件的响应文件模板（envsubst 渲染 `${INSTALL_PATH}` `${TIME_ZONE}`） |
| `dm_cleanup.sh` | `scripts/dm/` | 卸载清理脚本：停服务、杀进程、官方卸载、删目录、删用户 |
| `dm-deploy-guide.md` | `references/` | 本文档 |

---

## 前置条件

| 项目 | 要求 |
|------|------|
| 架构 | aarch64（鲲鹏 920 / ARMv8） |
| OS | openEuler 22.03 / 麒麟 V10 SP3 |
| 依赖命令 | `unzip` `timeout` `envsubst`（gettext） |
| 执行权限 | root 或 sudo（脚本内部自动切换 dmdba 执行安装程序） |
| 安装包 | DM8 ARM 版 zip 包（如 `dm8_*_HWarm_kylin10_64_ent_*.zip`） |
| 用户/组 | 脚本自动创建 `dmdba:dinstall` |

---

## 参数说明

### 环境配置文件 (install_env.conf)

阶段1生成，脚本通过 `--env-conf` 加载，关键字段：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `INSTALL_PATH` | 软件安装目录 | `/opt/dmdbms` |
| `DATA_PATH` | 实例数据目录 | `$INSTALL_PATH/data` |
| `INSTANCE_NAME` | 实例名 | `DAMENG` |
| `PORT_NUM` | 监听端口 | `5236` |
| `SYSDBA_PWD` | SYSDBA 密码 | `SYSDBA001`（脚本未提供时从本文件表格兜底读取） |
| `PAGE_SIZE` | 页大小 | `16` |
| `EXTENT_SIZE` | 扩展大小 | `32` |
| `CASE_SENSITIVE` | 大小写敏感 | `Y` |
| `CHARSET` | 字符集 (1=UTF-8, 0=GB18030) | `1` |
| `LENGTH_IN_CHAR` | 字符长度计算 | `1` |
| `TIME_ZONE` | 时区 | `+08:00` |

### 命令行参数

| 参数 | 必选 | 说明 |
|------|:----:|------|
| `--env-conf=FILE` | 是 | 环境配置文件 |
| `--package=FILE` | 是 | DM8 zip 安装包路径 |
| `--xml-template=FILE` | 是 | 响应文件模板（envsubst 渲染，通常传 `assets/dm/dm_silent.xml`） |
| `--sysdba-pwd=PWD` | 否 | SYSDBA 密码（命令行优先于 env-conf 的 `SYSDBA_PWD`；两者均未提供时从本文件上方表格的默认值兜底读取） |
| `--extract-dir=DIR` | 否 | 指定解压临时目录（默认 `$MIGRATION_WORK_DIR/database/tmp/dm`） |
| `--log-dir=DIR` | 否 | 日志目录（默认 `$MIGRATION_WORK_DIR/database/logs`） |

> `INSTALL_PATH`/`DATA_PATH`/`INSTANCE_NAME`/`PORT_NUM` 等安装参数统一由 `--env-conf` 提供；`SYSDBA_PWD` 可由 `--sysdba-pwd` 命令行覆盖，未提供时从本文件表格兜底读取默认值。密码使用完毕后脚本自动 `unset`。

---

## 部署流程

### 1. 执行达梦数据库静默安装脚本
`dm_silent_install.sh` 脚本内分模块负责：
- 前置检查-> 解压安装包-> 渲染配置文件-> 执行安装-> 初始化数据库实例
- 通过下文脚本调用示例执行。

### 2. 注册 systemd 服务

调用达梦官方 `dm_service_installer.sh`：
```
dm_service_installer.sh -t dmserver -p $INSTANCE_NAME -dm_ini $dm_ini
```
服务名：`DmService${INSTANCE_NAME}`（如 `DmServiceDAMENG`），自动 `enable` 并启动。

### 3. 验证

| 检查项 | 方法 |
|--------|------|
| 进程 | `pgrep -f "dmserver.*${INSTANCE_NAME}"` |
| 连通性 | `disql SYSDBA/${SYSDBA_PWD}@127.0.0.1:${PORT_NUM} -e "SELECT 1;"` |
| 服务 | `systemctl status DmService${INSTANCE_NAME}` |

---

## 调用示例

```bash
# 完整流水线模式（阶段1已生成 install_env.conf）
#   密码：--sysdba-pwd 优先于 env-conf 的 SYSDBA_PWD；两者均未提供时从本文件表格兜底读取
sh scripts/dm/dm_silent_install.sh \
  --env-conf=$WORK_DIR/build/install_env.conf \
  --package=$MIGRATION_WORK_DIR/packages/dm8_*_HWarm_kylin10_64.zip \
  --xml-template=assets/dm/dm_silent.xml \
  --log-dir=$WORK_DIR/logs \
  ${SYSDBA_PWD:+"--sysdba-pwd=$SYSDBA_PWD"}
```

---

## 卸载清理

### dm_cleanup.sh（达梦专用卸载）

执行流程：
1. 停止 `DmService${INSTANCE_NAME}` + `DmAPService` 系统服务
2. 杀死残留 `dmserver` / `dmap` 进程
3. 执行官方 `uninstall.sh`（交互式，自动 `yes y` 应答）
4. 执行 `dm_service_uninstaller.sh` 卸载服务注册
5. 删除安装目录、数据目录、`/etc/dm_svc.conf`
6. 删除 `dmdba` 用户和 `dinstall` 组

```bash
sh scripts/dm/dm_cleanup.sh
```

---

## 安装日志产物

| 日志文件 | 内容 |
|----------|------|
| `extract_<ts>.log` | 解压输出 |
| `install_<ts>.log` | DMInstall.bin 安装输出 |
| `root_install_<ts>.log` | root_installer.sh 输出 |
| `dminit_<ts>.log` | dminit 实例初始化输出 |
| `service_reg_<ts>.log` | systemd 服务注册输出 |
| `verify_<ts>.log` | 连通性验证输出 |

---

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 安装目录不为空 | 重复安装未清理 | `rm -rf $INSTALL_PATH` 或执行 `dm_cleanup.sh` |
| DMInstall.bin 不可执行 | 解压后权限丢失 | `chmod +x DMInstall.bin` |
| dminit 端口被占用 | 5236 端口已使用 | `--port` 指定其他端口 |
| systemctl 启动失败 | dm.ini 路径错误 | 检查 `dm_service_installer.sh -dm_ini` 参数 |
| disql 连接失败 | 实例未启动/密码错误 | 检查进程、端口、SYSDBA 密码 |
| ISO 挂载失败 | 非 root 或 loop 设备不足 | 用 root 执行或增加 loop 设备 |
---