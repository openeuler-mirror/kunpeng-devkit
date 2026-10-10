/**
 * 测试脚本：验证图表渲染逻辑（非 TUI 模式）
 * 运行: bun run src/test-render.ts
 */

import { loadTuningData } from "./data"
import { renderLineChart, renderTable, renderSummary, C } from "./chart"
import { join } from "path"

const dataFile = join(process.cwd(), "sample", "tuning-data.json")
const data = loadTuningData(dataFile)

console.log("\n" + "=".repeat(70) + "\n")
console.log("摘要信息:")
console.log(renderSummary(data, { color: false }))
console.log("\n" + "=".repeat(70) + "\n")
console.log("调优曲线图 (无色):")
console.log(renderLineChart(data, { width: 64, height: 12, color: false }))
console.log("\n" + "=".repeat(70) + "\n")
console.log("迭代数据表 (无色):")
console.log(renderTable(data, { color: false }))
console.log("\n" + "=".repeat(70) + "\n")
console.log("内联渲染预览完成。\n")
