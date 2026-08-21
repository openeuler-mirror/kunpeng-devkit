# 鲲鹏迁移采集与规划报告

## 1. 采集概览

| 项目 | 结果 |
|---|---|
| 采集编号 | {{collection_id}} |
| 采集状态 | {{collection_status}} |
| 采集方式 | {{collection_mode}} |
| 源端主机 | {{source_host}} |
| 源端系统与架构 | {{source_os_arch}} |

## 2. 部署架构

{{deployment_architecture_summary}}

详细关系位于 `details/devkit-source-scan-details.tar.gz!/architecture-summary.json`。

## 3. 已确认迁移范围

| 分类 | 组件 | 源版本 | 源端位置 | 选择依据 |
|---|---|---|---|---|
{{selected_migration_contents}}

## 4. 应用迁移方式

{{application_route_summary}}

SQL 迁移策略：{{sql_migration_summary}}

## 5. 已确认迁移路线

| 组件 | 源产品与版本 | 目标产品与版本 | 路线依据 | 目标包状态 |
|---|---|---|---|---|
{{confirmed_route}}

## 6. 已采集制品

| 归属组件 | 制品 | 源端路径 | 采集包内路径 |
|---|---|---|---|
{{collected_artifacts}}

## 7. 目标侧待处理事项

| 类型 | 关联组件 | 说明 |
|---|---|---|
{{target_actions}}

下游唯一业务输入：`migration-plan.json`。目标环境检查、安装包准备和许可证上传由目标侧 `migration-precheck` 更新到该文件。
