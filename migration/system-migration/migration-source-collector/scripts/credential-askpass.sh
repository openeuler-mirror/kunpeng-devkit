#!/bin/sh
set -u

[ "${MIGRATION_CREDENTIAL_PROVIDER:-}" = macos-keychain ] || exit 1
[ -n "${MIGRATION_CREDENTIAL_ID:-}" ] || exit 1
command -v security >/dev/null 2>&1 || exit 1

exec security find-generic-password \
  -a "$MIGRATION_CREDENTIAL_ID" \
  -s migration-source-collector \
  -w
