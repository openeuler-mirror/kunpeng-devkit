#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=/opt/ai-system-migration
SKILL_DIR=${SKILL_DIR:-/opt/ai-system-migration/skill}

cd "$SKILL_DIR"
python3 bin/ai_system_migration.py init --workspace "$WORKSPACE"
mkdir -p "$WORKSPACE/config" "$WORKSPACE/packages"
cp -n config/templates/migration_config.yaml "$WORKSPACE/config/migration_config.yaml"
cp -n config/templates/credentials.yaml.example "$WORKSPACE/config/credentials.yaml"

cat <<'TIP'
请先完成两件事：
1. 把 devkit_disk_scan.sh 放到 /opt/ai-system-migration/packages/devkit_disk_scan.sh
2. 修改 /opt/ai-system-migration/config/migration_config.yaml 中 source.ssh.host/source.ssh.username/source.ssh.private_key_path

然后执行：
python3 bin/ai_system_migration.py phase source-scan --config /opt/ai-system-migration/config/migration_config.yaml --dry-run

确认 dry-run 生成的 ssh/scp 命令正确后，再由集成框架去掉 dry-run 执行真实远程扫描。
TIP
