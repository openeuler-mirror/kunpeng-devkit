/**
 * OpenCode TUI 插件: 调优过程监控仪表盘
 *
 * 功能概览
 *   - 在 OpenCode TUI 中注册自定义路由 "tuning" 和 "tuning-chart"
 *   - /tuning        显示完整仪表盘（曲线图 + 迭代数据表格）
 *   - 每隔 5 秒自动从工作空间读取 JSON 数据刷新
 *   - 注册 /kp-param-tuning 斜杠命令
 *   - 在侧边栏注册 slot，展示调优概要 + 迷你图表
 *
 * 使用方式
 *   /kp-param-tuning         — 打开完整仪表盘（或按 Ctrl+Shift+T） 

 * 技术栈
 *   @opentui/solid (基于 SolidJS 的终端 UI 框架)
 *
 * 文件结构
 *   - showTuningDialog()    以对话框形式展示仪表盘的入口
 *   - SidebarContent        侧边栏内容组件（概要 + 迷你图表 + 迷你表格）
 *   - tui()                 TUI 插件入口：注册侧边栏、命令、快捷键、路由
 *   - TuningDashboard       仪表盘主组件（曲线图 + 表格 + 状态栏）
 */

/** @jsxImportSource @opentui/solid */
import type { TuiPlugin, TuiPluginModule } from "@opencode-ai/plugin/tui"
import { createSignal, onMount, onCleanup, Show, For, createMemo } from "solid-js"
import { useKeyboard } from "@opentui/solid"
import { findTuningData, loadTuningData, getBestIteration, getLatestIteration } from "./data"
import type { TuningData } from "./data"
import { renderLineChart, renderTable } from "./chart"

// ─── 常量 ───────────────────────────────────────────────

/** 自动刷新间隔（毫秒） */
const REFRESH_INTERVAL_MS = 5000

/** 表格最多显示的数据行数（超出可滚动） */
const MAX_TABLE_ROWS = 10

// ─── ANSI 颜色解析（用于 @opentui/solid 着色）──────────
//
// chart.ts 的渲染函数使用 ANSI 转义序列（如 \x1b[36m）着色，
// 但 @opentui/solid 的 <text> 组件无法解析内嵌 ANSI 序列。
// 此处将 ANSI 序列解析为带 fg/attributes 属性的文本段，
// 再通过 <text fg="cyan" attributes={1}> 的方式着色。

/** ANSI 前景色码 → @opentui/solid 颜色名 */
const ANSI_FG_MAP: Record<string, string> = {
  "31": "red",
  "32": "green",
  "33": "yellow",
  "34": "blue",
  "35": "magenta",
  "36": "cyan",
  "90": "gray",
}

interface TextSegment {
  text: string
  fg?: string
  attributes?: number
}

/**
 * 将含 ANSI 转义序列的文本解析为带颜色信息的文本段数组
 * 使 @opentui/solid 的 <text> 组件能正确着色
 */
function parseAnsi(input: string): TextSegment[] {
  const segments: TextSegment[] = []
  let currentFg: string | undefined
  let currentBold = false

  const re = /\x1b\[([0-9;]*)m/g
  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = re.exec(input)) !== null) {
    const text = input.slice(lastIndex, match.index)
    if (text) {
      segments.push({ text, fg: currentFg, attributes: currentBold ? 1 : undefined })
    }

    const codeStr = match[1]
    if (codeStr === "" || codeStr === "0") {
      currentFg = undefined
      currentBold = false
    } else {
      for (const c of codeStr.split(";")) {
        if (c === "0") {
          currentFg = undefined
          currentBold = false
        } else if (c === "1") {
          currentBold = true
        } else if (ANSI_FG_MAP[c]) {
          currentFg = ANSI_FG_MAP[c]
        }
      }
    }
    lastIndex = re.lastIndex
  }

  if (lastIndex < input.length) {
    segments.push({
      text: input.slice(lastIndex),
      fg: currentFg,
      attributes: currentBold ? 1 : undefined,
    })
  }

  return segments.length > 0 ? segments : [{ text: input }]
}

/**
 * 渲染含 ANSI 颜色的文本行
 * 将 chart.ts 输出的 ANSI 转义序列转换为 @opentui/solid 的 fg/attributes 属性
 */
