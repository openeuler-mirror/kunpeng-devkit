---
name: database
summary: 安装达梦 DM，按源库类型设置默认兼容模式，生成 DTS XML 并优先执行动态数据库迁移。
description: |
  当源数据库识别完成且目标数据库路线确认为 DM 后调用。该子 Skill 自动搜索 dts_cmd_run.sh，默认生成 DTS XML，展示摘要后执行。迁移优先动态方式，网络或权限不满足时再走静态方式。MySQL 静态迁移默认 mysqldump。
---

# database 子 Skill

## 默认策略

1. 目标数据库默认达梦 DM。
2. 所有数据库迁移优先动态迁移。
3. DTS XML 默认由 Skill 生成，也支持用户提供。
4. DTS XML 执行前必须展示摘要并有确认记录。
5. 如果目标机没有 DTS CLI，自动搜索常见路径；找不到则提示补充完整 DM 工具包。

## DTS CLI 搜索路径

- `$DM_HOME/tool/dts_cmd_run.sh`
- `/opt/dmdbms/tool/dts_cmd_run.sh`
- `/dm8/tool/dts_cmd_run.sh`
- `/opt/dm8/tool/dts_cmd_run.sh`
- `find /opt /dm8 / -path '*/tool/dts_cmd_run.sh'`，注意限制搜索深度和日志量。

## 兼容路线

| 源库 | 目标 | 默认策略 |
|---|---|---|
| MySQL | DM | MySQL 兼容路线，动态优先；静态可用 mysqldump。 |
| Oracle | DM | Oracle 兼容路线，动态 DTS 优先。 |
| SQL Server | DM | SQL Server 兼容路线，动态 DTS 优先。 |
| DB2 | DM | DB2 兼容路线，动态 DTS 优先。 |
| DM | DM | DM 互迁。 |

## DTS XML 生成摘要

执行前展示：

- 源库类型、地址、库名、schema。
- 目标库地址、库名、schema。
- 迁移对象范围。
- 是否迁移表、数据、索引、约束、视图、触发器、存储过程。
- 风险项：字符集、大小写、函数兼容、字段类型、分页语法、大对象字段。

## 静态迁移

- MySQL：默认 `mysqldump` 导出。
- Oracle/SQL Server：第一版优先 DTS 动态迁移，不强行自动离线导出；如用户提供 dump/sql 文件则执行导入或生成导入建议。

## 输出

```json
{
  "phase": "database",
  "status": "success",
  "target_database": "dm",
  "migration_mode": "dynamic",
  "dts_cli": "/opt/dmdbms/tool/dts_cmd_run.sh",
  "dts_xml": "/opt/ai-system-migration/workspace/db_migration/job.xml",
  "objects_migrated": {},
  "risks": []
}
```


## 增强版 DM 安装策略

当目标库为 DM 时，本子 Skill 不再只生成 DTS XML。它必须先判断目标机是否具备 DM 安装或迁移条件：

1. 自动检测 `/opt/dmdbms`、`/dm8`、`/opt/dm8`、5236 端口、`dts_cmd_run.sh`。
2. 如果未安装 DM，则搜索 DM8 ARM 安装包：`.iso`、`.bin`、`.zip`、`.tar.gz`。
3. 搜索顺序：本地包目录 -> 华为云鲲鹏归档仓 -> 配置的厂商官方 URL。
4. 找到 DM 安装包后进入 `database-install` 阶段。
5. 创建/复用 `dmdba` 用户，默认安装目录 `/opt/dmdbms`。
6. 使用 `dminit` 初始化实例，默认端口 `5236`。
7. MySQL 源库默认写入 `COMPATIBLE_MODE = 4`。
8. 注册并启动 systemd 服务。
9. 若存在 `/opt/ai-system-migration/workspace/db_migration/ry_dump.sql`，可进入 `database-migration` 阶段导入。

可执行入口：

```bash
python3 bin/ai_system_migration.py phase database-install   --config /opt/ai-system-migration/config/migration_config.yaml   --credentials /opt/ai-system-migration/config/credentials.yaml   --execute

python3 bin/ai_system_migration.py phase database-migration   --config /opt/ai-system-migration/config/migration_config.yaml   --credentials /opt/ai-system-migration/config/credentials.yaml   --execute
```

如果找不到 DM 安装包，必须返回 `waiting_input`，并明确列出已搜索目录和 URL。不得把数据库迁移标记为成功。
