#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR=${SKILL_DIR:-/home/hjn/trae-workspace/system-migration-skill-remote}
CONFIG=${CONFIG:-/opt/ai-system-migration/config/migration_config.yaml}
CREDENTIALS=${CREDENTIALS:-/opt/ai-system-migration/config/credentials.yaml}

cd "$SKILL_DIR"

python3 bin/ai_system_migration.py phase package-resolve --config "$CONFIG" --credentials "$CREDENTIALS" --execute
python3 bin/ai_system_migration.py phase middleware --config "$CONFIG" --credentials "$CREDENTIALS" --execute
python3 bin/ai_system_migration.py phase database-install --config "$CONFIG" --credentials "$CREDENTIALS" --execute
python3 bin/ai_system_migration.py phase database-migration --config "$CONFIG" --credentials "$CREDENTIALS" --execute
python3 bin/ai_system_migration.py phase report --config "$CONFIG" --credentials "$CREDENTIALS"
