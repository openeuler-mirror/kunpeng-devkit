---
name: cpp-arm-migration
description: 将 C/C++ 项目从 x86 迁移到 ARM（aarch64/鲲鹏），目标是使项目**同时**在 x86 和 ARM 上编译运行（双架构兼容）。支持 Bazel/CMake/Make/Blade/SCons 等主流构建系统。五阶段流程：① 环境检测与准备；② 依赖分析（含 ARM 兼容性探测）；③ 等待用户确认；④ DevKit 扫描 + 构建配置 + 源码适配；⑤ 循环编译验证直到成功。
---

# C/C++ 项目 ARM 迁移主控 Skill

## 核心原则

- **双架构兼容**：所有修改必须使项目**同时**支持 x86 和 ARM 编译。通过 `#if defined(__aarch64__)` 宏或构建系统 `select()` 分支区隔，**不破坏原有 x86 能力**
- **最小侵入**：优先修改构建配置而非源码；源码修改必须有架构宏保护
- **非侵入式工作目录**：所有临时产物（下载包、扫描报告、编译日志）放到项目目录之外的专用工作目录，不污染源码树
- **一次性信息收集**：所有需要用户提供的信息**在阶段 C 一次性问清楚**，不在后续流程中反复打断用户
- **子仓库优先**：存在私有仓库依赖时，优先推动子仓库完成 ARM 适配后再编译主仓库

---

## 整体流程

> **阶段 A（环境检测与准备）** → **阶段 B（依赖分析）** → **阶段 C（信息收集，等待用户回复）** → **阶段 D（DevKit 扫描 + 源码 & 构建适配）** → **阶段 E（编译验证循环）**

> ⚠️ **关键约束**：
> - 阶段 B 完成后，进入阶段 C 暂停等待用户回复，**未获得用户明确确认前不进入阶段 D**
> - 阶段 D 和 E 的所有修改均需有**架构宏保护**，确保 x86 编译不受影响

---

## 工作目录约定

**在开始任何操作前，先确定并创建统一工作目录**。工作目录放在 **workspace 根目录的同级**（不是项目子目录），不污染源码树。

```bash
# WORKSPACE_ROOT：IDE/Shell 的工作区根目录（不是项目子目录！）
# 例如：用户工作区为 /home/user/projects/myapp
#       项目在     /home/user/projects/myapp/service
#       则 WORKSPACE_ROOT=/home/user/projects/myapp
#          WORK_DIR=/home/user/projects/myapp-arm-migration   ← 在工作区同级

PROJECT_ROOT=<项目绝对路径>                      # 待迁移代码的最小根目录
WORKSPACE_ROOT=<IDE工作区根目录绝对路径>          # workspace 根目录
WORK_DIR="$(dirname $WORKSPACE_ROOT)/$(basename $WORKSPACE_ROOT)-arm-migration"
mkdir -p $WORK_DIR/{reports,downloads,build,logs,stubs}
echo "工作目录: $WORK_DIR"
```

子目录用途：
| 目录 | 用途 |
|------|------|
| `reports/` | DevKit 扫描报告、依赖分析报告、修改清单 |
| `downloads/` | 依赖源码包、ARM 预编译库下载 |
| `build/` | 第三方库临时编译安装目录 |
| `logs/` | 每轮编译日志（`build_1.log`、`build_2.log`…） |
| `stubs/` | 为无 ARM 版本的私有内部库创建的桩仓库 |

---

## 阶段 A：环境检测与准备

> 详细执行步骤见 [setup.md](setup.md)

**本阶段目标：确认 ARM 环境具备编译条件，输出环境检测报告。**

执行步骤（详见 setup.md）：

1. **A.1 收集系统环境信息**：获取 x86 和 ARM 环境的 gcc/glibc/OS 版本
2. **A.2 识别构建系统**：扫描项目根目录，确认 Make/CMake/Bazel/Blade/SCons
3. **A.3 检查构建工具版本**：确认 ARM 上的构建工具已安装且版本匹配
4. **A.4 处理 Blade 特殊情况**：检查 blade zip 包版本，必要时升级到支持 arm64 的版本
5. **A.5 处理 Bazel 特殊情况**：对比项目所需版本与系统版本，不一致时安装匹配版本
6. **A.6 识别 Protobuf 版本**：确认 protoc 版本与项目使用的 protobuf 版本一致
7. **A.7 生成环境检测报告**：输出汇总报告，标明所有已就绪/需处理的项

**阶段 A 完成后**，进入阶段 B。

---

## 阶段 B：依赖分析与 ARM 兼容性探测

> 详细执行步骤见 [dependency-analysis.md](dependency-analysis.md)，配合 [arm_confirmed.md](arm_confirmed.md) 使用

