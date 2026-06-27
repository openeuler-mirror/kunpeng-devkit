# 安装包解析、下载与禁止静默降级策略

本增强版补齐了此前执行结果暴露的两个问题：

1. 路线规划为 Tomcat -> 东方通，但执行阶段安装了 Apache Tomcat。
2. DM 缺失时没有按“本地包 -> 华为云鲲鹏归档 -> 官方公开 URL”查找安装包。

## 规则

安装阶段必须以 `route_plan.yaml` 为准，不允许因为安装包缺失而静默替换产品。

- Tomcat -> TongWeb：必须找到 TongWeb 安装包和 license。
- DM：必须找到 DM8 ARM 安装包，或者确认目标机已安装 DM。
- 找不到时返回 `waiting_input`，输出缺失文件、已搜索目录、已搜索 URL。

## 搜索顺序

1. `/opt/ai-system-migration/packages/`
2. `/opt/ai-system-migration/packages/middleware/`
3. `/opt/ai-system-migration/packages/tongweb/`
4. `/opt/ai-system-migration/packages/database/`
5. `/opt/ai-system-migration/packages/dm/`
6. `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/`
7. `package_resolution.official_urls` 中配置的厂商官方 URL 或直接下载链接。

## 命令

```bash
python3 bin/ai_system_migration.py phase package-resolve \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase middleware \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase database-install \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute
```

## 注意

- 若 TongWeb 是 `.bin` 或 `.sh` 厂商安装器，需要在 `middleware.tongweb.silent_install_args` 中配置静默安装参数。
- 若 TongWeb 是 `.tar.gz` 或 `.zip` 免安装包，脚本可直接解压到 `middleware.tongweb.install_dir`。
- DM 静默安装 XML 已自动生成，但不同 DM 发行包可能存在参数差异；如果安装器返回失败，报告中会保留 `log_tail` 并要求调整参数。
