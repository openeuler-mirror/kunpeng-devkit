---
name: migration-source-collector
description: X86 Linux 系统源端成分采集与迁移方案规划技能。提供源端系统成分采集、迁移范围确认、目标路线规划、Java应用识别与 SQL 适配决策能力，直接生成 migration-plan.json 及采集包。在需要将 X86 Linux 系统迁移至鲲鹏（aarch64）平台、需先在源端完成事实采集与迁移方案规划时触发。适用于 X86 Linux 系统的中间件、数据库、Java 应用及 JDK/JRE 成分采集；不用于目标端预检、迁移执行。
metadata:
  version: "3.9.2"
---

# X86系统成分采集

## 核心原则

- **唯一业务输出**：以 `assets/migration-plan-init.json` 为初始化文件生成 `migration-plan.json`，不生成 `migration-source.json` 或其他迁移计划副本
- **事实采集与方案规划**：在源端完成事实采集和迁移方案规划；采集阶段只写采集事实和路线候选，不替用户决策
- **强制交互门禁**：主流程阶段 4 至 7 是四个独立的强制交互门禁，每一步都必须收到用户针对本阶段的明确答复后才能进入下一阶段；模型只负责整理、分析和展示候选项，不得代替用户选择、不得将推荐项视为已确认、不得沿用历史答复或使用默认值代答、不得合并跳过任一阶段
- **非侵入式工作目录**：所有临时产物统一放到专用工作目录，不得在当前目录、`/tmp` 或 `/opt/kunpeng-migration/collection` 之外创建 Agent 端或源端的配置、执行文件、日志和采集结果
- **计划填写规范**：新增或修改 `migration-plan.json` 字段前必须先读取 [references/migration-plan-guide.md](references/migration-plan-guide.md)；不得增加旧版本字段或另建 Schema、JSON 示例计划文件
- **migration_id 唯一复用**：初始化正式 `migration-plan.json` 时生成一次 `migration_id`，作为本次系统迁移的唯一标识；后续采集、目标预检和迁移执行均复用该值，不重新生成

---

## 整体流程

> **阶段 1（采集机器确认与计划初始化）** → **阶段 2（源端系统成分采集）** → **阶段 3（补充采集）** → **阶段 4（迁移范围二次确认，强制交互门禁）** → **阶段 5（目标路线确认，强制交互门禁）** → **阶段 6（目标成份信息确认，强制交互门禁）** → **阶段 7（Java应用 与 SQL 适配确认，强制交互门禁）** → **阶段 8（报告生成与源端清理）** → **阶段 9（打包与最终校验）**

> **关键约束**：
> - 阶段 4 至 7 是四个独立的强制交互门禁，**未获得用户针对本阶段的明确答复前不进入下一阶段**
> - 模型只负责整理、分析和展示候选项，**不得代替用户选择**，不得将推荐项视为已确认，也不得沿用历史答复、使用默认值代答或合并跳过任一阶段
> - 交互必须调用**运行环境的交互式提问工具**，不得以纯文本输出代替（工具映射见「调起约定与跨助手适配」）

---

## 工作目录约定

**开始任务时固定设置 `WORK_DIR=/opt/kunpeng-migration/collection`**，并创建以下目录；任务过程中不得更换。所有新建目录、日志、过程文件和输出信息统一放在该工作目录下。

```bash
WORK_DIR=/opt/kunpeng-migration/collection
mkdir -p $WORK_DIR/{work,logs,credentials,runs}
```

| 目录 | 用途 |
|------|------|
| `work/` | 配置、补充计划和临时执行文件 |
| `logs/` | 每一步命令的标准输出和错误日志 |
| `credentials/` | Linux 上的加密 SSH 凭据 |
| `runs/` | RUN_DIR、migration-plan.json 和最终采集包 |

