#!/usr/bin/env bun
/**
 * 调优过程 TUI 全屏查看器
 *
 * 功能：
 *  - 全屏 ANSI 终端界面，展示调优曲线图与每轮迭代数据
 *  - 每隔 5 秒自动从工作空间读取 JSON 数据刷新
 *  - 支持键盘交互: q/Ctrl+C 退出, r 立即刷新
 *
 * 用法:
 *   bun run src/viewer.ts [json文件路径]
 *   node src/viewer.js [json文件路径]
 */

import * as readline from "readline"
import { findTuningData, loadTuningData, DataError } from "./data"
import type { TuningData } from "./data"
import { renderLineChart, renderTable, C } from "./chart"

// ─── 常量 ────────────────────────────────────────────────

const REFRESH_INTERVAL_MS = 5000
const HEADER_TITLE = "调优过程监控仪表盘"
const FOOTER_HINTS = "r: 刷新  |  q: 退出  |  自动刷新: 5s"

// ─── 终端工具函数 ────────────────────────────────────────

function clearScreen(): void {
  process.stdout.write("\x1b[2J")
}

function cursorTo(row: number, col: number): void {
  process.stdout.write(`\x1b[${row + 1};${col + 1}H`)
}

function cursorHome(): void {
  process.stdout.write("\x1b[H")
}

function hideCursor(): void {
  process.stdout.write("\x1b[?25l")
}

function showCursor(): void {
  process.stdout.write("\x1b[?25h")
}

function getTerminalSize() {
  return {
    cols: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
  }
}

/**
 * 在指定行写入文本（带定位）
 */
function writeAt(row: number, col: number, text: string): void {
  cursorTo(row, col)
  process.stdout.write(text)
}

/**
 * 写入居中标题行
 */
function writeCentered(row: number, col: number, width: number, text: string): void {
  const padding = Math.max(0, Math.floor((width - stripAnsi(text).length) / 2))
  writeAt(row, col + padding, text)
}

// ─── 简易 ANSI 长度计算 ──────────────────────────────────

