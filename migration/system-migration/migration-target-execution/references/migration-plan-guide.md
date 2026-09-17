# migration-plan.json 执行阶段更新规范

## 1. 适用范围

本文件用于规范目标环境准备与迁移执行阶段对源端交付 `migration-plan.json` 的读取和更新。

执行阶段继续使用源端交付的同一份计划，不重新构造源端采集事实和迁移路线。

执行阶段的字段范围：

- `migration_id`：只读，与 `target_environment.migration_work_dir` 共同确定本次迁移工作目录。
- `source_environment`：整体只读。
- `target_environment`：在目标环境检查和迁移工具准备期间，根据实际结果更新。
- `route.middleware[]`：对象、源端信息和目标路线只读；目标组件包的获取与准备信息可在计划确认前更新。
- `route.database[]`：对象、源端信息和目标路线只读；目标组件包的获取与准备信息可在计划确认前更新。
- `route.application[]`：整体只读。
- 操作计划获得确认后，整个 `migration-plan.json` 转为只读。

如果确认后需要修改计划，应停止当前迁移，根据新的实际情况更新计划并重新完成确认，不能直接修改后继续执行。

---

## 2. `migration_id`

执行阶段只读取该值，不重新生成或修改。统一运行目录为 `<target_environment.migration_work_dir>/<migration_id>`。

---

## 3. `source_environment`

整个 `source_environment` 只读。

### `source_environment.collection_package`

用于定位源端采集交付包。路径不可用时应报告交接问题，不修改为其他含义或使用伪造路径绕过检查。

### `source_environment.details_archive`

用于定位源端详细采集归档，执行阶段不修改。

---

## 4. `target_environment`

本节字段在目标环境检查和迁移工具准备期间根据实际结果更新。只写真实探测、实际准备或已验证的值，不根据源端信息猜测目标机环境。

### `target_environment.hostname`

填写目标机实际主机名。

### `target_environment.primary_ip`

填写目标机实际主 IP。

### `target_environment.os`

填写目标机实际操作系统信息。

### `target_environment.architecture`

填写目标机实际架构，并满足迁移执行要求的 `aarch64/arm64`。

### `target_environment.kernel`

填写目标机实际内核信息。

### `target_environment.glibc`

填写目标机实际 glibc 信息。

### `target_environment.package_manager`

填写目标机实际可用的包管理器。

### `target_environment.privilege`

填写目标机实际可用的 root/sudo 权限状态。

### `target_environment.java`

#### `target_environment.java.installed`

填写目标机 Java 实际安装状态。

#### `target_environment.java.version`

填写目标机实际 Java 版本。

#### `target_environment.java.command`

填写已经验证可执行的 Java 命令或路径。

### `target_environment.network`

#### `target_environment.network.status`

填写实际网络探测结果。

#### `target_environment.network.probe_url`

记录实际用于网络探测的 URL，不填写未验证地址。

### `target_environment.migration_work_dir`

保存统一工作目录的绝对基础路径。初始化模板默认值为 `/opt/kunpeng-migration/work`；目标执行各模块只从计划读取，不通过命令行参数或环境变量覆盖。执行期完整目录为该字段下的 `<migration_id>` 子目录。该字段在目标预检和后续执行阶段只读。

### `target_environment.free_space_bytes`

填写目标包目录所在文件系统的实际可用空间。

### `target_environment.migration_tools[]`

该数组是迁移工具包清单。一个条目表示一个包含多个工具的包，不表示单个工具，也不表达工具依赖关系。字段固定为：

- `id`：工具包唯一标识；
- `package_name`：工具包名称；
- `version`：工具包版本；
- `type`：工具包类型，只允许 `ARCHIVE` 或 `FILE`。`ARCHIVE` 需要展开，`FILE` 直接作为工具文件使用；
- `file_name`：工具包文件名；
- `download_url`：已确认的HTTPS下载地址；
- `local_path`：仅表示用户提供的原始本地工具包来源；预检复制或下载后的工作副本固定在 `$MIGRATION_WORK_DIR/tools/packages/<package-id>/<file_name>`，不回写该字段；
- `status`：工具包准备状态，只允许 `PENDING_DOWNLOAD/PENDING_UPLOAD/URL_REQUIRED/READY`；
- `tools`：工具包内包含的工具提示清单，每项只允许 `name`。名称可包含必要版本信息，例如 `Vineflower 1.12`。该字段不表达依赖关系，也不保存命令、路径或运行参数。

