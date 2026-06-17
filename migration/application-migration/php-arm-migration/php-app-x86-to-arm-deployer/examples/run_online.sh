#!/usr/bin/env bash
set -euo pipefail

mkdir -p /opt/migration/packages
cp config.yaml /opt/migration/config.yaml

python3 bin/php_arm_migration.py \
  --config /opt/migration/config.yaml \
  --app-package /opt/migration/packages/app.tar.gz \
  --mode all
