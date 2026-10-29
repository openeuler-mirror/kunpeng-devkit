#!/usr/bin/env bun
/**
 * 构建脚本：使用 Bun 编译 TypeScript/TSX 源文件
 *
 * 功能
 *   - 编译 src/ 下所有 .ts/.tsx 文件到 dist/
 *   - 正确处理 SolidJS JSX（@opentui/solid 自动运行时）
 *   - 编译前运行 tsc 类型检查
 *   - 可选：将编译产物复制到 .opencode/plugins/
 *   - global/workspace 部署时自动复制 tui.json 并重写插件路径
 *
 * 用法
 *   bun run build.mjs              编译全部（类型检查 + 输出）
 *   bun run build.mjs --check      仅类型检查，不输出文件
 *   bun run build.mjs --plugin     仅编译 TUI 插件
 *   bun run build.mjs --deploy                 部署到项目本地 .opencode/plugins/
 *   bun run build.mjs --deploy global          部署到全局 ~/.opencode/plugins/
 *   bun run build.mjs --deploy workspace <path>  部署到指定工作空间 <path>/.opencode/plugins/
 *   bun run build.mjs --watch      监听文件变化自动重新编译
 *
 * 环境要求
 *   - Bun >= 1.0
 *   - TypeScript（作为 devDependency）
 */

import { build } from "bun"
import { mkdir, rm, copyFile, exists } from "node:fs/promises"
import { join, resolve } from "node:path"
import { homedir } from "node:os"
// @opentui/solid 提供的 SolidJS JSX transform 插件
// 用 babel-preset-solid 把 .tsx 编成 SolidJS 风格（getter props / createComponent / createElement+spread）
// 这是 OpenCode 加载 .tsx 插件时使用的 transform；构建时同样必须使用，否则 Bun 会用 React 风格 jsxDEV
// （急切求值 props），破坏 SolidJS 响应式
import solidTransformPlugin from "@opentui/solid/bun-plugin"

// ─── 常量 ───────────────────────────────────────────────

const ROOT = import.meta.dir

/** 源文件目录 */
const SRC_DIR = join(ROOT, "src")

/** 编译输出目录 */
const DIST_DIR = join(ROOT, "dist")

/** OpenCode 插件安装目录（项目本地）*/
const PLUGINS_DIR = join(ROOT, ".opencode", "plugins")

/** OpenCode 全局插件安装目录（~/.opencode/plugins/）*/
const GLOBAL_PLUGINS_DIR = join(homedir(), ".opencode", "plugins")

/** TUI 配置文件（源）*/
const TUI_JSON_SRC = join(ROOT, "tui.json")

/**
 * 运行时由 OpenCode 宿主提供的依赖，打包时标记为 external
 * 不标记 external 会导致 Bun.build 静态分析 @opentui/core 内部
 * 对各平台原生包（darwin/win32/linux-*）的动态 import，
 * 而其中未安装的平台包会触发 "Could not resolve" 错误。
 */
const EXTERNAL = [
  "@opencode-ai/plugin",
  "@opentui/solid",
  "@opentui/core",
  "solid-js",
]

/** 构建入口 */
const ENTRY_POINTS = {
  /** TUI 插件（含 SolidJS JSX）*/
  plugin: join(SRC_DIR, "tuning-dashboard.tsx"),
  /** 独立 TUI 查看器 */
  viewer: join(SRC_DIR, "viewer.ts"),
  /** 测试脚本 */
  testRender: join(SRC_DIR, "test-render.ts"),
}

// ─── 工具函数 ───────────────────────────────────────────

/** 解析命令行参数 */
function parseArgs() {
  const args = process.argv.slice(2)

  // 解析 --deploy 子命令
  //   --deploy                  → 项目本地（默认）
  //   --deploy global           → 全局 ~/.opencode/plugins/ + tui.json
  //   --deploy workspace <path> → 指定工作空间 <path>/.opencode/plugins/ + tui.json
  let deployTarget = null
  let deployLabel = ""
  let deployMode = null
  let workspacePath = null
  const deployIdx = args.indexOf("--deploy")
  if (deployIdx !== -1) {
    const sub = args[deployIdx + 1]
    if (sub === "global") {
      deployTarget = GLOBAL_PLUGINS_DIR
      deployLabel = "全局目录"
      deployMode = "global"
    } else if (sub === "workspace") {
      const wsPath = args[deployIdx + 2]
      if (!wsPath) {
        log.error("--deploy workspace 需要指定路径，如: --deploy workspace /path/to/project")
        process.exit(1)
      }
      workspacePath = resolve(wsPath)
      deployTarget = join(workspacePath, ".opencode", "plugins")
      deployLabel = `工作空间 (${workspacePath})`
      deployMode = "workspace"
    } else {
      // --deploy 无子命令 → 项目本地
      deployTarget = PLUGINS_DIR
      deployLabel = "项目本地"
      deployMode = "local"
    }
  }

  return {
    checkOnly: args.includes("--check"),
    pluginOnly: args.includes("--plugin"),
    watch: args.includes("--watch"),
    deployTarget,
    deployLabel,
    deployMode,
    workspacePath,
  }
}

