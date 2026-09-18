#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/supplement.sh --config <file> --run-dir <dir> --plan <tsv>"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_true() {
  case "${1:-}" in true|TRUE|1|yes|YES) return 0 ;; *) return 1 ;; esac
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

safe_name() {
  printf '%s' "$1" | tr '/ :	' '____' | tr -cd '[:alnum:]_.-'
}

file_size() {
  size_file=$1
  if has_cmd stat; then
    stat -c '%s' "$size_file" 2>/dev/null || stat -f '%z' "$size_file" 2>/dev/null || echo 0
  else
    wc -c < "$size_file" 2>/dev/null || echo 0
  fi
}

file_mtime() {
  mtime_file=$1
  if has_cmd stat; then
    stat -c '%Y' "$mtime_file" 2>/dev/null || stat -f '%m' "$mtime_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

dir_size() {
  size_path=$1
  if has_cmd du; then
    du -sk "$size_path" 2>/dev/null | awk '{print $1*1024}'
  else
    echo 0
  fi
}

free_bytes() {
  free_path=$1
  if has_cmd df; then
    df -Pk "$free_path" 2>/dev/null | awk 'NR==2 {print $4*1024}'
  else
    echo 0
  fi
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

CONFIG=
RUN_DIR=
PLAN=
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG=${2-}; shift 2 ;;
    --run-dir) RUN_DIR=${2-}; shift 2 ;;
    --plan) PLAN=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -r "$CONFIG" ] || die "Config file is required and must be readable" 2
[ -d "$RUN_DIR/details/internal/scan-results" ] || die "Invalid run directory" 2
[ -r "$PLAN" ] || die "Supplement plan is required and must be readable" 2

AUDIT_FILE="$RUN_DIR/details/internal/audit/audit.tsv"
FILE_INDEX="$RUN_DIR/details/internal/scan-results/file-index.tsv"
COLLECTED_INDEX="$RUN_DIR/details/internal/scan-results/collected-artifacts.tsv"
[ -f "$AUDIT_FILE" ] || die "Run audit file is missing" 2
[ -f "$FILE_INDEX" ] || printf 'path\tsize\tmtime\thint\n' > "$FILE_INDEX"
[ -f "$COLLECTED_INDEX" ] || printf 'category\tclassification\tcomponent_hint\tsource_path\tcollected_path\tsize\tsha256\tconfidence\tdetection_basis\tstatus\n' > "$COLLECTED_INDEX"

append_audit() {
  audit_action=$1
  audit_source=$2
  audit_target=$3
  audit_status=$4
  audit_note=$5
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)" \
    "$audit_action" "$audit_source" "$audit_target" "$audit_status" "$audit_note" \
    >> "$AUDIT_FILE"
}

