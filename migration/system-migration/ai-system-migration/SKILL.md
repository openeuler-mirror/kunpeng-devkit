---
name: ai-system-migration
summary: 端到端完成 Java 应用 x86 -> ARM 系统迁移，复用 devkit_disk_scan.sh 采集结果，通过子 Skill 完成交互、路线确认、凭据收集、中间件/数据库/应用改造/部署验证。
description: |
  当用户需要将 Java 应用从 x86 Linux 迁移到 ARM Linux，尤其是 openEuler 系、CentOS ARM、国产操作系统环境时使用。
  该 Skill 不是重新实现磁盘扫描，而是调用源端 devkit_disk_scan.sh 获取真实采集结果，再基于 components.json、files_map.json、java_runtime.json、specified_pack.json 做二次分析。
  迁移分为默认迁移和自定义迁移两种模式：默认迁移生成推荐路线并尽量自动执行；自定义迁移允许用户选择中间件、数据库、JDK、应用改造和数据迁移路线。
  主 Skill 负责端到端编排；source-scan、scan-analysis、route、credential、middleware、database、app-transform、deploy-verify、report 子 Skill 分别承担采集、分析、交互和专项执行。
  适用场景示例：
  - Java Web 应用从 x86 服务器迁移到 ARM 服务器。
  - Tomcat/Resin/Nginx/Redis/MySQL/Oracle/SQL Server 等组合应用迁移。
  - 有源码 Java 应用迁移改造、SQL 兼容性改造、重新编译打包。
  - 无源码 Jar/WAR/EAR 反编译后配置和 SQL 适配迁移。
  - 默认国产化路线：Tomcat -> 东方通，数据库 -> 达梦 DM，JDK -> OpenJDK ARM。
allowed-tools:
  - shell
  - filesystem
  - subskill
  - python
---

# AI System Migration Skill

## 1. 核心原则

1. 仅第一版支持 Java 应用迁移，C/C++ 暂不作为自动迁移对象。
2. 源端扫描必须优先调用 `devkit_disk_scan.sh`，不得脱离脚本输出空猜。
3. 源端默认只读，涉及动态版本探测、数据库导出、连接源数据库、源码/配置发送给模型、反编译等动作必须经过用户确认或读取已确认配置。
4. 目标端默认需要 root 权限。
5. 工作目录统一使用 `/opt/ai-system-migration/`。
6. 密码、Token、数据库连接凭据只写入 `config/credentials.yaml`，报告和日志中必须脱敏。
7. 主流程尽量不中断。子 Skill 通过非阻断交互队列生成交互任务、默认值、风险提示和待确认项。主流程可以先执行不依赖该输入的阶段，硬依赖阶段仅局部等待，不让整体流程断点式停滞。
8. 失败自动修复规则：同阶段最多 5 轮；同一错误指纹连续出现 3 次停止；全流程自动修复总轮次最多 10 轮；用户可随时输入 `exit`、`quit`、`stop` 停止。
9. 最终输出 Markdown 报告、JSON 报告、JSONL 执行日志、配置文件和子 Skill 文档引用。

## 2. 子 Skill 拆分

主 Skill 必须按以下 9 个子 Skill 编排：

| 子 Skill | 职责 |
|---|---|
| `source-scan` | 默认在目标 ARM 上通过 SSH/SCP 远程调用源 x86 的 `devkit_disk_scan.sh`，完成扫描、动态探测确认、打包、数据库静态导出准备，并将结果回传目标 ARM。 |
| `scan-analysis` | 解析扫描结果，识别实际运行应用包、部署结构、源码候选、运行配置包。 |
| `route` | 生成默认/自定义迁移路线，给用户可确认的方案卡片。 |
| `credential` | 非阻断收集目标机 SSH、源库/目标库、应用账号等敏感信息。 |
| `middleware` | 安装 ARM 中间件并迁移配置，如东方通、Resin ARM、Nginx ARM、Redis ARM、OpenJDK ARM。 |
| `database` | 安装达梦 DM，生成 DTS XML，优先动态迁移，必要时执行静态迁移。 |
| `app-transform` | 有源码改造 SQL/配置并编译；无源码使用 CFR 反编译后改造重打包。 |
| `deploy-verify` | 启动数据库、中间件、应用，采集日志并进行自动修复。 |
| `report` | 生成 Markdown + JSON 报告、JSONL 执行日志摘要、风险和人工确认项。 |