`tool_name/package/command/jar/java_runtime/runtime_dir` 属于旧的单工具模型，不再支持。`type` 现用于描述工具包是 `ARCHIVE` 还是 `FILE`。`migration_tools[]` 中出现的全部工具包都进入预检manifest并必须满足准备与解析要求，不再按迁移路线筛选。预检只更新 `status`，`download_url/local_path/tools[].name` 均保持只读，工具运行入口固定在 `tools` 内形成，不写入迁移计划。

工具是否必须准备由 `migration_tools[]` 的声明本身决定：凡出现在该数组中的工具包都必须达到 `READY` 并完成工具解析；业务路线只决定是否要求某类工具必须出现在计划中，不再决定已声明工具是否跳过准备。`ARCHIVE` 类型从 `tools/unpacked` 的展开内容解析，`FILE` 类型直接从 `tools/packages/<package-id>/` 的工作副本解析。工具包工作副本固定从 `tools/packages/<package-id>/<file_name>` 定位，`local_path` 始终保留原始来源，不作为运行时工作副本路径。缺少工具时直接阻塞，不从系统PATH、环境变量、目标JDK或其它目录补充，也不下载清单外工具包。

---

## 4. `route`

执行阶段不重新规划迁移对象。目标预检只允许更新中间件、数据库包和迁移工具包的 `status`（以及经校验的 License 路径）；`packages[].source_type/download_url/local_path` 与 `migration_tools[].download_url/local_path` 保持采集阶段确认值。`route.application[]` 整体只读。

### 4.1 `route.middleware[]`

以下内容保持只读：

- `id`
- `classification`
- `source.product`
- `source.version`
- `source.location`
- `source.artifact_paths[]`
- `target.product`
- `target.version`

源端事实或目标路线需要改变时，应作为计划变更重新确认，不在执行过程中直接改写。

#### `packages[]`

目标组件包中，以下字段保持只读：

- `packages[].id`
- `packages[].type`
- `packages[].version`
- `packages[].file_name`
- `packages[].license_required`

计划确认前可根据实际包获取和准备情况更新：

- `packages[].source_type`
- `packages[].download_url`
- `packages[].local_path`
- `packages[].status`
- `packages[].license_path`

##### `packages[].source_type`

只允许：

```text
SYSTEM_REPOSITORY
OFFICIAL
MANUAL
```

正常情况下保持源端已确认值。需要改变包获取方式时，应有明确依据并在计划确认前完成调整，不自动切换来源。

##### `packages[].download_url`

- `SYSTEM_REPOSITORY`：保持空值。
- `OFFICIAL`：使用真实、已确认且可验证的 HTTPS URL。
- `MANUAL`：保持空值。

不得猜测或拼接下载地址。

##### `packages[].local_path`

下载、发现已有文件或人工准备完成后，填写目标机真实文件路径。`SYSTEM_REPOSITORY` 保持空值。

##### `packages[].status`

根据真实准备结果更新，只允许：

```text
PENDING_DOWNLOAD
PENDING_UPLOAD
URL_REQUIRED
READY
NOT_REQUIRED
MISSING
```

典型状态：

- `SYSTEM_REPOSITORY` → `NOT_REQUIRED`
- 文件实际存在且可用 → `READY`
- `OFFICIAL` 缺少可用 URL → `URL_REQUIRED`
- `MANUAL` 文件尚未准备 → `PENDING_UPLOAD`

不得为了通过检查将未准备完成的组件写为 `READY`。

##### `packages[].license_path`

