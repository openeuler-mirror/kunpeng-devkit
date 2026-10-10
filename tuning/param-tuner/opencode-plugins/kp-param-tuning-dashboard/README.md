# Kunpeng Param Tuning Dashboard

OpenCode 调优过程 TUI 仪表盘插件 — 在终端实时展示调优曲线图与每轮迭代数据。

## 功能概览

- **TUI 仪表盘**：在 OpenCode 中注册自定义路由 `/kp-param-tuning`，以全屏仪表盘形式展示调优曲线图 + 迭代数据表格
- **侧边栏集成**：在 OpenCode 侧边栏注册 slot，展示调优概要 + 迷你曲线图 + 迷你数据表
- **独立查看器**：脱离 OpenCode 也能使用的全屏 ANSI 终端查看器（`viewer.ts`）
- **自动刷新**：每隔 5 秒自动从工作空间读取 JSON 数据刷新
- **终端自适应**：图表与表格宽度随终端尺寸动态调整
- **手动滚动**：数据表格支持 `↑↓` / `jk` 按键滚动浏览
- **斜杠命令**：注册 `/kp-param-tuning` 斜杠命令
- **快捷键**：`Ctrl+Shift+T` 一键打开仪表盘

## 截图预览

使用 `bun run test:render` 可在终端预览渲染效果：

```
摘要信息:
Kunpeng PostgreSQL Parameter Tuning  ● running
计划轮次: 8/10  │  已完成: 29  │  最佳: 第5轮 95.8  │  最新: 72.3

调优曲线图 (无色):
95.8 ┤          ●
93.2 ┤        ╱╲
91.5 ┤      ╱╲╱╲
89.7 ┤    ╱╲╱╲╱╲
88.0 ┤   ╱╲╱╲
82.5 ┤  ╱╲╱╲
78.1 ┤ ╱
72.3 ┤●
     └──────────────────────────
       1  3  5  7  9  11 ...
              Round
```

## 环境要求

