/**
 * 调优数据类型定义与 JSON 加载模块
 * 负责在工作空间中搜索、解析调优过程的 JSON 数据
 */

import { readFileSync, existsSync, readdirSync, statSync } from "fs"
import { join, extname, basename } from "path"

// ─── 类型定义 ─────────────────────────────────────────────

export interface TuningIteration {
  round: number
  score: number
  improvement: number
  params: Record<string, string | number>
  metrics: Record<string, number>
  status: string
  timestamp: string
}

export interface TuningData {
  task: string
  status: string
  startTime: string
  totalRounds?: number
  currentRound?: number
  bestRound?: number
  bestScore?: number
  baseScore?: number
  iterations: TuningIteration[]
}

export class DataError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "DataError"
  }
}

// ─── 数据搜索与加载 ──────────────────────────────────────

/** 调优数据文件的候选名称模式 */
const TUNING_FILE_PATTERNS = [
  "tuning-data.json",
  "tuning_data.json",
  "tuning.json",
  "tuning-result.json",
  "tuning_results.json",
  "perf-tuning.json",
  "optimization.json",
]

/**
 * 在指定目录（含一级子目录）中搜索调优数据 JSON 文件
 * @param dir 搜索根目录
 * @returns 找到的文件绝对路径，未找到返回 null
 */
export function findTuningData(dir: string): string | null {
  // 1. 先在根目录按候选名称搜索
  for (const name of TUNING_FILE_PATTERNS) {
    const filePath = join(dir, name)
    if (existsSync(filePath)) return filePath
  }

  // 2. 扫描根目录下所有 .json 文件，匹配名称含 "tuning" 或 "optim"
  try {
    const entries = readdirSync(dir)
    for (const entry of entries) {
      const fullPath = join(dir, entry)
      const stat = statSync(fullPath)
      if (!stat.isFile()) continue
      if (extname(entry) !== ".json") continue
      const lower = entry.toLowerCase()
      if (lower.includes("tuning") || lower.includes("optim") || lower.includes("converge")) {
        return fullPath
      }
    }
  } catch {
    // 目录读取失败，忽略
  }

  // 3. 在一级子目录中搜索
  try {
    const entries = readdirSync(dir)
    for (const entry of entries) {
      const subDir = join(dir, entry)
      try {
        const stat = statSync(subDir)
        if (!stat.isDirectory()) continue
      } catch {
        continue
      }
      for (const name of TUNING_FILE_PATTERNS) {
        const filePath = join(subDir, name)
        if (existsSync(filePath)) return filePath
      }
      // 子目录中的匹配名称 json
      try {
        const subEntries = readdirSync(subDir)
        for (const sub of subEntries) {
          const fullPath = join(subDir, sub)
          try {
            if (!statSync(fullPath).isFile()) continue
          } catch {
            continue
          }
          if (extname(sub) !== ".json") continue
          const lower = sub.toLowerCase()
          if (lower.includes("tuning") || lower.includes("optim")) {
            return fullPath
          }
        }
      } catch {
        // 忽略
      }
    }
  } catch {
    // 忽略
  }

  return null
}

/**
 * 加载并解析调优数据 JSON 文件
 * @param filePath JSON 文件路径
 * @returns 解析后的 TuningData 对象
 */
export function loadTuningData(filePath: string): TuningData {
  if (!existsSync(filePath)) {
    throw new DataError(`文件不存在: ${filePath}`)
  }

  let raw: string
  try {
    raw = readFileSync(filePath, "utf-8")
  } catch (e) {
    throw new DataError(`读取文件失败: ${filePath} - ${(e as Error).message}`)
  }

  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch (e) {
    throw new DataError(`JSON 解析失败: ${filePath} - ${(e as Error).message}`)
  }

  return validateTuningData(json)
}

/**
 * 校验 JSON 结构并转换为 TuningData
 */
function validateTuningData(json: unknown): TuningData {
  if (typeof json !== "object" || json === null) {
    throw new DataError("JSON 根节点必须为对象")
  }

  const obj = json as Record<string, unknown>

  const iterations = obj["iterations"]
  if (!Array.isArray(iterations)) {
    throw new DataError("缺少 iterations 数组字段")
  }

  const parsed: TuningIteration[] = iterations.map((item, idx) => {
    if (typeof item !== "object" || item === null) {
      throw new DataError(`第 ${idx + 1} 轮迭代数据格式错误`)
    }
    const it = item as Record<string, unknown>
    return {
      round: typeof it["round"] === "number" ? it["round"] : idx + 1,
      score: typeof it["score"] === "number" ? it["score"] : 0,
      improvement: typeof it["improvement"] === "number" ? it["improvement"] : 0,
      params: (it["params"] as Record<string, string | number>) ?? {},
      metrics: (it["metrics"] as Record<string, number>) ?? {},
      status: typeof it["status"] === "string" ? it["status"] : "unknown",
      timestamp: typeof it["timestamp"] === "string" ? it["timestamp"] : "",
    }
  })

  return {
    task: typeof obj["task"] === "string" ? obj["task"] : "unknown task",
    status: typeof obj["status"] === "string" ? obj["status"] : "unknown",
    startTime: typeof obj["startTime"] === "string" ? obj["startTime"] : "",
    totalRounds: typeof obj["totalRounds"] === "number" ? obj["totalRounds"] : undefined,
    currentRound: typeof obj["currentRound"] === "number" ? obj["currentRound"] : undefined,
    bestRound: typeof obj["bestRound"] === "number" ? obj["bestRound"] : undefined,
    bestScore: typeof obj["bestScore"] === "number" ? obj["bestScore"] : undefined,
    baseScore: typeof obj["baseScore"] === "number" ? obj["baseScore"] : undefined,
    iterations: parsed,
  }
}

/**
 * 获取数据中最佳迭代轮次
 */
export function getBestIteration(data: TuningData): TuningIteration | null {
  if (data.iterations.length === 0) return null
  let best = data.iterations[0]
  for (const it of data.iterations) {
    if (it.score > best.score) best = it
  }
  return best
}

/**
 * 获取最近一轮迭代
 */
export function getLatestIteration(data: TuningData): TuningIteration | null {
  if (data.iterations.length === 0) return null
  return data.iterations[data.iterations.length - 1]
}
