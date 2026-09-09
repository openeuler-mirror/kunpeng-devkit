# 数据库安装部署

基于database-migration采集的参数与环境基础，全自动完成数据库软件安装、实例初始化、监听配置与系统服务注册，输出可正常连接使用的数据库服务。目标数据库不在支持矩阵内时，不中断流程，转入「不在支持范围内的数据库降级策略」提供基础辅助能力。本文件负责**数据库安装部署**，调用代码仓固定脚本执行。**skill和脚本源码不可修改。**

> 各数据库的完整部署参数、调用示例、日志产物、常见问题见 [database-migration/database-deploy/references/](references/) 下对应 `<db>-deploy-guide.md`。

## 前置约束
- 阶段1已执行完成，`install_env.conf` 参数文件已生成且校验通过
- 数据库安装包已由目标预检准备到 `$MIGRATION_WORK_DIR/packages/<database-id>/<file_name>`；`packages[].local_path` 保留原始来源，安装阶段直接使用工作目录中的 `READY` 文件
- `license_required=true` 时使用目标预检二次校验后写入 `packages[].license_path` 的 `DB_LICENSE_PATH`；未记录时不猜测其他文件
- 数据库专属 OS 用户（如 kingbase/mysql/dmdba）已由前置流程创建；安装脚本以 root 入口运行，install.bin 与数据库进程由脚本内部 su 切换至专属 OS 用户执行
- 用户选择跳过 License 不作为阶段前置阻塞。厂商安装器运行时确实强制要求License 时，停止该数据库的安装并记录 `DEFERRED_LICENSE`，继续后续流程。

## 目标数据库已存在检测与确认（安装前强制）

开始安装部署前，检测目标端口是否被占用、目标目录是否已有残留/实例。存在任一情况时：**中断流程，向用户说明情况并发起交互，由用户决定下一步**，未经用户确认不得继续或清理。

交互选项：
1. **更换端口/路径后安装（推荐默认）** — 改新库配置，不触碰占用端口的现有程序
2. 清理已有安装/残留后重新安装
3. 保留已有实例，跳过本次安装
4. 手动处理（用户自行处理后继续）

> 默认优先建议**改新库端口**（非侵入、不影响现有程序）；仅在占用程序确认可安全停止时，才考虑选项2清理。
> 数据库清理脚本仅在取得用户同意、或属于本次部署失败需回滚时才被调用。

## 不在支持范围内的数据库降级策略
目标数据库不在达梦/金仓/MySQL 支持范围内时（如 Oracle、GoldenDB、PostgreSQL、GaussDB 等），**不中断整体迁移流程**，按以下降级模式处理：

1. **明确告知**：向用户输出该数据库暂不在 DevKit 自动化静默安装支持范围内，无法执行自动安装，但不退出本 Skill。本Skill不保证数据库能够部署成功。
2. **切换为基础咨询模式**，提供 AI 辅助能力：
   - 环境预检：仍执行阶段3的通用检查项（内存/磁盘/依赖包/端口冲突/内核参数），输出针对该数据库的环境建议
   - 检查目标数据库信息：如果是非开源数据库，则必须用户如果手动上传了该数据库安装包才能继续数据库部署流程；如果是开源数据库，则AI自行尝试后续部署。
   - 安装指导：基于该数据库官方 ARM64 安装文档，给出手动安装步骤要点、专属运行用户规划、目录规划建议
   - 配置建议：给出 systemd 服务、资源限制（limits.conf）、环境变量等通用配置模板，由用户手动执行
   - 风险提示：列出该数据库在鲲鹏 ARM 平台的已知兼容性风险点
3. **产物记录**：将上述建议输出到 `$WORK_DIR/reports/deploy_advice_<db_type>_<时间戳>.md`，`deploy_summary_*.json` 中该库标记为 `"install_status": "manual_required"`
4. **流程继续**：自动完成系统迁移的过程中跳过该数据库部署流程，留到最后告知用户做后续决策。整体报告如实区分「自动安装成功」与「需手动安装」

> 降级模式只提供建议与配置模板，不代替用户执行该数据库的安装程序；用户自行安装完成后，可回到阶段5对该库执行可用性初验。

## 详细执行步骤

