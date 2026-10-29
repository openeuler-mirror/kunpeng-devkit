/**
 * opencode 插件: ESC 停止当前任务时，同步停止运行中的 devkit 进程
 *
 * 场景: 调优训练由 tuner_monitor.py 在后台启动 devkit kat train/continue 子进程。
 * 用户在 opencode TUI 中按 ESC 中止当前任务时，opencode 仅取消当前 agent 循环，
 * 后台 devkit 训练进程会残留继续运行，占用 CPU/内存并持续修改系统参数。
 *
 * 本插件监听 opencode 事件流，检测到消息被中止（MessageAbortedError，即 ESC 触发）
 * 后，立即 kill 掉残留的 devkit 相关进程，实现"ESC 停止任务 = 同步停止训练"。
 *
 * 部署: 自动发现（.opencode/plugin/*.js），无需在 opencode.json 注册。
 */

/** devkit 相关进程匹配模式（配合 pkill -f 使用） */
const DEVKIT_PATTERNS = [
  // devkit kat train / continue / set 等子命令进程
  "[d]evkit kat",
  // devkit 内部 python 调优 CLI
  "[k]at_python_cli",
  // 调优监控脚本
  "[t]uner_monitor.py",
]

/** 可选: 额外需要停止的相关命令（如 db_bench 压测进程），可在此追加 */
const EXTRA_PATTERNS = []

/**
 * 判断事件是否为"用户中止消息"（ESC 触发）
 */
function isAbortedEvent(event) {
  if (!event) return false
  if (event.type === "message.updated") {
    const info = event.properties?.info
    if (info?.error?.name === "MessageAbortedError") return true
  }
  if (event.type === "session.error") {
    const err = event.properties?.error
    if (err?.name === "MessageAbortedError") return true
  }
  return false
}

/**
 * 同步停止匹配的 devkit 进程
 */
async function stopDevkitProcesses($) {
  const patterns = [...DEVKIT_PATTERNS, ...EXTRA_PATTERNS]
  for (const pattern of patterns) {
    try {
      await $`pkill -TERM -f ${pattern}`.quiet()
    } catch {
      // pkill 无匹配进程时返回非零，属正常情况，忽略
    }
  }
}

export default async ({ $ }) => {
  return {
    event: async ({ event }) => {
      if (isAbortedEvent(event)) {
        // ESC 中止: 同步停止 devkit 进程
        await stopDevkitProcesses($)
      }
    },
  }
}
