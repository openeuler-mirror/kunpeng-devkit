# Java 构建与 ARM64 验证

阶段：

```text
build → package_scan → verify
```

继续使用顶层 `<work_dir>/migration-result.json`。

## build

使用 baseline 阶段自动识别并确认的构建命令重新构建。失败时返回 `NEEDS_AGENT_FIX / FIX_FINAL_BUILD`，修复后重新执行顶层命令自动从 `build` 继续。

## package_scan

收集 Maven/Gradle/常见 `dist` 目录生成的 JAR/WAR，排除 sources、javadoc、tests、original-*、`*.plain.jar` 等辅助包，复制到 `<work_dir>/output/` 并记录 SHA-256。

每个最终制品执行：

```bash
ai-migration porting pkg-mig -r csv
```

制品扫码同样严格按 `returncode` 判断：

```text
returncode == 0
→ 制品扫码通过
→ 不解析 CSV
→ 继续 verify

returncode != 0
→ 制品存在兼容性问题
→ 只读取 *_zh.csv
→ 忽略 *_en.csv
→ 根据中文 CSV 报告修复源码或依赖并重新构建
```

非 0 场景如果没有生成 `*_zh.csv`，返回 `AI_MIGRATION_PACKAGE_ZH_CSV_REPORT_MISSING`；中文 CSV 报告无法读取/解析时返回 `AI_MIGRATION_CSV_REPORT_INVALID`。只要 `returncode != 0` 且存在有效中文 CSV 报告，制品扫码保持 `NEEDS_FIX`，由 Agent 根据 CSV 内容修复源码或依赖。

## verify

验证阶段不再接受外部可选参数，固定执行：

```bash
uname -m
```

返回值为 `aarch64` 或 `arm64` 时 ARM64 架构验证成功。最终状态：

- `SUCCESS`：SQL 无待办、最终制品扫描通过且 ARM64 架构验证通过；
- `COMPLETED_WITH_ACTIONS`：已生成候选制品，但仍有 SQL 或 ARM64 架构验证待办。

具体证据和待办记录在 `migration-result.json.verification` 与 `completion_actions`。


verify 完成时额外生成 `<work_dir>/reports/final-source-changes.patch`，并把 compatibility Patch、SQL `source_code.patch` 和最终总 Patch 三个地址写入 `migration-result.json.patches/result_summary`。
