#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/package.sh --config <file> --run-dir <dir>"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

config_get() {
  cfg_key=$1
  cfg_file=$2
  cfg_default=${3-}
  cfg_value=
  [ -r "$cfg_file" ] || {
    printf '%s' "$cfg_default"
    return
  }
  while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
    case "$cfg_line" in ''|'#'*) continue ;; esac
    [ "${cfg_line%%=*}" = "$cfg_key" ] || continue
    cfg_value=${cfg_line#*=}
    break
  done < "$cfg_file"
  [ -n "$cfg_value" ] && printf '%s' "$cfg_value" || printf '%s' "$cfg_default"
}

hash_file() {
  hash_target=$1
  if has_cmd sha256sum; then
    sha256sum "$hash_target" | awk '{print $1}'
  elif has_cmd openssl; then
    openssl dgst -sha256 "$hash_target" | awk '{print $NF}'
  elif has_cmd shasum; then
    shasum -a 256 "$hash_target" | awk '{print $1}'
  else
    printf ''
  fi
}

file_size() {
  size_target=$1
  if has_cmd stat; then
    stat -c '%s' "$size_target" 2>/dev/null || stat -f '%z' "$size_target" 2>/dev/null || echo 0
  else
    wc -c < "$size_target" 2>/dev/null || echo 0
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_text() {
  required_file=$1
  required_text=$2
  required_label=$3
  grep -Fq "$required_text" "$required_file" ||
    die "$required_label is missing from $(basename "$required_file")" 3
}

validate_json_syntax() {
  json_file=$1
  if has_cmd jq; then
    jq empty "$json_file" >/dev/null 2>&1 || die "Invalid JSON: $json_file" 3
  else
    first_char=$(sed -n 's/^[[:space:]]*\([^[:space:]]\).*$/\1/p' "$json_file" | head -n 1)
    last_char=$(sed -n 's/.*\([^[:space:]]\)[[:space:]]*$/\1/p' "$json_file" | tail -n 1)
    [ "$first_char" = '{' ] && [ "$last_char" = '}' ] ||
      die "JSON boundary check failed: $json_file; install jq for full syntax validation" 3
  fi
}

validate_collected_path() {
  collected_path=$1
  [ -n "$collected_path" ] || die "A COLLECTED artifact has an empty collected_path" 3
  case "$collected_path" in
    details/artifacts/*|details/database-export/*|details/logs/*) ;;
    *) die "Collected artifact path is outside an allowed details directory: $collected_path" 3 ;;
  esac
  case "$collected_path" in
    *'/../'*|*'/..'|../*|/*) die "Unsafe collected artifact path: $collected_path" 3 ;;
  esac
  [ -e "$RUN_DIR/$collected_path" ] ||
    die "A COLLECTED artifact is missing from the run directory: $collected_path" 3
}

CONFIG=
RUN_DIR=
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG=${2-}; shift 2 ;;
    --run-dir) RUN_DIR=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -r "$CONFIG" ] || die "Config file is required and must be readable" 2
[ -d "$RUN_DIR/details" ] || die "Invalid run directory" 2

REPORT="$RUN_DIR/collection-report.md"
PLAN_JSON="$RUN_DIR/migration-plan.json"
INTERNAL_DIR="$RUN_DIR/details/internal"
ARCHITECTURE_SUMMARY="$INTERNAL_DIR/architecture-summary.json"
DETAILS_ARCHIVE="$RUN_DIR/details/devkit-source-scan-details.tar.gz"

[ -s "$REPORT" ] || die "collection-report.md must be generated before packaging" 3
[ -s "$PLAN_JSON" ] || die "migration-plan.json must be generated before packaging" 3

validate_json_syntax "$PLAN_JSON"
grep -Eq '\{\{[^}]*\}\}' "$REPORT" "$PLAN_JSON" 2>/dev/null &&
  die "Output still contains unfilled template placeholders" 3

for report_heading in \
  '# 鲲鹏迁移采集与规划报告' \
  '## 1. 采集概览' \
  '## 2. 部署架构' \
  '## 3. 已确认迁移范围' \
  '## 4. 应用迁移方式' \
  '## 5. 已确认迁移路线' \
  '## 6. 已采集制品' \
  '## 7. 目标侧待处理事项'; do
  require_text "$REPORT" "$report_heading" "Required report heading"
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PLAN_TOOL="$SCRIPT_DIR/migration_plan.py"
[ -r "$PLAN_TOOL" ] || die "Collector migration plan tool is missing: $PLAN_TOOL" 3
python3 "$PLAN_TOOL" validate --plan "$PLAN_JSON" --phase collector >/dev/null ||
  die "migration-plan.json failed collector contract validation" 3

PATH_LIST="$RUN_DIR/details/.migration-plan-paths.$$"
python3 - "$PLAN_JSON" > "$PATH_LIST" <<'PYPLAN'
import json,sys
plan=json.load(open(sys.argv[1],encoding='utf-8-sig'))
route=plan.get('route') or {}
for group in ('middleware','database'):
    for item in route.get(group) or []:
        for value in (item.get('source') or {}).get('artifact_paths') or []:
            if isinstance(value,str) and value:
                print(value)
for app in route.get('application') or []:
    for package in app.get('packages') or []:
        value=package.get('local_path') if isinstance(package,dict) else None
        if isinstance(value,str) and value and not value.startswith('/'):
            print(value)
PYPLAN
while IFS= read -r main_collected_path || [ -n "$main_collected_path" ]; do
  validate_collected_path "$main_collected_path"
done < "$PATH_LIST"
rm -f "$PATH_LIST"

if has_cmd tar; then
  ARCHIVE_PROVIDER=tar
elif has_cmd busybox; then
  ARCHIVE_PROVIDER=busybox
else
  die "tar or busybox is required to build the final package; the collected directory is preserved" 5
fi

if [ -d "$INTERNAL_DIR" ]; then
  [ -s "$ARCHITECTURE_SUMMARY" ] ||
    die "details/internal/architecture-summary.json must be generated before packaging" 3
  validate_json_syntax "$ARCHITECTURE_SUMMARY"
  grep -Eq '\{\{[^}]*\}\}' "$ARCHITECTURE_SUMMARY" 2>/dev/null &&
    die "architecture-summary.json still contains unfilled template placeholders" 3
  for architecture_key in \
    '"schema_version"' \
    '"collection_id"' \
    '"summary"' \
    '"components"' \
    '"relations"' \
    '"supporting_refs"'; do
    require_text "$ARCHITECTURE_SUMMARY" "$architecture_key" "Required architecture summary field"
  done
  if has_cmd jq; then
    jq -e '
      (.collection_id | type == "string" and length > 0) and
      (.summary | type == "string" and length > 0) and
      (.components | type == "array") and
      (.relations | type == "array") and
      (.supporting_refs | type == "array")
    ' "$ARCHITECTURE_SUMMARY" >/dev/null 2>&1 ||
      die "architecture-summary.json failed semantic validation" 3
  fi

  ARTIFACT_INDEX="$INTERNAL_DIR/scan-results/collected-artifacts.tsv"
  VERSION_INDEX="$INTERNAL_DIR/scan-results/component-versions.tsv"
  AUDIT_FILE="$INTERNAL_DIR/audit/audit.tsv"
  [ -s "$ARTIFACT_INDEX" ] || die "Automatic artifact collection index is missing" 3
  [ -s "$VERSION_INDEX" ] || die "Component version probe index is missing" 3
  [ -f "$AUDIT_FILE" ] || die "Internal audit file is missing" 3
  TAB=$(printf '\t')
  while IFS="$TAB" read -r artifact_category artifact_classification artifact_component artifact_source artifact_collected artifact_size artifact_hash artifact_confidence artifact_basis artifact_status || [ -n "${artifact_category:-}" ]; do
    [ "${artifact_category:-}" = category ] && continue
    [ "${artifact_status:-}" = collected ] || continue
    validate_collected_path "$artifact_collected"
    actual_size=$(file_size "$RUN_DIR/$artifact_collected")
    [ "$actual_size" = "$artifact_size" ] ||
      die "Collected artifact size does not match its scan index: $artifact_collected" 3
    if [ -n "$artifact_hash" ]; then
      actual_hash=$(hash_file "$RUN_DIR/$artifact_collected")
      [ -z "$actual_hash" ] || [ "$actual_hash" = "$artifact_hash" ] ||
        die "Collected artifact checksum does not match its scan index: $artifact_collected" 3
    fi
  done < "$ARTIFACT_INDEX"
else
  [ -s "$DETAILS_ARCHIVE" ] || die "Source scan details are missing" 3
  if [ "$ARCHIVE_PROVIDER" = tar ]; then
    tar -tzf "$DETAILS_ARCHIVE" 2>/dev/null | grep -Eq '(^|/)architecture-summary\.json$' ||
      die "Existing source scan details archive lacks architecture-summary.json" 3
  else
    busybox tar -tzf "$DETAILS_ARCHIVE" 2>/dev/null | grep -Eq '(^|/)architecture-summary\.json$' ||
      die "Existing source scan details archive lacks architecture-summary.json" 3
  fi
fi

WORK_DIR=$(config_get WORK_DIR "$CONFIG" '')
[ -n "$WORK_DIR" ] || die "WORK_DIR must be configured as an absolute path" 2
case "$WORK_DIR" in
  /|*/../*|*/..|*/./*|*/.) die "Invalid WORK_DIR" 2 ;;
  /*) ;;
  *) die "WORK_DIR must be an absolute path" 2 ;;
esac
WORK_DIR=${WORK_DIR%/}
case "$CONFIG" in
  */../*|*/..|*/./*|*/.) die "Invalid config file path" 2 ;;
