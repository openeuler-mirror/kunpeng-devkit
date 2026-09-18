#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/collect.sh --config <migration-source-collector.env>"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" 2>/dev/null && pwd)

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
    case "$cfg_line" in
      ''|'#'*) continue ;;
    esac
    [ "${cfg_line%%=*}" = "$cfg_key" ] || continue
    cfg_value=${cfg_line#*=}
    break
  done < "$cfg_file"
  [ -n "$cfg_value" ] && printf '%s' "$cfg_value" || printf '%s' "$cfg_default"
}

safe_name() {
  printf '%s' "$1" | tr '/ :	' '____' | tr -cd '[:alnum:]_.-'
}

detect_primary_ip() {
  detected_ip=
  if has_cmd ip; then
    detected_ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{
        for (i=1; i<=NF; i++) {
          if ($i == "src" && (i+1) <= NF) {
            print $(i+1)
            exit
          }
        }
      }')
    [ -n "$detected_ip" ] || detected_ip=$(ip -o -4 addr show scope global 2>/dev/null |
      awk '{sub(/\/.*/, "", $4); if ($4 !~ /^127\./) {print $4; exit}}')
  fi
  if [ -z "$detected_ip" ] && has_cmd hostname; then
    detected_ip=$(hostname -I 2>/dev/null |
      awk '{
        for (i=1; i<=NF; i++) {
          if ($i !~ /^127\./ && $i !~ /:/) {
            print $i
            exit
          }
        }
      }')
  fi
  if [ -z "$detected_ip" ] && has_cmd ip; then
    detected_ip=$(ip -o -6 addr show scope global 2>/dev/null |
      awk '{sub(/\/.*/, "", $4); print $4; exit}')
  fi
  printf '%s' "$detected_ip"
}

remove_managed_dir() {
  managed_dir=$1
  case "$managed_dir" in
    "$OUTPUT_DIR"/.migration-source-collector-*.collecting.*|\
    "$OUTPUT_DIR"/.migration-source-collector-*.previous.*)
      rm -rf "$managed_dir"
      ;;
    *)
      die "Refusing to remove unmanaged directory: $managed_dir" 8
      ;;
  esac
}

cleanup_stale_managed_dirs() {
  for stale_dir in \
    "$OUTPUT_DIR"/.migration-source-collector-*.collecting.* \
    "$OUTPUT_DIR"/.migration-source-collector-*.previous.*; do
    [ -e "$stale_dir" ] || continue
    stale_pid=${stale_dir##*.}
    case "$stale_pid" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$stale_pid" 2>/dev/null && continue ;;
    esac
    remove_managed_dir "$stale_dir"
  done
}

free_bytes() {
  free_path=$1
  if has_cmd df; then
    df -Pk "$free_path" 2>/dev/null | awk 'NR==2 {print $4*1024}'
  else
    echo 0
  fi
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

CONFIG=
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -n "$CONFIG" ] && [ -r "$CONFIG" ] || die "Config file is required and must be readable" 2
[ "$(uname -s 2>/dev/null)" = Linux ] || die "Only Linux source hosts are supported" 3
[ "$(id -u 2>/dev/null)" = 0 ] || die "Root permission is required" 4
[ -r /proc/1/stat ] || die "/proc is not readable" 5

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
MIN_FREE=$(config_get MIN_FREE_SPACE_BYTES "$CONFIG" 10737418240)
MAX_INDEX=$(config_get MAX_INDEX_FILES "$CONFIG" 2000000)
mkdir -p "$WORK_DIR/logs" "$OUTPUT_DIR" || die "Cannot create work directories" 6
[ -w "$OUTPUT_DIR" ] || die "Output directory is not writable: $OUTPUT_DIR" 6
cleanup_stale_managed_dirs
AVAILABLE=$(free_bytes "$OUTPUT_DIR")
case "$AVAILABLE" in ''|*[!0-9]*) AVAILABLE=0 ;; esac
case "$MIN_FREE" in ''|*[!0-9]*) die "MIN_FREE_SPACE_BYTES must be an integer" 2 ;; esac
if [ "$AVAILABLE" -gt 0 ] && [ "$AVAILABLE" -lt "$MIN_FREE" ]; then
  die "Free space is below the configured threshold" 7
fi

