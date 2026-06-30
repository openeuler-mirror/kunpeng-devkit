---
name: devkit-scan
description: C/C++ 项目 ARM 迁移的阶段 D 子 Skill：DevKit 扫描与源码/构建适配。运行华为鲲鹏 DevKit 对源码进行 x86 兼容性扫描，根据扫描报告完成源码架构适配修改（内联汇编、intrinsics、头文件、类型大小、内存对齐）和构建系统配置适配（ARM 编译选项）。严格串行：先完成扫描生成报告，再根据报告修改源码。作为 cpp-kunpeng-migration 主 Skill 的阶段 D 子 Skill 调用；当用户需要单独运行 DevKit 扫描、处理 x86 专属代码适配、或下载安装 DevKit 工具时也应直接调用本子 Skill。
---

# DevKit 扫描与源码适配（阶段 D）

## 模块架构

| 文件 | 职责 |
|------|------|
| **本文件（SKILL.md）** | 编排入口：阶段 D 整体流程、输入/输出契约、加载执行文件指引 |
| [sourcecode-devkit-scan.md](references/sourcecode-devkit-scan.md) | **完整执行流程**：D.1 DevKit 扫描 → D.2 源码/构建适配 → D.3 完整性验证 → D.4 检查清单 |
| [devkit-download.md](references/devkit-download.md) | DevKit CLI 包下载与安装（D.1.1 用户选择自动下载时加载） |
| [devkit-download.sh](scripts/devkit-download.sh) | DevKit 下载脚本（参数校验、重试、完整性校验、语义化退出码） |

---

## 输入 / 输出契约

| 方向 | 项 | 说明 |
|------|----|------|
| 输入 | `WORK_DIR` | 主 Skill 全局初始化的工作目录 |
| 输入 | `PROJECT_ROOT` | 项目根目录绝对路径 |
| 输入 | 构建系统类型 | 从阶段 A 环境检测报告读取（Bazel/CMake/Make/Blade/SCons/其他） |
| 输入 | 阶段 C 确认完成 | 私有依赖的 ARM 兼容性信息已获取，分支切换已完成 |
| 输出 | `$WORK_DIR/reports/devkit-*/` | DevKit 扫描报告（CSV/HTML） |
| 输出 | `$WORK_DIR/reports/devkit-scan.log` | 扫描日志 |
| 输出 | `$WORK_DIR/reports/source_changes.txt` | 源码修改清单 |
| 输出 | 项目源码 | 已完成架构宏保护的源码修改（x86 + ARM 双架构兼容） |

---

## 主流程

> **立即 `read_file("references/sourcecode-devkit-scan.md")` 获取完整执行步骤。**

阶段 D 严格串行，分为两个不可并行的子步骤：

### D.1 DevKit 扫描（门控步骤）

1. 定位 DevKit 工具（系统 PATH / 常见路径 / 用户手动提供 / 自动下载）
2. 确认扫描参数（`-b` 根据构建系统类型）
3. 执行扫描，生成报告
4. 读取并汇总扫描报告（按问题类型统计）

> **扫描期间不得进行任何源码或构建配置修改。**

### D.2 源码/构建适配（扫描结束后）

按扫描报告逐条处理，遵循**双架构兼容**原则（不删除原有 x86 实现）：

1. **D.2.1** 添加 ARM 强制全局编译选项（`-fsigned-char`、`-march=armv8.5-a`）— 编译前必做
2. **D.2.2** 处理 x86 专属头文件（架构宏保护 `#include`）
3. **D.2.3** 处理 intrinsics 函数调用（NEON 替代或标量退化）
4. **D.2.4** 处理内联汇编（架构宏隔离 + ARM 等价实现）
5. **D.2.5** 处理类型大小/字节序依赖（改用明确宽度类型）
6. **D.2.6** 处理内存对齐假设（使用 unaligned 加载或确保对齐）

### D.3 修改完整性验证

- 残留 x86 专属头文件检查
- 残留 intrinsics 调用检查
- 记录修改清单

### D.4 修改完成检查清单

确认所有问题类型已处理、残留检查通过、x86 代码路径未被删除。

---

## 硬性约束

- **严格串行**：D.1 扫描完成后才能开始 D.2 修改，不可并行
- **双架构兼容**：所有修改必须同时支持 x86 和 ARM 编译，不删除原有 x86 实现
- **DevKit 不可跳过**：`which devkit` 返回空时，必须通过 `AskUserQuestion` 让用户决策（手动提供路径 / 自动下载 / 中止）
- **扫描报告是阶段 E 的最高优先级参考依据**，路径 `$WORK_DIR/reports/devkit-*/`