function ColoredText(props: { line: string }) {
  const segments = createMemo(() => parseAnsi(props.line))
  return (
    <box style={{ flexDirection: "row", padding: 0, flexShrink: 0, height: 1 }}>
      <For each={segments()}>
        {(seg) => (
          <text fg={seg.fg} attributes={seg.attributes}>
            {seg.text}
          </text>
        )}
      </For>
    </box>
  )
}

// ─── 模块级共享状态 ────────────────────────────────────
//
// 这些模块级变量用于跨组件通信：
//   - refreshHandler / scrollUpHandler / scrollDownHandler
//       由仪表盘组件设置，供 keymap 命令触发（与 useKeyboard 互为补充）
//   - sidebarData / setSidebarData
//       侧边栏与仪表盘共享的调优数据信号，仪表盘刷新时同步更新侧边栏

let refreshHandler: (() => Promise<void>) | null = null
let scrollUpHandler: (() => void) | null = null
let scrollDownHandler: (() => void) | null = null

const [sidebarData, setSidebarData] = createSignal<TuningData | null>(null)

// ─── 对话框入口 ─────────────────────────────────────────

/**
 * 以对话框形式展示完整仪表盘
 * 优先使用 dialog API（模态覆盖层），不可用时回退到路由导航
 */
function showTuningDialog(api: any) {
  if (api.ui?.dialog?.replace) {
    api.ui.dialog.replace(() => (
      <TuningDashboard api={api} dialog />
    ))
  } else {
    // 回退：直接路由导航到 tuning 页面
    api.route.navigate("tuning")
  }
}

// ─── 侧边栏组件 ─────────────────────────────────────────
//
// 必须作为独立 SolidJS 组件，确保 onClick 事件和 createMemo 信号
// 在响应式上下文中正确工作。组件本身不直接加载数据，而是从
// 模块级 sidebarData 信号读取（由仪表盘或独立轮询更新）。

/**
 * 侧边栏内容：展示调优概要、迷你曲线图、迷你数据表
 */
function SidebarContent(props: { api: any }) {
  const data = sidebarData

  // 最近一轮与最佳轮次的迭代信息
  const latest = createMemo(() => data() ? getLatestIteration(data()!) : null)
  const best = createMemo(() => data() ? getBestIteration(data()!) : null)

  // 根据最新分数选择展示颜色（绿→青→黄→红）
  const scoreColor = createMemo(() => {
    const score = latest()?.score ?? 0
    return score >= 90 ? "green" : score >= 80 ? "cyan" : score >= 70 ? "yellow" : "red"
  })

  // 迷你曲线图：窄幅无色，适配侧边栏 26 列宽
  const miniChart = createMemo(() => {
    const d = data()
    if (!d) return ""
    return renderLineChart(d, { width: 26, height: 6, color: true })
  })

  // 迷你数据表：仅显示最近 5 轮，3 列（轮次/性能/提升）
  const miniTable = createMemo(() => {
    const d = data()
    if (!d) return ""
    return renderTable(d, { color: true, maxRows: 5, width: 26, columns: ["Round", "Performance", "Improvement"] })
  })

  return (
    <Show when={data()} fallback={
      <box style={{ flexDirection: "column" }}>
        <text attributes={1}>调优监控</text>
        <text fg="gray">暂无数据</text>
        <text fg="gray">请放置调优JSON</text>
        <text fg="gray">Ctrl+Shift+T 打开仪表盘</text>
      </box>
    }>
      <box style={{ flexDirection: "column" }}>
        {/* 标题行 + 打开仪表盘入口 */}
        <box style={{ flexDirection: "row" }}>
          <text attributes={1}>调优监控</text>
          <text fg="cyan" onMouseUp={() => showTuningDialog(props.api)}>  [打开仪表盘 →]</text>
        </box>
        {/* 概要信息 */}
        <text fg={scoreColor()}>{"最新: " + (latest()?.score ?? 0).toFixed(1)}</text>
        <text fg="green">{"最佳: " + (best()?.score ?? 0).toFixed(1)}</text>
        <text>{"轮次: " + data()!.iterations.length}</text>
        <text fg="gray">{"基准线: " + (data()!.baseScore?.toFixed?.(1) ?? "-")}</text>

        {/* 迷你曲线图 */}
        <text fg="gray">{"─".repeat(26)}</text>
        <text attributes={1}>调优曲线</text>
        <For each={miniChart().split("\n")}>
          {(line) => <ColoredText line={line} />}
        </For>

        {/* 迷你数据表 */}
        <text fg="gray">{"─".repeat(26)}</text>
        <text attributes={1}>迭代数据</text>
        <For each={miniTable().split("\n")}>
          {(line) => <ColoredText line={line} />}
        </For>

        {/* 底部提示 */}
        <text fg="gray">{"─".repeat(26)}</text>
        <text fg="gray">点击上方或 Ctrl+Shift+T</text>
      </box>
    </Show>
  )
}

