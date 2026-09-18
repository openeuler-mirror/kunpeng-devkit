# 阶段 1：环境检测与准备

本阶段用于检测鲲鹏目标环境的编译器、构建工具和基础依赖，对不满足要求的项自动修复（安装/升级），准备编译环境，确保项目在鲲鹏上具备编译条件。

**执行方式**：
- 作为 cpp-kunpeng-migration 主 Skill 的阶段 1 子 Skill 调用，由主 agent 以子 agent 模式拉起执行（调用方式见主 SKILL 文末「调起约定与跨助手适配」）。当用户需要单独执行环境检测、检查构建工具版本兼容性、准备鲲鹏编译环境、或处理 Blade/Bazel 版本不匹配时也可直接调用本子 Skill。

**子 agent 边界**：
- 子 agent **不向用户提问**，检测到的版本不一致项按「子 agent 待确认项输出契约」写入 `$WORK_DIR/reports/stage_1_pending_items.md`，由主 agent 在阶段 3 统一提问。

**输入参数**：

本子 Skill 接收以下三个路径变量作为输入：

- `<项目绝对路径>` -> `PROJECT_ROOT`
- `<工作目录绝对路径>` -> `WORK_DIR`
- `<skill目录绝对路径>` -> `SKILL_DIR`（cpp-kunpeng-migration skill 目录）

- `SKILL_DIR`：本 skill 自知（cpp-kunpeng-migration 目录 = 本子 skill 目录的上一层）。
- `PROJECT_ROOT`、`WORK_DIR`：主 agent 调用时由主 agent 传入；独立调用时优先从用户提示词取，未提供则向用户提问获取。

# 使用流程

## 1. 收集系统环境信息

在 **鲲鹏目标环境** 收集基线信息：gcc 版本、glibc 版本、内核版本、操作系统发行版并记录。


### 1.1 检查磁盘可用空间

在 **鲲鹏目标环境** 检查项目根目录所在分区的可用磁盘空间。迁移过程涉及依赖源码签出、子模块更新、构建工具下载、编译产物和编译日志写入，空间不足会导致中途失败。所需空间与项目代码规模相关，需先统计代码大小再动态估算阈值。

```bash
# 统计项目代码文件大小（排除 .git、构建产物等），单位 MB
du -sm --exclude=.git --exclude=build --exclude=out $PROJECT_ROOT | awk '{print $1}'

# 检查项目根目录所在分区可用空间
df -h $PROJECT_ROOT
```

**空间阈值估算规则**：

基于项目代码大小动态估算所需可用空间，公式如下：

| 组成 | 估算 | 说明 |
|------|------|------|
| 编译产物（.o 文件、链接产物） | 代码大小 × 3 | C/C++ 编译产物通常为源码的 3-5 倍 |
| 依赖源码下载与编译 | 代码大小 × 1 | 第三方依赖签出与临时编译 |
| DevKit 扫描产物、编译日志等 | 代码大小 × 1 | 扫描报告、多轮编译日志 |
| **合计建议可用空间** | **代码大小 × 5**（最低 1 GB） | |

> 示例：项目代码 200 MB -> 建议可用空间 ≥ 1 GB（取最低阈值）；项目代码 500 MB -> 建议可用空间 ≥ 2.5 GB；项目代码 2 GB -> 建议可用空间 ≥ 10 GB。

**判定规则**：

- 可用空间**低于估算阈值**时，作为待确认项写入 `$WORK_DIR/reports/stage_1_pending_items.md`，由主 agent 在阶段 3 统一向用户提问
- 待确认项需注明：代码大小、估算所需空间、当前可用空间、不足差额，供用户判断是更改产物落盘地址还是中止
- **严禁**自行删除项目或系统文件释放空间，也**不向用户提问**，一律写入待确认项文件

## 2. 识别构建系统

扫描项目根目录，识别项目使用的构建系统。查找以下标志文件：

| 标志文件                              | 构建系统  |
| --------------------------------- | ----- |
| `Makefile`、`makefile`、`*.mk`      | Make  |
| `CMakeLists.txt`、`*.cmake`        | CMake |
| `WORKSPACE`、`BUILD`、`BUILD.bazel` | Bazel |
| `BLADE_ROOT`、`BUILD`、`BLADE`      | Blade |
| `SConstruct`、`SConscript`         | SCons |

如果检测到多个构建系统，根据根目录级别的文件判断主构建系统。

## 3. 检查构建工具版本和可用性

在 **鲲鹏目标环境** 检查构建工具版本。**不强制检查所有工具**，而是根据第 2 节识别出的项目构建系统，按需检查对应工具的版本（如 Make、CMake、Bazel、SCons）；若项目依赖 JDK，确认是否为毕昇 JDK 及其版本。

如果构建工具未安装或版本不满足要求，**自动尝试安装**（安装流程见第 4 节对应构建系统的参考文档），安装时按 [build-tools-reference.md](references/build-tools-reference.md) 中的链接选取规则下载：优先使用内部定制版下载链接，若无内部定制版，使用官方下载链接

## 4 按需处理特定构建系统

若第 2 节识别出项目使用 **Blade** 或 **Bazel**，按需加载对应参考文档执行额外处理：

- Blade：加载 [blade-handling.md](references/blade-handling.md)
- Bazel：加载 [bazel-handling.md](references/bazel-handling.md)

## 5 识别 Protobuf 版本

如项目使用 Protobuf，识别项目所用的 protobuf 版本，并确保鲲鹏环境的 protoc 与之匹配--版本不一致时**自动为鲲鹏编译安装匹配版本的 protoc**。

> 完整检测与编译安装步骤见 [protobuf-version-check.md](references/protobuf-version-check.md)。

**关键约束**：即使鲲鹏系统已安装更高版本的 protobuf，也**绝不升级项目使用的 protobuf 版本**，只为鲲鹏编译安装匹配版本的 protoc 二进制即可--升级项目 protobuf 会破坏兼容性。

## 6 生成环境检测与修复报告

完成以上所有检查和修复后，生成汇总报告。

**报告模板**

见 [environment-check-report-template.md](assets/environment-check-report-template.md)。

将此报告保存到工作目录中，文件名为 `$WORK_DIR/reports/environment_check_report.md`。

---

## 输出要求（硬性约束）

1. **必须**将环境检测报告写入文件 `$WORK_DIR/reports/environment_check_report.md`
2. **必须**将待确认项写入文件 `$WORK_DIR/reports/stage_1_pending_items.md`（格式见下方）
3. 即使无待确认项，也必须写入空清单并标注"无待确认项"
4. **严禁**向用户提问（你没有向用户提问的权限，需用户决策的项一律写入待确认项文件，由主 agent 在阶段 3 统一提问）
5. **严禁**修改项目源码或构建配置（你只做检测和报告）
6. 完成后，在你的最终回复中输出：
   - 环境检测结论（是否具备编译条件）
   - 识别到的构建系统类型
   - 待确认项数量
   - 报告文件路径

## 待确认项格式

见 [pending-items-template.md](assets/pending-items-template.md)。

现在开始执行阶段 1 环境检测。
