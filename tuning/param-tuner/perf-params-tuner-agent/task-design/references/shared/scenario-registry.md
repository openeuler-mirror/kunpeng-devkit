# 场景注册表

> KAT 内置场景索引，列出所有可用场景及其 meta.yaml 路径。

## 场景列表

| 名称 | meta.yaml |
|------|-----------|
| Redis | assets/scenarios/Redis/meta.yaml |
| MySQL | assets/scenarios/MySQL/meta.yaml |
| PostgreSQL | assets/scenarios/PostgreSQL/meta.yaml |
| openGauss | assets/scenarios/openGauss/meta.yaml |
| Vastbase | assets/scenarios/Vastbase/meta.yaml |
| Kafka | assets/scenarios/Kafka/meta.yaml |
| Hive | assets/scenarios/Hive/meta.yaml |
| Flink | assets/scenarios/Flink/meta.yaml |
| Spark | assets/scenarios/Spark/meta.yaml |
| Rocksdb | assets/scenarios/Rocksdb/meta.yaml |

## 路由规则

1. 根据用户输入语义识别目标场景
2. 若能明确识别 → 直接使用该场景
3. 若存在多个候选（如"数据库"可能对应 MySQL、PostgreSQL、openGauss、Vastbase）→ 列出候选项让用户选择
4. 若无法匹配任何场景 → 进入**自定义场景**流程（`workflow-custom.md`）

## 共享参数文件

以下参数文件不绑定特定场景，任何场景均可按需合并：

| 文件 | 说明 | 路径 |
|------|------|------|
| System base 参数 | 操作系统内核/网络/IO 参数 | assets/scenarios/System/param_System_base.yaml |
| System JVM 参数 | JVM GC/heap/compiler 参数 | assets/scenarios/System/param_System_jvm.yaml |
| Custom 参数 | 自定义业务参数（空模板） | assets/scenarios/Custom/param_Custom_System.yaml |