**本阶段目标：全面分析项目所有外部依赖，评估每个依赖的 ARM 兼容性，输出依赖分析报告。**

执行步骤（详见 dependency-analysis.md）：

1. **B.1 识别构建系统**：确认依赖声明方式（Bazel/CMake/Submodule/脚本下载/包管理器）
2. **B.2 扫描并初始化 Git Submodules**：最先处理，`git submodule update --init --recursive`
3. **B.3 按构建系统解析其余依赖**：Bazel WORKSPACE、CMake FetchContent/ExternalProject、Shell 脚本
4. **B.4 识别私有依赖**：内网域名/IP/SSH 地址的依赖标记为需 ARM 兼容性检查
5. **B.5 读取免检清单**：对照 `arm_confirmed.md` 过滤已确认兼容的依赖
6. **B.6 对私有依赖执行 ARM 兼容性探测**：检查 ARM 分支、提交历史
7. **B.7 检查 RPM spec 文件**：判断脚本下载的 RPM 是否有 spec 可自助打包
8. **B.8 识别并分析预编译二进制**：仓库内置 `.so`/`.a` + 外部无源码依赖，执行源码溯源
9. **B.9 递归分析子模块依赖**：最多 2 层深度
10. **B.10 生成依赖关系图**：Mermaid 格式
11. **B.11 生成依赖分析报告**：**直接输出到对话界面**，不创建文件（报告模板见 dependency-analysis-report-template-example.md）

**报告输出后**，进入阶段 C 暂停等待用户确认。

---

## 阶段 C：信息收集（暂停等待用户确认）

**阶段 B 完成并输出依赖分析报告后，在开始任何源码修改之前**，根据分析报告整理所有「无法自动解决」的项，**一次性**向用户提问：

```
📋 开始迁移前，需要您确认以下信息（请逐一回答）：

【依赖信息确认（无法自动获取，需您提供）】

来自依赖分析报告的 ⚠️ 待用户手动确认清单：
<直接引用 dependency-analysis.md 第 B.11 步输出的待确认清单>

【工具链与编译选项】
1. 编译目标：检测到编译目标为 <target>，是否正确？
2. Bazel/CMake 版本：项目要求 <版本>，ARM 环境已安装 <版本>，是否满足？

【功能决策（如有 x86 专属功能）】
3. [<可选功能名>] 依赖 x86 专属库 <库名>，是否在 ARM 上保留？
   - 保留：请提供 ARM 版或同意从源码重建
   - 禁用：通过宏/构建开关隔离，该功能在 ARM 上将不可用

如某项暂时无法提供，请注明"跳过"，将采用降级方案（禁用该功能或创建接口桩）。
```

**用户回复已确认兼容的依赖后**，按 [dependency-analysis.md](dependency-analysis.md)「用户确认后写入免检清单并执行真实切换」章节的流程：
- 立即写入 `arm_confirmed.md`
- 执行 git fetch + checkout 切换到确认的 ARM 分支
- 验证切换结果

**收到用户对所有必要信息的回复后**，进入阶段 D。

---

## 阶段 D：DevKit 扫描 + 构建配置 + 源码适配

> 详细执行步骤见 [sourcecode-devkit-scan.md](sourcecode-devkit-scan.md)

**本阶段目标：运行 DevKit 扫描发现源码 x86 专属问题，同时完成构建系统配置适配与源码修改。**

### D.1 准备工作目录与架构文件

```bash
# 创建 WORKSPACE 架构分离文件（Bazel 项目）
[ ! -f $PROJECT_ROOT/WORKSPACE_x86 ] && cp $PROJECT_ROOT/WORKSPACE $PROJECT_ROOT/WORKSPACE_x86
[ ! -f $PROJECT_ROOT/WORKSPACE_arm ] && cp $PROJECT_ROOT/WORKSPACE_x86 $PROJECT_ROOT/WORKSPACE_arm
```

### D.2 运行 DevKit 扫描（详见 sourcecode-devkit-scan.md）

```bash
DEVKIT=$(which devkit 2>/dev/null)
# 若 PATH 中不存在，按实际安装路径指定，例如：DEVKIT=/opt/devkit/bin/devkit

DEVKIT_REPORT_DIR="$WORK_DIR/reports/devkit-$(date +%Y%m%d%H%M%S)"
mkdir -p $DEVKIT_REPORT_DIR

$DEVKIT porting src-mig \
  -i $PROJECT_ROOT \
  -b <bazel|cmake|make|other> \
  -r all \
  -o $DEVKIT_REPORT_DIR
```

### D.3 构建配置适配（详见 sourcecode-devkit-scan.md）

按构建系统类型完成以下适配：

