# PHP 应用 x86 到 ARM 部署报告模板

脚本会自动生成实际报告，默认路径：

```bash
/opt/migration/reports/php_app_migration_report_时间戳.md
```

报告包含以下内容：

1. 部署结论
2. 系统信息
3. PHP 版本与扩展列表
4. 新增安装的软件包
5. 创建或修改的文件
6. 自动备份路径
7. 应用配置扫描结果
8. 警告信息
9. 失败项
10. 日志与结果文件路径
11. 回退说明

## 应用配置扫描说明

扫描项包括：

- 硬编码 IP
- 域名
- 数据库配置
- Redis 配置
- 上传目录
- 日志目录
- 绝对路径
- `.env`
- `config/database.php`
- `application/database.php`
- `config.php`

扫描结果只做提示，不自动修改应用文件。
