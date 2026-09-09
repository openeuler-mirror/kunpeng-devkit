# 数据库ARM迁移

执行目标库自动化静默安装、实例创建、系统服务配置、可用性验证，以及目标库的数据迁移。仅执行数据库部署与数据迁移动作，不包含源端信息采集；依赖外部提供 migration-plan.json获取安装配置。

## 核心原则
- **自动化部署**: 读取`migration-plan.json`信息无误后直接对数据库执行安装。
- **非侵入式工作目录**: 所有临时产物（下载包、扫描报告、编译日志）放到项目目录之外的专用工作目录，不污染源码树。
- **脚本控制关键步骤**: 数据库首次安装部署使用代码仓里固定代码的脚本，**脚本源码不可被修改**。
- **Skill文档不可被修改**：本skill在使用过程中不可被修改，包括当前目录下的所有md文档。

---
## 整体流程

> 1.信息收集 → 2.数据库安装部署 → 3.安装后验证，问题修复（含防火墙端口放行） → 4.数据迁移（可选）

**关键约束**：

1. **脚本固化原则**：`database-migration/database-deploy/scripts/` 下各数据库专属目录（`dm/`、`kingbase/`、`mysql/`）中的安装脚本与 `assets/` 下对应模板为固定版本，执行过程中禁止修改源码，仅允许通过传入参数控制安装行为。
2. **权限边界原则**：环境检查、依赖安装、服务注册需root/sudo权限；数据库安装、实例创建必须切换至专属数据库用户执行，禁止root直接运行数据库进程。
3. **离线场景约束**：无外网环境下，数据库ARM安装包由目标预检准备在 `$MIGRATION_WORK_DIR/packages/` 下，数据库阶段只使用计划中已经 `READY` 的包路径，脚本自动校验包完整性后执行离线安装。
4. **单节点默认规则**：默认执行单节点单机部署，分布式集群部署需额外传入集群配置参数。
5. **密码展示规则**：用户自定义密码属于敏感信息，任何任务、结果、报告、日志或命令文本都不得包含用户自定义密码。但**数据库安装默认密码例外**——当安装实际使用的管理员密码与 `database-deploy/references/<db>-deploy-guide.md` 中记录的默认值一致时（达梦 `SYSDBA001`、金仓 `Kingbase123`、MySQL `MySQL_123!`），该默认密码**必须以明文展示**在 `deploy_summary_*.json` 的 `password` 字段与 `deploy_report_*.md` 安装报告的醒目位置，供用户感知。此例外优先于"密码不明文"的整体迁移流程约束，子流程不得以"密码不展示"为由屏蔽默认密码。


> `license_required=true` 时使用目标预检二次校验后记录的 `packages[].license_path`，不猜测其他 License 文件。若目标数据库不在当前支持范围内（因为MySQL，DM/达梦，Kingbase/金仓支持安装后试用）且 License 未就绪，则明确告知用户当前数据库无法安装成功，跳过当前流程。


---

## 工作目录约定

数据库迁移不再自行选择工作根目录。系统迁移入口统一提供 `MIGRATION_WORK_DIR`，数据库所有运行期文件固定写入：

```bash
PLAN="${MIGRATION_PLAN_PATH:?请先完成目标预检并导出 MIGRATION_PLAN_PATH}"
export MIGRATION_WORK_DIR="$(python3 scripts/migration_plan.py work-dir --plan "$PLAN")"
WORK_DIR="$MIGRATION_WORK_DIR/database"
mkdir -p "$WORK_DIR"/{reports,build,logs,backup,dts_work,tmp}
export DATABASE_WORK_DIR="$WORK_DIR"
export TMPDIR="$WORK_DIR/tmp" TMP="$WORK_DIR/tmp" TEMP="$WORK_DIR/tmp"
```

其中 `reports/`、`build/`、`logs/`、`backup/`、`dts_work/` 和 `tmp/` 均属于迁移运行文件。安装包不落在本目录：由目标预检统一准备在 `$MIGRATION_WORK_DIR/packages/`，数据库阶段只使用计划中 `READY` 的包路径。数据库软件正式安装目录和数据目录继续按现有数据库部署参数处理，不受 `MIGRATION_WORK_DIR` 约束。

---

---

## 支持版本矩阵
| 数据库 | 推荐ARM兼容版本 | 最低系统要求 |
|--------|----------------|--------------|
| 达梦 DM | DM8 及以上 | openEuler 22.03 / 麒麟V10 SP3 |
| 金仓 Kingbase | ES V8R6 及以上 | openEuler 22.03 / 麒麟V10 |
| MySQL | 8.0 及以上 | 通用ARM64 Linux发行版 |


---

## 阶段 1：信息收集与环境准备