将 `remote-hosts.conf`、`collector.env` 和补充采集计划放在 `$WORK_DIR/work`；每次执行脚本时使用 `> $WORK_DIR/logs/<步骤名>.log 2>&1` 保存完整输出，命令结束后从该日志读取结果，不得只保留在前端终端。设置 `OUTPUT_DIR=$WORK_DIR/runs`、`--local-output $WORK_DIR/runs` 和 Linux 下的 `CREDENTIAL_STORE=$WORK_DIR/credentials`。SSH 源端暂存根目录固定为 `/opt/kunpeng-migration/collection/remote`。不得在当前目录、`/tmp` 或 `/opt/kunpeng-migration/collection` 之外创建 Agent 端或源端的配置、执行文件、日志和采集结果。

---

## 计划初始化与填写规范

初始化文件：

```text
assets/migration-plan-init.json
```

新增或修改 `migration-plan.json` 字段前必须先读取 [references/migration-plan-guide.md](references/migration-plan-guide.md)。该 MD 明确采集阶段可更新和只读的字段范围及填写规则。它不参与运行期解析，也不是第二份迁移计划。运行期唯一业务计划仍为 `<RUN_DIR>/migration-plan.json`。

初始化正式 `migration-plan.json` 时生成一次 `migration_id`，作为本次系统迁移的唯一标识；后续采集、目标预检和迁移执行均复用该值，不重新生成。

开始新任务时执行：

```bash
python3 scripts/migration_plan.py init \
  --init-file assets/migration-plan-init.json \
  --output <RUN_DIR>/migration-plan.json \
  --details-archive details/devkit-source-scan-details.tar.gz
```

不得增加旧版本字段或另建 Schema、JSON 示例计划文件。字段填写必须遵循 [references/migration-plan-guide.md](references/migration-plan-guide.md)。


## 主流程

### 阶段 1：采集机器确认与计划初始化

- 用户未指明采集机器时，先询问并取得明确答复；不得自行假定采集 Agent 本机。确认本机采集或 SSH 远程采集。
- 按「计划初始化与填写规范」执行 `scripts/migration_plan.py init`，以 `assets/migration-plan-init.json` 初始化 `<RUN_DIR>/migration-plan.json` 并生成唯一 `migration_id`。

### 阶段 2：源端系统成分采集

- 执行 `scripts/collect.sh` 或 `scripts/remote-collect.sh`，默认要求采集文件系统保留 10 GiB 可用空间。SSH 远程采集必须通过 `--local-output /opt/kunpeng-migration/collection/runs` 指定 Agent 端目录，不得使用当前工作目录推导输出位置；远端用户非 root 且无免密 sudo 权限时给出警告并终止，结果回传后必须通过 SHA-256 一致性校验。密码凭据预检无需 TTY；凭据缺失时，Agent 必须调用运行环境的交互式提问工具发起单项问题，让用户通过自定义答案（Other/Type something）输入密码，不得以普通文本要求用户回复密码并结束当前执行。取得输入后通过标准输入传给 `credential-set --password-stdin`，加密保存成功后自动继续采集。`--credential` 必须与主机配置中的 `credential_id` 一致；不得复述密码或将其写入配置、报告、环境变量、命令参数及临时明文文件。

### 阶段 3：补充采集

> 阶段 2 的 `collect.sh` 已自动调用 `collect-versions.sh` 和 `collect-artifacts.sh` 完成首轮版本探测与制品采集，并构建 `file-index.tsv`。本阶段按需重跑以补充自动采集遗漏的内容。

**1. `collect-versions.sh`**——重新探测组件版本（发现新进程或需复探时重跑）：

```bash
sh scripts/collect-versions.sh --run-dir <RUN_DIR>
```

- 读取：`process-details.tsv`、`process-args.tsv`（阶段 2 产出）
- 写入：`component-versions.tsv`

**2. `collect-artifacts.sh`**——`file-index.tsv` 更新后重跑，重新采集配置和 JAR/WAR 组件：

```bash
sh scripts/collect-artifacts.sh --config <collector.env> --run-dir <RUN_DIR>
```

- 读取：`component-versions.tsv`、`file-index.tsv`（两者必须存在）
- 覆盖写入：`collected-artifacts.tsv`、`artifact-summary.env`，复制文件到 `details/artifacts/`

