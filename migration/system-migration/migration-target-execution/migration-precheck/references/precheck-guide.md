# 目标预检内部说明

## 执行入口

预检内部命令已统一沉淀到：

```text
migration-precheck/scripts/run-precheck.sh
```

上层只传入已经规范化的 `MIGRATION_PLAN_PATH`，不逐条编排预检内部脚本。

## 内部顺序

`run-precheck.sh` 固定执行：

```text
目标环境采集
→ 合并目标事实
→ 生成组件/工具包 manifest
→ 准备组件包和工具包
→ 合并准备状态
→ License 检查
→ DevKit 解析
→ JDK/Vineflower 解析
→ SQL Analysis 解析
→ 最终校验与报告
```

运行文件写入本次统一工作目录：

```text
precheck/       环境事实、manifest、准备状态和预检报告
packages/       数据库/中间件目标组件包
tools/packages/ 工具包工作副本
tools/unpacked/ ARCHIVE 工具包展开内容
tools/runtime/  迁移工具运行时
tools/bin/      可执行工具引用
tools/lib/      JAR 等工具引用
licenses/       目标组件 License
tmp/            临时文件
```

## 文件准备

目标组件和工具包均以 `migration-plan.json` 中已确认的来源字段为准：

- `SYSTEM_REPOSITORY`：组件无需准备本地包；
- `OFFICIAL`：从计划中的 HTTPS `download_url` 下载；
- `MANUAL`：只检查 `local_path`，缺失时返回待上传状态。

工具包中的 `ARCHIVE` 类型展开到 `tools/unpacked/<package-id>/`；`FILE` 类型直接从 `tools/packages/<package-id>/` 使用。工作副本路径不回写计划。

## 工具解析

预检只从计划声明并已准备的工具包中解析工具：

- AI Migration Tool → `tools/bin/ai-migration`；
- JDK/Vineflower → `tools/runtime/jdk`、`tools/lib/vineflower-1.12.jar`、`tools/bin/vineflower-java`；
- SQL Analysis → `tools/lib/sql-analysis.jar`。

Java 应用迁移需要的 JDK 必须来自 `migration_tools[]`，不使用系统 PATH、`JAVA_HOME` 或中间件阶段安装的 JDK 代替。

## 结果判定

最终校验读取当前 `migration-plan.json` 和受控工作目录中的准备结果。组件包、工具包或声明工具未就绪时返回阻塞；License 缺失仅生成非阻断提示。所有阻塞项处理完成后才进入 `operation-plan.json` 生成阶段。