| 依赖 | 版本 | 说明 |
|------|------|------|
| [Bun](https://bun.sh) | >= 1.0 | 运行时 + 构建工具 |
| [OpenCode](https://opencode.ai) | >= 1.14.0 | TUI 插件宿主（可选，独立查看器不需要） |
| Node.js | >= 18 | `@types/node` 类型支持 |

## 快速开始

### 1. 安装依赖

```bash
bun install
```

### 2. 预览渲染效果

```bash
bun run test:render
```

### 3. 启动独立查看器

```bash
# 自动搜索工作空间中的调优 JSON 文件
bun run viewer

# 指定 JSON 文件路径
bun run viewer:sample
```

### 4. 在 OpenCode 中使用

确保 `tui.json` 已配置插件入口：

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "plugin": [
    ["./src/tuning-dashboard.tsx", {}]
  ]
}
```

在 OpenCode 中使用以下任一方式打开仪表盘：

| 方式 | 命令 / 快捷键 | 说明 |
|------|-------------|------|
| 斜杠命令 | `/kp-param-tuning` | 打开完整仪表盘（曲线图 + 表格） |
| 快捷键 | `Ctrl+Shift+T` | 打开仪表盘（对话框形式） |

## 仪表盘交互

| 按键 | 功能 |
|------|------|
| `r` | 立即刷新数据 |
| `↑` / `k` | 表格上滚一行 |
| `↓` / `j` | 表格下滚一行 |
| `q` / `ESC` | 退出仪表盘，返回主页 |

## 构建脚本

使用 [build.mjs](file:///src/build.mjs) 进行类型检查和编译：

```bash
# 完整构建（类型检查 + 编译到 dist/）
bun run build

# 仅类型检查，不输出文件
bun run build:check

# 仅编译 TUI 插件
bun run build:plugin

# 编译并部署到 .opencode/plugins/
bun run build:deploy

# 监听模式，文件变化自动重编译
bun run build:watch
```

构建产物输出到 `dist/` 目录：

| 文件 | 说明 |
|------|------|
| `dist/tuning-dashboard.js` | 编译后的 TUI 插件（含 SolidJS JSX 转换） |
| `dist/viewer.js` | 编译后的独立查看器 |
| `dist/test-render.js` | 编译后的测试脚本 |

## 数据格式

调优数据为 JSON 文件，项目会在工作空间中自动搜索以下文件名：

`tuning-data.json`、`tuning_data.json`、`tuning.json`、`tuning-result.json`、`tuning_results.json`、`perf-tuning.json`、`optimization.json`

也支持文件名包含 `tuning`、`optim` 或 `converge` 的任意 `.json` 文件。

### JSON 结构

```json
{
  "task": "Kunpeng PostgreSQL Parameter Tuning",
  "status": "running",
  "startTime": "2026-08-27T10:00:00Z",
  "totalRounds": 10,
  "currentRound": 8,
  "bestRound": 5,
  "bestScore": 95.8,
  "iterations": [
    {
      "round": 1,
      "score": 72.3,
      "improvement": 0.0,
      "params": {
        "shared_buffers": "2GB",
        "work_mem": "64MB",
        "wal_buffers": "16MB",
        "max_connections": "100"
      },
      "metrics": {
        "tps": 8500,
        "latency_ms": 12.5,
        "cpu_usage": 45,
        "memory_usage": 60
      },
      "status": "completed",
      "timestamp": "2026-08-27T10:05:00Z"
    }
  ]
}
```

### 字段说明

**顶层字段：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `task` | string | 否 | 调优任务名称，默认"未命名调优任务" |
| `status` | string | 否 | 任务状态（`running`/`completed`/其他） |
| `startTime` | string | 否 | 任务开始时间（ISO 格式） |
| `totalRounds` | number | 否 | 计划总轮次 |
| `currentRound` | number | 否 | 当前轮次 |
| `bestRound` | number | 否 | 最佳轮次 |
| `bestScore` | number | 否 | 最佳分数 |
| `iterations` | array | **是** | 迭代数据数组 |

**iterations 数组元素：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `round` | number | 否 | 轮次序号，默认取数组索引+1 |
| `score` | number | 否 | 性能评分，默认 0 |
| `improvement` | number | 否 | 较上轮提升百分比，默认 0 |
| `params` | object | 否 | 本轮参数键值对 |
| `metrics` | object | 否 | 本轮性能指标 |
| `status` | string | 否 | 本轮状态，默认 "unknown" |
| `timestamp` | string | 否 | 本轮完成时间（ISO 格式） |

完整示例见 [sample/tuning-data.json](file:///sample/tuning-data.json)。

## 项目结构

```
kp_param_tuning_dashboard/
├── src/
│   ├── data.ts                 # 数据类型定义与 JSON 加载模块
│   ├── chart.ts                # ASCII 图表渲染模块（曲线图/表格/摘要）
│   ├── tuning-dashboard.tsx    # OpenCode TUI 插件（SolidJS 仪表盘）
│   ├── viewer.ts               # 独立全屏 TUI 查看器
│   └── test-render.ts          # 渲染测试脚本（非 TUI 模式）
├── sample/
│   └── tuning-data.json        # 示例调优数据
├── build.mjs                   # Bun 构建脚本
├── tui.json                    # OpenCode TUI 插件配置
├── opencode.json               # OpenCode 配置
├── tsconfig.json               # TypeScript 配置
└── package.json                # 项目依赖与脚本
```

## 模块说明

### data.ts — 数据加载模块

负责在工作空间中搜索、解析调优过程的 JSON 数据。

- `findTuningData(dir)` — 在指定目录（含一级子目录）中搜索调优数据 JSON 文件
- `loadTuningData(filePath)` — 加载并校验 JSON 文件，返回 `TuningData` 对象
- `getBestIteration(data)` — 获取分数最高的迭代轮次
- `getLatestIteration(data)` — 获取最近一轮迭代
- `DataError` — 数据加载/解析异常类

### chart.ts — 图表渲染模块

提供调优曲线图、迭代数据表格的纯文本（ANSI）渲染，不依赖任何外部图表库。

- `renderLineChart(data, opts)` — 渲染 ASCII 调优曲线图（Bresenham 线段算法）
- `renderTable(data, opts)` — 渲染迭代数据表格（支持列筛选、行数限制、着色）
- `renderSummary(data, opts)` — 渲染摘要信息（任务名/状态/最佳/最新）
- `renderInline(data)` — 内联渲染（摘要 + 曲线图 + 表格，用于工具输出）
- `C` — ANSI 颜色常量对象

### tuning-dashboard.tsx — TUI 插件

基于 `@opentui/solid`（SolidJS 终端 UI 框架）的 OpenCode TUI 插件。

- 注册自定义路由 `/tuning` 和 `/tuning-chart`
- 注册侧边栏 slot（概要 + 迷你图表）
- 注册斜杠命令和快捷键
- 支持对话框模式（`Ctrl+Shift+T`）和路由模式
- 终端尺寸自适应 + 手动滚动 + 自动/手动刷新

### viewer.ts — 独立查看器

脱离 OpenCode 的全屏 ANSI 终端查看器，直接读取 JSON 文件并渲染。

- 全屏终端界面（ANSI 转义序列控制光标定位）
- 支持键盘交互（`q` 退出、`r` 刷新、`Ctrl+C` 强制退出）
- 终端尺寸变化自动重绘
- 信号处理（`SIGINT`/`SIGTERM` 优雅退出）

## 开发

```bash
# 类型检查
bun run build:check

# 监听模式开发（自动重编译）
bun run build:watch

# 运行测试渲染
bun run test:render
```

## 技术栈

- **运行时**：[Bun](https://bun.sh) >= 1.0
- **TUI 框架**：[@opentui/solid](https://www.npmjs.com/package/@opentui/solid)（基于 SolidJS 的终端 UI 框架）
- **插件宿主**：[OpenCode](https://opencode.ai) >= 1.14.0
- **语言**：TypeScript（strict 模式）
- **构建**：Bun.build() API

## 许可证

MIT