esac
case "$CONFIG" in
  "$WORK_DIR"/work/*) ;;
  *) die "Config file must be stored under WORK_DIR/work" 2 ;;
esac
OUTPUT_DIR=$(config_get OUTPUT_DIR "$CONFIG" '')
[ "$OUTPUT_DIR" = "$WORK_DIR/runs" ] || die "OUTPUT_DIR must be WORK_DIR/runs" 2
case "$RUN_DIR" in
  "$OUTPUT_DIR"/migration-source-collector-*) ;;
  *) die "RUN_DIR must be stored under WORK_DIR/runs" 2 ;;
esac
mkdir -p "$WORK_DIR/logs" "$OUTPUT_DIR" || die "Cannot create work directories" 4
RUN_NAME=$(basename "$RUN_DIR")
PACKAGE_PATH="$OUTPUT_DIR/$RUN_NAME.tar.gz"
PACKAGE_TMP="$OUTPUT_DIR/.$RUN_NAME.tar.gz.tmp.$$"
DETAILS_TMP="$RUN_DIR/details/.devkit-source-scan-details.tar.gz.tmp.$$"
cleanup_package_temps() {
  rm -f "$PACKAGE_TMP" "$DETAILS_TMP"
}
trap cleanup_package_temps 0 1 2 15

if [ -d "$INTERNAL_DIR" ]; then
  printf '%s\tpackage_prepare\t%s\t%s\tprepared\toutput validated and scan details prepared\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)" \
    "$RUN_DIR" "$PACKAGE_PATH" >> "$AUDIT_FILE"

  rm -f "$DETAILS_TMP"
  if [ "$ARCHIVE_PROVIDER" = tar ]; then
    tar -czf "$DETAILS_TMP" -C "$INTERNAL_DIR" . ||
      die "Cannot build source scan details archive" 5
    tar -tzf "$DETAILS_TMP" >/dev/null 2>&1 ||
      die "Source scan details archive verification failed" 5
  else
    busybox tar -czf "$DETAILS_TMP" -C "$INTERNAL_DIR" . ||
      die "Cannot build source scan details archive" 5
    busybox tar -tzf "$DETAILS_TMP" >/dev/null 2>&1 ||
      die "Source scan details archive verification failed" 5
  fi
  [ -s "$DETAILS_TMP" ] || die "Source scan details archive is empty" 5
  mv "$DETAILS_TMP" "$DETAILS_ARCHIVE" || die "Cannot finalize source scan details archive" 5
  case "$INTERNAL_DIR" in
    "$RUN_DIR/details/internal") rm -rf "$INTERNAL_DIR" ;;
    *) die "Unsafe internal directory" 5 ;;
  esac
fi

python3 "$PLAN_TOOL" set-source \
  --plan "$PLAN_JSON" \
  --collection-package "$PACKAGE_PATH" \
  --details-archive "details/devkit-source-scan-details.tar.gz" >/dev/null ||
  die "Cannot finalize source_environment in migration-plan.json" 5
python3 "$PLAN_TOOL" resolve-urls \
  --plan "$PLAN_JSON" \
  --reference "$SCRIPT_DIR/../references/migration-route-reference.md" >/dev/null ||
  die "Cannot resolve package URLs in migration-plan.json" 5
python3 "$PLAN_TOOL" validate --plan "$PLAN_JSON" --phase collector-final >/dev/null ||
  die "Final migration-plan.json validation failed" 5

rm -f "$PACKAGE_TMP"
if [ "$ARCHIVE_PROVIDER" = tar ]; then
  tar -czf "$PACKAGE_TMP" -C "$(dirname "$RUN_DIR")" "$RUN_NAME" ||
    die "Cannot create final package" 5
  tar -tzf "$PACKAGE_TMP" >/dev/null 2>&1 ||
    die "Final package verification failed" 5
else
  busybox tar -czf "$PACKAGE_TMP" -C "$(dirname "$RUN_DIR")" "$RUN_NAME" ||
    die "Cannot create final package" 5
  busybox tar -tzf "$PACKAGE_TMP" >/dev/null 2>&1 ||
    die "Final package verification failed" 5
fi
mv "$PACKAGE_TMP" "$PACKAGE_PATH" || die "Cannot publish final package" 5

PACKAGE_SHA256=$(hash_file "$PACKAGE_PATH")
PACKAGE_SIZE=$(file_size "$PACKAGE_PATH")
RUN_JSON=$(json_escape "$RUN_DIR")
PLAN_JSON_PATH=$(json_escape "$PLAN_JSON")
REPORT_JSON_PATH=$(json_escape "$REPORT")
PACKAGE_JSON=$(json_escape "$PACKAGE_PATH")

cat > "$OUTPUT_DIR/latest.json.tmp" <<EOF
{
  "run_dir": "$RUN_JSON",
  "migration_plan": "$PLAN_JSON_PATH",
  "collection_report": "$REPORT_JSON_PATH",
  "package": "$PACKAGE_JSON",
  "package_size": $PACKAGE_SIZE,
  "package_sha256": "$PACKAGE_SHA256"
}
EOF
mv "$OUTPUT_DIR/latest.json.tmp" "$OUTPUT_DIR/latest.json" ||
  die "Cannot update latest.json" 6

trap - 0 1 2 15
printf 'migration-plan.json: %s\n' "$PLAN_JSON"
printf '%s\n' "$PACKAGE_PATH"
