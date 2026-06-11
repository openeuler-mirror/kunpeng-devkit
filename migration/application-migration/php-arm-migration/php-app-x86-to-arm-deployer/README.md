# PHP 应用 x86 到 ARM 迁移部署 Skill 包

该包用于在 openEuler 22.03 ARM64 目标机上端到端部署 PHP 7.0.33 应用运行环境，包含：

- PHP 7.0.33 源码下载/编译/安装
- php-fpm 配置与 systemd 服务
- nginx 安装与应用访问配置
- `.tar.gz` / `.zip` 应用包部署
- 应用配置静态扫描：IP、域名、数据库、Redis、绝对路径等
- HTTP 200 验证
- 日志采集
- Markdown / JSON 报告输出
- 可选 PHP ARM 运行时打包

## 目标环境

- OS：openEuler 22.03
- 架构：aarch64 / ARM64
- 用户：root
- PHP：7.0.33
- PHP 安装目录：`/opt/php_7.0.33`
- PHP 兼容软链接：`/opt/php`
- 应用部署目录：`/opt/php-app`
- 工作目录：`/opt/migration`

## 快速使用

### 1. 解压 Skill 包

```bash
unzip php-app-x86-to-arm-deployer.zip
cd php-app-x86-to-arm-deployer
```

### 2. 准备目录

```bash
mkdir -p /opt/migration/packages
cp config.yaml /opt/migration/config.yaml
```

### 3. 放入应用包

将 PHP 应用包放入：

```bash
/opt/migration/packages/app.tar.gz
```

或：

```bash
/opt/migration/packages/app.zip
```

也可以执行时显式指定：

```bash
--app-package /opt/migration/packages/demo-app.tar.gz
```

### 4. 准备 PHP 源码包，可选

如果目标机能访问外网，脚本会自动尝试下载 PHP 7.0.33 源码包。

如果目标机不能访问外网，请手工下载并上传到：

```bash
/opt/migration/packages/php-7.0.33.tar.gz
```

官方下载地址优先使用：

```text
https://www.php.net/distributions/php-7.0.33.tar.gz
https://museum.php.net/php7/php-7.0.33.tar.gz
```

### 5. 执行端到端部署

```bash
python3 bin/php_arm_migration.py --config /opt/migration/config.yaml --mode all
```

指定应用包：

```bash
python3 bin/php_arm_migration.py \
  --config /opt/migration/config.yaml \
  --app-package /opt/migration/packages/demo-app.tar.gz \
  --mode all
```

启用 PHP ARM 运行时打包：

```bash
python3 bin/php_arm_migration.py \
  --config /opt/migration/config.yaml \
  --app-package /opt/migration/packages/demo-app.tar.gz \
  --runtime-pack \
  --mode all
```

## 结果查看

报告目录：

```bash
/opt/migration/reports/
```

日志目录：

```bash
/opt/migration/logs/
```

辅助脚本：

```bash
/opt/migration/scripts/
```

常用查看命令：

```bash
ls -lh /opt/migration/reports/
cat /opt/migration/reports/installed_packages.txt
bash /opt/migration/scripts/status_php_stack.sh
bash /opt/migration/scripts/verify_php_stack.sh
```

## 默认策略

### PHP 安装策略

- 默认安装到 `/opt/php_7.0.33`。
- 如果该路径已存在且 PHP 版本正确，则跳过 PHP 编译安装。
- 如果该路径为空目录，则直接安装。
- 如果该路径非空且 PHP 版本不正确，则自动备份为 `/opt/php_7.0.33.bak_时间戳` 后重新安装。
- 默认创建 `/opt/php -> /opt/php_7.0.33` 软链接。

### nginx 策略

- 优先 `yum install -y nginx`。
- yum 失败时尝试 `/opt/migration/packages/*.rpm` 离线安装。
- 不覆盖 `/etc/nginx/nginx.conf`。
- 只新增或重建 `/etc/nginx/conf.d/php_app.conf`。
- 如果已有 `php_app.conf`，先备份后重建。
- 默认端口 80；如果 80 被占用，尝试 8080、8081、8082。

### 应用包策略

- 默认从 `/opt/migration/packages` 自动选择非 PHP 源码的 `.tar.gz` / `.tgz` / `.zip` 包。
- 默认部署到 `/opt/php-app`。
- 如果 `/opt/php-app` 已存在且非空，自动备份后重新部署。
- 自动识别 Web 根目录：`public/`、`web/`、`www/`、`htdocs/`、应用根目录。
- 不自动修改业务配置。
- 不执行 `composer install`。
- 如果存在 `composer.json` 但没有 `vendor/`，报告中提示依赖可能缺失。

### 数据库策略

第一版不部署数据库，不安装 MySQL/MariaDB，不导入 SQL。

但会扫描应用配置中的数据库连接信息，并提示：

- 数据库 IP 是否从 ARM 目标机可达
- 防火墙是否放通
- 数据库白名单是否放通
- PHP 是否已启用 `mysqli` / `pdo_mysql`

### glibc 策略

使用系统自带 glibc，不升级、不替换、不覆盖系统 glibc。

## 离线环境说明

如果目标机不能联网，需要提前把这些内容放入：

```bash
/opt/migration/packages/
```

包括：

- `php-7.0.33.tar.gz`
- PHP 编译依赖的 aarch64 RPM 包
- nginx 及其依赖的 aarch64 RPM 包
- PHP 应用包 `.tar.gz` 或 `.zip`

参考文件：

```bash
docs/offline_packages_guide.md
```

## 不做的事情

该工具不会：

- 动态分析 x86 生产环境
- 自动修改业务配置
- 自动安装或迁移数据库
- 自动执行 Composer 联网安装
- 自动卸载已安装软件
- 自动删除已有系统组件
- 升级或替换系统 glibc
- 覆盖 nginx 主配置 `/etc/nginx/nginx.conf`

## 失败后排查

查看报告：

```bash
ls -lh /opt/migration/reports/
```

查看执行日志：

```bash
less /opt/migration/logs/php_arm_migration_*.log
```

查看服务日志：

```bash
journalctl -u php-fpm-7.0.33.service --no-pager -n 200
journalctl -u nginx --no-pager -n 200
```

查看 nginx 错误日志：

```bash
tail -n 200 /opt/migration/logs/nginx_php_app_error.log
tail -n 200 /var/log/nginx/error.log
```
