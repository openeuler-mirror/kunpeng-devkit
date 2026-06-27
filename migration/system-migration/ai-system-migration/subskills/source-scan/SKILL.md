---
name: source-scan
summary: 调用源 x86 环境上的 devkit_disk_scan.sh 完成 Java 应用部署态采集、运行配置打包和扫描结果归档。
description: |
  当主 Skill 进入源端采集阶段时调用。该子 Skill 不重新实现磁盘扫描，只负责复用 devkit_disk_scan.sh 的参数能力，引导或读取配置，执行扫描，校验产物，并把需要用户确认的动态探测、数据库导出等动作写入非阻断交互队列。
---

# source-scan 子 Skill

## 目标

1. 默认由目标 ARM 机器通过 SSH/SCP 远程连接源 x86，以 root 在源 x86 上执行 `devkit_disk_scan.sh`。
2. 支持将目标 ARM 侧的扫描脚本上传到源 x86 的 `/opt/ai-system-migration-source/bin/devkit_disk_scan.sh`，扫描完成后拉回结果。
3. 采集 Linux binary、中间件 Jar、Java Runtime、Web 中间件、数据库组件、配置文件、应用包。
4. 输出并校验：
   - `components.json`
   - `files_map.json`
   - `java_runtime.json`
   - `specified_pack.json`
   - `components/`、`webapps/`、`conf/` 等采集产物目录
   - `result/devkit-component-<IP>-<timestamp>.tar.gz`
5. 源端默认只读，动态版本探测、数据库导出必须有确认记录。

## 输入

- `migration_config.yaml`
- `credentials.yaml`，仅在需要源库导出时读取
- `state/interaction_answers.json`

## 调用策略

默认执行模式为 `remote_ssh`：

1. 主 Skill/编排脚本部署在目标 ARM 的 `/opt/ai-system-migration/skill/`。
2. `devkit_disk_scan.sh` 先放在目标 ARM 的 `/opt/ai-system-migration/packages/devkit_disk_scan.sh`。
3. 主流程通过 SSH 在源 x86 上创建 `/opt/ai-system-migration-source/`。
4. 主流程将扫描脚本上传到源 x86 的 `/opt/ai-system-migration-source/bin/devkit_disk_scan.sh`。
5. 源 x86 执行扫描，输出到 `/opt/ai-system-migration-source/source_scan_output/`。
6. 目标 ARM 拉回扫描结果到 `/opt/ai-system-migration/workspace/source_scan/`。

默认扫描目录为 `/`。如果用户提供扫描目录，优先使用用户输入。

动态版本探测处理：

1. 若 `source.dynamic_version_probe.enabled=false` 且无用户确认，则不启用。
2. 若用户确认启用，只允许执行版本类只读命令，例如 `--version`、`-version`、`-v`、`version`。
3. 不允许执行会启动/停止服务、写文件、修改配置、清理数据的命令。

数据库导出处理：

1. 若 `collect_database_dump.enabled=true`，先生成交互任务。
2. 未确认前，不导出数据库。
3. 已确认后，根据源库类型调用安全导出工具。MySQL 默认 `mysqldump`；Oracle/SQL Server 第一版优先 DTS 动态迁移，不强制离线导出。

## 目标 ARM 侧远程执行命令模板

```bash
ssh root@<source-x86-ip> "mkdir -p /opt/ai-system-migration-source/bin /opt/ai-system-migration-source/source_scan_output"
scp /opt/ai-system-migration/packages/devkit_disk_scan.sh root@<source-x86-ip>:/opt/ai-system-migration-source/bin/devkit_disk_scan.sh
ssh root@<source-x86-ip> "chmod +x /opt/ai-system-migration-source/bin/devkit_disk_scan.sh"
ssh root@<source-x86-ip> "bash /opt/ai-system-migration-source/bin/devkit_disk_scan.sh -d / -o /opt/ai-system-migration-source/source_scan_output -l info -j 4 --resume"
scp -r root@<source-x86-ip>:/opt/ai-system-migration-source/source_scan_output/ /opt/ai-system-migration/workspace/source_scan/
```

## 源 x86 本地执行命令模板

仅当 `source.execution_mode=local_source` 时使用。

```bash
bash /opt/devkit/devkit_disk_scan.sh \
  -d / \
  -o /opt/ai-system-migration/workspace/source_scan \
  -l info \
  -j 4 \
  --resume
```

如启用动态探测：

```bash
bash /opt/devkit/devkit_disk_scan.sh \
  -d / \
  -o /opt/ai-system-migration/workspace/source_scan \
  -l info \
  -j 4 \
  --dynamic-version-probe \
  --resume
```

如用户额外指定打包路径：

```bash
bash /opt/devkit/devkit_disk_scan.sh \
  -d / \
  -o /opt/ai-system-migration/workspace/source_scan \
  -F /opt/app \
  -F /data/config \
  --resume
```

## 输出

写入阶段结果：

```json
{
  "phase": "source-scan",
  "status": "success",
  "scan_dir": "/",
  "output_dir": "/opt/ai-system-migration/workspace/source_scan",
  "result_archive": "/opt/ai-system-migration/workspace/source_scan/result/devkit-component-xxx.tar.gz",
  "artifacts": [
    "components.json",
    "files_map.json",
    "java_runtime.json",
    "specified_pack.json"
  ],
  "manual_confirm_items": [],
  "risks": []
}
```

## 失败处理

- 脚本不存在：生成 `waiting_input`，要求用户提供脚本路径。
- 非 root：生成 `failed`，提示用 root 执行。
- 关键 JSON 缺失：生成 `partially_success`，允许进入报告阶段但不允许自动迁移。
- 结果压缩包缺失：提示检查脚本运行日志。
