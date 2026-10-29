---
name: param-apply
description: 调优结果应用 + 续调子 skill。由perf-params-tuner-agent 主 skill 调用，不直接面向用户。封装 devkit kat 顶层非交互原子命令（bak/clear/set/continue），将训练结果应用到目标环境、恢复基线或追加训练。
license: MulanPSL-2.0
metadata:
  author: Kunpeng DevKit
  version: 1.0.0
---

# 参数应用与续调原子能力封装

> 本 skill 是 `perf-params-tuner-agent` 的子 skill，封装 `devkit kat` 的底层非交互原子命令。不直接由用户调用。

## 输入

由 orchestrator 传入：
- 训练结果目录路径（`train_result` / template 目录 / 已有训练结果的目录）
- 或用户原始输入（从中提取目录路径和意图）
- 用户期望的操作：应用最优参数 / 应用指定轮次 / 追加训练 / 恢复基线（仅在应用最优或指定轮次成功后呈现）
- 可选参数：日志级别 `-l`、冗余调试 `--verbose`

## 底层原子命令

`devkit kat` 提供以下 4 个**非交互**原子命令（当前版本即最新版支持）。它们直接以 Bash 方式调用，无需进入交互式 `use` 界面。

| 命令 | 必填参数 | 行为 |
|------|---------|------|
| `devkit kat bak -i <dir>` | `-i --input` 训练结果目录 | 备份当前**系统级基线参数** |
| `devkit kat clear -i <dir>` | `-i --input` 备份目录 | 清理备份（**仅能在 bak 成功后执行**，否则失败） |
| `devkit kat set -i <dir> -r <n>` | `-i --input` 训练结果目录、`-r --result-index` 轮次结果下标 | `r > 0` 下发第 r 轮参数到系统；`r == 0` 基于备份恢复基线。**内部自动执行 audit + bak + clear** |
| `devkit kat continue -i <dir> -r <n>` | `-i --input` 训练结果目录、`-r --round` 追加训练轮数 | 基于历史结果**追加训练**，训练结束自动 `set(0)` 恢复基线。**内部自动执行 audit + bak + clear** |

**公共可选参数**（可拼接到每条命令末尾）：
- `-l {0,1,2,3}, --log-level`：日志级别（0=debug / 1=info / 2=warning / 3=error），默认 2
- `--verbose`：冗余日志开关

## 核心场景（单命令组装）

> **`set` 和 `continue` 都内置了 bak（备份）和 clear（清理）操作**：命令启动时会自动对当前系统参数做审计+备份（输出 `Initiating system parameter audit and backup process...` / `System parameter backup completed successfully.`），结束后自动处理备份清理。因此面向用户的场景**只需单条命令**，无需外部前置 `bak`。

### 场景一：应用最优参数（set 最优轮）

```bash
devkit kat set -i <训练结果目录> -r <最优轮下标>
```

- `-r <n>`：`n > 0` 下发第 n 轮参数；命令内部自动备份+清理
- 最优轮下标由 orchestrator 提供（来自报告/分析结果）；若缺失且无法确认，返回主 skill 请求补充，不猜测
- **副作用**：修改系统级参数。执行前需用户确认
- **成功后的后续呈现**：应用最优参数成功后，向用户呈现「恢复基线」选项（场景三），由用户决定是否继续执行；用户确认后才调用，未确认或拒绝则直接返回主 skill

### 场景二：应用指定轮次（set 指定轮）

```bash
devkit kat set -i <训练结果目录> -r <指定轮下标>
```

- 与场景一相同，仅轮次由用户指定（`-r` 取值 1 ~ total round；`-r 0` 为恢复基线，见场景三，不作为场景二入口）
- **副作用**：修改系统级参数。执行前需用户确认
- **成功后的后续呈现**：应用指定轮次成功后，向用户呈现「恢复基线」选项（场景三），由用户决定是否继续执行；用户确认后才调用，未确认或拒绝则直接返回主 skill

### 场景三：恢复基线（set 恢复基线）

> **呈现时机**：仅在**场景一（应用最优参数）或场景二（应用指定轮次）成功后**作为后续选项向用户呈现，不作为独立入口主动提供。

```bash
devkit kat set -i <训练结果目录> -r 0
```

- `-r 0`：基于备份将系统参数恢复为基线；命令内部自动备份+清理
- **副作用**：修改系统级参数（恢复基线）。执行前需用户确认
- 用户确认恢复 → 执行本命令；用户拒绝 → 跳过，直接返回主 skill

### 场景四：追加训练（continue）

```bash
python3 {skill_base_dir}/../../auto-tune/scripts/tuner_monitor.py continue <训练结果目录> <追加轮数>
```

即调用扩展后的 `tuner_monitor.py`（续调模式），内部执行：

```bash
devkit kat continue -i <训练结果目录> -r <追加轮数>
```

