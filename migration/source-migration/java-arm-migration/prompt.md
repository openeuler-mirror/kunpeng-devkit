# java-arm-migration 调用提示词

```text
请使用 java-arm-migration 迁移本地 Java 项目：【项目目录】
SQL迁移：【需要 / 不需要】
源数据库：【需要SQL迁移时必须填写】
目标数据库：【需要SQL迁移时必须填写】
请严格执行 prepare → inspect → baseline → compatibility → sql → build → package_scan → verify，不能删除或默认跳过必要阶段。
```

执行约束：

1. 用户没有说明 SQL 路由时，必须先取得明确决定，不得根据项目框架、SQL 文件或历史配置推断为“不需要”。
2. 出现 `WAITING_FOR_SQL` 时，必须用 `action_required.inputs` 真正调用独立 `sql-migration` Skill；Java resume controller 只负责等待结果和恢复 build，不会执行 SQL Skill。
3. 出现 `NEEDS_AGENT_FIX` 时，只按 `action_required` 修复；package scan 修复后必须重新 build。
4. 只有 build、package_scan、verify 都完成后才能宣布 Java ARM64 自动流程完成。
5. `sql_migration.status=NOT_APPLICABLE` 只能说明 SQL 路由选择了 SKIP，不能说“SQL 迁移已完成”。
