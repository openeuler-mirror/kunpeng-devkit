# 规则条目格式与示例

`finalize_ai_stage.py` 自动沉淀的规则条目格式。规则写入、去重和编号由确定性收敛逻辑完成，不由 AI 或调用方手工执行追加命令。

## 规则条目 Markdown 格式

````markdown
<!-- rule_fingerprint: <sha256> -->
<!-- rule_pattern_key: <转换模式键> -->
## [规则 NN] <rule_summary>
### 1. 语法转换映射
- **转换模式：** <rule_summary>
- **源数据库（<源>）：** 见下方转换前 SQL
- **目标数据库（<目标>）：** 见下方转换后 SQL；目标数据库动态 `EXPLAIN` 验证通过

### 2. 核心差异说明
- 转换模式键：`<rule_pattern_key>`
- 验证：目标数据库动态连接 `EXPLAIN` PASS
- 复用约束：作为相同转换模式的候选规则，后续仍需结合当前 SQL 上下文判断。

### 3. 标准对照示例
#### 转换前 SQL（<源>，<sql_id>）
```sql
<source_sql>
```
#### 转换后 SQL（<目标>）
```sql
<target_sql>
```
````

## 格式字段说明

| 字段 | 来源 | 说明 |
|------|------|------|
| `<!-- rule_fingerprint: ... -->` | `finalize_ai_stage.py` 生成 | 基于 source_db + target_db + rule_pattern_key 的 SHA256 指纹，用于幂等去重 |
| `<!-- rule_pattern_key: ... -->` | AI 写入的 `rule_pattern_key` | 转换模式键（如 `ORACLE_DECODE_TO_MYSQL_CASE_WHEN`），归一化后写入 |
| `[规则 NN]` | `finalize_ai_stage.py` 自动编号 | 按当前规则库文件中已有规则数 +1 递增，两位补零 |
| 规则标题 | AI 写入的 `rule_summary` | 一句话转换说明，未提供时用 `rule_pattern_key` 生成默认标题 |
| 转换前 SQL | item 的 `source_sql` | 纯 SQL 语句，未提供则跳过沉淀 |
| 转换后 SQL | 优先用 `ai_target_sql`，未提供时回退到 `validated_sql` | 纯 SQL 语句 |

## 完整规则示例

以下为一条完整的自动沉淀规则条目（Oracle DECODE → MySQL CASE WHEN）：

````markdown
<!-- rule_fingerprint: a3f5e8b2c1d4... -->
<!-- rule_pattern_key: ORACLE_DECODE_TO_MYSQL_CASE_WHEN -->
## [规则 01] Oracle DECODE 函数转 MySQL CASE WHEN 表达式
### 1. 语法转换映射
- **转换模式：** Oracle DECODE 函数转 MySQL CASE WHEN 表达式
- **源数据库（Oracle）：** 见下方转换前 SQL
- **目标数据库（MySQL）：** 见下方转换后 SQL；目标数据库动态 `EXPLAIN` 验证通过

### 2. 核心差异说明
- 转换模式键：`ORACLE_DECODE_TO_MYSQL_CASE_WHEN`
- workset_id：`0001:sql-0001`
- 验证：目标数据库动态连接 `EXPLAIN` PASS
- 复用约束：作为相同转换模式的候选规则，后续仍需结合当前 SQL 上下文判断。

### 3. 标准对照示例
#### 转换前 SQL（Oracle，sql-0001）
```sql
SELECT DECODE(status, 1, 'ACTIVE', 2, 'INACTIVE', 'UNKNOWN') FROM users
```
#### 转换后 SQL（MySQL）
```sql
SELECT CASE WHEN status = 1 THEN 'ACTIVE' WHEN status = 2 THEN 'INACTIVE' ELSE 'UNKNOWN' END FROM users
```
````

## 规则库文件结构

单个规则库文件包含多条规则，每条规则以 `<!-- rule_fingerprint: ... -->` 和 `<!-- rule_pattern_key: ... -->` 标记开头，追加至文件末尾：

````markdown
<!-- rule_fingerprint: a3f5e8b2c1d4... -->
<!-- rule_pattern_key: ORACLE_DECODE_TO_MYSQL_CASE_WHEN -->
## [规则 01] Oracle DECODE 函数转 MySQL CASE WHEN 表达式
### 1. 语法转换映射
...

### 2. 核心差异说明
...

### 3. 标准对照示例
...

<!-- rule_fingerprint: b7c9d1e3f5a2... -->
<!-- rule_pattern_key: ORACLE_ROWNUM_TO_MYSQL_LIMIT -->
## [规则 02] Oracle ROWNUM 转 MySQL LIMIT 子句
### 1. 语法转换映射
...
````

## 规则沉淀方式

规则文件路径：

```text
$WORK_DIR/devkit-sql-migration-cache/rulers_<SOURCE_DB>_to_<TARGET_DB>.md
```

`finalize_ai_stage.py` 对所有 AI converted 且通过完整性检查的项，按本模板自动生成规则并追加，按 target 库验证状态标注【已验证】或【待人工确认】。去重粒度为 source_db + target_db + rule_pattern_key，同一转换模式只沉淀一条规则。

以下项目不沉淀：

- AI 仅确认兼容的 `compatible`；
- AI converted 完整性检查失败（源码未实际修改/仍有方言残留）的项；
- `manual-review`；
- 缺少 `rule_pattern_key` 的 converted 项。