const ANSI_RE = /\x1b\[[0-9;]*m/g

function stripAnsi(str: string): string {
  return str.replace(ANSI_RE, "")
}

function ansiLen(str: string): number {
  return stripAnsi(str).length
}

// ─── 主 TUI 渲染 ─────────────────────────────────────────

function renderTUI(data: TuningData | null, error: string | null, jsonPath: string | null): void {
  const { cols, rows } = getTerminalSize()

  clearScreen()
  cursorHome()

  // 顶部边框 + 标题
  writeAt(0, 0, `${C.gray}┌${"─".repeat(cols - 2)}┐${C.reset}`)
  writeCentered(1, 0, cols, `${C.bold}${C.cyan}${HEADER_TITLE}${C.reset}`)

  if (data) {
    // 摘要信息
    const best = data.iterations.length > 0
      ? data.iterations.reduce((a, b) => (b.score > a.score ? b : a))
      : null

    const statusColor = data.status === "running" ? C.cyan : data.status === "completed" ? C.green : C.yellow
    const summaryLine = [
      `${C.gray}任务:${C.reset} ${C.bold}${data.task}${C.reset}`,
      `${C.gray}状态:${C.reset} ${statusColor}● ${data.status}${C.reset}`,
      best ? `${C.gray}最佳:${C.reset} ${C.green}第${best.round}轮 ${best.score.toFixed(1)}${C.reset}` : "",
      `${C.gray}迭代:${C.reset} ${data.iterations.length}/${data.totalRounds ?? "-"}${C.reset}`,
    ].filter(Boolean).join("  │  ")
    writeAt(3, 1, summaryLine.slice(0, cols - 2))

    // 分割线
    writeAt(4, 0, `${C.gray}├${"─".repeat(cols - 2)}┤${C.reset}`)

    // ── 调优曲线图区域 ──
    const chartTitle = `${C.bold}调优曲线图${C.reset}`
    writeAt(5, 1, chartTitle)

    const chartHeight = Math.min(16, Math.floor((rows - 14) / 2))
    const chartWidth = cols - 4
    if (data.iterations.length > 0) {
      const chart = renderLineChart(data, {
        width: chartWidth,
        height: chartHeight,
        color: true,
      })
      const chartLines = chart.split("\n")
      for (let i = 0; i < chartLines.length && 6 + i < rows - 2; i++) {
        writeAt(6 + i, 2, chartLines[i])
      }
    } else {
      writeAt(6, 2, `${C.gray}（暂无迭代数据）${C.reset}`)
    }

    // ── 分割线 ──
    const dividerRow = 6 + chartHeight + 1
    if (dividerRow < rows - 5) {
      writeAt(dividerRow, 0, `${C.gray}├${"─".repeat(cols - 2)}┤${C.reset}`)
    }

    // ── 迭代数据表 ──
    const tableTitle = `${C.bold}每轮迭代数据${C.reset}`
    if (dividerRow + 1 < rows) {
      writeAt(dividerRow + 1, 1, tableTitle)
    }

    const availableTableHeight = rows - dividerRow - 4
    const maxRows = Math.max(3, Math.floor(availableTableHeight))
    const table = renderTable(data, {
      color: true,
      maxRows: availableTableHeight > 0 ? maxRows : 5,
    })
    const tableLines = table.split("\n")
    for (let i = 0; i < tableLines.length && dividerRow + 2 + i < rows - 1; i++) {
      writeAt(dividerRow + 2 + i, 1, tableLines[i])
    }
  } else if (error) {
    // 错误显示
    writeAt(5, 1, `${C.red}${C.bold}数据加载错误${C.reset}`)
    writeAt(7, 2, `${C.yellow}${error}${C.reset}`)
    writeAt(9, 2, `${C.gray}等待 5 秒后重试...${C.reset}`)
    if (jsonPath) {
      writeAt(11, 2, `${C.gray}监控文件: ${jsonPath}${C.reset}`)
    } else {
      writeAt(11, 2, `${C.gray}未指定文件路径，正在搜索工作空间中的调优数据文件...${C.reset}`)
    }
  }

  // 底部边框 + 状态栏
  writeAt(rows - 2, 0, `${C.gray}├${"─".repeat(cols - 2)}┤${C.reset}`)

  const now = new Date()
  const timeStr = `${now.toLocaleTimeString("zh-CN", { hour12: false })}`
  const fileStr = jsonPath ? `${jsonPath}` : "自动搜索"
  const footer = `${C.gray}刷新时间: ${C.reset}${timeStr}  ${C.gray}│  数据源: ${C.reset}${fileStr}  ${C.gray}│  ${FOOTER_HINTS}${C.reset}`

  // 截断 footer 以适应宽度
  const footerText = stripAnsi(footer)
  if (footerText.length <= cols - 2) {
    writeAt(rows - 1, 1, footer)
  } else {
    // 只显示关键部分
    const shortFooter = `${C.gray}刷新: ${C.reset}${timeStr}  ${C.gray}│  ${FOOTER_HINTS}${C.reset}`
    writeAt(rows - 1, 1, shortFooter.slice(0, cols - 2))
  }

  // 确保光标在安全位置
  cursorTo(rows - 1, cols - 1)
}

// ─── 主循环 ─────────────────────────────────────────────

async function main(): Promise<void> {
  const args = process.argv.slice(2)
  const explicitPath = args[0] ?? null

  // 工作空间根目录 = 当前工作目录
  const workspaceDir = process.cwd()

  // 状态
  let data: TuningData | null = null
  let error: string | null = null
  let currentJsonPath: string | null = explicitPath

  // ── 初始化终端 ──
  hideCursor()

  // 设置原始模式捕获按键
  if (process.stdin.isTTY) {
    readline.emitKeypressEvents(process.stdin)
    process.stdin.setRawMode(true)
  }

  // 按键处理
  const keyHandler = (_str: string, key: { name?: string; ctrl?: boolean }): void => {
    if (key.ctrl && key.name === "c" || key.name === "q" || key.name === "escape") {
      cleanup()
      process.exit(0)
    }
    if (key.name === "r") {
      // 手动触发刷新
      refresh().then(() => renderTUI(data, error, currentJsonPath))
    }
  }
  process.stdin.on("keypress", keyHandler)

  // 终端大小变化时重绘
  process.stdout.on("resize", () => {
    renderTUI(data, error, currentJsonPath)
  })

  // ── 刷新函数 ──
  async function refresh(): Promise<void> {
    try {
      // 如果没有指定路径，搜索工作空间
      if (!currentJsonPath) {
        const found = findTuningData(workspaceDir)
        if (found) {
          currentJsonPath = found
        } else {
          data = null
          error = "未在工作空间中找到调优数据 JSON 文件。请确保文件名包含 'tuning' 或使用 'tuning-data.json'。"
          return
        }
      }

      // 加载数据
      const loaded = loadTuningData(currentJsonPath)
      data = loaded
      error = null
    } catch (e) {
      data = null
      if (e instanceof DataError) {
        error = e.message
      } else {
        error = (e as Error).message
      }
    }
  }

  // 首次刷新
  await refresh()
  renderTUI(data, error, currentJsonPath)

  // 定时刷新（每 5 秒）
  const timer = setInterval(async () => {
    await refresh()
    renderTUI(data, error, currentJsonPath)
  }, REFRESH_INTERVAL_MS)

  // ── 清理函数 ──
  function cleanup(): void {
    clearInterval(timer)
    showCursor()
    clearScreen()
    cursorHome()
    if (process.stdin.isTTY) {
      process.stdin.setRawMode(false)
      process.stdin.removeListener("keypress", keyHandler)
      process.stdin.pause()
    }
    process.stdout.write(`${C.gray}调优监控已退出。${C.reset}\n`)
  }

  // 退出信号处理
  process.on("SIGINT", () => {
    cleanup()
    process.exit(0)
  })
  process.on("SIGTERM", () => {
    cleanup()
    process.exit(0)
  })
  process.on("exit", () => {
    showCursor()
  })
}

// ─── 启动 ────────────────────────────────────────────────

main().catch((e) => {
  showCursor()
  console.error(`${C.red}启动失败: ${e.message}${C.reset}`)
  process.exit(1)
})
