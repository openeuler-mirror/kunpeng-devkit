# 源端采集执行指南

## 1. 采集边界

采集脚本只读取源端事实，不安装软件、不停止服务、不修改业务配置。数据库导出只有在用户明确授权后调用
`export-db.sh`。密码、Token、私钥和许可证内容不得写入JSON或报告。

## 2. 采集方式

本机使用 `collect.sh`，远程主机使用 `remote-collect.sh`。远程连接优先使用密钥；使用密码认证且凭据尚未保存时，Agent必须调用前端内置 `question` 工具，让用户通过自定义答案（Other/Type something）输入密码，不得改为普通文本提问。取得输入后通过标准输入调用 `credential-set --password-stdin`，保存到 macOS Keychain 或 Linux GPG 加密凭据库后自动继续采集。不得让用户另行执行命令后回复，也不得复述或生成临时明文密码文件。首轮采集后根据缺口调用 `collect-versions.sh`、`supplement.sh` 和
`collect-artifacts.sh`。远程采集必须显式传入 Agent 端绝对输出目录 `--local-output`。同一源IP的新结果替换旧结果；每次采集前清理脚本管理的异常残留临时目录，远端暂存目录按主机复用，不累计历史副本。

## 3. 成分确认

进程、端口、systemd、软件目录和Java启动命令需要相互印证。候选项按 `primary`、`likely`、`candidate`
分级，最终只把用户二次确认纳入迁移的项目写入 `migration-plan.json`。Nginx、Redis即使服务未运行，也要根据已安装软件包、可执行文件、服务定义和配置文件继续采集，不得仅因无运行进程而跳过。JDK/JRE统一归入中间件。

步骤5至8分别是强制交互门禁，每步必须得到用户针对本步的明确答复后再继续。等待答复时只暂停当前门禁并保留工作目录和已完成结果，不得退出或结束任务；收到答复后从当前门禁自动续跑。`detection_method` 为 `rpm-owner`、`rpm-package`、`deb-owner` 或 `deb-package` 时，步骤5只确认是否迁移，不校验版本；确认后必须优先推荐目标系统仓库安装，并同时提供URL下载选项。选择系统仓库时不再确认版本和URL，无法精确匹配时使用同一目标产品的最高具体版本回填备用URL；选择URL时继续完成普通路线和安装包确认。

写入或更新 `migration-plan.json` 前，必须读取 `migration-plan-guide.md`，按其中的采集阶段字段范围、条件规则和禁止猜测要求填写。运行期业务输入仍只有 `migration-plan.json`。

## 4. 路线规划

采集阶段确认源产品到目标产品的路线。目标环境架构、权限、磁盘、网络、JDK和包管理器检查仍由
`migration-precheck` 在鲲鹏目标机执行。路线推荐、目标产品、目标版本、安装包来源和应用迁移相关SQL适配决策必须展示给用户并取得明确答复；模型不得自行完成确认。

## 5. 制品规则

配置文件和应用包复制到 `details/artifacts/`，并把相对路径写入：

- 中间件、数据库：`source.artifact_paths[]`；
- Java应用：`packages[].local_path`。

目标组件包规划写入组件 `packages[]`。`source_type` 仅允许 `SYSTEM_REPOSITORY`、`OFFICIAL`、`MANUAL`：系统仓库安装使用 `SYSTEM_REPOSITORY`；从明确 HTTPS 地址下载使用 `OFFICIAL`；仅当用户选择自定义版本且在镜像仓和官网均未找到对应安装包时使用 `MANUAL`。`SYSTEM_REPOSITORY` 不要求本地安装包，但仍要填写 `download_url` 作为备用来源；无法精确匹配时使用同一目标产品的最高具体版本。`OFFICIAL` 必须给出 `download_url`，`MANUAL` 必须给出预期 `local_path`。目标环境无网络时的下载和上传提示由目标检查阶段处理，本 Skill 不因此默认使用 `MANUAL`。

迁移辅助工具包统一声明在 `target_environment.migration_tools[]`，每个条目保存工具包标识、名称、版本、类型、文件名、下载地址、本地路径、`status` 和 `tools[]`。`type` 仅允许 `ARCHIVE` 或 `FILE`。`tools[]` 的每一项只填写 `name`，用于提示模型从哪个工具包获取工具；运行入口、路径、依赖关系和运行参数不进入计划。目标预检将本地工具包复制、下载工具包保存到 `tools/packages`；仅 `ARCHIVE` 类型展开到 `tools/unpacked`，`FILE` 类型直接使用工作副本。`migration_tools[]` 中出现的每个工具包均为执行必需项，目标预检全部准备并校验，不再根据 `route` 按需跳过。工具包 `status` 只允许 `PENDING_DOWNLOAD/PENDING_UPLOAD/URL_REQUIRED/READY`。运行入口只从统一 `tools` 目录解析。采集报告保留完整证据和排除项，主计划只保存后续执行需要的信息。

## 6. Java应用与SQL

每个纳入系统迁移的Java应用都必须采集实际运行或交付使用的JAR/WAR组件并写入 `packages[]`；至少包含一个JAR/WAR组件，且 `packages[].local_path` 不允许为空。`install_location` 记录源端应用安装/部署位置，仅作为部署上下文参考；`packages[].local_path` 记录JAR/WAR组件在采集交付中的实际存放地址，Java应用迁移只通过该字段定位输入组件。
系统迁移直接基于采集到的JAR/WAR组件执行应用迁移，不采集源码目录。数据库产品发生变化或SQL方言需要适配时，将
`application_sql_migration.requires_sql_adaptation` 设为 `true`，并记录 `selected_route`。

## 7. 打包要求

`package.sh` 校验报告标题、架构摘要、制品索引和计划内路径。打包前生成
`details/devkit-source-scan-details.tar.gz`，回写源端交接路径，再进行 `collector-final` 校验。
