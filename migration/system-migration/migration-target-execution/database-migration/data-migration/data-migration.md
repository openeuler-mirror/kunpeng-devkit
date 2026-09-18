# 数据迁移 Skill（MySQL -> DM）

**仅做数据迁移**，不做源端采集、不安装数据库。目标自动化完成数据迁移，当前仅支持mysql到达梦数据库。数据库连接信息从流水线既有产物（migration-plan.json、install_env.conf、deploy_summary_*.json）提取或由用户瞬时输入。数据迁移方式由达梦数据库提供的DTS数据迁移命令行工具完成。

获得源数据库连接信息后，通过 `database-migration/data-migration/scripts/dm/gen_xml.sh` 渲染模板生成 runtime XML，执行 `dts_cmd_run.sh CONFIG FILE=<xml> DESCRYPT_PASSWORD=0` 完成迁移。

> 当前仅支持 MySQL -> DM：脚本统一在 `database-migration/data-migration/scripts/dm/` 下管理，模板统一在 `database-migration/data-migration/assets/dm/` 下管理。

### 关键约束：

1.**schema 必须预先存在**：DTS 不会自动创建目标 schema。若 `DST_SCHEMA` 在目标 DM 中不存在，所有 `CREATE_TABLE` 任务会因 `无效的模式名[X]` 失败，且 DTS 进程退出码仍为 0，仅靠退出码无法识别。

运行前先经 `prepare_schema.sh` 幂等检查并创建目标 schema（已存在则跳过）。这两步的强制顺序由编排脚本 `run_data_migration.sh` 内部保证，**主流程始终调用该编排脚本**。

2.**前置依赖：MySQL驱动**：数据迁移的源端连通性测试、表清单确认与 `verify_migration.sh` 软校验均依赖 `mysql` 命令行。客户端安装与连通性测试由 md 控制（见「阶段1.5」），脚本层不强制特定客户端。

### 阶段 0 源端 MySQL 客户端准备

在进入阶段 1 交互确认之前，先确保目标机的 `mysql` 命令行能连接源端 MySQL（含 MySQL8 的 `caching_sha2_password` 认证）。**此步骤为首次安装/准备客户端时的主动措施，一次性执行，避免连接时报 `caching_sha2_password` 插件缺失再回头处理。**

1. **确认客户端品类**：
   ```bash
   mysql --version   # 若为 MariaDB，需补齐其客户端侧认证插件，见第 3 步
   ```
2. **确认源库默认认证插件**：源端为 MySQL 8 时，默认账号使用 `caching_sha2_password`，客户端需对应插件文件。
3. **主动补齐客户端认证插件（针对 MariaDB 客户端）**：`caching_sha2_password.so` 由系统 `mariadb-server` 包提供，走系统仓库安装即可（无需第三方 jar、无需自装 python）：
   ```bash
   dnf provides "*/caching_sha2_password.so"    # 确认提供者为 mariadb-server
   dnf install -y mariadb-server                # 补齐 /usr/lib64/mariadb/plugin/caching_sha2_password.so
   ls -la /usr/lib64/mariadb/plugin/caching_sha2_password.so   # 校验插件文件已就位
   ```
   > 离线/无系统镜像源时，先行预置该插件包或在可联网机预下载后离线安装；也可在源端将账号降级为 `mysql_native_password`（两条都与"报错后再处理"相对的主动择一措施）。
4. **安装完成后立即验证一次连通**：
   ```bash
   timeout 5 mysql -h"$SRC_HOST" -P"$SRC_PORT" -u"$SRC_USER" -p"$SRC_PWD" -N -e "SELECT 1"
   ```
   该探测仅为确认客户端可用，不替代阶段 1.5 的正式连通性测试。

> 各字段尚未在阶段 1 交互确定时，可使用占位/默认主机与端口做安装验证；关键原则是首次准备客户端时就保证认证插件齐全，避免后续反复报错。

### 阶段1 迁移参数交互确认

迁移所需的源端关键连接信息不能笼统地用单个问题一次性索要，必须**逐个字段**向用户发起询问并请用户确认输入内容。**目标端 DM 固定为本机已部署的达梦数据库，无需与用户交互**；目标端连接参数一律从本 Skill 交付产物（`install_env.conf`、`deploy_summary_*.json`）自动提取。

#### 源端 MySQL（逐项询问，每个字段给出默认选项）