**3. `supplement.sh`**——按补充计划采集额外文件（配置、日志、归档等自动采集遗漏项）：

```bash
sh scripts/supplement.sh --config <collector.env> --run-dir <RUN_DIR> --plan <supplement-plan.tsv>
```

- 读取：`--plan` 补充计划 TSV、`--config` collector.env
- 追加写入：`file-index.tsv`、`collected-artifacts.tsv`，复制文件到 `details/artifacts/`


**调用顺序约束**：

- `collect-versions.sh` 必须先于 `collect-artifacts.sh`——后者依赖前者产出的 `component-versions.tsv` 做组件识别
- `supplement.sh` 追加写入 `collected-artifacts.tsv`，`collect-artifacts.sh` 覆盖写入——若两者都执行，`supplement.sh` 应在 `collect-artifacts.sh` 之后运行，避免补充条目被覆盖
- 典型顺序：`collect-versions.sh` → `collect-artifacts.sh` → `supplement.sh`

### 阶段 4：迁移范围二次确认（强制交互门禁）

- 通过调用运行环境的交互式提问工具，向用户展示拟纳入迁移的中间件、JDK/JRE 和数据库清单，取得用户二次确认后再写入对应 `route` 数组。

### 阶段 5：目标路线确认（强制交互门禁）

本阶段分两步串行，**先确认目标产品与版本，再基于已确认的目标产品查询安装包**：

**步骤 5.1 确认目标产品与版本**：根据源组件的产品和版本查询 [references/migration-route-reference.md](references/migration-route-reference.md)，获取支持的候选目标产品和目标版本，通过调用运行环境的交互式提问工具向用户确认：
   - 仅存在一条明确路线时，生成并展示待用户确认的推荐路线；
   - 存在多个目标产品或目标版本时，向用户展示全部有效候选路线并取得用户选择；
   - 用户确认后写入 `target.product` 与 `target.version`。

**步骤 5.2 确认目标安装包**：**以步骤 5.1 已确认的目标产品和版本**重新查询 [references/migration-route-reference.md](references/migration-route-reference.md)，获取该目标产品的 License 要求、安装包 URL 模板及可选目标 OS 包，通过调用运行环境的交互式提问工具向用户确认：
   - 同一目标产品和版本存在多个目标 OS 安装包时，取得用户目标 OS 选择并写入对应实际 `file_name`，不得使用通用文件名；
   - **安装包来源必须基于已确认的目标产品查询，不得使用源产品的安装包信息**（例如源 MySQL 迁移至目标 DM 时，安装包来源须查 DM 的包与 URL，不得展示 MySQL 的）；
   - 确认后写入 `packages[]` 的 `file_name`、`download_url` 等字段。

### 阶段 6：目标成份信息确认（强制交互门禁）

- 基于阶段 5 已确认的目标产品与版本，通过调用运行环境的交互式提问工具向用户逐项询问安装包来源（系统仓库 / URL 下载 / 人工提供），取得用户明确答复后写入组件 `packages[]` 的 `source_type`、`status` 等字段。**安装包来源选项必须对应已确认的目标产品，不得回退至源产品**。

### 阶段 7：Java 应用  与 SQL 适配确认（强制交互门禁）

- 对每个 Java 应用，通过调用运行环境的交互式提问工具确认并写入可迁移的 JAR/WAR 组件及 SQL 适配决策：
   - `packages[]`：至少包含一个实际采集到的 JAR/WAR 组件；
   - `packages[].local_path`：必须填写组件在采集交付中的真实路径，不允许为空；
   - `application_sql_migration.requires_sql_adaptation`：是否调用 SQL 改造流程；
   - `application_sql_migration.selected_route`：需要 SQL 改造时，先通过调用运行环境的交互式提问工具确认应用使用的源数据库，再按以下规则交互并填写用户确认的 `<源数据库> -> <目标数据库>`：
     - `route.database` 非空时，把与该应用对应的数据库迁移目标作为默认推荐，同时展示 [references/migration-route-reference.md](references/migration-route-reference.md) 中该源数据库的其他候选，并允许用户自定义输入；
     - `route.database` 为空时，根据该参考文件展示源数据库的全部默认候选，不替用户选择，并允许用户自定义输入。