HOSTNAME_VALUE=$(hostname 2>/dev/null || echo unknown-host)
PRIMARY_IP=$(config_get SOURCE_HOST_IP "$CONFIG" '')
[ -n "$PRIMARY_IP" ] || PRIMARY_IP=$(detect_primary_ip)
[ -n "$PRIMARY_IP" ] ||
  die "Cannot determine a non-loopback source IP; set SOURCE_HOST_IP in the config" 6
HOST_KEY=$(safe_name "$PRIMARY_IP")
[ -n "$HOST_KEY" ] || die "SOURCE_HOST_IP cannot be converted to a safe directory name" 6
RUN_NAME="migration-source-collector-$HOST_KEY"
FINAL_RUN_DIR="$OUTPUT_DIR/$RUN_NAME"
RUN_DIR="$OUTPUT_DIR/.${RUN_NAME}.collecting.$$"
BACKUP_RUN_DIR="$OUTPUT_DIR/.${RUN_NAME}.previous.$$"
[ ! -e "$RUN_DIR" ] || remove_managed_dir "$RUN_DIR"
trap 'if [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then remove_managed_dir "$RUN_DIR"; fi' 0 1 2 15
SCAN_RESULTS="$RUN_DIR/details/internal/scan-results"
ARTIFACTS="$RUN_DIR/details/artifacts"
AUDIT="$RUN_DIR/details/internal/audit"

for output_path in \
  "$SCAN_RESULTS" \
  "$ARTIFACTS/applications/primary" \
  "$ARTIFACTS/applications/primary_exploded" \
  "$ARTIFACTS/applications/candidate" \
  "$ARTIFACTS/configs" \
  "$ARTIFACTS/sources" \
  "$ARTIFACTS/components" \
  "$ARTIFACTS/services" \
  "$ARTIFACTS/business-data" \
  "$AUDIT"; do
  mkdir -p "$output_path" || die "Cannot create run directory: $output_path" 8
done

cp "$CONFIG" "$AUDIT/collector-config.env" 2>/dev/null || true
printf 'time\taction\tsource\ttarget\tstatus\tnote\n' > "$AUDIT/audit.tsv"

append_audit() {
  audit_action=$1
  audit_source=$2
  audit_target=$3
  audit_status=$4
  audit_note=$5
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)" \
    "$audit_action" "$audit_source" "$audit_target" "$audit_status" "$audit_note" \
    >> "$AUDIT/audit.tsv"
}

CAPABILITIES="$SCAN_RESULTS/capabilities.tsv"
printf 'capability\tstatus\tprovider\tlimitation\n' > "$CAPABILITIES"
probe() {
  probe_name=$1
  shift
  probe_provider=
  for probe_candidate in "$@"; do
    if has_cmd "$probe_candidate"; then
      probe_provider=$probe_candidate
      break
    fi
  done
  if [ -n "$probe_provider" ]; then
    printf '%s\tavailable\t%s\t\n' "$probe_name" "$probe_provider" >> "$CAPABILITIES"
  else
    printf '%s\tunavailable\t\tprovider not found\n' "$probe_name" >> "$CAPABILITIES"
  fi
}
probe process ps
probe port ss netstat lsof
probe service systemctl
probe file_scan find busybox
probe archive tar busybox
probe checksum sha256sum openssl shasum
probe jar_manifest unzip
probe version_timeout timeout
printf 'procfs\tavailable\t/proc\t\n' >> "$CAPABILITIES"

{
  echo "hostname=$HOSTNAME_VALUE"
  echo "kernel=$(uname -r 2>/dev/null || echo unknown)"
  echo "arch=$(uname -m 2>/dev/null || echo unknown)"
  echo "collection_mode=$(config_get COLLECTION_MODE "$CONFIG" local)"
  echo "control_host_architecture=$(config_get CONTROL_HOST_ARCHITECTURE "$CONFIG" "$(uname -m 2>/dev/null || echo unknown)")"
  echo "remote_host_id=$(config_get REMOTE_HOST_ID "$CONFIG" '')"
  echo "role_hint=$(config_get ROLE_HINT "$CONFIG" '')"
  if [ -r /etc/os-release ]; then
    OS_NAME=$(awk -F= '$1=="PRETTY_NAME" {sub(/^PRETTY_NAME=/,""); gsub(/^"|"$/,""); print; exit}' /etc/os-release)
    echo "os=${OS_NAME:-unknown}"
  else
    echo "os=unknown"
  fi
  echo "primary_ip=$PRIMARY_IP"
} > "$SCAN_RESULTS/host.env"
append_audit collect_host /proc "$SCAN_RESULTS" success "host collection completed"