/** 彩色日志输出 */
const log = {
  info: (msg) => console.log(`\x1b[36m[info]\x1b[0m  ${msg}`),
  ok: (msg) => console.log(`\x1b[32m[ok]\x1b[0m    ${msg}`),
  warn: (msg) => console.log(`\x1b[33m[warn]\x1b[0m  ${msg}`),
  error: (msg) => console.error(`\x1b[31m[error]\x1b[0m ${msg}`),
}

// ─── 类型检查 ───────────────────────────────────────────

/**
 * 运行 TypeScript 类型检查（tsc --noEmit）
 * @returns 类型检查是否通过
 */
async function typeCheck() {
  log.info("运行类型检查 (tsc --noEmit)...")
  const proc = Bun.spawn(["bun", "x", "tsc", "--noEmit"], {
    cwd: ROOT,
    stdout: "pipe",
    stderr: "pipe",
  })

  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  const exitCode = await proc.exited

  if (stdout.trim()) console.log(stdout.trim())
  if (stderr.trim()) console.error(stderr.trim())

  if (exitCode !== 0) {
    log.error("类型检查失败，请修复上述错误")
    return false
  }

  log.ok("类型检查通过")
  return true
}

// ─── 编译 ───────────────────────────────────────────────

/**
 * 使用 Bun.build() 编译单个入口文件
 * @param entrypoint 入口文件路径
 * @param outdir     输出目录
 * @returns 编译是否成功
 */
async function compileFile(entrypoint, outdir) {
  const result = await build({
    entrypoints: [entrypoint],
    outdir,
    target: "bun",
    format: "esm",
    splitting: false,
    sourcemap: "inline",
    minify: false,
    // 运行时由 OpenCode 宿主提供的依赖，不打包进产物
    external: EXTERNAL,
    // SolidJS JSX transform：.tsx 经 babel-preset-solid 转为响应式（getter）props
    // 若不注册，Bun 默认走 React 风格 jsxDEV，props 急切求值，Show/For/信号失效
    plugins: [solidTransformPlugin],
  })

  if (!result.success) {
    for (const entry of result.logs) {
      console.error(entry)
    }
    return false
  }

  return true
}

/**
 * 编译全部入口文件
 * @param opts { pluginOnly } 是否仅编译插件
 * @returns 是否全部成功
 */
async function compileAll(opts = {}) {
  const { pluginOnly } = opts

  // 清理旧的输出目录
  if (await exists(DIST_DIR)) {
    await rm(DIST_DIR, { recursive: true })
  }
  await mkdir(DIST_DIR, { recursive: true })

  let allOk = true

  // ── 编译 TUI 插件（TSX，经 SolidJS transform）──
  log.info(`编译插件: ${ENTRY_POINTS.plugin}`)
  if (!await compileFile(ENTRY_POINTS.plugin, DIST_DIR)) {
    allOk = false
  } else {
    log.ok(`  -> ${join(DIST_DIR, "tuning-dashboard.js")}`)
  }

  if (!pluginOnly) {
    // ── 编译独立查看器 ──
    log.info(`编译查看器: ${ENTRY_POINTS.viewer}`)
    if (!await compileFile(ENTRY_POINTS.viewer, DIST_DIR)) {
      allOk = false
    } else {
      log.ok(`  -> ${join(DIST_DIR, "viewer.js")}`)
    }

    // ── 编译测试脚本 ──
    log.info(`编译测试脚本: ${ENTRY_POINTS.testRender}`)
    if (!await compileFile(ENTRY_POINTS.testRender, DIST_DIR)) {
      allOk = false
    } else {
      log.ok(`  -> ${join(DIST_DIR, "test-render.js")}`)
    }
  }

  return allOk
}

// ─── 部署插件 ───────────────────────────────────────────

/**
 * 将 tui.json 复制到目标位置并重写插件路径
 * @param mode  部署模式: "global" | "workspace"
 * @param wsPath  workspace 路径（workspace 模式时使用）
 * @returns 是否成功
 */
