#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PRECHECK_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_ROOT=$(CDPATH= cd -- "$PRECHECK_DIR/.." && pwd)
PLAN_TOOL="$TARGET_ROOT/scripts/migration_plan.py"

usage() {
  echo "Usage: sh migration-precheck/scripts/run-precheck.sh --plan <migration-plan.json>"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

run_resolver() {
  if "$@"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 20 ] || return "$rc"
  return 0
}

PLAN=
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -n "$PLAN" ] || die "--plan is required" 2
PLAN=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PLAN")
[ -r "$PLAN" ] || die "migration-plan.json is not readable: $PLAN" 2

MIGRATION_WORK_DIR=$(python3 "$PLAN_TOOL" work-dir --plan "$PLAN")
WORK="$MIGRATION_WORK_DIR/precheck"
mkdir -p "$WORK" "$MIGRATION_WORK_DIR/packages" "$MIGRATION_WORK_DIR/tools" \
  "$MIGRATION_WORK_DIR/licenses" "$MIGRATION_WORK_DIR/tmp"

TMPDIR="$MIGRATION_WORK_DIR/tmp"
TMP="$TMPDIR"
TEMP="$TMPDIR"
export TMPDIR TMP TEMP

sh "$SCRIPT_DIR/check-target.sh" \
  --plan "$PLAN" \
  --work-dir "$MIGRATION_WORK_DIR" \
  > "$WORK/target-facts.tsv" \
  2> "$WORK/target-facts.err"

python3 "$PLAN_TOOL" merge-target \
  --plan "$PLAN" \
  --facts "$WORK/target-facts.tsv"

python3 "$PLAN_TOOL" manifest \
  --plan "$PLAN" \
  --output "$WORK/package-manifest.tsv"

sh "$SCRIPT_DIR/prepare-packages.sh" \
  --plan "$PLAN" \
  --work-dir "$MIGRATION_WORK_DIR" \
  --manifest "$WORK/package-manifest.tsv" \
  > "$WORK/package-status.tsv" \
  2> "$WORK/package-status.err"

python3 "$PLAN_TOOL" merge-packages \
  --plan "$PLAN" \
  --status "$WORK/package-status.tsv"

python3 "$PLAN_TOOL" check-licenses \
  --plan "$PLAN" \
  > "$WORK/license-status.json"

# Exit code 20 means the resolver found a normal precheck blocking item. Continue
# the remaining resolvers so finalize can report all missing tools in one pass.
run_resolver python3 "$SCRIPT_DIR/resolve-devkit.py" \
  --plan "$PLAN" \
  --work-dir "$MIGRATION_WORK_DIR"

run_resolver python3 "$SCRIPT_DIR/resolve-java-tools.py" \
  --plan "$PLAN" \
  --work-dir "$MIGRATION_WORK_DIR"

run_resolver python3 "$SCRIPT_DIR/resolve-sql-analysis.py" \
  --plan "$PLAN" \
  --work-dir "$MIGRATION_WORK_DIR"

python3 "$PLAN_TOOL" finalize \
  --plan "$PLAN" \
  --report "$WORK/migration-plan-report.md"