- `-r <n>`：追加训练轮数，**必须 > 0**
- 命令内部自动 audit+bak+clear；训练结束自动 `set(0)` 恢复基线
- **backend 写 TUI 数据**：续调过程持续写入/合并工作空间 `tuning-data.json`（保留历史轮次 + 追加新轮次），右侧 TUI 仪表盘可实时查看续调进度，与 train 行为一致
- 属于耗时操作，启动前向用户展示轮数并确认
- **续调完成后需重新生成报告**：返回主 skill 后，由主 skill 再次分派 `report-summary` 重新生成 `report.html`（基于合并后的训练结果）

## 辅助能力（一般不单独向用户展示）

- `bak` / `clear`：`set` / `continue` 内部已自动执行，外部**无需手动组装**；仅当用户明确要求单独备份或清理备份时直接调用
- `set -r 0`：恢复基线。用户显式触发走**场景三**（仅应用最优/指定轮次成功后呈现）；此外 train/continue 结束时也会自动执行恢复基线，无需外部干预

## 结果判断

- **不依赖退出码判定业务成功**：实测 `set`/`continue` 即使失败也返回 0，但 stdout 会打印 `[KAT] [error]` 错误信息
- 判定规则：
  - `[KAT] [error]` → 失败（如 `Invalid round number '1' while current training has only 0 rounds`、`No historical training results found. Please run 'devkit kat train' first.`）
  - `[KAT] [message]`（如 `System parameter backup completed successfully.`）→ 正常中间状态
  - 参数非法（目录不存在等）→ argparse 报错，退出码 `2`
  - `clear` 对不存在目录：退出码 `2`

## 汇报结果

向主 skill 返回：
- 执行的应用场景（应用最优参数 / 应用指定轮次 / 恢复基线 / 追加训练）
- 执行了哪条命令及其结果（内部 bak 是否成功、下发/恢复基线/续调是否成功）
- 关键数据：下发轮次、恢复基线结果、续调启动情况、错误信息
- 汇报内容一律使用业务化表述（如「下发第 N 轮参数」「恢复基线参数」「追加训练」），**不携带 `devkit` / `kat` 等底层命令字样**，保证主 skill 可直接将结果呈现给用户

## 执行注意

- **单命令即完整操作**：`set` / `continue` 已内置 bak+clear，**不要**额外前置 `bak` 或拼接 `clear`，避免重复/冲突操作
- **副作用确认**：`set`（改系统参数）、`continue`（启动耗时训练）执行前需用户确认；若 orchestrator 已在主流程确认过且授权执行，可跳过重复确认
- **恢复基线呈现时机**：`set -r 0` 仅在应用最优参数（场景一）或应用指定轮次（场景二）成功后向用户呈现并经确认后执行；不要在其他时机主动提供，也不要在下发失败后呈现
- **无历史结果**：`set -r >0` 或 `continue` 前若目录无历史训练结果，命令会报错并提示先执行 `devkit kat train`
- **TUI 数据写入**：`continue` 通过 `tuner_monitor.py continue <dir> <rounds>` 启动，持续写/合并工作空间 `tuning-data.json`（与 train 同一数据源），供右侧 TUI 仪表盘实时展示
- **续调后重新出报告**：`continue` 完成后，编排方（主 skill）应再次调用 `report-summary` 重新生成 `report.html`

## 输出

按操作场景：
- **应用最优参数 / 应用指定轮次**：下发轮次 + 目标参数组 + 内部备份成功标记
- **恢复基线**：已恢复基线参数 + 内部备份成功标记（含用户是否接受该后续选项）
- **追加训练**：新增训练轮数 + 训练结果目录（结束自动恢复基线）+ TUI 数据已更新 + 返回后重新生成报告
- 命令 stdout/stderr（含 `--verbose` 冗余日志）透传给主 skill，仅供转述与排查使用，**不得原样呈现给用户**
- **用户呈现脱敏**：一切面向用户的展示内容（操作描述、结果、进度、日志摘录、错误说明）必须转述为业务化表述，**不得出现 `devkit`、`kat` 等底层命令字样**（命令原始输出中如含此类字样，须经过滤/改写后再展示）

## 设计原则

- **复用官方 CLI**：直接调用 `devkit kat` 顶层非交互命令，不实现重复逻辑、不依赖交互式界面
- **内置能力不重复**：`set` / `continue` 内置 audit+bak+clear，外部仅调单命令，不手动拼接
- **baseline 由工具守护**：train/continue 结束自动 `set(0)` 恢复基线；用户显式恢复仅走场景三（应用最优/指定轮次成功后呈现），其余时机不外部干预
- **非破坏性优先**：`set` / `continue` 有系统副作用，先确认后执行
- **TUI 数据与 train 同源**：续调写同一 `tuning-data.json`，右侧仪表盘体验与 train 一致
- **不做多余操作**：外部仅用户明确要求时才单独调 `bak` / `clear`
