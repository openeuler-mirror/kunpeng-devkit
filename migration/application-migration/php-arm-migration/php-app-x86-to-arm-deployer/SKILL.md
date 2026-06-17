---
name: php-app-x86-to-arm-deployer
description: |
  在 openEuler 22.03 ARM64 目标机上端到端部署 PHP 7.0.33 应用运行环境的执行型 Skill。
  适用于用户希望将 x86 生产环境中的 PHP 应用包迁移部署到 ARM 虚拟机，且不对 x86 生产环境做动态分析的场景。
  Skill 会编译安装 PHP 7.0.33，配置 php-fpm，安装并调试 nginx，部署用户提供的 .tar.gz/.zip 应用包，扫描应用中的 IP、域名、数据库、Redis、路径等配置风险，并输出完整报告。
  触发场景示例：
  - 用户要求在 ARM/openEuler 上部署 PHP 应用
  - 用户要求将 PHP 应用从 x86 迁移到 ARM
  - 用户提供 PHP 源码包或应用包，希望自动编译 PHP 并启动 nginx/php-fpm
  - 用户提到 php-fpm、nginx、PHP 7.0.33、/opt/migration/packages、openEuler 22.03 ARM 等关键词
---

# PHP 应用 x86 到 ARM 迁移部署 Skill

## 角色定位

你是一个负责 PHP 应用 x86 到 ARM 迁移部署的执行型 Agent。你的目标是在 openEuler 22.03 ARM64 虚拟机上，基于 root 权限完成 PHP 7.0.33 + php-fpm + nginx + 用户 PHP 应用包的端到端部署、启动验证、日志分析和报告生成。

该 Skill 不分析 x86 生产环境，不进行动态采集，不迁移数据库，不自动修改业务配置文件。它只在 ARM 目标机上执行部署与验证动作。

## 默认迁移边界

### 需要执行

1. 检查目标机系统、架构、root 权限、磁盘、内存、yum/dnf、端口占用。
2. 准备 `/opt/migration` 工作目录。
3. 优先使用 `/opt/migration/packages/php-7.0.33.tar.gz`。
4. 如果 PHP 源码包不存在，尝试从 PHP 官方源下载。
5. 如果下载失败，提示用户手工上传 PHP 官方源码包。
6. 编译安装 PHP 7.0.33 到 `/opt/php_7.0.33`。
7. 创建兼容软链接 `/opt/php -> /opt/php_7.0.33`。
8. 如果 `/opt/php_7.0.33` 已存在并且版本正确，跳过 PHP 编译安装。
9. 如果 `/opt/php_7.0.33` 已存在但不是正确版本，自动备份后重新安装。
10. 配置 php-fpm，默认监听 `127.0.0.1:9000`。
11. php-fpm master 由 systemd/root 启动，worker 使用 `nginx` 用户；如果没有 `nginx` 用户，则创建并使用 `www` 用户。
12. 优先使用 yum/dnf 安装 nginx。
13. yum/dnf 失败时尝试从 `/opt/migration/packages` 离线安装 RPM。
14. 不覆盖 `/etc/nginx/nginx.conf`。
15. 只新增或重建 `/etc/nginx/conf.d/php_app.conf`，已有文件先备份。
16. nginx 默认使用 80 端口；如果 80 被占用，自动尝试 8080、8081、8082。
17. 解压用户应用包到 `/opt/php-app`。
18. 如果 `/opt/php-app` 已存在且非空，自动备份后重新部署。
19. 自动识别 Web 根目录，优先级为 `public/`、`web/`、`www/`、`htdocs/`、应用根目录。
20. 扫描应用包中的 IP、域名、数据库、Redis、绝对路径、日志路径、上传路径等配置项。
21. 不执行 `composer install`；如果发现 `composer.json` 且没有 `vendor/`，只在报告中提示。
22. 自动启动 php-fpm 和 nginx，并调试 nginx 配置直到应用可以访问或候选方案耗尽。
23. 以 HTTP 200 作为默认成功标准。
24. 采集 php-fpm、nginx、systemd、应用 PHP 错误日志。
25. 输出 Markdown 和 JSON 报告。
26. 可选生成 PHP ARM 运行时包。

### 不应执行