## 3. 默认迁移路线

- OS：openEuler 系、CentOS ARM、国产 Linux。
- 执行用户：root。
- 扫描目录：用户未指定时默认为 `/`。
- 源端动态版本探测：需要用户确认，必须限制为只读版本探测命令。
- 运行配置：默认采集并打包。
- 数据库数据导出：允许，但执行前必须确认。
- JDK：默认保持原大版本，安装 OpenJDK ARM。
- Tomcat：默认迁移到东方通。
- 宝兰德：作为自定义选项。
- Resin：默认迁移到 Resin ARM。
- Nginx：默认安装 Nginx ARM 并迁移配置。
- Redis：默认安装 Redis ARM 并迁移配置。
- 数据库：默认迁移到达梦 DM，按源库类型选择兼容模式。
- 数据库迁移：优先动态迁移；网络或权限不满足时走静态迁移。
- DTS XML：默认由 Skill 生成，执行前展示摘要；用户也可提供已有 XML。
- DM DTS CLI：优先自动搜索 `dts_cmd_run.sh`，找不到则提示补充完整 DM 工具包。
- 有源码：默认自动改造并编译打包。
- 无源码：默认使用 CFR，执行反编译前要求用户确认授权。
- 模型：默认 `agent-native`，可选 `openai-compatible`、`manual-review`。源码和配置发送给模型前必须确认。

## 4. 主流程

### 4.1 初始化

读取或创建：

```text
/opt/ai-system-migration/config/migration_config.yaml
/opt/ai-system-migration/config/credentials.yaml
/opt/ai-system-migration/config/route_plan.yaml
/opt/ai-system-migration/state/state.json
/opt/ai-system-migration/state/interaction_tasks.jsonl
/opt/ai-system-migration/logs/execution-log.jsonl
```

### 4.2 源端扫描

调用 `source-scan` 子 Skill。默认执行模式是目标 ARM 侧远程扫描源 x86：

1. 确认源端脚本路径。
2. 确认扫描根目录，未指定时使用 `/`。
3. 确认输出目录。
4. 动态版本探测需要用户确认。
5. 数据库导出需要用户确认。
6. 执行 `devkit_disk_scan.sh`。
7. 校验生成产物：
   - `components.json`
   - `files_map.json`
   - `java_runtime.json`
   - `specified_pack.json`
   - `result/devkit-component-<IP>-<timestamp>.tar.gz`

### 4.3 结果分析

调用 `scan-analysis` 子 Skill：

1. 基于 `java_runtime.json` 判断实际运行 Jar/WAR/EAR。
2. 基于 `components.json` 判断 Tomcat/Resin/Nginx/Redis/JDK/数据库部署结构。
3. 基于 `files_map.json` 关联应用包和配置文件。
4. 搜索源码候选：`.git`、`pom.xml`、`build.gradle`、`settings.gradle`、`src/main/java`、`Dockerfile`、`Jenkinsfile`。
5. 将源码候选与应用包的 `artifactId`、`version`、`finalName`、Manifest、文件名做关联。
6. 输出置信度和待用户确认项。

### 4.4 路线确认

调用 `route` 子 Skill：

1. 基于扫描结果生成默认迁移路线。
2. 如果用户选择自定义迁移，展示可选项。
3. 生成 `route_plan.yaml`。
4. 不阻塞主流程：若用户暂未确认，非破坏性阶段可继续；需要安装/修改前必须读取已确认路线或使用默认路线。

### 4.5 凭据收集

调用 `credential` 子 Skill：

1. 收集目标机 SSH 信息或手动上传目录。
2. 收集源库账号、目标库账号、数据库迁移账号。
3. 所有敏感信息写入 `credentials.yaml`。
4. 报告、日志、JSONL 输出中全部脱敏。

