# AI 系统迁移 Skill 设计说明

## 1. 定位

该 Skill 面向 Java 应用从 x86 Linux 到 ARM Linux 的端到端迁移。第一版暂不做 C/C++ 自动迁移，只在扫描结果中保留识别信息。

主流程由 `ai-system-migration` 负责编排，9 个子 Skill 分别处理源端扫描、结果分析、路线选择、凭据收集、中间件迁移、数据库迁移、应用改造、部署验证和报告输出。

## 2. 为什么使用子 Skill

CLI 工具在长流程中交互体验较差，且主对话很难在多个阶段灵活中断、补充、继续。因此本方案采用子 Skill 完成交互：

- 子 Skill 负责生成交互任务、默认方案和风险提示。
- 主流程将交互写入 `state/interaction_tasks.jsonl`。
- 用户回复或配置文件补齐后写入 `state/interaction_answers.json`。
- 主流程不会因为一个交互问题全局中断；只会让依赖该输入的阶段局部等待。

## 3. 工作目录

统一使用：

```text
/opt/ai-system-migration/
├── workspace/
├── config/
├── logs/
├── state/
└── packages/
```

## 4. 源端采集器

本 Skill 不重写扫描逻辑，源端采集必须调用用户已有脚本：

```text
devkit_disk_scan.sh
```

脚本产物是后续分析的唯一事实基础：

- `components.json`
- `files_map.json`
- `java_runtime.json`
- `specified_pack.json`
- 结果压缩包

## 5. 迁移路线

默认路线：

- JDK -> OpenJDK ARM，保持原大版本。
- Tomcat -> 东方通。
- Resin -> Resin ARM。
- Nginx -> Nginx ARM。
- Redis -> Redis ARM。
- 数据库 -> 达梦 DM。
- 数据库迁移优先动态迁移，静态迁移作为兜底。

## 6. 数据库迁移

目标数据库默认 DM。

- Skill 自动搜索 DTS CLI：`dts_cmd_run.sh`。
- 默认由 Skill 生成 DTS XML 草案。
- 执行前必须展示摘要并确认。
- MySQL 静态迁移默认使用 `mysqldump`。
- Oracle/SQL Server 第一版优先 DTS 动态迁移，不强行自动离线导出。

## 7. 应用改造

有源码：

- 修改 JDBC 配置、Driver、MyBatis XML、SQL 文件、JPA/Hibernate 方言。
- 编译打包并记录日志。

无源码：

- 需要用户确认反编译授权。
- 默认 CFR。
- 优先修改配置、XML、SQL、Driver。
- 保留原包备份。

## 8. 安全边界

- 源端默认只读。
- 动态版本探测、数据库导出、源库连接、源码外发模型、反编译必须确认。
- 密码只在 `credentials.yaml` 中保存，报告日志必须脱敏。
- 不允许无限重试。

## 增强版：route-plan 与执行一致性

此前流程穿刺中出现了 route 阶段生成 `Tomcat -> 东方通`，但 middleware 阶段实际安装 Apache Tomcat 的问题。增强版修复为：

1. `route_plan.yaml` 是产品迁移路线的唯一事实来源。
2. middleware 阶段必须读取 route 结果，并按目标产品查找安装包。
3. 找不到目标产品安装包时，阶段返回 `waiting_input`。
4. 不允许使用功能相近的开源组件代替目标产品，除非配置中显式开启 fallback。
5. database 阶段同理，DM 未安装时必须先搜索和安装 DM；找不到 DM 安装包时停止并输出缺失项。

新增脚本模块：

- `bin/lib/package_resolver.py`
- `bin/lib/middleware_migrator.py`
- `bin/lib/dm_installer.py`

新增阶段：

- `package-resolve`
- `middleware`
- `database-install`
- `database-migration`
