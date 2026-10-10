/**
 * ASCII 图表渲染模块
 * 提供调优曲线图、迭代数据表格的纯文本渲染
 */

import type { TuningData } from "./data"
import { getBestIteration, getLatestIteration } from "./data"

// ─── ANSI 颜色常量 ───────────────────────────────────────

export const C = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  gray: "\x1b[90m",
  bgBlue: "\x1b[44m",
  bgGreen: "\x1b[42m",
  bgRed: "\x1b[41m",
}

// ─── 通用工具 ────────────────────────────────────────────

function pad(str: string, len: number, align: "left" | "right" | "center" = "left"): string {
  const s = String(str)
  const diff = len - s.length
  if (diff <= 0) return s.slice(0, len)
  if (align === "right") return " ".repeat(diff) + s
  if (align === "center") {
    const left = Math.floor(diff / 2)
    return " ".repeat(left) + s + " ".repeat(diff - left)
  }
  return s + " ".repeat(diff)
}

function formatNum(n: number, decimals = 1): string {
  return n.toFixed(decimals)
}

function formatTime(ts: string): string {
  if (!ts) return "-"
  // 从 ISO 时间字符串中提取 HH:MM:SS
  const match = ts.match(/T(\d{2}:\d{2}:\d{2})/)
  return match ? match[1] : ts.slice(-8)
}

// ─── 调优曲线图渲染 ──────────────────────────────────────

export interface ChartOptions {
  width?: number
  height?: number
  showAxis?: boolean
  color?: boolean
}

/**
 * 渲染 ASCII 调优曲线图
 * 支持 M wide × N tall 的网格，自动缩放数据范围
 */
export function renderLineChart(data: TuningData, opts: ChartOptions = {}): string {
  const width = opts.width ?? 60
  const height = opts.height ?? 12
  const showAxis = opts.showAxis ?? true
  const useColor = opts.color ?? true

  if (data.iterations.length === 0) {
    return `${useColor ? C.gray : ""}（暂无迭代数据）${useColor ? C.reset : ""}`
  }

  const scores = data.iterations.map((it) => it.score)
  const minScore = Math.min(...scores)
  const maxScore = Math.max(...scores)
  const range = maxScore - minScore || 1

  // 图表绘图区域宽度 = 总宽度 - 左侧轴标签宽度
  const axisWidth = 8 // "95.0 ┤ " => 6 chars + padding
  const plotWidth = Math.max(width - axisWidth - 1, 10)
  const plotHeight = Math.max(height - 3, 5) // 留出底部 x 轴标签空间

  // 初始化网格
  const grid: string[][] = Array.from({ length: plotHeight }, () =>
    Array.from({ length: plotWidth }, () => " ")
  )

  // 计算每个数据点的 x, y 坐标
  const points = scores.map((score, i) => {
    const x = scores.length === 1
      ? Math.floor(plotWidth / 2)
      : Math.round((i / (scores.length - 1)) * (plotWidth - 1))
    const y = Math.round(plotHeight - 1 - ((score - minScore) / range) * (plotHeight - 1))
    return { x, y, score }
  })

  // 在网格中绘制连线
  for (let i = 0; i < points.length; i++) {
    const p = points[i]
    grid[p.y][p.x] = "●"

    if (i > 0) {
      const prev = points[i - 1]
      drawLine(grid, prev.x, prev.y, p.x, p.y)
    }
  }

  // 绘制 Baseline 基准线（data.baseScore，红色虚线）
  // 在数据线之后绘制，仅填充空格位置，数据点/线优先显示
  if (data.baseScore != null) {
    const baselineY = Math.max(0, Math.min(plotHeight - 1, Math.round(plotHeight - 1 - ((data.baseScore - minScore) / range) * (plotHeight - 1))))
    if (baselineY >= 0 && baselineY < plotHeight) {
      for (let x = 0; x < plotWidth; x++) {
        if (grid[baselineY][x] === " ") {
          grid[baselineY][x] = "┄"
        }
      }
    }
  }

  // 组装输出行
  const lines: string[] = []
  for (let row = 0; row < plotHeight; row++) {
    const yVal = maxScore - (row / (plotHeight - 1)) * range
    const axisLabel = pad(formatNum(yVal), 5, "right")
    const gridLine = grid[row].join("")

    if (useColor) {
      // 数据点着色：最佳绿色，最差红色，中间青色
      const coloredLine = gridLine
        .replace(/●/g, `${C.cyan}●${C.reset}`)
        .replace(/[─│╭╮╰╯╱╲]/g, `${C.cyan}$&${C.reset}`)
        .replace(/┄/g, `${C.red}┄${C.reset}`)
      lines.push(`${C.gray}${axisLabel}${C.reset} ${C.gray}┤${C.reset} ${coloredLine}`)
    } else {
      lines.push(`${axisLabel} ┤ ${gridLine}`)
    }
  }

  // x 轴底线
  if (showAxis) {
    const axisLine = "─".repeat(plotWidth)
    if (useColor) {
      lines.push(`${" ".repeat(5)} ${C.gray}└${axisLine}${C.reset}`)
    } else {
      lines.push(`${" ".repeat(5)} └${axisLine}`)
    }

    // x 轴标签
    const labels: string[] = Array.from({ length: plotWidth }, () => " ")
    const step = Math.max(1, Math.ceil(scores.length / Math.floor(plotWidth / 4)))
    for (let i = 0; i < scores.length; i += step) {
      const x = scores.length === 1
        ? Math.floor(plotWidth / 2)
        : Math.round((i / (scores.length - 1)) * (plotWidth - 1))
      const label = String(i + 1)
      for (let c = 0; c < label.length && x + c < plotWidth; c++) {
        labels[x + c] = label[c]
      }
    }
    if (useColor) {
      lines.push(`${" ".repeat(6)}${C.gray}${labels.join("")}${C.reset}`)
      lines.push(`${" ".repeat(6)}${C.gray}${pad("Round", plotWidth, "center")}${C.reset}`)
    } else {
      lines.push(`${" ".repeat(6)}${labels.join("")}`)
      lines.push(`${" ".repeat(6)}${pad("Round", plotWidth, "center")}`)
    }
  }

  return lines.join("\n")
}

