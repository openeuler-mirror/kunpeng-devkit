# ARM 迁移总结报告

> 项目：<PROJECT_ROOT>
> 构建系统：<Bazel/CMake/Make/Blade/SCons>
> 迁移日期：<开始日期 ~ 结束日期>
> 最终状态：编译成功

---

## 一、重要提示与建议

<第4节 重要提示与建议>

---

## 二、各阶段执行时长

<第1节 各阶段执行时长表格>

---

## 三、修改文件清单

<第2节 修改文件清单>

### 修改统计
- 修改文件总数：<N>
- 源码文件：<N>
- 构建配置文件：<N>
- 其他：<N>

### 未包含在 patch 中的二进制文件改动

> 以下二进制文件改动未纳入 `migration.patch`，需单独处理。完整列表见 `$WORK_DIR/reports/binary_changes.txt`。

| 文件路径 | 改动类型 | 处理建议 |
|---------|---------|---------|
| <路径> | 新增/修改/删除 | 重新编译 / 从 Kunpeng 环境获取 / 随依赖包分发 |

---

## 四、迁移过程摘要

| 阶段 | 关键结果 |
|------|---------|
| 1 环境检测 | <识别的构建系统、安装/升级的工具及版本> |
| 2 依赖分析 | <依赖总数、命中免检清单数、待确认数> |
| 3 用户确认 | <确认项数、切换依赖数> |
| 4 源码迁移扫描 | <扫描问题数、已修复数、按类型分布> |
| 5 编译验证 | <编译尝试次数、修复错误数、最终结果> |

---

## 五、相关文件路径

| 文件 | 路径 |
|------|------|
| 环境检测报告 | $WORK_DIR/reports/environment_check_report.md |
| 依赖分析报告 | $WORK_DIR/reports/dependency_analysis_<项目名>.md |
| 修复历史 | $WORK_DIR/reports/fix_history.txt |
| DevKit 扫描报告 | $WORK_DIR/reports/devkit-<时间戳>/ |
| 用户决策记录 | $WORK_DIR/reports/user_decisions.txt |
| 时间线日志 | $WORK_DIR/reports/timeline.log |
| 编译日志 | $WORK_DIR/logs/build_<N>.log |
| 迁移 patch | $WORK_DIR/output/migration.patch（源码+构建配置，排除二进制） |
| 二进制改动清单 | $WORK_DIR/reports/binary_changes.txt |
| ARM 适配确认清单 | $WORK_DIR/kunpeng_confirmed.md |

---

## 六、编译产物与编译命令

> 取编译成功那次为准。

| 项目 | 内容 |
|------|------|
| 编译产物目录 | <产物目录路径> |
| 编译命令与脚本 | <完整编译命令与脚本路径；优先从上下文获取，上下文无则从编译日志提取> |