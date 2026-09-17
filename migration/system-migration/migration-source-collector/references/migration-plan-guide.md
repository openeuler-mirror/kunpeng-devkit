# migration-plan.json 采集阶段填写规范

## 1. 适用范围

本文件用于规范源端成分采集与迁移路线确认阶段对 `migration-plan.json` 的创建和更新。

运行期唯一迁移计划为 `<RUN_DIR>/migration-plan.json`，`assets/migration-plan-init.json` 仅用于初始化结构。

采集阶段的字段范围：

- `migration_id`：初始化时生成，后续保持不变。
- `source_environment`：填写源端采集交付信息。
- `target_environment`：整体只读，保持初始化值，不写入目标机实际环境信息。
- `route.middleware[]`：根据采集结果和确认后的迁移路线新增、修改或删除。
- `route.database[]`：根据采集结果和确认后的迁移路线新增、修改或删除。
- `route.application[]`：根据采集结果和确认后的迁移路线新增、修改或删除。
- 不新增未定义的根字段，不引入旧版本兼容字段，不生成第二份迁移计划。

每次更新前先读取当前 `migration-plan.json`，已有对象按 `id` 定位后修改，避免重新构造整份计划导致已有信息丢失。

---

## 2. `migration_id`

初始化正式 `migration-plan.json` 时生成一次，用于唯一标识本次系统迁移。迁移过程中保持不变，不根据路由、目标环境或包准备状态重新生成。

---

## 3. `source_environment`

### `source_environment.collection_package`

记录最终采集交付包路径。

- 初始化时保持 `null`。
- 采集包实际生成后再写入真实路径。
- 不得提前填写、猜测或填写不存在的路径。
- 最终交付前必须能够对应到实际采集包。

### `source_environment.details_archive`

记录详细采集结果归档在采集交付中的位置。

- 使用真实存在的归档路径，优先使用相对路径。
- 示例：`details/devkit-source-scan-details.tar.gz`。
- 归档位置发生变化时同步更新。
- 最终交付前必须有值。

---

## 4. `target_environment`

采集阶段整个 `target_environment` 保持只读。`migration_work_dir` 由初始化模板提供目标执行工作目录的绝对基础路径，采集阶段不得清空或改写。

不得根据源机环境推断或填写目标机的主机名、IP、操作系统、架构、内核、glibc、包管理器、权限、Java 环境、网络状态、可用空间和迁移工具运行信息；已有初始化值、`migration_work_dir` 和工具声明保持不变。

---

## 4. `route`

### 4.1 `route.middleware[]`

只保留已确认纳入迁移范围的中间件。每个对象的 `id` 必须稳定且唯一，已有对象后续更新继续使用原 `id`。

#### `id`

- 必须唯一且稳定。
- 允许字母、数字、`.`、`_`、`-`。
- 长度不超过 128，首字符为字母或数字。

#### `classification`

只允许：

```text
primary
likely
candidate
manual
```

#### `source`

##### `source.product`

填写实际识别到的源端中间件产品名称，不得猜测。

##### `source.version`

填写实际探测或确认到的版本；无法确认时保持空值。

##### `source.location`

填写源端真实部署、安装或执行位置。

##### `source.artifact_paths[]`

填写已采集的配置、制品或其他迁移所需文件路径，优先使用采集交付包内的相对路径。

#### `target`

##### `target.product`

填写已确认的目标中间件产品，不根据现有脚本、经验或默认值自行选择。

##### `target.version`

填写已确认的目标版本；无法确认时保持空值。

#### `packages[]`

用于描述目标中间件安装所需组件包。目标组件包的 `type` 固定为 `TARGET_COMPONENT`。

##### `packages[].id`

必须唯一且稳定。

##### `packages[].type`

固定为：

```text
TARGET_COMPONENT
```

##### `packages[].version`

填写与目标组件对应的版本。

##### `packages[].file_name`

- `SYSTEM_REPOSITORY`：填写系统仓库包名，例如 `nginx`、`redis`。
- `OFFICIAL`、`MANUAL`：填写实际安装包文件名。

##### `packages[].source_type`

只允许：

```text
SYSTEM_REPOSITORY
OFFICIAL
MANUAL
```

含义：

- `SYSTEM_REPOSITORY`：通过目标系统软件仓库安装，不需要提前准备安装文件。
- `OFFICIAL`：从已确认的下载地址获取安装文件。
- `MANUAL`：需要人工准备安装文件。

##### `packages[].download_url`

- `SYSTEM_REPOSITORY`：不作为系统仓库安装的前置条件；优先填写精确匹配的 HTTPS URL，无法精确匹配时填写同一目标产品最高具体版本的URL作为备用来源。
- `OFFICIAL`：填写已经确认可用的 HTTPS 下载地址，不得拼接或猜测。
- `MANUAL`：保持空值。

##### `packages[].local_path`

通常保持空值，待目标侧实际准备安装包后更新。仅在目标侧文件位置已经明确且真实存在时填写，不得把源机绝对路径作为目标机路径。

##### `packages[].status`

只允许：

```text
PENDING_DOWNLOAD
PENDING_UPLOAD
URL_REQUIRED
READY
NOT_REQUIRED
MISSING
```

建议初始状态：

- `SYSTEM_REPOSITORY` → `NOT_REQUIRED`
- `OFFICIAL` 且 URL 已确认 → `PENDING_DOWNLOAD`
- `OFFICIAL` 且 URL 未确认 → `URL_REQUIRED`
- `MANUAL` → `PENDING_UPLOAD`

没有真实文件或仓库条件支撑时不得填写 `READY`。

