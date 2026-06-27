#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=${WORKSPACE:-/opt/ai-system-migration}
SKILL_HOME=${SKILL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}

python3 "$SKILL_HOME/bin/ai_system_migration.py" init --workspace "$WORKSPACE"
mkdir -p "$WORKSPACE/config"
cp -n "$SKILL_HOME/config/templates/migration_config.yaml" "$WORKSPACE/config/migration_config.yaml"
cp -n "$SKILL_HOME/config/templates/credentials.yaml.example" "$WORKSPACE/config/credentials.yaml"

python3 "$SKILL_HOME/bin/ai_system_migration.py" run --config "$WORKSPACE/config/migration_config.yaml" --dry-run
