# 目标预检

## 功能

基于 `MIGRATION_PLAN_PATH` 完成目标环境检查和迁移文件准备，不安装目标组件，不创建计划副本。

主要处理：

- 采集目标机架构、系统、权限、磁盘、包管理器、Java 和网络等环境事实；
- 准备数据库、中间件目标包以及 `migration_tools[]` 中声明的全部工具包；
- 检查 License，解析 DevKit、迁移 JDK/Vineflower 和 SQL Analysis；
- 按 `references/migration-plan-guide.md` 的目标预检白名单更新原计划；
- 生成 `$MIGRATION_WORK_DIR/precheck/migration-plan-report.md`。

## 入口

目标执行根 Skill 已将计划路径固定为绝对路径：

```bash
sh migration-precheck/scripts/run-precheck.sh \
  --plan "$MIGRATION_PLAN_PATH"
```

内部步骤和中间文件说明见 `references/precheck-guide.md`。

## 处理规则

预检开始时目标架构必须为 `aarch64` 或 `arm64`，否则提示当前架构并立即终止。目标包目录所在文件系统的可用空间必须大于 10 GiB；目标执行用户非 root 且无免密 sudo 权限时必须给出警告。

目标组件包按 `packages[].source_type` 准备：

- `SYSTEM_REPOSITORY`：无需准备文件；
- `OFFICIAL`：使用计划中的 HTTPS `download_url`；
- `MANUAL`：仅检查计划中的 `local_path`。

迁移工具包全部准备到受控 `tools/` 目录，并按声明解析后续实际使用的工具。目标机现有 Java 仅作为环境事实，不替代计划声明的迁移 JDK。

`license_required=true` 的数据库或中间件包从 `$MIGRATION_WORK_DIR/licenses/<component-id>/<package-id>/` 检查 License。未上传时生成非阻断待办。

`source_type`、`download_url`、`local_path` 等采集确认字段保持不变；预检只更新允许的目标环境事实、准备状态、License 路径和工具状态。

## 结果

- 退出码 `0`：预检通过，可进入目标变更确认；
- 退出码 `20`：仍有阻塞项，需要补充目标包、工具包或完成工具解析；
- License 未上传只记录 `LICENSE_UPLOAD_REQUIRED`，不阻塞预检。
