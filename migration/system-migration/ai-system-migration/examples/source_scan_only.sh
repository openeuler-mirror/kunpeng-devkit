#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=${WORKSPACE:-/opt/ai-system-migration}
SKILL_HOME=${SKILL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}
CONFIG=${1:-$WORKSPACE/config/migration_config.yaml}

python3 "$SKILL_HOME/bin/ai_system_migration.py" phase source-scan --config "$CONFIG" --dry-run
