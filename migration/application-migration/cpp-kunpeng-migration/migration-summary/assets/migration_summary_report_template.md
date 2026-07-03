# ARM 迁移总结报告

> 项目：<PROJECT_ROOT>
> 构建系统：<Bazel/CMake/Make/Blade/SCons>
> 迁移日期：<开始日期 ~ 结束日期>
> 最终状态：编译成功 / 人工介入

---

## 一、重要提示与建议

<6.3 的提示内容>

---

## 二、各阶段执行时长

<6.1 的时长表格>

---

## 三、修改文件清单

<6.2 的修改文件表格>

### 修改统计
- 修改文件总数：<N>
- 源码文件：<N>
- 构建配置文件：<N>
- 其他：<N>

---

## 四、迁移过程摘要

| 阶段 | 关键结果 |
|------|---------|
| 1 环境检测 | <识别的构建系统、安装/升级的工具及版本> |
| 2 依赖分析 | <依赖总数、命中免检清单数、待确认数> |
| 3 用户确认 | <确认项数、切换依赖数> |
| 4 DevKit 扫描 | <扫描问题数、已修复数、按类型分布> |
| 5 编译验证 | <编译尝试次数、修复错误数、最终结果> |

---

## 五、相关文件路径

| 文件 | 路径 |
|------|------|
| 环境检测报告 | $WORK_DIR/reports/environment_check_report.md |
| 依赖分析报告 | $WORK_DIR/reports/dependency_analysis_<项目名>.md |
| 修复历史 | $WORK_DIR/reports/fix_history.txt |
| 修改清单（git diff） | $WORK_DIR/reports/final_changes_<日期>.txt |
| DevKit 扫描报告 | $WORK_DIR/reports/devkit-<时间戳>/ |
| 用户决策记录 | $WORK_DIR/reports/user_decisions.txt |
| 时间线日志 | $WORK_DIR/reports/timeline.log |
| 编译日志 | $WORK_DIR/logs/build_<N>.log |
