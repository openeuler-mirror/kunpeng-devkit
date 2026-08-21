# 中间件迁移

读取 `MIGRATION_PLAN_PATH` 指向的 `migration-plan.json` 的 `route.middleware`，逐项完成中间件迁移并输出原生汇总结果。

## 入口

```bash
bash middleware-migration/scripts/run_migration.sh "$MIGRATION_PLAN_PATH"
```

调用方只需传入 `migration-plan.json`，内部脚本完成解析、排序（JDK 优先）、安装、配置恢复、服务切换与验证、汇总。详细策略见 `config/middleware_registry.json`。

## 关键约束

### 部署目录

部署目录不由 `migration-plan.json` 显式指定，而是自动推导：

1. **产品策略**：`middleware_registry.json` 中每类中间件配置的 `deploy_dir_strategy` 决定推导方式——`source_parent`（默认，装到源目录的同级）、`install_dir`（按源安装目录推导）、`skip`（系统包安装，不推导）；
2. **源端信息**：`migration-plan.json` 中 `source.location`（源机安装路径），作为推导输入；
3. **环境变量覆盖**：可通过 `DEPLOY_DIR_<TYPE>` 显式指定部署目录（设为 `skip` 表示跳过该中间件的目录推导）。

### 冲突检测

迁移前检测两类冲突，检测到时**必须**通过运行环境的交互式提问工具向用户提问，阻塞等待真实答复后再继续。不得跳过提问、以纯文本代替提问，或自行决定覆盖/跳过。

- **目录冲突**：目标部署目录已存在。`overwrite` = 删除现有目录后覆盖安装，`skip` = 跳过该迁移项。
- **服务冲突**：目标环境已存在同名 systemd 服务。`overwrite` = 备份旧 service 文件后覆盖服务注册（**不删除原服务目录和配置文件**），`skip` = 跳过该迁移项。

### 依赖

Java 中间件优先复用已迁移的目标 Java 运行时；未就绪时按 registry 声明的依赖准备。计划内若所有 Java 中间件 JDK 需求版本一致，统一使用该版本避免冲突。

## 输出

```text
middleware/reports/batch_migration_summary.json
middleware/reports/batch_migration_summary.md   
```

批次状态：`SUCCEEDED`（全部成功）/ `SUCCEEDED_WITH_WARNINGS`（存在警告或跳过）/ `FAILED`（至少一项失败）/ `BLOCKED`（存在 License 等前置条件）。

冲突待确认时输出：

```text
middleware/reports/middleware-action-required.json
```

单项失败不阻止其他可执行项，批次最终状态和退出码反映整体结果。

## 脚本说明

```text
scripts/
├── run_migration.sh          # 批量迁移入口：解析 plan、排序(JDK优先)、逐项调度、冲突预检、汇总输出
├── init_context.sh           # 初始化 SKILL_DIR/RUN_ID 等运行环境
├── migrate_jdk.sh            # JDK/JRE 迁移：安装 Java 运行时，设置 JAVA_HOME
├── migrate_javamiddleware.sh # 通用 Java 中间件迁移(Tomcat/Resin/Nacos/RocketMQ)：依赖 JDK、配置 systemd、恢复配置
├── migrate_tongweb.sh        # TongWeb 迁移：专用安装、依赖 JDK、健康检查
├── migrate_besappserver.sh   # BES AppServer 迁移：专用安装、依赖 JDK、健康检查
├── migrate_package.sh        # 通用包迁移(Nginx/Redis/ES 等)：yum/apt/源码编译、配置恢复、systemd 注册
├── migrate_generic.sh        # 兜底通用迁移：未登记产品走此脚本，尽力安装与配置恢复
└── lib/
    ├── common.sh             # 公共函数：部署目录推导、依赖管理、服务启停、冲突处理、日志等
    ├── transform_plan.py     # 将 migration-plan.json 转换为内部统一格式，含产品名标准化
    ├── json_query.py         # JSON 查询工具(替代 jq)
    └── registry_query.py     # registry 查询工具(替代 yq)，解析 middleware_registry.json  # 
```
