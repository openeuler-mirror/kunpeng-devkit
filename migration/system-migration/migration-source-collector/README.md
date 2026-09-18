# migration-source-collector

## 简介

`migration-source-collector` 用于在 x86 Linux 源端采集系统迁移所需的事实信息和迁移制品，并在用户确认迁移范围、目标路线、安装包来源、Java应用组件及 SQL 适配策略后生成正式 `migration-plan.json` 和最终采集包。

支持本机采集和 SSH 远程采集。源端与目标执行阶段通过 `migration-plan.json` 及其引用制品交接，不依赖目标执行 Skill 的脚本。

## 功能特性

- 采集操作系统、服务、端口、组件、版本、部署位置等系统事实。
- 采集中间件、JDK/JRE、数据库及 Java JAR/WAR 应用组件。
- 支持本机采集和 SSH 远程采集。
- 远程采集使用加密凭据存储，密码不写入配置、日志、报告或命令参数。
- 根据迁移路线参考文件生成目标产品、目标版本和安装包候选。
- 通过独立交互门禁确认迁移范围、迁移路线、包来源和 Java 应用 SQL 适配策略。
- 基于 `assets/migration-plan-init.json` 初始化唯一正式 `migration-plan.json`。
- 生成一次 `migration_id`，后续目标预检和迁移执行继续复用。
- 采集完成后生成报告、架构摘要、详细扫描归档和最终采集包。

## 适用场景

- 需要对现有 x86 Linux 主机进行迁移前成分采集。
- 需要形成后续鲲鹏 ARM64 系统迁移的正式输入计划。
- 需要盘点服务器中的数据库、中间件、JDK/JRE 和 Java 应用。
- 需要提前确认目标迁移产品、版本、安装包来源和 License 要求。
- Java应用需要基于实际 JAR/WAR 制品迁移，并提前确认是否进行 SQL 方言适配。

## 前置条件

- 源主机为 Linux。
- 本机采集需要在源主机上具备 root 权限。
- SSH远程采集需要可访问目标源主机，并准备主机、用户和凭据标识等连接信息。
- Agent端工作目录固定使用 `/opt/kunpeng-migration/collection`。
- Agent端应具备足够磁盘空间用于采集文件、JAR/WAR和最终采集包。
- 最终打包需要 `tar` 或 `busybox tar`。
- 用户需要在采集过程中完成迁移范围、目标路线、安装包来源和应用 SQL 策略的明确确认。

## Skill 目录结构

```text
migration-source-collector/
├── SKILL.md
├── README.md
├── prompt.md
├── assets/
│   ├── migration-plan-init.json
│   ├── collection-report-template.md
│   ├── architecture-summary-template.json
│   └── remote-hosts-template.conf
├── references/
│   ├── collector-guide.md
│   ├── migration-plan-guide.md
│   └── migration-route-reference.md
└── scripts/
    ├── collect.sh                    # 本机基础采集
    ├── remote-collect.sh             # SSH远程采集与清理
    ├── collect-versions.sh           # 组件版本补充
    ├── supplement.sh                 # 服务/端口/关系补充
    ├── collect-artifacts.sh          # 配置与JAR/WAR等制品采集
    ├── export-db.sh                  # 数据库补充导出能力
    ├── credential-askpass.sh         # SSH凭据辅助
    ├── migration_plan.py             # migration-plan初始化/更新/校验
    └── package.sh                    # 最终归档与采集包生成
```

## 使用方式

推荐通过顶层 Skill 直接描述采集目标，由 Skill 根据本机或 SSH 场景组织内部步骤。

本机采集示例：

```text
请使用 migration-source-collector 采集当前 x86 Linux 主机，完成系统成分、数据库、中间件、JDK/JRE 和 Java 应用 JAR/WAR 采集，并生成 migration-plan.json 和最终采集包。
```

远程采集示例：

```text
请使用 migration-source-collector 通过 SSH 采集 192.168.1.10，SSH用户为 root，凭据标识为 source-01。按 Skill 流程完成采集，并在迁移范围、目标路线、安装包来源和应用 SQL 策略阶段分别让我确认。
```

SSH密码不应直接写入调用提示词；凭据缺失时按 Skill 的安全交互流程输入。

## 工作流程

```text
确定采集方式
本机 / SSH远程
        ↓
初始化RUN_DIR和migration-plan.json
        ↓
基础系统成分采集
        ↓
版本、服务、端口和应用关系补充
        ↓
配置、数据库信息和JAR/WAR制品采集
        ↓
确认迁移范围
        ↓
确认目标产品/目标路线
        ↓
确认目标版本和安装包来源
        ↓
确认Java应用JAR/WAR及SQL适配策略
        ↓
生成collection-report.md
和architecture-summary.json
        ↓
远程场景清理源端暂存目录
        ↓
校验migration-plan.json
        ↓
生成详细扫描归档和最终采集包
```

采集过程中涉及用户选择的步骤必须使用当前步骤的明确答复，不以推荐值代替确认。

## 输出产物

每次采集结果位于：

```text
/opt/kunpeng-migration/collection/runs/<RUN_NAME>/
```

最终至少包含：

```text
migration-plan.json
collection-report.md
details/devkit-source-scan-details.tar.gz
```

同时最终采集包生成在 `runs` 目录下，通常为：

```text
<RUN_NAME>.tar.gz
```

其中：

- `migration-plan.json`：后续目标迁移执行的唯一业务计划输入。
- `collection-report.md`：源端采集结果摘要。
- `details/devkit-source-scan-details.tar.gz`：详细扫描和架构信息归档。
- `<RUN_NAME>.tar.gz`：包含本次采集交付内容的最终采集包。

## 常见问题

### 1. 本机采集和远程采集如何选择？

如果要采集运行 Skill 的当前 Linux 主机，选择本机采集；如果源系统位于另一台服务器，通过 SSH 远程采集。

### 2. 为什么采集过程中需要多次确认？

事实采集只能说明“发现了什么”，无法替代用户决定“迁移什么、迁移到什么产品、使用什么安装包、应用是否需要SQL迁移”。这些决定会写入正式 `migration-plan.json`，因此必须分阶段确认。

### 3. SSH密码会写入采集配置吗？

不会。密码通过安全交互获取并加密存储，不写入普通配置、报告、日志、环境变量或命令参数。

### 4. Java应用为什么只采集 JAR/WAR，不要求源码？

系统迁移执行中的 Java 应用基于实际采集到的 JAR/WAR 制品处理。有源码项目迁移由独立 `java-arm-migration` 顶层 Skill 负责。

### 5. `migration-plan.json` 可以重新生成一份给目标端吗？

不应另建第二份计划。采集阶段生成的正式 `migration-plan.json` 会由目标预检在允许范围内原子更新，后续各模块继续使用同一份计划。
