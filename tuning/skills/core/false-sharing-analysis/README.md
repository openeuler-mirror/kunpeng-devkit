# false-sharing-analysis

该 skill 结合 `devopt` memory 输出与 C/C++ 项目源码，只把 `FS` 访问端点映射到具体变量、字段或数组元素，并给出或实施伪共享源码修复。其他记录和访问同一逻辑值的情况不在分析与修复范围内。核心入口是 [SKILL.md](SKILL.md)。

已经有分析结果时：

```text
使用 $false-sharing-analysis 分析下面的 devopt memory 输出，判断伪共享是否成立；如果我明确要求修复或优化，只修改直接相关的源码。
```

需要从运行进程自动采集时：

```bash
bash scripts/collect-memory-analysis.sh -p <PID> --devopt /XXXXX/devopt.sh
```

`--devopt` 必须传入 tar.gz 解压后的实际脚本路径，例如 `/XXXXX/devopt.sh`。采集脚本自动执行 `record`、memory 数据追加和 `script -t memory` 三个阶段，`-d` 默认是 10 秒。它只负责生成分析证据；agent 读取结果后完成源码映射与伪共享判定，用户明确要求修复或优化时修改直接相关的源码。第一步生成的 rawdata 不在当前目录时，增加 `--rawdata-dir DIR`；已有 rawdata 时可用 `-i FILE` 从第二阶段继续。

只做分析时：

```text
使用 $false-sharing-analysis 分析下面的 devopt memory 输出并结合当前项目源码定位变量。给出文件的修改建议、证据、置信度和补丁草案。
```

完整格式与分析过程见 `references/example.md`。已有 devopt 结果时不再采集；没有结果时，先确认 SPE、root 权限、`devopt.sh` 路径和 PID，再决定是否采集。agent 与应用可能处于不同环境，PC 不同不能单独证明证据来自旧版本。skill 不会修改 Makefile、CMake 或其他构建配置。