| 顺序 | 字段 | 默认/选项 | 说明 |
|:----:|------|-----------|------|
| 1 | 源端主机 `SRC_HOST` | **默认取迁移来源主机**（默认为 `migration-plan.json` 记录的源端 IP）；用户可直接确认沿用，或改为其他主机。| 源 MySQL 所在主机 IP / 域名 |
| 2 | 源端端口 `SRC_PORT` | **默认 MySQL 标准端口 `3306`**（可改为其他值） | 源 MySQL 监听端口 |
| 3 | 源端用户 `SRC_USER` | 需用户输入（通常是 `root`，可列为候选） | 源 MySQL 登录账号 |
| 4 | 源端密码 `SRC_PWD` | **仅用户输入**（无默认值，敏感） | 源 MySQL 登录密码，传递规则见「密码处理」 |
| 5 | 源端库名 `SRC_SCHEMA` | **可填写指定库名，也可选「全部」** | 待迁移的源业务数据库 (schema) |

#### 密码处理

1. **通行与展示**：所有敏感密码（源端数据库密码、目标端 DM 密码）在我方可控的全部传输与留存环节（临时 conf、日志、报告、命令文本等）**一律禁止写入文件**，仅由 agent 在当前 shell 内存中持有，并通过环境变量（export）直接传递给编排脚本及其内部子脚本；展示、报告、日志、命令文本中不得呈现明文。
   **唯一例外**：DTS 工具 `dts_cmd_run.sh` 仅接受含密码的 runtime XML 文件作为输入（`DESCRYPT_PASSWORD=0`，无环境变量/密码学接口），该 XML 由 `gen_xml.sh` 在脚本内部经环境变量取值生成，`chmod 600`，迁移完成后由编排脚本 `trap EXIT` 立即删除，属工具必需输入而非密码留存，生命周期受控。除此之外任何脚本与 agent 交互均不得以文件承载密码。
2. **源端数据库密码由用户即时提供**：源端 MySQL 的密码是与源机器系统登录密码不同的独立凭据，须由用户即时输入（阶段1 `SRC_PWD` 仅用户输入、无默认值）。不要从既有产物（`migration-plan.json`、`install_env.conf`、SSH/密钥、历史部署文件等）获取或尝试任何机器密码来充当它。
3. **目标端 DM 密码按交付产物提取**：目标端为本机达梦，其管理员密码（install_env.conf 的 `SYSDBA_PWD`，管理员固定为 `SYSDBA`）属已审计的设备密码，按交付产物提取即可。

#### 交互要求

1. **逐个提问**：每个字段单独向用户确认，一次只确认一个字段，不把多个字段合并成一个问题。
2. **提供默认选项**：对主机、端口、用户、库名等字段，先给出明确的默认值或选项供用户确认；仅密码字段必须由用户输入。
3. **结果汇总确认**：源端每个字段逐项确认完毕后，再汇总展示一遍，供用户最终确认后进入后续流程。
4. **目标端不交互**：目标端 DM 固定为本机（`DST_HOST=127.0.0.1`）、本机达梦端口（`DST_PORT`）、管理员（`DST_USER`）与密码，一律从交付产物自动提取，不向用户询问。

### 阶段1.5 源端连通性测试（md 文字控制，软预检）

连通性测试是**软预检**，行为由本段文字决定。拿到阶段1的源端字段后，按下述方式人工执行一次 probe：

1. **前置已就绪**：客户端品类已确认、源端 MySQL8 认证插件已在「阶段 0 源端 MySQL 客户端准备」补齐，此处直接探测连通性。
2. **短超时探测**：用 `timeout`（建议 5s 内）执行一次连通查询，避免不可达地址长时间卡住：
   ```bash
   timeout 5 mysql -h"$SRC_HOST" -P"$SRC_PORT" -u"$SRC_USER" -p"$SRC_PWD" -N -e "SELECT 1"
   ```
3. **按返回分类处理**：
   - 成功 → 连通正常，继续后续流程。
   - `UNKNOWN_PLUGIN` / `caching_sha2_password can not be loaded` → 说明「阶段 0」未生效（客户端认证插件仍缺失），按该章节正向补齐插件，而非当作密码错误。属软风险，补齐插件后重测即可。
   - 连接拒绝/超时（网络或端口不通）→ 软预检 **FAIL**，先解决源端可达性再继续。

> 连通测试的密码传递规则同「密码处理」。

### 阶段2 生成数据迁移详细配置

从流水线产物(`migration-plan.json`, `install_env.conf`,`deploy_summary_*.json`, 表清单 CSV)中提取目标端 DM 与其余非密码字段的连接信息。源端密码不由此处提取（见「密码处理」第 2 条）。以下提取规则仅适用于目标端 DM 与其余非密码字段：