`URL_REQUIRED` 只允许在采集过程暂存；最终交付前必须补充真实 HTTPS URL 并改为对应状态，`collector-final` 不接受 `URL_REQUIRED`。

源组件由 `rpm-owner`、`rpm-package`、`deb-owner` 或 `deb-package` 识别时，不校验源版本，并始终优先推荐系统仓库安装，同时允许用户改选URL下载。选择系统仓库时使用 `SYSTEM_REPOSITORY` 和 `NOT_REQUIRED`，`file_name` 填写系统包名，`local_path` 及目标版本保持空值；优先按已有 `target.version` 或 `packages[].version` 回填URL，无法精确匹配时使用路线表中同一目标产品的最高具体版本回填 `packages[].version` 和 `download_url`。选择URL时按普通组件填写 `OFFICIAL`、实际URL和 `PENDING_DOWNLOAD`。

##### `packages[].license_required`

根据目标软件是否需要授权填写布尔值。

### 4.2 `route.database[]`

只保留已确认纳入迁移范围的数据库。每个对象的 `id` 必须稳定且唯一。

#### `id`

必须唯一且稳定。

#### `classification`

只允许：

```text
primary
likely
candidate
manual
```

#### `source`

##### `source.product`

填写实际识别到的源数据库产品。

##### `source.version`

填写实际探测或确认到的版本；无法确认时保持空值。

##### `source.location`

填写源端真实安装、数据或部署位置。

##### `source.artifact_paths[]`

填写已采集的配置、导出物或其他数据库迁移制品路径，优先使用采集交付包内相对路径。

#### `target`

##### `target.product`

填写已确认的目标数据库产品。数据库替换路线必须有明确依据，例如 MySQL → DM。

##### `target.version`

填写已确认的目标版本。

#### `packages[]`

用于描述目标数据库安装所需组件包，字段规则与中间件目标组件包一致。

##### `packages[].id`

必须唯一且稳定。

##### `packages[].type`

固定为：

```text
TARGET_COMPONENT
```

##### `packages[].version`

填写目标数据库安装包对应版本。

##### `packages[].file_name`

填写实际安装包文件名；使用系统仓库时填写包名。

##### `packages[].source_type`

只允许：

```text
SYSTEM_REPOSITORY
OFFICIAL
MANUAL
```

##### `packages[].download_url`

`OFFICIAL` 只填写真实、已确认的 HTTPS URL；`SYSTEM_REPOSITORY` 和 `MANUAL` 保持空值。

##### `packages[].local_path`

通常保持空值，待目标侧实际准备安装包后更新。不得使用源机绝对路径作为目标机安装包路径。

##### `packages[].status`

使用与中间件目标组件包一致的状态集合和初始状态规则。

##### `packages[].license_required`

根据目标数据库授权要求填写布尔值。

商业数据库没有稳定可用下载地址时使用 `MANUAL`，不得伪造下载 URL。

### 4.3 `route.application[]`

只保留已确认纳入迁移范围的 Java 应用。系统迁移直接处理采集到的 JAR/WAR 组件，不采集源码目录。每个对象的 `id` 必须稳定且唯一。

#### `id`

必须唯一且稳定。

#### `classification`

只允许：

```text
primary
likely
candidate
manual
```

#### `product`

填写应用名称或已识别的产品名称。

#### `version`

填写实际采集或确认的版本；无法确认时保持 `null`。

#### `install_location`

填写源端应用实际安装或部署位置，作为部署上下文参考。该字段不表示 JAR/WAR 组件存放地址，也不用于定位迁移输入组件。

#### `packages[]`

用于描述源端 JAR/WAR 组件。至少包含一个组件，`type` 固定为 `SOURCE_COMPONENT`。

##### `packages[].id`

必须唯一且稳定。

##### `packages[].type`

固定为：

```text
SOURCE_COMPONENT
```

##### `packages[].file_name`

填写真实 JAR/WAR 文件名，仅允许 `.jar` 或 `.war`。

##### `packages[].local_path`

填写 JAR/WAR 组件在采集交付中的真实存放路径，不允许为空，优先使用相对路径。Java应用迁移通过该字段定位组件。

##### `packages[].license_required`

根据应用组件实际授权要求填写，通常为 `false`。

应用对象只允许 `id`、`classification`、`product`、`version`、`install_location`、`packages[]`、`application_sql_migration` 这些正式字段。`native_replacements`、`archive_mutations`、`java_compile` 不写入 `migration-plan.json`：归档条目变更属于单个 JAR/WAR 组件的运行时数据，编译参数由 Java 迁移流程自动确定。

#### `application_sql_migration`

##### `application_sql_migration.selected_route`

仅在 `requires_sql_adaptation=true` 时填写用户确认的明确路线，格式为 `<源数据库> -> <目标数据库>`。`route.database` 非空时默认推荐与对应数据库迁移目标一致的路线，但必须同时允许用户选择该源数据库的其他候选或自定义输入；`route.database` 为空时，按 `migration-route-reference.md` 展示源数据库的默认候选并由用户选择，也允许自定义输入。不得把推荐项直接视为用户确认结果。

##### `application_sql_migration.requires_sql_adaptation`

根据应用 SQL 和数据库适配确认结果填写布尔值。

---

## 5. 完成要求

采集阶段完成后应确保：

- 源端事实均有实际采集依据；
- 迁移目标和应用SQL适配决策均已确认；
- 未确认信息保持空值或对应待处理状态，不使用猜测值补齐；
- `target_environment` 未被采集阶段改写；
- `migration-plan.json` 通过采集阶段完整性校验。

采集交付完成后，本阶段不再继续修改 `migration-plan.json`。