// ─── TUI 插件入口 ──────────────────────────────────────
//
// 插件初始化流程：
//   1. 注册侧边栏 slot（即使后续步骤出错也能显示侧边栏）
//   2. 启动侧边栏数据独立轮询
//   3. 注册命令与快捷键（兼容新旧 OpenCode API）
//   4. 注册 tuning / tuning-chart 自定义路由
//   5. 注册仪表盘内键盘快捷键（r/↑↓/jk/q/ESC）

const tui: TuiPlugin = async (api, _options, _meta) => {
  // ── 步骤 1：注册侧边栏 slot ──
  const apiSlots = api as any
  if (typeof apiSlots.slots?.register === "function") {
    apiSlots.slots.register({
      order: 1000,
      slots: {
        sidebar_content: () => <SidebarContent api={api} />,
      },
    })
  }

  // ── 步骤 2：侧边栏数据加载（独立轮询，不依赖仪表盘是否打开）──
  const loadSidebarData = async () => {
    const workspaceDir = process.cwd()
    const jsonPath = findTuningData(workspaceDir)
    if (!jsonPath) { setSidebarData(null); return }
    try { setSidebarData(loadTuningData(jsonPath)) } catch { setSidebarData(null) }
  }
  await loadSidebarData()
  const sidebarTimer = setInterval(loadSidebarData, REFRESH_INTERVAL_MS)
  api.lifecycle.onDispose(() => clearInterval(sidebarTimer))

  // ── 步骤 3：注册命令与快捷键 ──
  // 兼容新旧 OpenCode API：
  //   旧版 (< 1.14.42): api.command.register + api.keymap.registerLayer
  //   新版 (>= 1.14.42): api.keymap.registerLayer（api.command 已移除）
  const apiAny = api as any

  if (typeof apiAny.command?.register === "function") {
    // ── 旧版 OpenCode：通过 api.command.register 注册命令 ──
    apiAny.command.register(() => [
      {
        title: "Kunpeng Param Tuning Dashboard",
        value: "tuning.open",
        category: "Plugin",
        namespace: "palette",
        slashName: "kp-param-tuning",
        slash: { name: "kp-param-tuning" },
        slashAliases: ["tune", "调优"],
        desc: "打开调优过程监控仪表盘",
        onSelect: () => showTuningDialog(api),
      }
    ])
    // 快捷键仍通过 keymap 注册
    apiAny.keymap.registerLayer({
      mode: "base",
      bindings: [
        { key: "ctrl+shift+t", cmd: "tuning.open", desc: "打开调优仪表盘" },
      ],
    })
  } else {
    // ── 新版 OpenCode (>= 1.14.42)：通过 api.keymap.registerLayer 注册命令 ──
    api.keymap.registerLayer({
      mode: "base",
      commands: [
        {
          name: "tuning.open",
          title: "Kunpeng Param Tuning Dashboard",
          category: "Plugin",
          namespace: "palette",
          slashName: "kp-param-tuning",
          slash: { name: "kp-param-tuning" },
          slashAliases: ["tune", "调优"],
          desc: "打开调优过程监控仪表盘",
          run() {
            showTuningDialog(api)
          },
        }
      ],
      bindings: [
        { key: "ctrl+shift+t", cmd: "tuning.open", desc: "打开Kunpeng Param Tuning Dashboard" },
      ],
    })
  }

  // ── 步骤 4：注册 tuning 自定义路由 ──
  api.route.register([
    {
      name: "tuning",
      render: () => <TuningDashboard api={api} />,
    }
  ])

  // ── 步骤 5：注册仪表盘内键盘快捷键 ──
  // tuning.dashboard 模式下的命令定义（供 bindings 引用）
  api.keymap.registerLayer({
    mode: "tuning.dashboard",
    bindings: [
      { key: "escape", cmd: () => api.route.navigate("home"), desc: "返回主页" },
      { key: "q", cmd: () => api.route.navigate("home"), desc: "退出仪表盘" },
    ],
    commands: [
      {
        name: "tuning.refresh",
        run() {
          refreshHandler?.()
        },
      },
      {
        name: "tuning.scrollUp",
        run() {
          scrollUpHandler?.()
        },
      },
      {
        name: "tuning.scrollDown",
        run() {
          scrollDownHandler?.()
        },
      },
    ],
  })

  // 将 r/↑↓/jk 键绑定到对应命令（快捷键映射层）
  api.keymap.registerLayer({
    mode: "tuning.dashboard",
    bindings: [
      { key: "r", cmd: "tuning.refresh", desc: "立即刷新" },
      { key: "up", cmd: "tuning.scrollUp", desc: "表格上滚" },
      { key: "down", cmd: "tuning.scrollDown", desc: "表格下滚" },
      { key: "j", cmd: "tuning.scrollDown", desc: "表格下滚" },
      { key: "k", cmd: "tuning.scrollUp", desc: "表格上滚" },
    ],
  })
}

