# 目标 ARM 侧远程扫描源 x86 机器约定

## 执行模型

主 Skill 和编排脚本部署在目标 ARM 机器上。源 x86 机器只作为被扫描对象，不需要预先安装完整 Skill。

流程：

1. 在目标 ARM 上初始化 `/opt/ai-system-migration/`。
2. 将 `devkit_disk_scan.sh` 放到目标 ARM 的 `/opt/ai-system-migration/packages/devkit_disk_scan.sh`。
3. 主流程通过 SSH 连接源 x86 机器。
4. 主流程在源 x86 上创建 `/opt/ai-system-migration-source/`。
5. 主流程把扫描脚本上传到源 x86 的 `/opt/ai-system-migration-source/bin/devkit_disk_scan.sh`。
6. 在源 x86 上以 root 执行扫描：

```bash
bash /opt/ai-system-migration-source/bin/devkit_disk_scan.sh \
  -d / \
  -o /opt/ai-system-migration-source/source_scan_output \
  -l info \
  -j 4 \
  --resume
```

7. 扫描完成后，将 `/opt/ai-system-migration-source/source_scan_output/` SCP 回目标 ARM 的 `/opt/ai-system-migration/workspace/source_scan/`。
8. 后续 `scan-analysis`、`route`、`database`、`app-transform`、`deploy-verify` 都在目标 ARM 上基于回传结果执行。

## 推荐目录

目标 ARM：

```text
/opt/ai-system-migration/
├── SKILL.md
├── subskills/
├── bin/
├── config/
├── packages/
│   └── devkit_disk_scan.sh
├── workspace/
│   └── source_scan/              # 从源 x86 回传的扫描结果
├── logs/
└── state/
```

源 x86：

```text
/opt/ai-system-migration-source/
├── bin/
│   └── devkit_disk_scan.sh       # 由目标 ARM 上传
└── source_scan_output/           # 源端扫描输出目录
```

## 配置示例

```yaml
workspace: /opt/ai-system-migration
source:
  execution_mode: remote_ssh
  ssh:
    host: 192.168.1.10
    port: 22
    username: root
    private_key_path: /root/.ssh/id_rsa
  scan_script: /opt/ai-system-migration/packages/devkit_disk_scan.sh
  remote_workspace: /opt/ai-system-migration-source
  remote_scan_script: /opt/ai-system-migration-source/bin/devkit_disk_scan.sh
  remote_output_dir: /opt/ai-system-migration-source/source_scan_output
  scan_roots:
    - /
  output_dir: /opt/ai-system-migration/workspace/source_scan
```

## 密码方式说明

编排脚本骨架默认使用系统 `ssh/scp`，推荐 SSH key 或已建立的 SSH agent。

如果必须使用密码，建议由 `credential` 子 Skill 生成一次性 expect/sshpass 包装，不要把密码写入命令日志，也不要进入最终报告。