record_supplement_artifact() {
  record_category=$1
  record_source=$2
  record_target=$3
  record_reason=$4
  case "$record_category" in
    application) record_classification=candidate; record_component=java-application ;;
    config) record_classification=supplemental_config; record_component=unresolved ;;
    *) record_classification=supplemental; record_component=unresolved ;;
  esac
  case "$record_target" in
    "$RUN_DIR"/*) record_relative=${record_target#"$RUN_DIR"/} ;;
    *) record_relative=$record_target ;;
  esac
  if [ -f "$record_target" ]; then
    record_size=$(file_size "$record_target")
    record_hash=$(hash_file "$record_target")
  else
    record_size=$(dir_size "$record_target")
    record_hash=
  fi
  record_reason=$(printf '%s' "$record_reason" | tr '\t\r\n' '   ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$record_category" "$record_classification" "$record_component" "$record_source" \
    "$record_relative" "$record_size" "$record_hash" medium "$record_reason" collected \
    >> "$COLLECTED_INDEX"
}

MIN_FREE=$(config_get MIN_FREE_SPACE_BYTES "$CONFIG" 10737418240)
MAX_TOTAL=$(config_get MAX_TOTAL_PACKAGE_BYTES "$CONFIG" 32212254720)
MAX_SINGLE=$(config_get MAX_SINGLE_FILE_BYTES "$CONFIG" 2147483648)
MAX_INDEX=$(config_get MAX_INDEX_FILES "$CONFIG" 2000000)
INCLUDE_LOGS=$(config_get INCLUDE_LOGS "$CONFIG" false)
INCLUDE_BUSINESS_DATA=$(config_get INCLUDE_BUSINESS_DATA "$CONFIG" true)
LOG_POLICY=$(config_get LOG_POLICY "$CONFIG" recent)
LOG_DAYS=$(config_get LOG_RECENT_DAYS "$CONFIG" 7)
LOG_LIMIT=$(config_get LOG_RECENT_FILE_LIMIT "$CONFIG" 20)

copy_preserve() {
  copy_source=$1
  copy_target=$2
  mkdir -p "$(dirname "$copy_target")" || return 1
  cp -a "$copy_source" "$copy_target" 2>/dev/null || cp -R "$copy_source" "$copy_target" 2>/dev/null
}

archive_path() {
  archive_source=$1
  archive_target=$2
  archive_parent=$(dirname "$archive_source")
  archive_base=$(basename "$archive_source")
  if has_cmd tar; then
    tar -czf "$archive_target" -C "$archive_parent" "$archive_base"
  elif has_cmd busybox; then
    busybox tar -czf "$archive_target" -C "$archive_parent" "$archive_base"
  else
    return 1
  fi
}

emit_candidate() {
  candidate_file=$1
  case "$candidate_file" in
    *.jar|*.war|*.properties|*.yml|*.yaml|*.xml|*.conf|*.cnf|*.ora|*.ini|*.json|*.service|*.sh|*.sql|*/pom.xml|*/build.gradle|*/settings.gradle|*.so)
      candidate_size=$(file_size "$candidate_file")
      candidate_mtime=$(file_mtime "$candidate_file")
      printf '%s\t%s\t%s\t%s\n' "$candidate_file" "$candidate_size" "$candidate_mtime" "${candidate_file##*.}" >> "$FILE_INDEX"
      ;;
  esac
}

