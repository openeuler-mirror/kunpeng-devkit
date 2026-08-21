# Java 构建与 ARM64 验证

阶段：

```text
build → package_scan → verify
```

继续使用顶层 `<work_dir>/migration-result.json`。

## build

使用 baseline 阶段确认的构建命令重新构建。失败时返回 `NEEDS_AGENT_FIX / FIX_FINAL_BUILD`，修复后从 `build` 继续。

## package_scan

收集 Maven/Gradle/常见 `dist` 目录生成的 JAR/WAR，排除 sources、javadoc、tests、original-*、`*.plain.jar` 等辅助包，复制到 `<work_dir>/output/` 并记录 SHA-256。

每个最终制品执行：

```bash
ai-migration porting pkg-mig
```

出现 findings 时回到 `build` 修复源码或依赖后重新构建。多制品运行验证需要明确主制品时，通过 `<work_dir>/artifact-selection.json` 选择。

## verify

默认使用 `uname -m` 验证 ARM64；配置 `--verify-command` 时再执行运行/验收验证。验证命令可引用：

```text
{work_source}
{work_dir}
{output_dir}
{artifact}
```

最终状态：

- `SUCCESS`：SQL无待办、ARM64架构验证通过且运行/验收验证成功；
- `COMPLETED_WITH_ACTIONS`：已生成候选制品，但仍有 SQL、ARM64 或运行验证待办。

具体证据和待办记录在 `migration-result.json.verification` 与 `completion_actions`。
