#!/usr/bin/env bash
set -euo pipefail

mkdir -p /opt/migration/packages
cp config.yaml /opt/migration/config.yaml

# 请提前放入：
# /opt/migration/packages/php-7.0.33.tar.gz
# /opt/migration/packages/app.tar.gz 或 app.zip
# /opt/migration/packages/*.rpm

python3 bin/php_arm_migration.py \
  --config /opt/migration/config.yaml \
  --app-package /opt/migration/packages/app.tar.gz \
  --mode all