### 1. 运行账号与安装目录初始化
#### 1.1 创建数据库专属用户与用户组
不同数据库使用独立运行用户，遵循官方规范：
```bash
source $WORK_DIR/build/install_env.conf

case $DB_TYPE in
    dm)     DB_USER=dmdba ;;
    kingbase) DB_USER=kingbase ;;
    mysql)  DB_USER=mysql ;;
esac

sudo groupadd -f $DB_USER
sudo id $DB_USER &>/dev/null || sudo useradd -g $DB_USER -m $DB_USER
```

#### 1.2 目录创建与权限分配
```bash
sudo mkdir -p $INSTALL_PATH $DATA_PATH
sudo chown -R $DB_USER:$DB_USER $INSTALL_PATH $DATA_PATH
sudo chmod -R 755 $INSTALL_PATH
```

#### 1.3 环境变量预配置
为数据库用户写入基础环境变量到 `.bashrc`，包含安装目录、实例名、端口等，确保登录即可使用数据库命令。

### 2. 数据库静默安装执行
#### 2.1 安装包校验与解压
```bash
INSTALL_PACKAGE="$DB_PACKAGE_PATH"
if [ ! -f "$INSTALL_PACKAGE" ]; then
    echo "ERROR: 安装包不存在，请上传到精确路径 $INSTALL_PACKAGE"
    exit 1
fi

tar -xf $INSTALL_PACKAGE -C $WORK_DIR/build/ >> $WORK_DIR/logs/install_${DB_TYPE}_$(date +%s).log 2>&1
```

#### 2.2 静默安装执行
> 核心规则：调用 `database-migration/database-deploy/scripts/` 下对应数据库的固化安装脚本，**脚本源码不可修改**。具体参考各个数据库的reference部署指南。
> **脚本调用或运行失败时必须立即执行「回滚与清理」，清理步骤 1 已创建的用户、目录、环境变量等全部前置工作产物**，规则见下文「回滚与清理」。


> **密码安全规范**：不在脚本内硬编码默认密码，密码优先级为 
> `--xxx-pwd` 入参 > `env-conf` > `references/<db>-deploy-guide.md` 表格中的约定默认值。
> 密码变量在脚本内使用完毕后立即 `unset`，`cleanup` 兜底再 `unset` 一次。
> 敏感密码建议优先通过权限 600 的 `env-conf` 提供，避免出现在命令行（`ps` 可见）；命令行入参仅用于临时覆盖。

#### 2.3 安装进度实时展示
安装过程后台运行，前台实时打印日志尾部，避免无反馈卡顿：
```bash
tail -f $WORK_DIR/logs/install_*.log &
TAIL_PID=$!
wait $INSTALL_PID
kill $TAIL_PID
```
安装异常中断时自动捕获退出码，输出错误提示与日志路径。

### 3. 数据库实例创建与初始化
1. 自动生成实例响应文件，代入阶段1采集的实例名、端口、字符集、管理员密码
2. 切换数据库用户执行实例创建命令
3. 等待实例初始化完成，校验数据目录文件完整性
4. 执行基础参数优化（最大连接数、内存占比等）

### 4. 监听配置与系统服务注册
1. 监听服务配置，根据数据库类型自动生成监听配置文件，绑定指定端口，启动监听并校验状态。

2. systemd系统服务注册，注册为系统服务并设置开机自启，不同数据库的启停命令已封装在固化脚本中，由各自reference内容自动适配替换。

### 5. 安装可用性初验
完成部署后执行5项基础校验，全部通过则标记安装成功：
1. 进程校验：数据库主进程存活
2. 端口校验：目标端口处于监听状态
3. 登录校验：管理员账号可本地连接
4. 功能校验：执行基础SQL查询返回正常
5. 服务校验：systemctl启停服务正常

> 防火墙端口放行（流程末尾自动执行）确保目标数据库端口可被外部访问。在初验通过、生成报告前，自动放行该数据库的 `PORT_NUM`
> 端口放行使用本库实际安装写入的 `PORT_NUM`（非硬编码默认），放行结果记录进阶段6的部署报告。