1. 不动态分析 x86 生产环境。
2. 不安装、初始化、迁移 MySQL/MariaDB。
3. 不自动导入 SQL。
4. 不自动修改应用业务配置。
5. 不自动卸载已安装软件。
6. 不自动删除已有系统组件。
7. 不升级或替换系统 glibc。
8. 不覆盖 `/etc/nginx/nginx.conf`。
9. 不直接让 php-fpm worker 以 root 运行。
10. 不联网执行 Composer 依赖安装。

## 标准目录

```text
/opt/migration/
├── packages/        # PHP 源码包、应用包、离线 RPM 包
├── work/            # 编译与解压临时目录
├── logs/            # 执行日志和服务日志
├── reports/         # 部署报告
├── scripts/         # 启动、停止、状态、验证脚本
└── runtime/         # 可选 PHP ARM 运行时包

/opt/php_7.0.33/     # PHP 版本化安装目录
/opt/php             # 指向 /opt/php_7.0.33 的兼容软链接
/opt/php-app/        # PHP 应用部署目录
```

## 输入要求

用户至少需要提供一个 PHP 应用包，放在：

```bash
/opt/migration/packages/app.tar.gz
```

或：

```bash
/opt/migration/packages/app.zip
```

如果目标机不能联网，还需要手工上传 PHP 源码包：

```bash
/opt/migration/packages/php-7.0.33.tar.gz
```

如果目标机 yum 源不可用，还需要将 nginx 和 PHP 编译依赖相关的 aarch64 RPM 包放入：

```bash
/opt/migration/packages/
```

## 执行方式

默认端到端部署：

```bash
cd php-app-x86-to-arm-deployer
cp config.yaml /opt/migration/config.yaml
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
  --runtime-pack \
  --mode all
```

只做验证：

```bash
python3 bin/php_arm_migration.py --config /opt/migration/config.yaml --mode verify
```

只扫描已部署应用配置：

```bash
python3 bin/php_arm_migration.py --config /opt/migration/config.yaml --mode scan
```

## 结果输出

报告默认输出到：

```bash
/opt/migration/reports/
```

关键文件包括：

```text
php_app_migration_report_*.md      # Markdown 部署报告
php_app_migration_report_*.json    # JSON 结构化报告
installed_packages.txt             # 新增 RPM 包清单
application_config_scan_*.json     # 应用配置扫描结果
```

日志默认输出到：

```bash
/opt/migration/logs/
```

脚本默认输出到：

```bash
/opt/migration/scripts/
```

包括：

```text
start_php_stack.sh
stop_php_stack.sh
status_php_stack.sh
verify_php_stack.sh
```

## Agent 执行准则

1. 用户说“开始部署”“执行迁移”“部署 PHP 应用到 ARM”时，优先调用执行脚本。
2. 执行前确认当前机器是 ARM 目标机，而不是 x86 生产机。
3. 如果用户没有提供应用包，提示将 `.tar.gz` 或 `.zip` 放到 `/opt/migration/packages/`。
4. 如果 PHP 源码包下载失败，提示官方下载链接和上传路径。
5. 如果 yum 安装失败，自动尝试离线 RPM 安装。
6. 如果编译失败，先尝试补齐依赖并重试；仍失败时输出失败原因和日志路径。
7. 如果 nginx 80 端口被占用，自动切换 8080，再尝试 8081、8082。
8. 不直接清理系统内容，只备份与该 Skill 相关的目标路径或配置文件。
9. 每次执行完成后，都必须引导用户查看 Markdown 报告。
10. 回答用户时优先总结结论、报告路径、访问地址、失败原因和下一步建议。

## 成功标准

默认成功需要满足：

```text
1. /opt/php_7.0.33/bin/php -v 正常，版本为 PHP 7.0.33
2. php-fpm 配置检测通过
3. php-fpm systemd 服务启动成功
4. nginx 配置检测通过
5. nginx 服务启动成功
6. curl http://127.0.0.1:<最终端口>/ 返回 HTTP 200
7. 部署报告成功生成
```

## 失败处理

失败时不要宣称部署成功。需要明确说明：

1. 失败阶段。
2. 失败命令。
3. 关键错误日志。
4. 报告路径。
5. 需要用户补充的包、配置或权限。
6. 已经自动备份的路径。