if has_cmd ps; then
  ps -eo pid=,ppid=,user=,comm=,args= > "$SCAN_RESULTS/processes.txt" 2>/dev/null || true
else
  : > "$SCAN_RESULTS/processes.txt"
  for proc_dir in /proc/[0-9]*; do
    [ -r "$proc_dir/cmdline" ] || continue
    proc_pid=${proc_dir##*/}
    proc_command=$( (tr '\000' ' ' < "$proc_dir/cmdline") 2>/dev/null || true )
    proc_exe=$(readlink "$proc_dir/exe" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$proc_pid" "$proc_exe" "$proc_command" >> "$SCAN_RESULTS/processes.txt"
  done
fi

printf 'pid\texe\tcwd\tjava_home\tselected_env\n' > "$SCAN_RESULTS/process-details.tsv"
printf 'pid\targ_index\targument\n' > "$SCAN_RESULTS/process-args.tsv"
for proc_dir in /proc/[0-9]*; do
  [ -r "$proc_dir/cmdline" ] || continue
  proc_pid=${proc_dir##*/}
  proc_exe=$(readlink "$proc_dir/exe" 2>/dev/null || true)
  proc_cwd=$(readlink "$proc_dir/cwd" 2>/dev/null || true)
  java_home=
  selected_env=
  if [ -r "$proc_dir/environ" ]; then
    proc_environment=$( (tr '\000' '\n' < "$proc_dir/environ") 2>/dev/null || true )
    java_home=$(printf '%s\n' "$proc_environment" | awk -F= '$1=="JAVA_HOME" {sub(/^[^=]*=/,""); print; exit}')
    selected_env=$(printf '%s\n' "$proc_environment" | awk -F= '$1 ~ /^(JAVA_HOME|CLASSPATH|CATALINA_HOME|CATALINA_BASE|RESIN_HOME|TONGWEB_HOME|TONGWEB_BASE|JBOSS_HOME|DOMAIN_HOME|ES_PATH_CONF|RABBITMQ_CONFIG_FILE|TNS_ADMIN|ORACLE_HOME|DM_HOME|NGINX_CONF|SPRING_PROFILES_ACTIVE)$/ {print}' | tr '\n' ';')
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$proc_pid" "$proc_exe" "$proc_cwd" "$java_home" "$selected_env" >> "$SCAN_RESULTS/process-details.tsv"
  (tr '\000' '\n' < "$proc_dir/cmdline") 2>/dev/null | awk -v pid="$proc_pid" '
    {
      gsub(/\t/, " ")
      printf "%s\t%d\t%s\n", pid, NR-1, $0
    }
  ' >> "$SCAN_RESULTS/process-args.tsv"
done

if [ -r "$SCRIPT_DIR/collect-versions.sh" ]; then
  if sh "$SCRIPT_DIR/collect-versions.sh" --run-dir "$RUN_DIR" >/dev/null; then
    append_audit collect_versions /proc "$SCAN_RESULTS/component-versions.tsv" success "component version probes completed"
  else
    printf 'pid\tcomponent\tproduct\tversion\tversion_status\tsource_path\tdetection_method\traw_output\n' \
      > "$SCAN_RESULTS/component-versions.tsv"
    append_audit collect_versions /proc "$SCAN_RESULTS/component-versions.tsv" failed "component version probes failed"
  fi
else
  printf 'pid\tcomponent\tproduct\tversion\tversion_status\tsource_path\tdetection_method\traw_output\n' \
    > "$SCAN_RESULTS/component-versions.tsv"
  append_audit collect_versions "$SCRIPT_DIR/collect-versions.sh" "$SCAN_RESULTS/component-versions.tsv" failed "version helper missing"
fi

if has_cmd ss; then
  ss -lntup > "$SCAN_RESULTS/ports.txt" 2>/dev/null || true
elif has_cmd netstat; then
  netstat -lntup > "$SCAN_RESULTS/ports.txt" 2>/dev/null || true
elif has_cmd lsof; then
  lsof -nP -i > "$SCAN_RESULTS/ports.txt" 2>/dev/null || true
else
  {
    echo '# provider=/proc/net; pid mapping may be unavailable'
    cat /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
  } > "$SCAN_RESULTS/ports.txt"
fi

: > "$SCAN_RESULTS/services.txt"
if has_cmd systemctl; then
  systemctl list-units --type=service --all --no-pager > "$SCAN_RESULTS/services.txt" 2>/dev/null || true
fi
if has_cmd find; then
  for service_root in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system /etc/init.d; do
    [ -d "$service_root" ] || continue
    find "$service_root" -maxdepth 2 -type f -print 2>/dev/null >> "$SCAN_RESULTS/service-files.txt" || true
  done
fi
append_audit collect_runtime /proc "$SCAN_RESULTS" success "runtime collection completed"

FILE_INDEX="$SCAN_RESULTS/file-index.tsv"
printf 'path\tsize\tmtime\thint\n' > "$FILE_INDEX"

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

SCAN_ROOTS=$(config_get SCAN_ROOTS "$CONFIG" /)
SOURCE_ROOTS=$(config_get SOURCE_ROOTS "$CONFIG" '')
EXTRA_ROOTS=$(config_get EXTRA_PACK_PATHS "$CONFIG" '')
ALL_ROOTS=$SCAN_ROOTS
[ -n "$SOURCE_ROOTS" ] && ALL_ROOTS="$ALL_ROOTS,$SOURCE_ROOTS"
[ -n "$EXTRA_ROOTS" ] && ALL_ROOTS="$ALL_ROOTS,$EXTRA_ROOTS"

OLD_IFS=$IFS
IFS=','
for scan_root in $ALL_ROOTS; do
  IFS=$OLD_IFS
  [ -n "$scan_root" ] || { IFS=','; continue; }
  [ -e "$scan_root" ] || {
    append_audit index "$scan_root" "$FILE_INDEX" skipped "path not found"
    IFS=','
    continue
  }
  if has_cmd find; then
    find "$scan_root" \
      \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path "$OUTPUT_DIR" \) -prune -o \
      -type f \( \
        -iname '*.jar' -o -iname '*.war' -o -iname '*.properties' -o \
        -iname '*.yml' -o -iname '*.yaml' -o -iname '*.xml' -o -iname '*.conf' -o \
        -iname '*.cnf' -o -iname '*.ora' -o -iname '*.ini' -o -iname '*.json' -o \
        -iname '*.service' -o -iname '*.sh' -o -iname '*.sql' -o -iname 'pom.xml' -o \
        -iname 'build.gradle' -o -iname 'settings.gradle' -o -iname '*.so' \
      \) -print 2>/dev/null | while IFS= read -r candidate_file; do
        emit_candidate "$candidate_file"
        index_lines=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
        [ "$index_lines" -le "$MAX_INDEX" ] || break
      done
    append_audit index "$scan_root" "$FILE_INDEX" success "candidate file index collected"
  elif has_cmd busybox; then
    busybox find "$scan_root" -type f 2>/dev/null | while IFS= read -r candidate_file; do
      emit_candidate "$candidate_file"
      index_lines=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
      [ "$index_lines" -le "$MAX_INDEX" ] || break
    done
    append_audit index "$scan_root" "$FILE_INDEX" degraded "busybox find used"
  else
    append_audit index "$scan_root" "$FILE_INDEX" skipped "file scan provider unavailable"
  fi
  total_index_lines=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
  [ "$total_index_lines" -le "$MAX_INDEX" ] || break
  IFS=','
done
IFS=$OLD_IFS

INDEX_TMP="$SCAN_RESULTS/.file-index-dedup.$$"
awk -F '\t' 'NR == 1 || !seen[$1]++' "$FILE_INDEX" > "$INDEX_TMP" &&
  mv "$INDEX_TMP" "$FILE_INDEX"
rm -f "$INDEX_TMP"

if [ -r "$SCRIPT_DIR/collect-artifacts.sh" ]; then
  if sh "$SCRIPT_DIR/collect-artifacts.sh" --config "$CONFIG" --run-dir "$RUN_DIR"; then
    append_audit auto_collect "$SCAN_RESULTS" "$ARTIFACTS" success "application packages and component configs collected"
  else
    append_audit auto_collect "$SCAN_RESULTS" "$ARTIFACTS" failed "automatic artifact collection failed"
  fi
else
  append_audit auto_collect "$SCRIPT_DIR/collect-artifacts.sh" "$ARTIFACTS" failed "helper script missing"
fi

PROCESS_LINES=$(wc -l < "$SCAN_RESULTS/processes.txt" 2>/dev/null || echo 0)
PORT_LINES=$(wc -l < "$SCAN_RESULTS/ports.txt" 2>/dev/null || echo 0)
INDEX_LINES=$(wc -l < "$FILE_INDEX" 2>/dev/null || echo 1)
FILE_CANDIDATES=$((INDEX_LINES > 0 ? INDEX_LINES - 1 : 0))
PRIMARY_PACKAGES=$(awk -F= '$1=="primary_application_packages" {print $2}' "$SCAN_RESULTS/artifact-summary.env" 2>/dev/null || true)
CANDIDATE_PACKAGES=$(awk -F= '$1=="candidate_application_packages" {print $2}' "$SCAN_RESULTS/artifact-summary.env" 2>/dev/null || true)
CONFIG_FILES=$(awk -F= '$1=="middleware_config_files" {print $2}' "$SCAN_RESULTS/artifact-summary.env" 2>/dev/null || true)
{
  echo '# Source scan summary'
  echo "host: $HOSTNAME_VALUE"
  echo "process_lines: $PROCESS_LINES"
  echo "port_lines: $PORT_LINES"
  echo "file_candidates: $FILE_CANDIDATES"
  echo "primary_application_packages: ${PRIMARY_PACKAGES:-0}"
  echo "candidate_application_packages: ${CANDIDATE_PACKAGES:-0}"
  echo "middleware_config_files: ${CONFIG_FILES:-0}"
  echo
  echo '## likely runtime processes'
  grep -Ei 'java|tomcat|catalina|resin|tongweb|nginx|redis|mysql|mariadb|oracle|pmon|tnslsnr|dmserver|rabbit|elastic' "$SCAN_RESULTS/processes.txt" 2>/dev/null | head -n 200 || true
  echo
  echo '## detected component versions'
  awk -F '\t' 'NR == 1 || $5 == "DETECTED" { print }' "$SCAN_RESULTS/component-versions.tsv" 2>/dev/null | head -n 200 || true
  echo
  echo '## key candidate files'
  grep -Ei '\.(jar|war|yml|yaml|properties|conf|cnf|ora|service|sql|so)$|/pom\.xml$|/build\.gradle$|resin\.xml$|server\.xml$' "$FILE_INDEX" 2>/dev/null | head -n 500 || true
  echo
  echo '## collected application packages and component configs'
  awk -F '\t' 'NR == 1 || $10 == "collected" { print }' "$SCAN_RESULTS/collected-artifacts.tsv" 2>/dev/null | head -n 300 || true
} > "$SCAN_RESULTS/summary.txt"
append_audit summarize "$SCAN_RESULTS" "$SCAN_RESULTS/summary.txt" success "compact scan summary generated"

[ ! -e "$BACKUP_RUN_DIR" ] || remove_managed_dir "$BACKUP_RUN_DIR"
if [ -e "$FINAL_RUN_DIR" ]; then
  mv "$FINAL_RUN_DIR" "$BACKUP_RUN_DIR" ||
    die "Cannot prepare existing host result for replacement" 8
fi
if mv "$RUN_DIR" "$FINAL_RUN_DIR"; then
  RUN_DIR=
  [ ! -e "$BACKUP_RUN_DIR" ] || remove_managed_dir "$BACKUP_RUN_DIR"
  rm -f "$OUTPUT_DIR/$RUN_NAME.tar.gz"
else
  [ ! -e "$BACKUP_RUN_DIR" ] || mv "$BACKUP_RUN_DIR" "$FINAL_RUN_DIR" 2>/dev/null || true
  die "Cannot publish the new host result" 8
fi
trap - 0 1 2 15
printf '%s\n' "$FINAL_RUN_DIR"