本阶段目标：确认待安装数据库参数并检查、修复目标环境，为静默安装生成配置文件。

执行步骤（由 Agent 自行判断执行方式，不依赖固定命令）：

1.1 **采集安装参数**：从 `migration-plan.json` 提取数据库类型、版本、安装/数据根路径、端口、实例名、字符集、License 路径（`license_required=true` 时读 `packages[].license_path`）等。支持范围外的数据库（非 达梦/金仓/MySQL）标记为非自动安装，不打断流程并在最后提示。将非秘密参数写入 `$WORK_DIR/build/install_env.conf` 作为阶段2输入；管理员密码仅记录其密码文件路径，不写明文。若密码等于各库参考文档记录的默认值（DM `SYSDBA001`、Kingbase `Kingbase123`、MySQL `MySQL_123!`），在配置中标记 `IS_DEFAULT_PASSWORD=true` 以便阶段2明文展示。

1.2 **环境基线检查**：判断内存/磁盘是否满足该库最低要求；在当前步骤**强制核对**数据库必需运行依赖 glibc、libaio、ncurses、readline、zlib 是否齐全，任一缺失即判定环境检查不通过；检查信号量/共享内存/文件句柄等内核与资源限制、目标端口与进程冲突。

1.3 **问题自动修复**：无问题则跳过。有问题时优先自动修复——依赖缺失则安装、资源限制不足则补写 `limits.conf`、内核参数不达标则改 `sysctl.conf` 并 `sysctl -p`；**端口冲突属于阻断项**，自动修复无法解决，必须**中断流程并立即向用户确认**：展示冲突端口、占用进程与占用数据库实例，交由用户决定（选择其他端口 / 停止占用进程 / 手动处理），未经用户确认不得继续安装。所有系统配置修改前先备份到 `$WORK_DIR/backup/`。

1.4 **环境检测报告**：若发生过环境修复，在 `$WORK_DIR/reports/` 生成 `env_check_report_*.md`，记录服务器基础信息、待安装参数、检查结果与修复情况。

异常处理：架构不兼容直接终止；关键依赖无法修复则标记高风险并让用户确认；磁盘空间不足提示扩容后终止。


## 阶段 2：数据库安装部署

> 详细执行步骤见 [database-deploy/database-deploy.md](database-deploy/database-deploy.md)

本阶段目标：全自动安装数据库，创建数据库用户，保证数据库可用度。


## 阶段 3：安装后检查与问题修复
> 本阶段核心目标是验证数据库ARM架构兼容性、功能完整性，定位并修复典型安装故障。

执行步骤：

3.1 运行态基础检查：进程存活状态、端口监听状态、内存/CPU资源占用、目录权限校验

3.2 功能兼容性验证：基础SQL执行、字符集校验、连接数测试、ARM平台常用函数兼容性检测

3.3 日志全量巡检：扫描数据库运行日志、系统messages日志，定位告警、报错与兼容性警告

3.4 典型问题自动修复：针对ARM环境常见问题（依赖缺失、内核参数不兼容、glibc版本不匹配、权限不足）执行预置修复脚本

3.5 输出正式安装验收报告，标记未解决问题与手动处理建议.

3.5.1 防火墙端口放行：初验通过后，自动放行本库实际 `PORT_NUM`（firewalld/iptables），确保数据库端口可被外部访问，放行结果记录进验收报告（详见 database-deploy.md「5.1 防火墙端口放行」）。

3.6 若路线为 MySQL → DM，则在上述流程全部顺利执行完并输出结论以后进入阶段4（数据迁移）；其余路线按阶段4所述跳过。


## 阶段 4：数据迁移
> 详细执行步骤、迁移路线与交互流程见 [data-migration/data-migration.md](data-migration/data-migration.md)

本阶段目标：将源数据库的业务数据迁移到已部署完成的目标数据库。当前仅支持 MySQL → DM 迁移路线（详见 data-migration.md）；若目标数据库不是 DM，则提示当前流程不支持自动化数据迁移，并跳过本阶段。


## 回滚与清理机制
- 安装失败自动回滚：删除安装目录、移除系统服务、删除数据库用户，恢复环境至安装前状态
- 配置变更可回溯：所有系统配置修改均提前备份，备份文件存放于 `$WORK_DIR/backup/` 目录
- 当前支持的数据库的专属清理脚本（每数据库一个，root 执行）：
  - 达梦：`database-migration/database-deploy/scripts/dm/dm_cleanup.sh`
  - 金仓：`database-migration/database-deploy/scripts/kingbase/kingbase_cleanup.sh`
  - MySQL：`database-migration/database-deploy/scripts/mysql/mysql_cleanup.sh`
---
