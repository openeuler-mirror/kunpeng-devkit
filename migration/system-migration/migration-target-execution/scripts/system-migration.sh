#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
usage() {
  printf '%s\n' \
    'Usage: system-migration.sh <command> [arguments]' \
    'Commands:' \
    '  work-dir Resolve and initialize MIGRATION_WORK_DIR from migration-plan.json' \
    '  inspect  Validate migration-plan.json and show required migration modules' \
    '  prepare  After target precheck, generate operation-plan.json' \
    '  approve  Record the user decision for operation-plan.json' \
    '  verify   Verify plan/approval digests before a target-mutating child Skill'
}
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
command_name=$1
shift
case "$command_name" in
  work-dir|inspect|prepare|approve|verify) exec python3 "$SCRIPT_DIR/migration_control.py" "$command_name" "$@" ;;
  -h|--help|help) usage ;;
  *) printf 'Unknown command: %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