**Bazel 项目：**
- 修改 `software.sh`：添加架构分支，ARM 环境跳过 x86 工具链初始化
- 修改 `build.sh`：添加 `uname -m` 检测，自动选择 WORKSPACE 和 Bazel 配置
- 更新 `.bazelrc`：添加 `build:linux_aarch64` 配置段，将 x86 专属标志移到 `build:linux_x86` 段
- 创建/补全 `platforms/BUILD`：添加 ARM 平台定义
- 更新 `WORKSPACE_arm`：替换 JDK/预编译库 URL 为 ARM 版本，处理私有库桩

**CMake 项目：**
```cmake
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -march=armv8-a -fsigned-char")
else()
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mf16c -mavx2")
endif()
```

**Make 项目：**
```makefile
ARCH := $(shell uname -m)
ifeq ($(ARCH), aarch64)
    ARCH_CXXFLAGS = -march=armv8-a -fsigned-char
else
    ARCH_CXXFLAGS = -mf16c -mavx2
endif
CXXFLAGS += $(ARCH_CXXFLAGS)
```

### D.4 按 DevKit 报告修改源码（详见 sourcecode-devkit-scan.md）

逐一处理 DevKit 报告中的每个问题：
- 用 `#if defined(__aarch64__)` / `#if !defined(__aarch64__)` 架构宏保护 x86 专属代码
- ARM 替代实现（如 NEON 替代 SSE/AVX）
- 无 ARM 替代时：用宏完全禁用该代码块并添加注释说明

### D.5 处理私有库与本地桩（详见 sourcecode-devkit-scan.md）

当私有库无法访问且只需编译期接口时，在 `$WORK_DIR/stubs/` 下创建接口桩。

**阶段 D 完成后**，进入阶段 E。

---

## 阶段 E：编译验证循环

> 详细执行步骤见 [sourcecode-build-verify.md](sourcecode-build-verify.md)，错误排查参考 [sourcecode-error-patterns.md](sourcecode-error-patterns.md)

**本阶段目标：循环执行编译验证，直到编译成功或人工介入。**

### E.1 确定编译命令

按构建系统类型确定编译命令（详见 sourcecode-build-verify.md D.1 节）。

### E.2 循环编译修复（最多 10 次）

```
attempt = 1, MAX = 10
while attempt <= MAX:
    执行编译 → 保存日志到 $WORK_DIR/logs/build_${attempt}.log
    
    if 编译成功（退出码 0，无 error: 行）:
        → 输出成功摘要，进入收尾
    
    提取错误 → 优先查 sourcecode-error-patterns.md 已知案例
    
    if 当前错误 == 上次错误（修复无效）:
        → 进入人工介入报告，终止
    
    执行修复 → 记录到 fix_history.txt
    attempt += 1

if attempt > MAX:
    → 进入人工介入报告，终止
```

### E.3 成功后收尾

- 清理临时 WORKSPACE 文件
- 输出完成摘要（含修改清单、编译轮次）
- 提示在 x86 机器验证双架构兼容性

---

## 完成后输出摘要

```
✅ ARM 迁移完成摘要

【项目信息】
- 项目路径：$PROJECT_ROOT
- 构建系统：<类型>
- 编译目标：<target>
- 工作目录：$WORK_DIR

【环境准备结果】
- 构建工具：<工具/版本，状态>
- Protobuf：<版本，状态>

【依赖处理结果】
- N 个依赖：X 个已确认兼容 / Y 个替换 ARM 版 / Z 个禁用或创建桩

【构建配置修改】
- <文件路径>：<修改内容>

【源码修改】（DevKit 发现 N 项，已修复 M 项）
- <文件路径>：<修改说明>

【编译结果】
- 第 N 次编译成功
- 日志：$WORK_DIR/logs/build_N.log

【双架构兼容验证】
- ARM：✅ 成功
- x86：⬜ 需在 x86 机器验证（或：bazel build <target> --config=linux_x86）
```

---

## 附加资源

- **阶段 A：环境检测与准备**：[setup.md](setup.md)
- **阶段 B：依赖分析与兼容性探测**：[dependency-analysis.md](dependency-analysis.md)
- **依赖分析报告模板**：[dependency-analysis-report-template-example.md](dependency-analysis-report-template-example.md)
- **ARM 兼容性已确认清单**：[arm_confirmed.md](arm_confirmed.md)
- **阶段 D：DevKit 扫描与源码/构建适配**：[sourcecode-devkit-scan.md](sourcecode-devkit-scan.md)
- **阶段 E：编译验证与循环修复**：[sourcecode-build-verify.md](sourcecode-build-verify.md)
- **编译错误模式案例库**：[sourcecode-error-patterns.md](sourcecode-error-patterns.md)