/**
 * 在网格中绘制两点之间的 ASCII 线段（Bresenham 变体）
 */
function drawLine(grid: string[][], x1: number, y1: number, x2: number, y2: number): void {
  const dx = x2 - x1
  const dy = y2 - y1
  const steps = Math.max(Math.abs(dx), Math.abs(dy))

  for (let i = 1; i < steps; i++) {
    const t = i / steps
    const x = Math.round(x1 + dx * t)
    const y = Math.round(y1 + dy * t)
    if (y >= 0 && y < grid.length && x >= 0 && x < grid[0].length) {
      if (grid[y][x] === " " || grid[y][x] === "·") {
        // 判断线段方向
        const localDx = Math.round(dx * (1 / steps) * 100) / 100
        const localDy = Math.round(dy * (1 / steps) * 100) / 100
        if (Math.abs(localDy) < 0.01) {
          grid[y][x] = "─"
        } else if (Math.abs(localDx) < 0.01) {
          grid[y][x] = "│"
        } else if ((localDx > 0 && localDy < 0) || (localDx < 0 && localDy > 0)) {
          grid[y][x] = "╱"
        } else {
          grid[y][x] = "╲"
        }
      }
    }
  }
}

// ─── 迭代数据表格渲染 ───────────────────────────────────

export function renderTable(data: TuningData, opts: { color?: boolean; maxRows?: number; width?: number; columns?: string[] } = {}): string {
  const useColor = opts.color ?? true
  const maxRows = opts.maxRows ?? 0 // 0 = 显示全部
  const best = getBestIteration(data)

  // 可选列筛选（默认全部 5 列）
  const allCols = ["Round", "Performance", "Improvement", "Timestamp", "Status"]
  const allRatios = [0.10, 0.20, 0.20, 0.30, 0.20]
  const selected = opts.columns ?? allCols
  const colIdx = selected.map(s => allCols.indexOf(s)).filter(i => i >= 0)
  const cols = colIdx.map(i => allCols[i])
  // 重新归一化选中列的比例
  const selRatios = colIdx.map(i => allRatios[i])
  const ratioSum = selRatios.reduce((a, b) => a + b, 0)
  const colRatios = selRatios.map(r => r / ratioSum)

  const rows = data.iterations
  const displayRows = maxRows > 0 ? rows.slice(-maxRows) : rows
  const truncated = maxRows > 0 && rows.length > maxRows

  const totalWidth = opts.width ?? 60
  const colWidths = colRatios.map(r => Math.max(Math.floor(totalWidth * r), 6))

  // 边框行
  const topBorder = "┌" + colWidths.map((w) => "─".repeat(w + 2)).join("┬") + "┐"
  const midBorder = "├" + colWidths.map((w) => "─".repeat(w + 2)).join("┼") + "┤"
  const botBorder = "└" + colWidths.map((w) => "─".repeat(w + 2)).join("┴") + "┘"

  const lines: string[] = []

  // 边框使用灰色
  const bc = useColor ? C.gray : ""

  lines.push(`${bc}${topBorder}${useColor ? C.reset : ""}`)

  // 表头行
  const headerCells = cols.map((c, i) => ` ${pad(c, colWidths[i], "center")} `).join("│")
  if (useColor) {
    lines.push(`${bc}│${C.bold}${headerCells}${C.reset}${bc}│${C.reset}`)
  } else {
    lines.push(`│${headerCells}│`)
  }

  lines.push(`${bc}${midBorder}${useColor ? C.reset : ""}`)

  // 数据行
  if (truncated) {
    const dots = colWidths.map((w) => ` ${pad("...", w, "center")} `).join("│")
    lines.push(`${bc}│${dots}│${C.reset}`)
  }

  for (const it of displayRows) {
    const isBest = best !== null && it.round === best.round

    // 单元格内容与对齐方式（按选中列筛选）
    const allTexts = [
      String(it.round) + (isBest ? "*" : ""),
      formatNum(it.score),
      (it.improvement >= 0 ? "+" : "") + formatNum(it.improvement) + "%",
      formatTime(it.timestamp),
      it.status,
    ]
    const allAligns: ("left" | "right" | "center")[] = ["center", "right", "right", "center", "center"]
    const cellTexts = colIdx.map(i => allTexts[i])
    const cellAligns = colIdx.map(i => allAligns[i])

    if (useColor) {
      // 每列独立颜色
      const scoreColor = C.cyan
      const improveColor = it.improvement > 0 ? C.green : it.improvement < 0 ? C.red : C.gray
      const sl = it.status.toLowerCase()
      const statusColor = /complete|success|done/.test(sl) ? C.green
        : /run|active|progress/.test(sl) ? C.cyan
        : /fail|error/.test(sl) ? C.red
        : C.yellow
      const allColors = [isBest ? C.green : "", scoreColor, improveColor, C.gray, statusColor]
      const cellColors = colIdx.map(i => allColors[i])

      const cells = cellTexts.map((text, i) =>
        ` ${cellColors[i]}${pad(text, colWidths[i], cellAligns[i])}${C.reset} `
      ).join(`${bc}│${C.reset}`)

      lines.push(`${bc}│${C.reset}${cells}${bc}│${C.reset}`)
    } else {
      const cells = cellTexts.map((text, i) =>
        ` ${pad(text, colWidths[i], cellAligns[i])} `
      ).join("│")

      lines.push(`│${cells}│`)
    }
  }

  lines.push(`${bc}${botBorder}${C.reset}`)

  return lines.join("\n")
}

