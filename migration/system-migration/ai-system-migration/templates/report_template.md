# AI 系统迁移报告

## 1. 迁移结论

- 应用类型：Java
- 目标架构：ARM / aarch64
- 默认路线：OpenJDK ARM，Tomcat -> 东方通，Resin -> Resin ARM，数据库 -> 达梦 DM
- 当前状态：{{status}}

## 2. 源端扫描范围

- 扫描目录：{{scan_dir}}
- 输出目录：{{output_dir}}
- 结果包：{{result_archive}}

## 3. 应用部署结构

### Java 进程与主 Jar/WAR/EAR 关联

{{runtime_apps}}

### 运行中组件

{{running_components}}

### 磁盘存在但未运行组件

{{detected_components}}

## 4. 源码路径判断结果

{{source_candidates}}

## 5. 迁移路线

{{route_plan}}

## 6. 中间件迁移结果

{{middleware_result}}

## 7. 数据库迁移结果

{{database_result}}

## 8. 应用改造结果

{{app_transform_result}}

## 9. 启动验证结果

{{deploy_verify_result}}

## 10. 失败项和人工确认项

{{manual_confirm_items}}

## 11. 安装包来源、版本和 SHA256

{{package_sources}}

## 12. 回滚建议

{{rollback_suggestions}}