### 阶段 8：报告生成与源端清理

- 生成 `collection-report.md` 和 `architecture-summary.json`。
- SSH 远程采集在最后一次同步成功后、打包前执行 `scripts/remote-collect.sh cleanup --hosts /opt/kunpeng-migration/collection/work/remote-hosts.conf --run-dir <RUN_DIR>`，删除源端本次采集结果和暂存目录；本机采集无需执行。清理失败时不得忽略或继续打包。

### 阶段 9：打包与最终校验

- 执行 `scripts/package.sh`。脚本回写 `source_environment.collection_package` 与 `source_environment.details_archive`，校验计划后生成最终采集包。

---

阶段 4 至 7 的"确认"均指用户二次确认（约束见「核心原则」与「整体流程」）。每一步都向用户展示当前阶段的候选信息，收到明确答复后才进入下一阶段；交互必须调用运行环境的交互式提问工具（工具映射见「调起约定与跨助手适配」）。等待答复时仅暂停在当前门禁，保留 `WORK_DIR`、`RUN_DIR` 和已完成结果，不得退出或结束当前任务，也不得把等待视为失败；收到答复后在同一任务中从当前门禁自动续跑，直至下一门禁或流程完成。

---

## 调起约定与跨助手适配

阶段 4 至 7 的"确认"一律调用**运行环境的交互式提问工具**提交结构化 question（含 `id`/`prompt`/`options`）并阻塞等待用户真实回复，**不是在回复正文里打问句**。工具按所用运行环境映射，不得以纯文本输出代替：

| 编程助手 | 交互式提问工具 |
|----------|----------------|
| Claude Code | `AskUserQuestion`（阻塞） |
| Trae | `AskUserQuestion` |
| CatPaw IDE | `AskQuestion` |
| OpenCode | `question` |

> 本 Skill 正文一律用「调用运行环境的交互式提问工具」「向用户提问」等语义动词表述，运行时按上表映射到所用助手的对应工具。其中「确认」是唯一可能被纯文本输出"假装"完成的动作——**必须落到上表工具，不得用回复正文代替**。每个独立决策点 = 一个 question 条目；单次提问上限不足时（多数助手单次最多 4 个 question）分批提问，每批不超过 4 个。

对于"系统包安装组件"，阶段 4 仅确认是否迁移该组件，阶段 5 步骤 5.2 确认安装来源（须基于步骤 5.1 已确认的目标产品）。若用户选择系统仓库安装，则跳过阶段 6 的版本和 URL 确认，但仍正常回填 `packages[].version` 和 `download_url`；无法精确匹配版本时，使用路线表中同一目标产品的最高具体版本作为推荐版本。若选择 URL 下载，则正常进入阶段 6。

---

## 迁移计划填写规则

迁移计划填写规则见 [references/migration-plan-filling-rules.md](references/migration-plan-filling-rules.md)（含中间件和数据库、Java应用、迁移工具三部分的字段约束与行为规则）。逐字段 schema 规范见 [references/migration-plan-guide.md](references/migration-plan-guide.md)。

---

## 最终校验

```bash
python3 scripts/migration_plan.py validate \
  --plan <RUN_DIR>/migration-plan.json \
  --phase collector-final
```

最终交付至少包含：

```text
migration-plan.json
collection-report.md
details/devkit-source-scan-details.tar.gz
```

最终采集结果页面的第一行必须先展示 `migration-plan.json` 的绝对地址：

```text
migration-plan.json: <RUN_DIR>/migration-plan.json
```

然后再展示采集报告、详细归档和最终采集包等其他结果地址。

详细采集、路线和制品规则见 [references/collector-guide.md](references/collector-guide.md)。