// ─── 摘要信息渲染 ───────────────────────────────────────

export function renderSummary(data: TuningData, opts: { color?: boolean } = {}): string {
  const useColor = opts.color ?? true
  const best = getBestIteration(data)
  const latest = getLatestIteration(data)
  const ec = useColor ? C.gray : ""

  const lines: string[] = []

  const statusColor = data.status === "running"
    ? (useColor ? C.cyan : "")
    : data.status === "completed"
      ? (useColor ? C.green : "")
      : (useColor ? C.yellow : "")

  // 第一行：任务名 + 状态
  if (useColor) {
    lines.push(`${C.bold}${data.task}${C.reset}  ${statusColor}● ${data.status}${C.reset}`)
  } else {
    lines.push(`${data.task}  ● ${data.status}`)
  }

  // 第二行：关键指标
  const parts: string[] = []
  if (data.totalRounds) {
    parts.push(`计划轮次: ${data.currentRound ?? "-"}/${data.totalRounds}`)
  }
  if (data.iterations.length > 0) {
    parts.push(`已完成: ${data.iterations.length}`)
  }
  if (best) {
    parts.push(`最佳: 第${best.round}轮 ${formatNum(best.score)}`)
  }
  if (latest) {
    parts.push(`最新: ${formatNum(latest.score)}`)
  }

  lines.push(`${ec}${parts.join("  │  ")}${useColor ? C.reset : ""}`)

  return lines.join("\n")
}

// ─── 内联精简渲染（用于 OpenCode 工具输出）──────────────

export function renderInline(data: TuningData): string {
  return [
    renderSummary(data, { color: true }),
    "",
    renderLineChart(data, { width: 64, height: 12, color: true }),
    "",
    renderTable(data, { color: true }),
  ].join("\n")
}