仅当 `license_required=true` 时使用。提示用户将单个 License 文件上传到
`$MIGRATION_WORK_DIR/licenses/<component-id>/<package-id>/`；用户确认上传后必须二次校验。只有该目录中存在唯一、非空且可读的文件时，才将实际文件绝对路径写入此字段。未上传、未检出或检测到多个文件时保持为空并再次提示，但不得作为迁移预检阻塞项。

### 4.2 `route.database[]`

以下内容保持只读：

- `id`
- `classification`
- `source.product`
- `source.version`
- `source.location`
- `source.artifact_paths[]`
- `target.product`
- `target.version`

数据库源端事实或目标产品、版本需要改变时，应作为计划变更重新确认。

#### `packages[]`

目标组件包中，以下字段保持只读：

- `packages[].id`
- `packages[].type`
- `packages[].version`
- `packages[].file_name`
- `packages[].license_required`

计划确认前可根据实际包获取和准备情况更新：

- `packages[].source_type`
- `packages[].download_url`
- `packages[].local_path`
- `packages[].status`
- `packages[].license_path`

##### `packages[].source_type`

只允许 `SYSTEM_REPOSITORY`、`OFFICIAL`、`MANUAL`。正常情况下保持已确认值；需要改变获取方式时应作为计划调整处理。

##### `packages[].download_url`

`OFFICIAL` 使用真实、已确认且可验证的 HTTPS URL；`SYSTEM_REPOSITORY` 和 `MANUAL` 保持空值。

##### `packages[].local_path`

安装包实际准备完成后填写目标机真实路径；`SYSTEM_REPOSITORY` 保持空值。

##### `packages[].status`

按照真实准备结果更新，使用与中间件目标组件包相同的状态集合和判断规则。

##### `packages[].license_path`

使用与中间件目标组件包相同的上传目录、用户交互、二次校验和非阻断规则。

### 4.3 `route.application[]`

整个 `route.application[]` 在执行阶段保持只读，包括：

- `id`
- `classification`
- `product`
- `version`
- `install_location`
- `packages[]`
- `application_sql_migration.selected_route`
- `application_sql_migration.requires_sql_adaptation`

`install_location` 仅作为源端应用安装/部署位置参考，不用于定位JAR/WAR组件。每个应用至少包含一个 JAR/WAR 组件；每个组件的 `packages[].local_path` 必须为非空路径，并作为Java迁移定位JAR/WAR组件的唯一计划字段。Java迁移按 `packages[]` 逐组件执行并形成独立工作目录与结果。Java迁移直接使用既有SQL迁移决策执行。应用组件或SQL路线不可用时，应报告阻塞或发起计划变更，不在正式迁移过程中静默改写计划。

`route.application[]` 仅允许 `id`、`classification`、`product`、`version`、`install_location`、`packages[]`、`application_sql_migration`。`native_replacements`、`archive_mutations`、`java_compile` 均不属于计划字段；归档变更位于单个组件运行目录，编译参数由迁移流程确定。

---

## 5. 执行阶段可更新字段范围

在操作计划确认前，可更新的 `migration-plan.json` 字段范围为：

```text
target_environment.hostname
target_environment.primary_ip
target_environment.os
target_environment.architecture
target_environment.kernel
target_environment.glibc
target_environment.package_manager
target_environment.privilege
target_environment.java.*
target_environment.network.*
target_environment.free_space_bytes
target_environment.migration_tools[].download_url
target_environment.migration_tools[].local_path
route.middleware[].packages[].source_type
route.middleware[].packages[].download_url
route.middleware[].packages[].local_path
route.middleware[].packages[].status
route.middleware[].packages[].license_path
route.database[].packages[].source_type
route.database[].packages[].download_url
route.database[].packages[].local_path
route.database[].packages[].status
route.database[].packages[].license_path
```

其中 `download_url` 和 `source_type` 的变化属于计划内容调整，只在有明确依据时修改，不根据运行失败自动切换。

操作计划确认后，整个 `migration-plan.json` 只读。数据库、中间件和 Java 的运行状态、迁移结果、补丁和验证结果写入各自的执行结果中，不继续追加到迁移计划。
