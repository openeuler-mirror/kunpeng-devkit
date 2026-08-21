# 迁移计划填写规则

> 本文件规范采集阶段对 `migration-plan.json` 各 `route` 节点和 `migration_tools` 的填写行为约束。逐字段 schema 规范见 [migration-plan-guide.md](migration-plan-guide.md)。

---

## 1. 中间件和数据库

**每项必须包含的字段**：

- 唯一 `id`
- `classification`
- `source.product/version/location/artifact_paths`
- `target.product/version`
- `packages[]`

**`source.artifact_paths[]` 规则**：

- 只保存相对采集目录或绝对路径字符串

**目标安装包对象**：

- 必须保留初始化结构中定义的字段
- 采集阶段 `status` 可使用：`PENDING_DOWNLOAD`、`PENDING_UPLOAD`、`URL_REQUIRED`、`READY`、`NOT_REQUIRED`

**`packages[].source_type` 取值**：

- `SYSTEM_REPOSITORY`：目标组件由目标机系统仓库安装
  - 不要求准备本地安装包；仍填写 `download_url` 作为备用来源
  - 无法精确匹配版本时，使用同一目标产品的最高具体版本
  - 适用于 Nginx、Redis 等实际迁移策略会先走 yum/dnf 的组件
- `OFFICIAL`：从计划中明确的 HTTPS `download_url` 获取文件
  - 不区分厂商官网、镜像站或内部下载地址
  - URL 未确定时使用 `URL_REQUIRED`
- `MANUAL`：仅当用户选择自定义版本，且在镜像仓和官网均未找到对应安装包时使用
  - 要求用户把文件放到 `local_path`
  - 目标检查阶段发现目标环境无网络时，可提示用户从已确认地址下载后上传到指定目录（该情况不在本 Skill 中处理）
  - 不得因产品为 TongWeb、DM8 等商业软件而默认使用 `MANUAL`

**系统包安装组件判定**（`component-versions.tsv` 的 `detection_method` 为 `rpm-owner`/`rpm-package`/`deb-owner`/`deb-package` 时）：

- 阶段 4 只询问是否纳入迁移，不要求用户校验源版本
- 确认迁移后，阶段 5 必须：
  - 忽略版本及路线表是否命中
  - 始终把"目标系统 yum/dnf/apt 仓库安装"作为第一项和默认推荐
  - 同时提供"从已确认 URL 下载安装包"选项
  - 不得因路线表只有 URL 或版本未命中而省略系统仓库选项
- 用户选择系统仓库时：
  - 写入 `source_type=SYSTEM_REPOSITORY`、`status=NOT_REQUIRED`
  - `file_name` 使用系统包名，`local_path` 和目标版本保持空值
  - 优先按已有 `target.version` 或 `packages[].version` 回填 URL
  - 无法精确匹配时，使用路线表中同一目标产品的最高具体版本回填 `packages[].version` 和 `download_url`，但不改变系统仓库安装方式
- 用户选择 URL 时：
  - 按普通路线执行目标版本和安装包确认
  - 写入 `source_type=OFFICIAL`、`status=PENDING_DOWNLOAD`

**`source_type` 限制**：

- 只允许上述三种值，其他值均视为无效

**JDK/JRE 归属**：

- 统一作为中间件写入 `route.middleware[]`
- 不得写入 `route.application[]`、`route.database[]` 或采集阶段的 `target_environment.java`
- 目标产品和版本按中间件路线规则展示候选并由用户二次确认

---

## 2. Java应用

- `install_location` 记录源端应用安装/部署参考路径，不作为 JAR/WAR 组件定位依据
- JAR/WAR 组件写入 `packages[]`，类型固定为 `SOURCE_COMPONENT`
- 每个纳入系统迁移的 Java 应用至少包含一个 JAR/WAR 组件
- 每个 `packages[].local_path` 必须填写组件在采集交付中的非空真实存放路径
- 系统迁移直接基于这些 JAR/WAR 组件执行应用迁移，不采集或使用源码路径

---

## 3. 迁移工具

**声明位置**：目标迁移辅助工具包统一声明在 `target_environment.migration_tools[]`

**包字段**：`id` / `package_name` / `version` / `type` / `file_name` / `download_url` / `local_path` / `status` / `tools`

**`tools[]` 规则**：

- 只保留 `name`，用于提示工具所在的工具包
- 不保存运行命令、路径、依赖关系或其它参数

**目标预检处理**：

- 本地工具包复制、下载工具包保存到 `tools/packages`
- `type=ARCHIVE` 的工具包展开到 `tools/unpacked`
- `type=FILE` 的条目直接作为工具文件使用

**校验要求**：

- `migration_tools[]` 中出现的每个工具包都是迁移执行必需项
- 均进入目标预检准备和校验，不再按迁移路线跳过

**`status` 取值**：只允许 `PENDING_DOWNLOAD` / `PENDING_UPLOAD` / `URL_REQUIRED` / `READY`

**解析目录**：所有系统迁移工具只从统一 `tools` 目录解析