### 6. 生成安装报告
安装初验通过后，在 `$WORK_DIR/reports/` 目录同时生成两份报告：
- `deploy_report_<时间戳>.md`：人类可读的安装部署结果报告，包含完整执行过程、校验明细与风险提示
- `deploy_summary_<时间戳>.json`：面向机器读取的精简摘要，仅保留数据库运行必需字段，供后续阶段或外部工具直接消费。

> **默认密码明文展示规则（优先级最高）**：当安装实际使用的管理员密码与下表所列的约定默认值完全一致时，该默认密码**必须以明文**同时写入 `deploy_summary_*.json` 的 `password` 字段与 `deploy_report_*.md` 安装报告的醒目位置。判定基准为下表所列值：
> | 数据库 | 默认管理员账号 | 约定默认密码明文值 |
> |--------|---------------|----------------|
> | 达梦 DM | `SYSDBA` | `SYSDBA001` |
> | 金仓 Kingbase | `system` | `Kingbase123` |
> | MySQL | `root` | `MySQL_123!` |
>
> 此规则**优先于**"密码不明文"的整体迁移流程约束以及本文件下方"JSON 不写入密码"的常规约束。子流程不得以任何"密码不展示"理由屏蔽默认密码的明文展示，以确保用户能感知到使用了默认密码这一安全风险。非默认密码（用户自定义）仍按常规约束不展示，仅记录于权限 600 的独立密码文件。

#### 安装报告 JSON 摘要字段定义
```json
{
  "db_type": "dm | kingbase | mysql",
  "db_version": "<实际安装版本号>",
  "arch": "aarch64",
  "os": "<操作系统发行版与版本>",
  "run_user": "<数据库专属运行用户，如 dmdba>",
  "install_path": "<数据库软件安装绝对路径>",
  "data_path": "<数据文件目录绝对路径>",
  "port": "<监听端口，整数>",
  "instance_name": "<实例名/SID>",
  "charset": "<字符集，如 UTF8>",
  "systemd_service": "<systemd 服务名，如 dm.service>",
  "admin_user": "<管理员账号>",
  "password": "<管理员账号密码>",              
  "install_status": "success | failed | manual_required",
  "verification": {
    "process": true,
    "port": true,
    "login": true,
    "sql": true,
    "service": true
  },
  "work_dir": "<本次迁移工作目录绝对路径>",
  "log_file": "<安装日志文件绝对路径>",
  "timestamp": "<报告生成时间，ISO8601>"
}
```

> - JSON 仅包含数据库「能否被连接和管理」的最小必需信息，不写入详细日志内容
> - 用户自定义密码（非默认值）：`password` 字段省略，密码仅记录在权限 600 的独立密码文件中，JSON 中只引用 `admin_user` 账号名
> - `install_status` 取值由阶段 5 五项初验结果汇总得出，任一不通过即为 `failed`；不在支持范围的数据库固定为 `manual_required`
> - JSON 文件权限默认 644，便于后续自动化工具读取

## 回滚与清理
整个流程一旦失败就需要在失败后触发对应数据库的回滚与清理，每数据库使用专属清理脚本（root 执行）。**调用前必须先经用户确认**（见前文「目标数据库已存在检测与确认」）：
- 用户要求对数据库进行清理与回滚时，清理脚本自动执行（删除安装目录、移除用户与服务），此时无需再次交互确认；
- **清理已存在的既有实例**时，必须先取得用户明确同意后才执行。
具体脚本：
- **达梦**：`bash database-migration/database-deploy/scripts/dm/dm_cleanup.sh`（停服务、杀进程、官方卸载、删目录、删用户）
- **金仓**：`bash database-migration/database-deploy/scripts/kingbase/kingbase_cleanup.sh`（停服务、杀进程、卸ISO残留、删目录、还原limits.conf、删用户）
- **MySQL**：`bash database-migration/database-deploy/scripts/mysql/mysql_cleanup.sh`（停服务、杀进程、删目录、移除/etc/my.cnf、还原limits.conf、删用户）

## 异常处理
- 安装脚本执行失败：自动执行回滚，删除安装目录、移除用户与服务，输出错误日志
- 实例创建失败：保留软件安装，清理实例文件，输出失败原因支持重试
- 服务启动失败：自动扫描运行日志，匹配ARM环境常见问题，给出修复建议
