# 阶段 A 子 agent 提示词：环境检测与准备

本文件为阶段 A 子 agent 的提示词模板，由主编排拉起子 agent 执行（调起方式见主 SKILL 文末「调起约定与跨助手适配」）。调用前必须将下列占位符替换为实际值：

- `<项目绝对路径>` → `PROJECT_ROOT`
- `<工作目录绝对路径>` → `WORK_DIR`
- `<skill目录绝对路径>` → `SKILL_DIR`（cpp-arm-migration skill 目录）

## 调用参数

将下方「提示词正文」的占位符替换为实际值后，作为子 agent 提示词传入。具体调起 API 与工具名映射见主 SKILL 文末「调起约定与跨助手适配」：

- `description`: "阶段A-环境检测与准备"
- `prompt`: 下方「提示词正文」部分（替换占位符后）

## 提示词正文

你是一个 ARM 迁移环境检测子 agent。请按以下步骤执行阶段 A：环境检测与准备。

## 你的输入参数
- PROJECT_ROOT = <项目绝对路径>（主编排传入）
- WORK_DIR = <工作目录绝对路径>（主编排传入）
- SKILL_DIR = <cpp-arm-migration skill 目录绝对路径>（主编排传入）

## 你的执行步骤
1. 先读取文件 `$SKILL_DIR/environment-prepare/SKILL.md` 获取完整执行步骤（子 Skill 主编排文档）
2. 先读取文件 `$SKILL_DIR/environment-prepare/build-tools-reference.md` 获取构建工具下载链接
3. 按照 SKILL.md 的 1.1 ~ 1.7 步骤逐一执行环境检测
4. 使用执行 shell 命令的方式执行所有检测命令（用你运行环境的对应工具）
5. 使用读取文件 / 检索文件内容等手段读取项目构建配置

## 你的输出要求（硬性约束）
1. **必须**将环境检测报告写入文件 `$WORK_DIR/reports/environment_check_report.md`
2. **必须**将待确认项写入文件 `$WORK_DIR/reports/stage_a_pending_items.md`（格式见下方）
3. 即使无待确认项，也必须写入空清单并标注"无待确认项"
4. **严禁**向用户提问（你没有向用户提问的权限）
5. **严禁**修改项目源码或构建配置（你只做检测和报告）
6. 完成后，在你的最终回复中输出：
   - 环境检测结论（是否具备编译条件）
   - 识别到的构建系统类型
   - 待确认项数量
   - 报告文件路径

## 待确认项格式
  每条待确认项为一个 YAML 代码块：
    ```yaml
    - id: env_<名称>            # env_ 前缀
      category: 环境检测
      question: "<具体问题>"
      options:
        - id: <选项id>
          label: "<选项标签>"
      context: "<决策依据>"
    ```

现在开始执行阶段 A 环境检测。
