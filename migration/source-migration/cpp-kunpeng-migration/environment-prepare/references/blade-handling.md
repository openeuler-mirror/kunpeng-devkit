# Blade 构建系统处理

> **何时加载**：项目使用 Blade 作为构建系统时，由 environment-prepare 主文档按需加载本参考文档，执行额外处理步骤。

---

## Step 1：检查项目中的 Blade 来源

在项目中搜索 blade zip 包、blade 目录、blade 入口脚本（含 blade.py）。

## Step 2：检查 Blade 的鲲鹏和 Python3 兼容性

如果 blade 以 zip 包形式存放在代码仓库中：

1. 解压 zip 包并检查 blade 版本（查看 `__init__.py` 或类似版本文件）。
2. 若 blade 版本低于 2.0（**2.0 之前不支持鲲鹏和 Python3**），**优先升级到 Blade 2.0**（避免直接跳 3.0 跨度过大）：
   - 从 [build-tools-reference.md](build-tools-reference.md) 选取下载链接，优先内部定制版，否则官方链接
   - 按链接下载并替换项目中的 blade zip 包
   - 验证新版可在 Python3 下运行（`python3 -m blade --version`）；2.0 仍不满足再升 3.0
3. 检查 Python 版本兼容性；若 blade 需 Python3 而系统默认 Python2，确保用 `python3` 调用 blade。