// ─── 仪表盘主组件 ───────────────────────────────────────
//
// 组件职责：
//   - 从工作空间自动搜索并加载调优 JSON 数据
//   - 渲染曲线图 + 迭代数据表格（full 模式）或仅曲线图（chart 模式）
//   - 支持手动滚动表格、手动刷新、终端尺寸自适应
//   - dialog 模式下以模态框形式展示（带边框和背景色）

/**
 * 调优过程监控仪表盘
 * @param props.api    OpenCode 插件 API
 * @param props.view   视图模式：full=完整仪表盘，chart=仅曲线图
 * @param props.dialog 是否以对话框形式展示
 */
function TuningDashboard(props: { api: any; view?: "full" | "chart"; dialog?: boolean }) {
  // ── 响应式状态 ──
  const [data, setData] = createSignal<TuningData | null>(null)
  const [error, setError] = createSignal<string | null>(null)
  const [lastUpdate, setLastUpdate] = createSignal<string>("")
  const [jsonPath, setJsonPath] = createSignal<string | null>(null)

  // 终端尺寸自适应（监听 resize 事件）
  const [termCols, setTermCols] = createSignal(process.stdout.columns || 80)
  const [termRows, setTermRows] = createSignal(process.stdout.rows || 24)

  // 工作空间根目录（插件运行时的 cwd）
  const workspaceDir = process.cwd()

  // 宽度偏移：dialog 模式下因边框/padding 占用更多横向空间
  const widthOffset = props.dialog ? 6 : 4

  // ── 动态高度计算 ──
  // 固定元素行数：标题(1) + 分割线(1) + 摘要(2) + 分割线(1) + 图标题(1) +
  //   分割线(1) + 表标题(1) + 表头(3) + 表尾(1) + 滚动提示(1) + 分割线(1) + 状态栏(1) = 15
  // 加上 padding(2) + dialog 边框(2)
  const FIXED_LINES = 15 + 2 + (props.dialog ? 2 : 0)

  // 仪表盘可用内容高度
  const availHeight = createMemo(() => {
    const rows = termRows()
    const h = props.dialog ? rows - Math.floor(rows / 4) - 2 : rows
    return Math.max(h - FIXED_LINES, 8)
  })

  // 表格最大可见行数（不超过 MAX_TABLE_ROWS，为图表预留至少 5 行）
  const maxRows = createMemo(() => {
    const avail = availHeight()
    const chartMin = props.view === "chart" ? 0 : 5
    return Math.min(Math.max(avail - chartMin, 1), MAX_TABLE_ROWS)
  })

  // ── 数据刷新 ──
  // 首次调用时搜索 JSON 路径并缓存；后续刷新复用缓存路径
  const refresh = async () => {
    try {
      let path = jsonPath()
      if (!path) {
        path = findTuningData(workspaceDir)
        if (path) setJsonPath(path)
      }
      if (!path) {
        setError("未找到调优数据 JSON 文件，请确保工作空间中存在 tuning-data.json")
        setData(null)
        return
      }
      const loaded = loadTuningData(path)
      setData(loaded)
      // 同步更新侧边栏共享数据
      setSidebarData(loaded)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
      setData(null)
      setSidebarData(null)
    }
    setLastUpdate(new Date().toLocaleTimeString("zh-CN", { hour12: false }))
  }

  // 推入自定义模式 "tuning.dashboard"，使 keymap 生效（含 r 键刷新）
  const popMode = props.api.mode.push("tuning.dashboard")
  onCleanup(popMode)

  // ── 键盘事件处理 ──
  // useKeyboard 直接监听按键，作为 keymap 的补充
  // （dialog 模式下 keymap 可能不生效，此处兜底）
  useKeyboard((key) => {
    if (key.name === "r") {
      refresh()
    } else if (key.name === "up" || key.name === "k") {
      scrollUp()
    } else if (key.name === "down" || key.name === "j") {
      scrollDown()
    } else if (key.name === "escape" || key.name === "q") {
      if (props.dialog) {
        props.api.ui.dialog?.close?.()
      } else {
        props.api.route.navigate("home")
      }
    }
  })

  // ── 组件挂载：注册回调 + 监听 resize + 启动定时刷新 ──
  onMount(async () => {
    // 注册手动刷新回调（供 r 键 / keymap 命令调用）
    refreshHandler = refresh
    onCleanup(() => { refreshHandler = null })

    // 注册滚动回调（供 ↑↓/jk 键 / keymap 命令调用）
    scrollUpHandler = scrollUp
    scrollDownHandler = scrollDown
    onCleanup(() => { scrollUpHandler = null; scrollDownHandler = null })

    // 监听终端尺寸变化，实现图表/表格自适应
    const onResize = () => {
      setTermCols(process.stdout.columns || 80)
      setTermRows(process.stdout.rows || 24)
    }
    process.stdout.on("resize", onResize)
    onCleanup(() => process.stdout.off("resize", onResize))

    // 首次刷新 + 定时刷新（每 5 秒）
    await refresh()
    const timer = setInterval(refresh, REFRESH_INTERVAL_MS)
    onCleanup(() => clearInterval(timer))
  })

  // ── 响应式计算：曲线图 ──
  // 宽度自适应终端列数，高度根据视图模式动态调整
  const chartText = createMemo(() => {
    const d = data()
    if (!d || d.iterations.length === 0) return "（暂无迭代数据）"
    const cols = termCols()
    // chart-only 视图用全部可用高度；完整仪表盘取表格剩余空间
    const avail = availHeight()
    const chartHeight = props.view === "chart"
      ? Math.max(avail, 5)
      : Math.max(avail - maxRows(), 5)
    return renderLineChart(d, { width: cols - widthOffset, height: chartHeight, color: true })
  })

  // ── 响应式计算：数据表格 ──
  // 注意：renderTable 实际输出宽度 = 指定 width + (1 + 3*列数) 字符
  // （边框 + 分隔符 + padding），5 列时多 16 字符，需从 separator 宽度中扣除
  const tableWidthOffset = 1 + 3 * 5 // 5 列
  const tableText = createMemo(() => {
    const d = data()
    if (!d) return ""
    const w = termCols() - widthOffset
    return renderTable(d, { color: true, width: Math.max(w - tableWidthOffset, 30) })
  })

  // ── 表格行拆分 ──
  // renderTable 输出结构：顶边框 + 表头行 + 中边框 + 数据行... + 底边框
  // 将其拆分为三部分：表头（前 3 行）、数据行（中间）、底边框（末行）
  const tableLines = createMemo(() => tableText() ? tableText().split("\n") : [])
  const tableHeader = createMemo(() => tableLines().slice(0, 3))
  const tableBodyAll = createMemo(() => tableLines().slice(3, -1))
  const tableFooter = createMemo(() => tableLines().length > 3 ? [tableLines()[tableLines().length - 1]] : [])

  // ── 表格手动滚动 ──
  // 通过偏移量控制可见行范围，超出 maxRows 时显示滚动指示器
  const [tableScroll, setTableScroll] = createSignal(0)
  const tableBodyVisible = createMemo(() => {
    const all = tableBodyAll()
    const mr = maxRows()
    // 偏移量不超过最大可滚动范围
    const offset = Math.min(tableScroll(), Math.max(0, all.length - mr))
    return all.slice(offset, offset + mr)
  })
  const scrollDown = () => setTableScroll((s) => Math.min(s + 1, Math.max(0, tableBodyAll().length - maxRows())))
  const scrollUp = () => setTableScroll((s) => Math.max(0, s - 1))

  // ── 响应式计算：摘要信息 ──
  const best = createMemo(() => data() ? getBestIteration(data()!) : null)
  const latest = createMemo(() => data() ? getLatestIteration(data()!) : null)

  // 动态分隔线宽度（随终端宽度自适应）
  const separator = createMemo(() => "─".repeat(termCols() - widthOffset))

  return (
    <box style={{
      flexDirection: "column",
      padding: 1,
      // dialog 模式下限制尺寸并居中，带圆角边框与背景色
      width: props.dialog ? termCols() - 2 : undefined,
      height: props.dialog ? termRows() - Math.floor(termRows() / 4) - 2 : undefined,
      alignSelf: props.dialog ? "center" : undefined,
      backgroundColor: props.dialog ? "#1a1b26" : undefined,
      borderStyle: props.dialog ? "rounded" : undefined,
      borderColor: props.dialog ? "#4a4a6a" : undefined,
    }}>
      {/* ─── 标题栏 ─── */}
      <box style={{ flexDirection: "row" }}>
        <text attributes={1}>
          {props.view === "chart" ? "  调优曲线图  " : "  调优过程监控仪表盘  "}
        </text>
      </box>

      {/* ─── 分割线 ─── */}
      <text>{separator()}</text>

      {/* ─── 摘要信息（任务/状态/迭代数/最佳/最新/基准线）─── */}
      <Show when={data()} fallback={
        <Show when={error()} fallback={<text>加载中...</text>}>
          <text fg="red">
            {"⚠ 数据加载错误: " + error()}
          </text>
          <text>{"等待 5 秒后自动重试..."}</text>
        </Show>
      }>
        <box style={{ flexDirection: "row", flexShrink: 0, height: 1 }}>
          <text>{"任务: " + data()!.task + "    状态: "}</text>
          <text fg={/complete|done/i.test(data()!.status) ? "green" : /run/i.test(data()!.status) ? "cyan" : "yellow"}>{"● " + data()!.status}</text>
        </box>
        <text>{"迭代: " + data()!.iterations.length + "/" + (data()!.totalRounds ?? "-") +
          "    最佳: 第" + (best()?.round ?? "-") + "轮 " + (best()?.score.toFixed(1) ?? "-") +
          "    最新: " + (latest()?.score.toFixed(1) ?? "-") +
          "    基准线: " + (data()!.baseScore?.toFixed?.(1) ?? "-")}</text>
      </Show>

      {/* ─── 分割线 ─── */}
      <text>{separator()}</text>

      {/* ─── 调优曲线图 ─── */}
      <text attributes={1}>{" 调优曲线图"}</text>
      <box style={{ flexDirection: "column", padding: 0, flexShrink: 0, flexGrow: 1 }}>
        <For each={chartText().split("\n")}>
          {(line) => <ColoredText line={line} />}
        </For>
      </box>

      {/* ─── 分割线 ─── */}
      <text>{separator()}</text>

      {/* ─── 迭代数据表（仅 full 模式显示）─── */}
      <Show when={props.view !== "chart"}>
        <text attributes={1}>{" 每轮迭代数据"}</text>
        {/* 表头（固定不滚动） */}
        <For each={tableHeader()}>
          {(line) => <ColoredText line={line} />}
        </For>
        {/* 数据行（手动滚动，只显示可见行） */}
        <For each={tableBodyVisible()}>
          {(line) => <ColoredText line={line} />}
        </For>
        {/* 底边框（固定不滚动） */}
        <For each={tableFooter()}>
          {(line) => <ColoredText line={line} />}
        </For>
        {/* 滚动指示器（数据行超过可见数时显示） */}
        <Show when={tableBodyAll().length > maxRows()}>
          <text fg="gray">{`  共 ${tableBodyAll().length} 行 (↑↓/jk 滚动)`}</text>
        </Show>

        {/* 分割线 */}
        <text>{separator()}</text>
      </Show>

      {/* ─── 底部状态栏（刷新时间 + 数据源 + 快捷键提示）─── */}
      <text>
        {"刷新时间: " + lastUpdate() + "  |  数据源: " + (jsonPath() ?? "自动搜索") + "  |  r:刷新  ↑↓/jk:滚动  ESC:返回"}
      </text>
    </box>
  )
}

// ─── 插件模块导出 ───────────────────────────────────────

const plugin: TuiPluginModule & { id: string } = {
  id: "kp.tuning-dashboard",
  tui,
}

export default plugin