### 4.6 迁移包传输

两种方式：

1. SCP 自动传输：使用 `credentials.yaml` 中目标机 SSH 信息。
2. 手动上传：提示用户将扫描压缩包上传到目标目录。

传输后必须校验文件存在、大小、SHA256。

### 4.7 中间件迁移

调用 `middleware` 子 Skill：

1. 安装 OpenJDK ARM。
2. Tomcat 默认迁移到东方通；自定义可选宝兰德或 Tomcat ARM。
3. Resin 默认安装 Resin ARM。
4. 安装 Nginx ARM、Redis ARM。
5. 优先使用华为云鲲鹏归档仓和用户提供安装包；缺失时可从官网获取 ARM 版本，但必须在报告中记录来源、版本和 SHA256。
6. 迁移配置：Tomcat/东方通、Resin、Nginx、Redis 配置文件和运行配置包。

### 4.8 数据库迁移

调用 `database` 子 Skill：

1. 安装达梦 DM。
2. 根据源库类型设置默认兼容模式。
3. 创建数据库、用户、密码、schema、必要权限。
4. 优先动态迁移。
5. 自动搜索 DTS CLI：
   - `$DM_HOME/tool/dts_cmd_run.sh`
   - `/opt/dmdbms/tool/dts_cmd_run.sh`
   - `/dm*/tool/dts_cmd_run.sh`
6. 默认生成 DTS XML，展示摘要后执行。
7. 静态迁移时，MySQL 默认 `mysqldump`；Oracle/SQL Server 第一版优先 DTS 动态迁移，不强行自动离线导出。

### 4.9 应用改造

调用 `app-transform` 子 Skill：

有源码：

1. 修改数据库配置。
2. 替换 JDBC Driver。
3. 扫描 MyBatis XML、SQL 文件、JPA/Hibernate 方言。
4. 做 SQL 兼容性改造。
5. 编译打包。

无源码：

1. 要求用户确认反编译授权。
2. 使用 CFR 反编译。
3. 优先改配置、XML、SQL、JDBC Driver。
4. 必要时修改 Java 逻辑。
5. 保留原始 Jar/WAR/EAR 备份。
6. 检测 `META-INF/*.SF`、`*.RSA`、`*.DSA` 签名风险。
7. 重新打包。

### 4.10 部署验证与修复

调用 `deploy-verify` 子 Skill：

1. 启动数据库。
2. 启动中间件。
3. 部署应用包到正确目录。
4. 启动应用。
5. 采集日志和端口状态。
6. 根据错误指纹自动修复。
7. 达到重试上限后停止自动修复，并输出人工处理建议。

### 4.11 报告

调用 `report` 子 Skill 输出：

- `migration-report.md`
- `migration-report.json`
- `execution-log.jsonl`
- `route-plan.yaml`
- `scan-summary.json`
- `risk-items.json`
- `manual-confirm-items.json`

## 5. 交互不打断主流程的实现要求

子 Skill 不直接让主 Skill 卡住等待，而是写入交互队列：

```json
{
  "task_id": "route-confirm-001",
  "phase": "route",
  "type": "confirmation",
  "blocking_scope": "middleware_install",
  "default_action": "use_default_route",
  "question": "是否确认使用默认国产化迁移路线？",
  "options": ["confirm", "customize", "skip"],
  "expires_policy": "use_default_if_safe"
}
```

主流程读取交互队列时遵守：

1. 有安全默认值的确认项，用户暂未回复时可使用默认值继续非破坏性阶段。
2. 涉及密码、源码外发、反编译授权、源库连接、源端导出、生产启停等无安全默认值的任务，只阻塞对应阶段，不阻塞其他不依赖阶段。
3. 所有交互任务都必须写入 `manual-confirm-items.json` 和最终报告。

## 6. 输出要求

每个阶段必须输出：

```json
{
  "phase": "database",
  "status": "success | failed | skipped | waiting_input | partially_success",
  "summary": "阶段摘要",
  "actions": [],
  "artifacts": [],
  "risks": [],
  "manual_confirm_items": [],
  "next_steps": []
}
```