#### 提取规则

1. **DM数据信息（键名以 install_env.conf 实际写入为准）**：从 `install_env.conf` 读取并与 DTS 的 `DST_*` 映射：
   | install_env.conf 键 | → DTS conf | 说明 |
   |--------------------|------------|------|
   | `INSTALL_PATH` | → `DM_HOME` | 达梦安装根目录 |
   | `PORT_NUM` | → `DST_PORT` | DM 监听端口，取实际值，不猜测 5236 |
   | （DM 管理员固定账号 `SYSDBA`） | → `DST_USER` | 固定 `SYSDBA` |
   | `SYSDBA_PWD` | → `DST_PWD` | 管理员密码 |
   
   目标端 schema `DST_SCHEMA` 缺省等于 `DST_USER`。**不存在的键名**（`DB_PORT`、`SYSDBA_USER`、`SYSDBA_PASSWORD_FILE`、`ADMIN_PASSWORD`）不属于 install_env.conf，不要使用。
3. **多来源并存**：由 AI 判断哪个最权威（通常 `migration-plan.json` > 用户输入 > `install_env.conf`），取首个非空值。
4. **目标端 DM 密码**：取 install_env.conf 的 `SYSDBA_PWD`（管理员固定 `SYSDBA`），属已审计设备密码。
5. **表清单**：优先级：用户提供 > 表清单CSV > `migration-plan.json` 中记录的迁移对象。

> AI 提取完成后，将非密码字段写入临时 conf（`chmod 600`、用后即删），密码字段按「密码处理」经环境变量传递。conf 文件格式见下方「模板占位符」。

#### 模板占位符

`dts_runtime_template.xml` 中的占位符与 conf 文件 KEY 对应关系：

| 占位符 | conf 文件 KEY | 说明 |
|--------|---------------|------|
| `{TASK_NAME}` | `TASK_NAME` | 任务名，默认 `source2dm` |
| `{SRC_HOST}` | `SRC_HOST` | 源端主机 |
| `{SRC_PORT}` | `SRC_PORT` | 源端端口 |
| `{SRC_USER}` | `SRC_USER` | 源端用户 |
| `{SRC_PWD}` | `SRC_PWD` | 源端密码 |
| `{SRC_SCHEMA}` | `SRC_SCHEMA` | 源端库名 |
| `{DST_HOST}` | `DST_HOST` | 目标端主机 |
| `{DST_PORT}` | `DST_PORT` | 目标端端口 |
| `{DST_USER}` | `DST_USER` | 目标端用户 |
| `{DST_PWD}` | `DST_PWD` | 目标端密码 |
| `{DST_SCHEMA}` | `DST_SCHEMA` | 目标端 schema，默认等于 DST_USER |
| `{THREAD_COUNT}` | `THREAD_COUNT` | 并发数，默认 2 |
| `{TO_UPPER}` | `TO_UPPER` | 对象名转大写，默认 true |
| `{ITEM_COUNT}` | 自动计算 | 由 TABLE_LIST 生成 |
| `{TRANSFORM_ITEMS}` | 自动生成 | 由 TABLE_LIST 生成 |

`TABLE_LIST` 为空格分隔的表名，支持 `schema.table` 或纯 `table`（纯表名用 `SRC_SCHEMA`）。示例：
```
TABLE_LIST="orders users"              # 两个表，schema 取 SRC_SCHEMA
TABLE_LIST="db1.t1 db2.t2"             # 跨 schema
```

#### 模板结构约束

生成的 XML **必须**严格遵守 `database-migration/data-migration/assets/dm/dts_runtime_template.xml` 的结构，不得增减元素或改变属性名：
- 根元素 `<TransformTask transformer="13">`，属性名 `transformer`值代表达梦数据库的迁移路线。
- `<Mode>` 下 `<DBStrategies>` 和 `<Schema>/<Strategies>` 的 `<Strategy>` 必须是**内容形式**
- `<TransformItems>` 每个待迁移表一行 `<TransformItem type="table" .../>`。

### 阶段3 调用编排脚本（唯一入口）

**本阶段是整个数据迁移的强制执行入口**：直接调用编排脚本 `run_data_migration.sh`，由它内部依次执行 `gen_xml → prepare_schema → run_migration → verify_migration → 清理`，并负责补全 `MIGRATION_WORK_DIR` 环境与各步骤衔接；**不得绕过编排脚本单独调用其内部子脚本**。需要独立验证目标端时用 `disql` 直接查询即可。AI 将非密码字段写入 600 临时 conf、密码字段按「密码处理」export 后调用编排脚本。