TAB=$(printf '\t')
while IFS="$TAB" read -r action category source_path reason || [ -n "${action:-}" ]; do
  case "${action:-}" in ''|'#'*) continue ;; esac
  case "$action" in INDEX_PATH|COPY_FILE|PACKAGE_PATH|COLLECT_LOGS) ;; *)
    append_audit "$action" "${source_path:-}" '' skipped "action not allowed"
    continue
    ;;
  esac
  case "$category" in application|config|source|component|business_data|service|log) ;; *)
    append_audit "$action" "${source_path:-}" '' skipped "category not allowed"
    continue
    ;;
  esac
  if [ "$category" = log ] && [ "$action" != COLLECT_LOGS ]; then
    append_audit "$action" "${source_path:-}" '' skipped "log paths require COLLECT_LOGS"
    continue
  fi
  if [ "$action" = COLLECT_LOGS ] && [ "$category" != log ]; then
    append_audit "$action" "${source_path:-}" '' skipped "COLLECT_LOGS requires log category"
    continue
  fi
  if [ "$category" = business_data ] && ! is_true "$INCLUDE_BUSINESS_DATA"; then
    append_audit "$action" "${source_path:-}" '' skipped "business data collection disabled"
    continue
  fi
  case "$source_path" in /*) ;; *)
    append_audit "$action" "$source_path" '' skipped "path must be absolute"
    continue
    ;;
  esac
  [ -e "$source_path" ] || {
    append_audit "$action" "$source_path" '' skipped "path not found: $reason"
    continue
  }

  available=$(free_bytes "$RUN_DIR")
  case "$available" in ''|*[!0-9]*) available=0 ;; esac
  if [ "$available" -gt 0 ] && [ "$available" -lt "$MIN_FREE" ]; then
    append_audit "$action" "$source_path" '' failed "free space threshold reached"
    break
  fi
  used=$(dir_size "$RUN_DIR")
  case "$used" in ''|*[!0-9]*) used=0 ;; esac
  if [ "$used" -gt 0 ] && [ "$used" -ge "$MAX_TOTAL" ]; then
    append_audit "$action" "$source_path" '' failed "total package limit reached"
    break
  fi

  case "$category" in
    application) target_category=applications/candidate ;;
    config) target_category=configs/supplemental ;;
    source) target_category=sources ;;
    component) target_category=components ;;
    business_data) target_category=business-data ;;
    service) target_category=services ;;
    log) target_category=logs ;;
  esac
  if has_cmd cksum; then
    path_id=$(printf '%s' "$source_path" | cksum | awk '{print $1}')
  else
    path_id=path
  fi
  target_name=$(safe_name "$category-$(basename "$source_path")-$path_id")

  case "$action" in
    INDEX_PATH)
      if has_cmd find; then
        find "$source_path" -type f -print 2>/dev/null | while IFS= read -r candidate_file; do
          emit_candidate "$candidate_file"
          index_lines=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
          [ "$index_lines" -le "$MAX_INDEX" ] || break
        done
        append_audit "$action" "$source_path" "$FILE_INDEX" success "$reason"
      elif has_cmd busybox; then
        busybox find "$source_path" -type f 2>/dev/null | while IFS= read -r candidate_file; do
          emit_candidate "$candidate_file"
          index_lines=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
          [ "$index_lines" -le "$MAX_INDEX" ] || break
        done
        append_audit "$action" "$source_path" "$FILE_INDEX" partial "busybox find used: $reason"
      else
        append_audit "$action" "$source_path" '' skipped "file scan provider unavailable"
      fi
      ;;
    COPY_FILE)
      [ -f "$source_path" ] || {
        append_audit "$action" "$source_path" '' skipped "not a regular file"
        continue
      }
      source_size=$(file_size "$source_path")
      if [ "$source_size" -gt "$MAX_SINGLE" ]; then
        append_audit "$action" "$source_path" '' skipped "single file limit reached"
        continue
      fi
      target_path="$RUN_DIR/details/artifacts/$target_category/$target_name"
      if copy_preserve "$source_path" "$target_path"; then
        append_audit "$action" "$source_path" "$target_path" success "$reason"
        record_supplement_artifact "$category" "$source_path" "$target_path" "$reason"
      else
        append_audit "$action" "$source_path" "$target_path" failed "$reason"
      fi
      ;;
    PACKAGE_PATH)
      target_path="$RUN_DIR/details/artifacts/$target_category/$target_name.tar.gz"
      mkdir -p "$(dirname "$target_path")" || die "Cannot create artifact directory" 8
      if archive_path "$source_path" "$target_path"; then
        append_audit "$action" "$source_path" "$target_path" success "$reason"
        record_supplement_artifact "$category" "$source_path" "$target_path" "$reason"
      else
        target_path="$RUN_DIR/details/artifacts/$target_category/$target_name"
        if copy_preserve "$source_path" "$target_path"; then
          append_audit "$action" "$source_path" "$target_path" partial "archive unavailable; copied path"
          record_supplement_artifact "$category" "$source_path" "$target_path" "archive unavailable; $reason"
        else
          append_audit "$action" "$source_path" "$target_path" failed "$reason"
        fi
      fi
      ;;
    COLLECT_LOGS)
      if ! is_true "$INCLUDE_LOGS"; then
        append_audit "$action" "$source_path" '' skipped "log collection disabled by default"
        continue
      fi
      target_path="$RUN_DIR/details/logs/$target_name"
      mkdir -p "$target_path" || die "Cannot create log directory" 8
      if [ "$LOG_POLICY" = full ]; then
        if copy_preserve "$source_path" "$target_path"; then
          append_audit "$action" "$source_path" "$target_path" success "full logs: $reason"
        else
          append_audit "$action" "$source_path" "$target_path" failed "$reason"
        fi
      elif has_cmd find; then
        find "$source_path" -type f -mtime "-$LOG_DAYS" -print 2>/dev/null | head -n "$LOG_LIMIT" | while IFS= read -r log_file; do
          copy_preserve "$log_file" "$target_path/$(safe_name "$log_file")" || true
        done
        append_audit "$action" "$source_path" "$target_path" success "recent logs: $reason"
      else
        append_audit "$action" "$source_path" '' skipped "find unavailable for recent log policy"
      fi
      ;;
  esac
done < "$PLAN"