## 7. 禁止事项

1. 不得在未确认情况下修改源端生产环境。
2. 不得在日志和报告中输出明文密码。
3. 不得在没有用户授权情况下将源码、配置、SQL 发给外部模型。
4. 不得在没有用户授权情况下反编译客户 Jar/WAR/EAR。
5. 不得忽略 `devkit_disk_scan.sh` 的真实结果自行编造部署结构。
6. 不得在 DTS CLI 不存在时假装已经完成迁移。
7. 不得无限重试同一错误。

## 7. 安装包查找与禁止静默降级（增强版要求）

为避免出现“路线选择为 Tomcat -> 东方通，但执行阶段实际安装 Apache Tomcat”的问题，本 Skill 必须强制执行以下规则：

1. `route_plan.yaml` 是安装阶段的唯一产品路线依据。
2. 当路线为 `Tomcat -> 东方通/TongWeb` 时，`middleware` 阶段必须解析并安装 TongWeb，不得静默安装 Apache Tomcat。
3. 只有当 `middleware.fallback_to_apache_tomcat: true` 被显式配置时，才允许降级到 Apache Tomcat，并且最终报告必须标注 fallback。
4. TongWeb 必须同时满足安装包和 license 存在。缺少任一项时，`middleware` 阶段返回 `waiting_input`，并输出缺失项。
5. 所有安装包查找优先级固定为：
   - `/opt/ai-system-migration/packages/`
   - `/opt/ai-system-migration/packages/middleware/`
   - `/opt/ai-system-migration/packages/tongweb/`
   - `/opt/ai-system-migration/packages/database/`
   - `/opt/ai-system-migration/packages/dm/`
   - `https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/`
   - 配置中的厂商官方 URL 或直接下载链接。
6. 搜索/下载到的安装包必须记录：本地路径、来源类型、URL、文件名、大小、SHA256。

对应可执行入口：

```bash
python3 bin/ai_system_migration.py phase package-resolve --config /opt/ai-system-migration/config/migration_config.yaml --execute
python3 bin/ai_system_migration.py phase middleware --config /opt/ai-system-migration/config/migration_config.yaml --execute
```

## 8. DM 自动安装与数据库迁移增强版要求

当默认数据库路线为 DM 时，`database` 阶段必须先执行 DM 可安装性检查：

1. 检查 `/opt/dmdbms`、`/dm8`、`/opt/dm8`、5236 端口和 `dts_cmd_run.sh`。
2. 如果 DM 未安装，按安装包查找优先级搜索 DM8 ARM Linux 包，支持 `.iso`、`.bin`、`.zip`、`.tar.gz`。
3. 找到安装包后，生成 DM 静默安装 XML，默认安装到 `/opt/dmdbms`。
4. 创建或复用 `dmdba` 用户和 `dinstall` 用户组。
5. 使用 `dminit` 初始化实例，默认：`DB_NAME=DMDB`、`INSTANCE_NAME=DMSERVER`、`PORT_NUM=5236`。
6. 按源库类型设置默认兼容模式；MySQL 迁移默认写入 `COMPATIBLE_MODE = 4`。
7. 注册 systemd 服务并启动。
8. 安装完成后重新搜索 `dts_cmd_run.sh`。
9. 若存在静态 SQL 文件，例如 `/opt/ai-system-migration/workspace/db_migration/ry_dump.sql`，可执行 `database-migration` 阶段导入。

对应可执行入口：

```bash
python3 bin/ai_system_migration.py phase database-install --config /opt/ai-system-migration/config/migration_config.yaml --credentials /opt/ai-system-migration/config/credentials.yaml --execute
python3 bin/ai_system_migration.py phase database-migration --config /opt/ai-system-migration/config/migration_config.yaml --credentials /opt/ai-system-migration/config/credentials.yaml --execute
```

如果未找到 DM 安装包，Skill 必须返回 `waiting_input`，不能假装安装成功，也不能跳过后继续给出“数据库迁移成功”的结论。