```bash
# 前置（agent inline 执行，幂等）：客户端正向准备已完成（见「阶段 0」，首次安装即补齐认证插件）
# AI 已完成：1.逐项交互拿源端 MySQL 连接（阶段1）；2.提取目标 DM 字段（阶段2）；3.确定 TABLE_LIST
# 若用户明确表示跳过本流程，则结束。

# 密码 export（见「密码处理」），非密码字段写 600 临时 conf：
export SRC_PWD="$SRC_PWD" DST_PWD="$DST_PWD"
CONF="$MIGRATION_WORK_DIR/database/dts_work/.run_conf.$$"
{
  echo "SRC_HOST='$SRC_HOST'";  echo "SRC_PORT='$SRC_PORT'"
  echo "SRC_USER='$SRC_USER'"
  echo "SRC_SCHEMA='$SRC_SCHEMA'"
  echo "DST_HOST='$DST_HOST'";  echo "DST_PORT='$DST_PORT'"
  echo "DST_USER='$DST_USER'"
  echo "DST_SCHEMA='$DST_SCHEMA'"
  echo "TABLE_LIST='$TABLE_LIST'"
  # 以下可选，省略时编排脚本走默认值
  echo "TASK_NAME='${TASK_NAME:-source2dm}'"
  echo "THREAD_COUNT='${THREAD_COUNT:-2}'"
  echo "TO_UPPER='${TO_UPPER:-true}'"
  echo "DM_HOME='${DM_HOME:-/opt/dmdbms}'"
} > "$CONF"; chmod 600 "$CONF"
bash database-migration/data-migration/scripts/dm/run_data_migration.sh --conf="$CONF"
```

> `TABLE_LIST`、`schema.table` 语法与模板结构约束见阶段2「模板占位符」「模板结构约束」两节，此处不重复。

### 阶段5 目标库数据确认验证

```bash
cd <DM_HOME>/bin
./disql <DST_USER>/<DST_PWD>@<DST_HOST>:<DST_PORT> <<'EOF'
SELECT table_name FROM all_tables WHERE owner='<DST_SCHEMA>' ORDER BY table_name;
SELECT COUNT(*) FROM <DST_SCHEMA>."<table_name>";
EOF
```

> 表名大小写由 `objectNameToUpperCase` 决定。小写表名需用双引号查询。

## 安全性流程

密码通行规则统一见「密码处理」，此处仅补充跨脚本实现与端到端流向：

- **流向**：用户输入 `SRC_PWD` / 读取 `install_env.conf` 的 `DST_PWD` → agent export → `run_data_migration.sh` 继承并 export → 子脚本经环境变量读取。全程不落盘。
- **runtime XML 是唯一落盘例外**（DTS 工具 `dts_cmd_run.sh` 仅接受文件输入，`DESCRYPT_PASSWORD=0`，无环境变量/加密接口）：`gen_xml.sh` 渲染后 `chmod 600`，迁移完成由编排脚本 `trap EXIT` 立即删除。
- 非密码字段走 600 临时 conf（source 后即删 + `trap EXIT` 兜底清理）。
- 环境变量仅在进程生命周期内可见，进程退出即消亡，相比落盘文件（即使 rm 仍可被文件系统恢复）风险更低。

## 故障排查

| 现象 | 处理 |
|------|------|
| `NumberFormatException: null` | 根元素属性名必须是 `transformer`，不是 `transform` |
| `No enum constant ...TransformStrategy.` | `<Strategy>` 必须是内容形式，不能自闭合 |
| 进程退出码 137 | DTS 进程被 kill（内存不足或超时）；调大 DM JDK 的 `-Xmx` 或机器内存后重试 |
| MySQL SSL 告警 | 无害，忽略 |
| `无效的模式名[X]` 且 DTS_EXIT=0 | 未执行 `prepare_schema.sh`；schema 必须预先存在，DTS 不会自动创建 |
| `caching_sha2_password can not be loaded` | 首次安装客户端时通常已在「阶段 0 源端 MySQL 客户端准备」主动补齐认证插件而不会出现。若仍出现，说明阶段 0 未生效：按「阶段 0」正向补齐 `/usr/lib64/mariadb/plugin/caching_sha2_password.so`（`dnf install -y mariadb-server`），再重测连通；此错误**非密码错误**。离线替代：源账号降级 `mysql_native_password` |
| verify_migration.sh 输出 VERIFY SUCCESS 但实际表未迁移 | 旧版 verify 仅检查退出码，未校验 `出错:N`；已修复，硬校验包含出错数=0 |