async function deployTuiJson(mode, wsPath) {
  if (!await exists(TUI_JSON_SRC)) {
    log.warn(`tui.json 源文件不存在: ${TUI_JSON_SRC}，跳过 tui.json 部署`)
    return false
  }

  const config = JSON.parse(await Bun.file(TUI_JSON_SRC).text())

  if (mode === "global") {
    // 全局: tui.json → ~/.opencode/tui.json, plugin 路径 → ./plugins/tuning-dashboard.js
    config.plugin = [["./plugins/tuning-dashboard.js", {}]]
    const destDir = join(homedir(), ".opencode")
    const destPath = join(destDir, "tui.json")
    await mkdir(destDir, { recursive: true })
    await Bun.write(destPath, JSON.stringify(config, null, 2) + "\n")
    log.ok(`已部署 tui.json 到全局目录: ${destPath}`)
  } else if (mode === "workspace") {
    // workspace: tui.json → <workspace>/tui.json, plugin 路径 → ./.opencode/plugins/tuning-dashboard.js
    config.plugin = [["./.opencode/plugins/tuning-dashboard.js", {}]]
    const destPath = join(wsPath, "tui.json")
    await Bun.write(destPath, JSON.stringify(config, null, 2) + "\n")
    log.ok(`已部署 tui.json 到工作空间: ${destPath}`)
  }
  return true
}

/**
 * 将编译产物复制到指定的插件目录
 * @param targetDir  目标插件目录（.opencode/plugins/）
 * @param label       部署目标描述（用于日志输出）
 * @param deployMode  部署模式: "local" | "global" | "workspace"
 * @param wsPath      workspace 路径（workspace 模式时使用）
 */
async function deployPlugin(targetDir, label, deployMode, wsPath) {
  const srcFile = join(DIST_DIR, "tuning-dashboard.js")
  const destFile = join(targetDir, "tuning-dashboard.js")

  if (!await exists(srcFile)) {
    log.error(`找不到编译产物: ${srcFile}`)
    return false
  }

  // 确保插件目录存在
  await mkdir(targetDir, { recursive: true })

  await copyFile(srcFile, destFile)
  log.ok(`已部署插件到 ${label}: ${destFile}`)

  // global/workspace 模式下同时部署 tui.json
  if (deployMode === "global" || deployMode === "workspace") {
    await deployTuiJson(deployMode, wsPath)
  }

  return true
}

// ─── 监听模式 ───────────────────────────────────────────

/**
 * 监听源文件变化，自动重新编译
 */
async function watchMode(opts) {
  const { watch: _watch, ...compileOpts } = opts

  // 首次编译
  await compileAll(compileOpts)

  log.info("监听文件变化中... (Ctrl+C 退出)")

  const watcher = new Bun.FileSystemWatcher({
    // 监听 src 目录下的 .ts/.tsx 文件
    paths: [SRC_DIR],
    async onChange() {
      log.info("检测到文件变化，重新编译...")
      await compileAll(compileOpts)
      if (opts.deployTarget) {
        await deployPlugin(opts.deployTarget, opts.deployLabel, opts.deployMode, opts.workspacePath)
      }
    },
  })

  // 保持进程运行
  await new Promise(() => {})
}

// ─── 主流程 ─────────────────────────────────────────────

async function main() {
  const args = parseArgs()

  console.log("")
  console.log("  Kunpeng Param Tuning Dashboard - Build Script")
  console.log("  ================================")
  console.log("")

  // ── 步骤 1：类型检查 ──
  const typeOk = await typeCheck()
  if (!typeOk) {
    process.exit(1)
  }

  // ── 仅类型检查模式 ──
  if (args.checkOnly) {
    console.log("")
    log.ok("类型检查完成（--check 模式，跳过编译）")
    return
  }

  // ── 步骤 2：编译 ──
  const compileOk = await compileAll({ pluginOnly: args.pluginOnly })
  if (!compileOk) {
    log.error("编译失败")
    process.exit(1)
  }

  // ── 步骤 3：部署（可选）──
  if (args.deployTarget) {
    if (!await deployPlugin(args.deployTarget, args.deployLabel, args.deployMode, args.workspacePath)) {
      log.warn("插件部署失败，但编译产物已在 dist/ 目录")
    }
  }

  // ── 监听模式 ──
  if (args.watch) {
    await watchMode({
      pluginOnly: args.pluginOnly,
      deployTarget: args.deployTarget,
      deployLabel: args.deployLabel,
      deployMode: args.deployMode,
      workspacePath: args.workspacePath,
    })
    return
  }

  console.log("")
  log.ok("构建完成")
  console.log("")
}

// ─── 启动 ───────────────────────────────────────────────

main().catch((e) => {
  log.error(`构建异常: ${e.message}`)
  // Bun.build 抛出的错误把详细信息放在 .logs 里，stack 可能为 undefined
  if (Array.isArray(e.logs)) {
    for (const entry of e.logs) console.error(entry)
  } else if (e.stack) {
    console.error(e.stack)
  }
  process.exit(1)
})
