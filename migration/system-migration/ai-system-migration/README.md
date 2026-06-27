# AI System Migration Skill

面向 Java 应用的 x86 -> ARM 端到端迁移 Skill 包。第一版聚焦部署态 Java 应用，默认目标为国产 ARM Linux 环境，优先支持 openEuler 系、CentOS ARM 等系统。

## 设计目标

- 主 Skill 默认部署在目标 ARM 机器上，通过 SSH/SCP 远程调用源 x86 机器上的 `devkit_disk_scan.sh` 完成采集；也支持退化为源端本地执行。
- 通过主 Skill + 子 Skill 的方式拆分复杂迁移流程。
- 子 Skill 负责交互、方案卡片、凭据收集、专项判断；主流程尽量不中断。
- 默认迁移模式下生成推荐方案，用户确认后自动迁移。
- 自定义迁移模式下允许选择迁移路线、安装版本、数据库迁移方式和模型接入方式。
- 最终输出 Markdown 报告、JSON 报告、JSONL 执行日志、配置文件和所有子 Skill 文档。

## 包结构

```text
ai-system-migration-skill/
├── SKILL.md                                  # 主 Skill
├── README.md
├── bin/
│   ├── ai_system_migration.py                # 迁移编排脚本骨架
│   └── lib/
│       ├── interaction_bus.py                # 非阻断交互队列
│       ├── scan_analyzer.py                  # 扫描结果解析
│       ├── route_planner.py                  # 默认/自定义迁移路线生成
│       ├── database_migrator.py              # DM/DTS 迁移辅助
│       ├── app_transformer.py                # Java 应用改造辅助
│       ├── deploy_verifier.py                # 启动验证辅助
│       └── report_writer.py                  # 报告生成
├── subskills/
│   ├── source-scan/SKILL.md
│   ├── scan-analysis/SKILL.md
│   ├── route/SKILL.md
│   ├── credential/SKILL.md
│   ├── middleware/SKILL.md
│   ├── database/SKILL.md
│   ├── app-transform/SKILL.md
│   ├── deploy-verify/SKILL.md
│   └── report/SKILL.md
├── config/templates/
│   ├── migration_config.yaml
│   ├── credentials.yaml.example
│   ├── model_config.yaml.example
│   └── route_plan.yaml.example
├── templates/
│   ├── dts/dm_dts_template.xml
│   ├── report_template.md
│   └── schemas/
├── examples/
│   ├── run_default.sh
│   ├── run_custom.sh
│   └── source_scan_only.sh
└── docs/
    ├── design.md
    ├── non_blocking_subagent_interaction.md
    └── default_route_matrix.md
```

## 快速使用：目标 ARM 侧执行，远程扫描源 x86

推荐把完整 Skill 放在目标 ARM 的 `/opt/ai-system-migration/skill/`，工作目录使用 `/opt/ai-system-migration/`。

```bash
mkdir -p /opt/ai-system-migration/skill /opt/ai-system-migration/packages
unzip ai-system-migration-skill.zip -d /opt/ai-system-migration/skill
cd /opt/ai-system-migration/skill

python3 bin/ai_system_migration.py init --workspace /opt/ai-system-migration
cp config/templates/migration_config.yaml /opt/ai-system-migration/config/migration_config.yaml
cp config/templates/credentials.yaml.example /opt/ai-system-migration/config/credentials.yaml

# 将 devkit_disk_scan.sh 放到目标 ARM，后续由主流程上传到源 x86
cp /path/to/devkit_disk_scan.sh /opt/ai-system-migration/packages/devkit_disk_scan.sh
chmod +x /opt/ai-system-migration/packages/devkit_disk_scan.sh

# 修改 migration_config.yaml 中的 source.ssh.host/username/private_key_path 后执行
python3 bin/ai_system_migration.py phase source-scan --config /opt/ai-system-migration/config/migration_config.yaml --dry-run
```

真实执行时，主流程会把 `/opt/ai-system-migration/packages/devkit_disk_scan.sh` 上传到源 x86 的 `/opt/ai-system-migration-source/bin/devkit_disk_scan.sh`，在源端执行扫描，再把 `/opt/ai-system-migration-source/source_scan_output/` 拉回目标 ARM 的 `/opt/ai-system-migration/workspace/source_scan/`。

> 说明：本包是 Skill + 编排脚本骨架，真正执行迁移时需要目标环境具备 root 权限、源端 `devkit_disk_scan.sh`、必要安装包、数据库迁移工具、JDK/中间件安装包等。

## 增强版变更：安装包搜索、禁止降级、DM 自动安装

本增强版新增以下脚本模块：

```text
bin/lib/package_resolver.py      # 本地/华为云鲲鹏归档/官方 URL 安装包搜索与下载
bin/lib/middleware_migrator.py   # 中间件路线强制执行，Tomcat->TongWeb 不允许静默降级
bin/lib/dm_installer.py          # DM 安装包搜索、静默安装、实例初始化、服务注册、SQL 导入辅助
```

新增可执行阶段：

```bash
python3 bin/ai_system_migration.py phase package-resolve --config /opt/ai-system-migration/config/migration_config.yaml --execute
python3 bin/ai_system_migration.py phase middleware --config /opt/ai-system-migration/config/migration_config.yaml --execute
python3 bin/ai_system_migration.py phase database-install --config /opt/ai-system-migration/config/migration_config.yaml --credentials /opt/ai-system-migration/config/credentials.yaml --execute
python3 bin/ai_system_migration.py phase database-migration --config /opt/ai-system-migration/config/migration_config.yaml --credentials /opt/ai-system-migration/config/credentials.yaml --execute
```

### 重要行为变化

- 如果 `route_plan.yaml` 中 Tomcat 目标是 TongWeb/东方通，但没有找到 TongWeb 安装包或 license，`middleware` 阶段会停止并返回 `waiting_input`。
- 不再自动降级安装 Apache Tomcat，除非显式配置：

```yaml
middleware:
  fallback_to_apache_tomcat: true
```

- DM 未安装时，会先搜索本地 DM 包，再尝试华为云鲲鹏归档仓和配置的官方 URL；找到后进入 `database-install`。
- 若 DM 包不存在，返回 `waiting_input`，不会伪造安装结果。

### 推荐补包目录

```bash
mkdir -p /opt/ai-system-migration/packages/tongweb
mkdir -p /opt/ai-system-migration/packages/dm

# 东方通示例
/opt/ai-system-migration/packages/tongweb/TongWeb*.tar.gz
/opt/ai-system-migration/packages/tongweb/license.dat

# 达梦示例
/opt/ai-system-migration/packages/dm/dm8_*_arm*.iso
# 或 /opt/ai-system-migration/packages/dm/DMInstall.bin
```

### 从上次中断处继续

如果你已经完成 source-scan、scan-analysis、route、app-transform，并且只是缺 TongWeb/DM，可以执行：

```bash
cd /home/hjn/trae-workspace/system-migration-skill-remote

python3 bin/ai_system_migration.py phase package-resolve \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase middleware \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase database-install \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase database-migration \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml \
  --execute

python3 bin/ai_system_migration.py phase report \
  --config /opt/ai-system-migration/config/migration_config.yaml \
  --credentials /opt/ai-system-migration/config/credentials.yaml
```
