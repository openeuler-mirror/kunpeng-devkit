#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/collect-artifacts.sh --config <file> --run-dir <dir>"
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

safe_name() {
  safe_value=$(printf '%s' "$1" | tr '/ :\t' '____' | tr -cd '[:alnum:]_.-')
  [ -n "$safe_value" ] && printf '%s' "$safe_value" || printf 'artifact'
}

clean_tsv() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

file_size() {
  size_file=$1
  if has_cmd stat; then
    stat -c '%s' "$size_file" 2>/dev/null || stat -f '%z' "$size_file" 2>/dev/null || echo 0
  else
    wc -c < "$size_file" 2>/dev/null || echo 0
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

path_id() {
  if has_cmd cksum; then
    printf '%s' "$1" | cksum | awk '{print $1}'
  else
    safe_name "$1"
  fi
}

run_find() {
  if has_cmd find; then
    find "$@"
  elif has_cmd busybox; then
    busybox find "$@"
  else
    return 1
  fi
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
[ -d "$RUN_DIR/details/internal/scan-results" ] || die "Invalid run directory" 2

SCAN_RESULTS="$RUN_DIR/details/internal/scan-results"
ARTIFACTS="$RUN_DIR/details/artifacts"
AUDIT_FILE="$RUN_DIR/details/internal/audit/audit.tsv"
PROCESSES="$SCAN_RESULTS/processes.txt"
PROCESS_DETAILS="$SCAN_RESULTS/process-details.tsv"
PROCESS_ARGS="$SCAN_RESULTS/process-args.tsv"
SERVICES="$SCAN_RESULTS/services.txt"
SERVICE_FILES="$SCAN_RESULTS/service-files.txt"
FILE_INDEX="$SCAN_RESULTS/file-index.tsv"
COLLECTED_INDEX="$SCAN_RESULTS/collected-artifacts.tsv"
COMPONENT_VERSIONS="$SCAN_RESULTS/component-versions.tsv"
PARSED_NGINX="$SCAN_RESULTS/.parsed-nginx-configs.$$"
LIST_PREFIX="$SCAN_RESULTS/.artifact-list.$$"
LIST_SEQUENCE=0

[ -f "$AUDIT_FILE" ] || die "Run audit file is missing" 2
[ -f "$PROCESSES" ] || die "Process scan result is missing" 2
[ -f "$PROCESS_DETAILS" ] || die "Process detail scan result is missing" 2
[ -f "$PROCESS_ARGS" ] || die "Process argument scan result is missing" 2
[ -f "$FILE_INDEX" ] || die "File index is missing" 2
mkdir -p "$ARTIFACTS/applications/primary" "$ARTIFACTS/applications/primary_exploded" \
  "$ARTIFACTS/applications/candidate" "$ARTIFACTS/configs" || die "Cannot create artifact directories" 3

MIN_FREE=$(config_get MIN_FREE_SPACE_BYTES "$CONFIG" 10737418240)
MAX_TOTAL=$(config_get MAX_TOTAL_PACKAGE_BYTES "$CONFIG" 32212254720)
MAX_SINGLE=$(config_get MAX_SINGLE_FILE_BYTES "$CONFIG" 2147483648)
MAX_CANDIDATES=$(config_get MAX_CANDIDATE_APPLICATION_PACKAGES "$CONFIG" 500)
MAX_CONFIGS=$(config_get MAX_MIDDLEWARE_CONFIG_FILES "$CONFIG" 1000)

case "$MIN_FREE" in ''|*[!0-9]*) MIN_FREE=10737418240 ;; esac
case "$MAX_TOTAL" in ''|*[!0-9]*) MAX_TOTAL=32212254720 ;; esac
case "$MAX_SINGLE" in ''|*[!0-9]*) MAX_SINGLE=2147483648 ;; esac
case "$MAX_CANDIDATES" in ''|*[!0-9]*) MAX_CANDIDATES=500 ;; esac
case "$MAX_CONFIGS" in ''|*[!0-9]*) MAX_CONFIGS=1000 ;; esac

CANDIDATE_COUNT=0
CONFIG_COUNT=0
TAB=$(printf '\t')
: > "$PARSED_NGINX"
cleanup_artifact_temps() {
  rm -f "$PARSED_NGINX" "$LIST_PREFIX".* 2>/dev/null || true
}
trap cleanup_artifact_temps 0 1 2 15
printf 'category\tclassification\tcomponent_hint\tsource_path\tcollected_path\tsize\tsha256\tconfidence\tdetection_basis\tstatus\n' > "$COLLECTED_INDEX"

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

append_record() {
  record_category=$(clean_tsv "$1")
  record_classification=$(clean_tsv "$2")
  record_component=$(clean_tsv "$3")
  record_source=$(clean_tsv "$4")
  record_collected=$(clean_tsv "$5")
  record_size=$(clean_tsv "$6")
  record_hash=$(clean_tsv "$7")
  record_confidence=$(clean_tsv "$8")
  record_basis=$(clean_tsv "$9")
  record_status=$(clean_tsv "${10}")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$record_category" "$record_classification" "$record_component" "$record_source" \
    "$record_collected" "$record_size" "$record_hash" "$record_confidence" \
    "$record_basis" "$record_status" >> "$COLLECTED_INDEX"
}

already_collected() {
  collected_source=$1
  awk -F '\t' -v source="$collected_source" \
    'NR > 1 && $4 == source && $10 == "collected" { found=1; exit } END { exit(found ? 0 : 1) }' \
    "$COLLECTED_INDEX"
}

within_limits() {
  incoming_size=$1
  current_free=$(free_bytes "$RUN_DIR")
  current_used=$(dir_size "$RUN_DIR")
  case "$current_free" in ''|*[!0-9]*) current_free=0 ;; esac
  case "$current_used" in ''|*[!0-9]*) current_used=0 ;; esac
  if [ "$current_free" -gt 0 ] && [ "$current_free" -lt $((MIN_FREE + incoming_size)) ]; then
    return 1
  fi
  [ $((current_used + incoming_size)) -le "$MAX_TOTAL" ]
}

relative_to_run() {
  relative_path=$1
  case "$relative_path" in
    "$RUN_DIR"/*) printf '%s' "${relative_path#"$RUN_DIR"/}" ;;
    *) printf '%s' "$relative_path" ;;
  esac
}

copy_file_artifact() {
  artifact_category=$1
  artifact_classification=$2
  artifact_component=$3
  artifact_source=$4
  artifact_confidence=$5
  artifact_basis=$6

  [ -f "$artifact_source" ] || return 1
  already_collected "$artifact_source" && return 0

  if [ "$artifact_classification" = candidate ]; then
    if [ "$CANDIDATE_COUNT" -ge "$MAX_CANDIDATES" ]; then
      append_record "$artifact_category" "$artifact_classification" "$artifact_component" \
        "$artifact_source" '' 0 '' "$artifact_confidence" "$artifact_basis; candidate limit reached" skipped
      append_audit auto_collect "$artifact_source" '' skipped "candidate application limit reached"
      return 1
    fi
  fi
  if [ "$artifact_category" = config ] && [ "$CONFIG_COUNT" -ge "$MAX_CONFIGS" ]; then
    append_record "$artifact_category" "$artifact_classification" "$artifact_component" \
      "$artifact_source" '' 0 '' "$artifact_confidence" "$artifact_basis; config limit reached" skipped
    append_audit auto_collect "$artifact_source" '' skipped "middleware config limit reached"
    return 1
  fi

  artifact_size=$(file_size "$artifact_source")
  case "$artifact_size" in ''|*[!0-9]*) artifact_size=0 ;; esac
  if [ "$artifact_size" -gt "$MAX_SINGLE" ] || ! within_limits "$artifact_size"; then
    append_record "$artifact_category" "$artifact_classification" "$artifact_component" \
      "$artifact_source" '' "$artifact_size" '' "$artifact_confidence" "$artifact_basis; size limit reached" skipped
    append_audit auto_collect "$artifact_source" '' skipped "artifact size or free-space limit reached"
    return 1
  fi

  artifact_id=$(path_id "$artifact_source")
  artifact_base=$(safe_name "$(basename "$artifact_source")")
  case "$artifact_category" in
    application) artifact_dir="$ARTIFACTS/applications/$artifact_classification/$artifact_id" ;;
    config) artifact_dir="$ARTIFACTS/configs/$(safe_name "$artifact_component")/$artifact_id" ;;
    *) return 1 ;;
  esac
  artifact_target="$artifact_dir/$artifact_base"
  mkdir -p "$artifact_dir" || return 1
  if cp -p "$artifact_source" "$artifact_target" 2>/dev/null || cp "$artifact_source" "$artifact_target" 2>/dev/null; then
    artifact_hash=$(hash_file "$artifact_target")
    artifact_relative=$(relative_to_run "$artifact_target")
    append_record "$artifact_category" "$artifact_classification" "$artifact_component" \
      "$artifact_source" "$artifact_relative" "$artifact_size" "$artifact_hash" \
      "$artifact_confidence" "$artifact_basis" collected
    append_audit auto_collect "$artifact_source" "$artifact_target" success "$artifact_classification: $artifact_basis"
    [ "$artifact_classification" = candidate ] && CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
    [ "$artifact_category" = config ] && CONFIG_COUNT=$((CONFIG_COUNT + 1))
    return 0
  fi

  append_record "$artifact_category" "$artifact_classification" "$artifact_component" \
    "$artifact_source" '' "$artifact_size" '' "$artifact_confidence" "$artifact_basis" failed
  append_audit auto_collect "$artifact_source" "$artifact_target" failed "$artifact_basis"
  return 1
}

package_directory_artifact() {
  artifact_component=$1
  artifact_source=$2
  artifact_confidence=$3
  artifact_basis=$4

  [ -d "$artifact_source" ] || return 1
  already_collected "$artifact_source" && return 0
  source_size=$(dir_size "$artifact_source")
  case "$source_size" in ''|*[!0-9]*) source_size=0 ;; esac
  if [ "$source_size" -gt "$MAX_TOTAL" ] || ! within_limits "$source_size"; then
    append_record application primary_exploded "$artifact_component" "$artifact_source" '' \
      "$source_size" '' "$artifact_confidence" "$artifact_basis; size limit reached" skipped
    return 1
  fi
  if has_cmd tar; then
    archive_provider=tar
  elif has_cmd busybox; then
    archive_provider=busybox
  else
    append_record application primary_exploded "$artifact_component" "$artifact_source" '' \
      "$source_size" '' "$artifact_confidence" "$artifact_basis; archive provider unavailable" skipped
    return 1
  fi

  artifact_id=$(path_id "$artifact_source")
  artifact_base=$(safe_name "$(basename "$artifact_source")")
  artifact_dir="$ARTIFACTS/applications/primary_exploded/$artifact_id"
  artifact_target="$artifact_dir/$artifact_base.tar.gz"
  mkdir -p "$artifact_dir" || return 1
  if [ "$archive_provider" = tar ]; then
    tar -czf "$artifact_target" -C "$(dirname "$artifact_source")" "$(basename "$artifact_source")" 2>/dev/null || return 1
  else
    busybox tar -czf "$artifact_target" -C "$(dirname "$artifact_source")" "$(basename "$artifact_source")" 2>/dev/null || return 1
  fi
  artifact_size=$(file_size "$artifact_target")
  artifact_hash=$(hash_file "$artifact_target")
  artifact_relative=$(relative_to_run "$artifact_target")
  append_record application primary_exploded "$artifact_component" "$artifact_source" \
    "$artifact_relative" "$artifact_size" "$artifact_hash" "$artifact_confidence" "$artifact_basis" collected
  append_audit auto_collect "$artifact_source" "$artifact_target" success "primary_exploded: $artifact_basis"
}

next_list_file() {
  LIST_SEQUENCE=$((LIST_SEQUENCE + 1))
  printf '%s.%s' "$LIST_PREFIX" "$LIST_SEQUENCE"
}

env_value() {
  env_blob=$1
  env_key=$2
  printf '%s' "$env_blob" | tr ';' '\n' | awk -F= -v key="$env_key" \
    '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

process_line() {
  process_pid=$1
  awk -v pid="$process_pid" '$1 == pid { print; exit }' "$PROCESSES"
}

component_for_pid() {
  component_line=$(process_line "$1" | tr '[:upper:]' '[:lower:]')
  case "$component_line" in
    *nginx*) printf 'nginx' ;;
    *redis*) printf 'redis' ;;
    *rabbit*) printf 'rabbitmq' ;;
    *elasticsearch*) printf 'elasticsearch' ;;
    *tongweb*) printf 'tongweb' ;;
    *catalina*|*tomcat*) printf 'tomcat' ;;
    *wildfly*|*jboss*) printf 'jboss-wildfly' ;;
    *weblogic*) printf 'weblogic' ;;
    *resin*) printf 'resin' ;;
    *mysqld*|*mariadbd*) printf 'mysql' ;;
    *tnslsnr*|*ora_pmon*) printf 'oracle' ;;
    *dmserver*) printf 'dm' ;;
    *java*) printf 'java-application' ;;
    *) printf 'application' ;;
  esac
}

cwd_for_pid() {
  detail_pid=$1
  awk -F '\t' -v pid="$detail_pid" 'NR > 1 && $1 == pid { print $3; exit }' "$PROCESS_DETAILS"
}

resolve_path() {
  raw_path=$1
  base_path=$2
  case "$raw_path" in
    /*) printf '%s' "$raw_path" ;;
    *) printf '%s/%s' "${base_path:-/}" "$raw_path" ;;
  esac
}

collect_config_dir() {
  config_component=$1
  config_dir=$2
  config_depth=$3
  config_basis=$4
  [ -d "$config_dir" ] || return 0
  config_list=$(next_list_file)
  if has_cmd find || has_cmd busybox; then
    run_find "$config_dir" -maxdepth "$config_depth" -type f \
      \( -name '*.conf' -o -name '*.cnf' -o -name '*.xml' -o -name '*.properties' -o \
         -name '*.yml' -o -name '*.yaml' -o -name '*.ini' -o -name '*.json' -o \
         -name 'jvm.options' -o -name 'enabled_plugins' -o -name 'setenv.sh' \) \
      -print 2>/dev/null > "$config_list"
    while IFS= read -r config_file; do
      copy_file_artifact config active_config "$config_component" "$config_file" high "$config_basis" || true
    done < "$config_list"
  fi
  rm -f "$config_list"
}

collect_deployment_dir() {
  deployment_component=$1
  deployment_dir=$2
  deployment_basis=$3
  [ -d "$deployment_dir" ] || return 0
  deployment_list=$(next_list_file)
  if has_cmd find || has_cmd busybox; then
    run_find "$deployment_dir" -maxdepth 2 -type f \
      \( -name '*.jar' -o -name '*.war' \) -print 2>/dev/null > "$deployment_list"
    while IFS= read -r deployment_file; do
      copy_file_artifact application primary "$deployment_component" "$deployment_file" high "$deployment_basis" || true
    done < "$deployment_list"
  fi
  rm -f "$deployment_list"
}

collect_tomcat_base() {
  tomcat_base=$1
  [ -d "$tomcat_base" ] || return 0
  for config_file in \
    "$tomcat_base/conf/server.xml" \
    "$tomcat_base/conf/web.xml" \
    "$tomcat_base/conf/context.xml" \
    "$tomcat_base/conf/catalina.properties" \
    "$tomcat_base/conf/logging.properties" \
    "$tomcat_base/conf/tomcat-users.xml" \
    "$tomcat_base/bin/setenv.sh"; do
    copy_file_artifact config active_config tomcat "$config_file" high "active CATALINA_BASE=$tomcat_base" || true
  done
  collect_config_dir tomcat "$tomcat_base/conf/Catalina" 4 "active Tomcat context configuration"

  webapps_dir="$tomcat_base/webapps"
  [ -d "$webapps_dir" ] || return 0
  collect_deployment_dir tomcat "$webapps_dir" "archive in active Tomcat appBase=$webapps_dir"
  exploded_list=$(next_list_file)
  if has_cmd find || has_cmd busybox; then
    run_find "$webapps_dir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null > "$exploded_list"
    while IFS= read -r exploded_dir; do
      exploded_name=$(basename "$exploded_dir")
      if [ ! -f "$webapps_dir/$exploded_name.war" ]; then
        package_directory_artifact tomcat "$exploded_dir" medium \
          "exploded application in active Tomcat appBase; original WAR not found" || true
      fi
    done < "$exploded_list"
  fi
  rm -f "$exploded_list"
}

collect_jboss_root() {
  jboss_root=$1
  [ -d "$jboss_root" ] || return 0
  collect_config_dir jboss-wildfly "$jboss_root/standalone/configuration" 3 "active JBoss/WildFly configuration"
  collect_config_dir jboss-wildfly "$jboss_root/domain/configuration" 3 "active JBoss/WildFly domain configuration"
  collect_deployment_dir jboss-wildfly "$jboss_root/standalone/deployments" "archive in active JBoss/WildFly deployments"
  collect_deployment_dir jboss-wildfly "$jboss_root/domain/deployments" "archive in active JBoss/WildFly domain deployments"
}

collect_tongweb_root() {
  tongweb_root=$1
  [ -d "$tongweb_root" ] || return 0
  collect_config_dir tongweb "$tongweb_root/conf" 4 "active TongWeb configuration"
  collect_config_dir tongweb "$tongweb_root/config" 4 "active TongWeb configuration"
  for deployment_dir in "$tongweb_root/deploy" "$tongweb_root/deployments" "$tongweb_root/autodeploy" "$tongweb_root/applications"; do
    collect_deployment_dir tongweb "$deployment_dir" "archive in active TongWeb deployment directory"
  done
}

collect_resin_root() {
  resin_root=$1
  [ -d "$resin_root" ] || return 0
  collect_config_dir resin "$resin_root/conf" 4 "active Resin configuration"
  for config_file in "$resin_root/conf/resin.xml" "$resin_root/conf/resin.properties"; do
    copy_file_artifact config active_config resin "$config_file" high "active RESIN_HOME=$resin_root" || true
  done
}

collect_weblogic_domain() {
  domain_root=$1
  [ -d "$domain_root" ] || return 0
  collect_config_dir weblogic "$domain_root/config" 5 "active WebLogic domain configuration"
}

collect_elasticsearch_conf() {
  elastic_conf=$1
  [ -d "$elastic_conf" ] || return 0
  collect_config_dir elasticsearch "$elastic_conf" 3 "active Elasticsearch configuration"
}

collect_nginx_config() {
  nginx_config=$1
  nginx_depth=${2:-0}
  nginx_classification=${3:-active_config}
  nginx_confidence=${4:-high}
  nginx_basis=${5:-active Nginx configuration}
  [ -f "$nginx_config" ] || return 0
  grep -Fxq "$nginx_config" "$PARSED_NGINX" 2>/dev/null && return 0
  printf '%s\n' "$nginx_config" >> "$PARSED_NGINX"
  copy_file_artifact config "$nginx_classification" nginx "$nginx_config" "$nginx_confidence" "$nginx_basis" || true
  [ "$nginx_depth" -lt 3 ] || return 0

  include_list=$(next_list_file)
  awk '
    {
      line=$0
      sub(/#.*/, "", line)
      if (line ~ /^[[:space:]]*include[[:space:]]+/) {
        sub(/^[[:space:]]*include[[:space:]]+/, "", line)
        sub(/[[:space:]]*;[[:space:]]*$/, "", line)
        gsub(/^["\047]|["\047]$/, "", line)
        if (line != "") print line
      }
    }
  ' "$nginx_config" > "$include_list"
  while IFS= read -r include_pattern; do
    case "$include_pattern" in *'$'*) continue ;; esac
    case "$include_pattern" in
      /*) resolved_pattern=$include_pattern ;;
      *) resolved_pattern="$(dirname "$nginx_config")/$include_pattern" ;;
    esac
    include_dir=$(dirname "$resolved_pattern")
    include_name=$(basename "$resolved_pattern")
    matched_list=$(next_list_file)
    if [ -d "$include_dir" ] && { has_cmd find || has_cmd busybox; }; then
      run_find "$include_dir" -maxdepth 1 -type f -name "$include_name" -print 2>/dev/null > "$matched_list"
      while IFS= read -r included_config; do
        collect_nginx_config "$included_config" $((nginx_depth + 1)) \
          "$nginx_classification" "$nginx_confidence" "$nginx_basis"
      done < "$matched_list"
    elif [ -f "$resolved_pattern" ]; then
      collect_nginx_config "$resolved_pattern" $((nginx_depth + 1)) \
        "$nginx_classification" "$nginx_confidence" "$nginx_basis"
    fi
    rm -f "$matched_list"
  done < "$include_list"
  rm -f "$include_list"
}

is_component_detected() {
  detection_pattern=$1
  grep -Eiq "$detection_pattern" "$PROCESSES" 2>/dev/null ||
    grep -Eiq "$detection_pattern" "$SERVICES" 2>/dev/null ||
    grep -Eiq "$detection_pattern" "$SERVICE_FILES" 2>/dev/null ||
    grep -Eiq "$detection_pattern" "$COMPONENT_VERSIONS" 2>/dev/null ||
    case "$detection_pattern" in
      *nginx*) awk -F '\t' 'NR > 1 && tolower($1) ~ /\/nginx\.conf$/ { found=1; exit } END { exit(found ? 0 : 1) }' "$FILE_INDEX" ;;
      *redis*)
        awk -F '\t' 'NR > 1 && tolower($1) ~ /\/redis[^/]*\.conf$/ { found=1; exit } END { exit(found ? 0 : 1) }' "$FILE_INDEX" ||
          awk -F '\t' 'NR > 1 && $2 == "redis" && $5 == "DETECTED" { found=1; exit } END { exit(found ? 0 : 1) }' "$COMPONENT_VERSIONS"
        ;;
      *) return 1 ;;
    esac
}

collect_indexed_configs() {
  indexed_component=$1
  indexed_pattern=$2
  indexed_basis=$3
  indexed_list=$(next_list_file)
  awk -F '\t' -v pattern="$indexed_pattern" '
    NR > 1 {
      path=tolower($1)
      if (path ~ pattern) print $1
    }
  ' "$FILE_INDEX" > "$indexed_list"
  while IFS= read -r indexed_path; do
    [ -f "$indexed_path" ] || continue
    if [ "$indexed_component" = nginx ]; then
      collect_nginx_config "$indexed_path" 0 candidate_config medium "$indexed_basis"
    else
      copy_file_artifact config candidate_config "$indexed_component" "$indexed_path" medium "$indexed_basis" || true
    fi
  done < "$indexed_list"
  rm -f "$indexed_list"
}

collect_service_definitions() {
  service_component=$1
  service_pattern=$2
  [ -r "$SERVICE_FILES" ] || return 0
  while IFS= read -r service_path; do
    [ -f "$service_path" ] || continue
    if printf '%s\n' "$service_path" | grep -Eiq "$service_pattern" || \
      grep -Eiq "$service_pattern" "$service_path" 2>/dev/null; then
      copy_file_artifact config service_config "$service_component" "$service_path" medium \
        "service definition associated with detected component" || true
    fi
  done < "$SERVICE_FILES"
}

is_candidate_jar() {
  jar_path=$1
  case "$(printf '%s' "$jar_path" | tr '[:upper:]' '[:lower:]')" in
    */lib/*|*/libs/*|*/web-inf/lib/*|*/.m2/repository/*|*/.gradle/caches/*|*/jre/lib/*|*/jdk*/lib/*)
      return 1
      ;;
  esac
  if has_cmd unzip && unzip -p "$jar_path" META-INF/MANIFEST.MF 2>/dev/null | grep -Eiq '^(Main-Class|Start-Class):'; then
    return 0
  fi
  case "$jar_path" in
    /app/*|/apps/*|/opt/*|/usr/local/*|/var/opt/*|/srv/*|/data/*|/home/*|/mnt/*|/workspace/*|*/deploy/*|*/deployments/*)
      return 0
      ;;
  esac
  return 1
}

# 进程参数直接引用的应用包拥有最高优先级。
while IFS="$TAB" read -r arg_pid arg_index arg_value || [ -n "${arg_pid:-}" ]; do
  [ "${arg_pid:-}" = pid ] && continue
  case "$(printf '%s' "${arg_value:-}" | tr '[:upper:]' '[:lower:]')" in
    *.jar|*.war)
      arg_cwd=$(cwd_for_pid "$arg_pid")
      arg_path=$(resolve_path "$arg_value" "$arg_cwd")
      if [ -f "$arg_path" ]; then
        arg_component=$(component_for_pid "$arg_pid")
        copy_file_artifact application primary "$arg_component" "$arg_path" high \
          "referenced by running process pid=$arg_pid argument=$arg_index" || true
      fi
      ;;
  esac
done < "$PROCESS_ARGS"

# 从进程环境恢复容器、中间件和数据库的活动目录。
while IFS="$TAB" read -r detail_pid detail_exe detail_cwd detail_java_home detail_env || [ -n "${detail_pid:-}" ]; do
  [ "${detail_pid:-}" = pid ] && continue
  detail_component=$(component_for_pid "$detail_pid")
  case "$detail_component" in
    tomcat)
      tomcat_base=$(env_value "$detail_env" CATALINA_BASE)
      [ -n "$tomcat_base" ] || tomcat_base=$(env_value "$detail_env" CATALINA_HOME)
      [ -n "$tomcat_base" ] && collect_tomcat_base "$tomcat_base"
      ;;
    tongweb)
      tongweb_root=$(env_value "$detail_env" TONGWEB_BASE)
      [ -n "$tongweb_root" ] || tongweb_root=$(env_value "$detail_env" TONGWEB_HOME)
      [ -n "$tongweb_root" ] && collect_tongweb_root "$tongweb_root"
      ;;
    jboss-wildfly)
      jboss_root=$(env_value "$detail_env" JBOSS_HOME)
      [ -n "$jboss_root" ] && collect_jboss_root "$jboss_root"
      ;;
    weblogic)
      domain_root=$(env_value "$detail_env" DOMAIN_HOME)
      [ -n "$domain_root" ] && collect_weblogic_domain "$domain_root"
      ;;
    resin)
      resin_root=$(env_value "$detail_env" RESIN_HOME)
      [ -n "$resin_root" ] && collect_resin_root "$resin_root"
      ;;
    elasticsearch)
      elastic_conf=$(env_value "$detail_env" ES_PATH_CONF)
      [ -n "$elastic_conf" ] && collect_elasticsearch_conf "$elastic_conf"
      ;;
    rabbitmq)
      rabbit_conf=$(env_value "$detail_env" RABBITMQ_CONFIG_FILE)
      if [ -n "$rabbit_conf" ]; then
        copy_file_artifact config active_config rabbitmq "$rabbit_conf" high "RABBITMQ_CONFIG_FILE for pid=$detail_pid" || \
          copy_file_artifact config active_config rabbitmq "$rabbit_conf.conf" high "RABBITMQ_CONFIG_FILE for pid=$detail_pid" || true
      fi
      ;;
    oracle)
      tns_admin=$(env_value "$detail_env" TNS_ADMIN)
      oracle_home=$(env_value "$detail_env" ORACLE_HOME)
      [ -n "$tns_admin" ] && collect_config_dir oracle "$tns_admin" 2 "active Oracle TNS_ADMIN"
      [ -n "$oracle_home" ] && collect_config_dir oracle "$oracle_home/network/admin" 2 "active Oracle network configuration"
      ;;
  esac
done < "$PROCESS_DETAILS"

# 解析命令行中的显式配置路径和 Java 系统属性。
last_pid=
expect_config=
while IFS="$TAB" read -r arg_pid arg_index arg_value || [ -n "${arg_pid:-}" ]; do
  [ "${arg_pid:-}" = pid ] && continue
  if [ "$arg_pid" != "$last_pid" ]; then
    last_pid=$arg_pid
    expect_config=
  fi
  arg_component=$(component_for_pid "$arg_pid")
  arg_cwd=$(cwd_for_pid "$arg_pid")
  if [ -n "$expect_config" ]; then
    config_path=$(resolve_path "$arg_value" "$arg_cwd")
    case "$expect_config" in
      nginx) collect_nginx_config "$config_path" ;;
      *) copy_file_artifact config active_config "$expect_config" "$config_path" high \
           "explicit process argument for pid=$arg_pid" || true ;;
    esac
    expect_config=
    continue
  fi
  case "$arg_component:$arg_value" in
    nginx:-c) expect_config=nginx ;;
    mysql:--defaults-file=*)
      copy_file_artifact config active_config mysql "${arg_value#*=}" high "mysqld --defaults-file for pid=$arg_pid" || true
      ;;
    redis:*.conf)
      config_path=$(resolve_path "$arg_value" "$arg_cwd")
      copy_file_artifact config active_config redis "$config_path" high "redis-server config argument for pid=$arg_pid" || true
      ;;
    dm:*.ini)
      config_path=$(resolve_path "$arg_value" "$arg_cwd")
      copy_file_artifact config active_config dm "$config_path" high "dmserver config argument for pid=$arg_pid" || true
      ;;
    *:-Dcatalina.base=*) collect_tomcat_base "${arg_value#*=}" ;;
    *:-Dcatalina.home=*) collect_tomcat_base "${arg_value#*=}" ;;
    *:-Djboss.home.dir=*) collect_jboss_root "${arg_value#*=}" ;;
    *:-Djboss.server.base.dir=*)
      jboss_base=${arg_value#*=}
      collect_config_dir jboss-wildfly "$jboss_base/configuration" 3 "active JBoss/WildFly server base"
      collect_deployment_dir jboss-wildfly "$jboss_base/deployments" "active JBoss/WildFly server base"
      ;;
    *:-Ddomain.home=*) collect_weblogic_domain "${arg_value#*=}" ;;
    *:-Dweblogic.RootDirectory=*) collect_weblogic_domain "${arg_value#*=}" ;;
    *:-Des.path.conf=*) collect_elasticsearch_conf "${arg_value#*=}" ;;
    *:-Epath.conf=*) collect_elasticsearch_conf "${arg_value#*=}" ;;
  esac
done < "$PROCESS_ARGS"

# 运行组件的标准配置位置作为显式参数缺失时的可靠回退。
if is_component_detected 'nginx'; then
  for config_file in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf; do
    collect_nginx_config "$config_file" 0 active_config medium "standard path for detected Nginx"
  done
fi
if is_component_detected 'redis-server|redis_sentinel'; then
  for config_file in /etc/redis/redis.conf /etc/redis.conf /usr/local/etc/redis.conf; do
    copy_file_artifact config active_config redis "$config_file" medium "standard path for detected Redis" || true
  done
fi
if is_component_detected 'rabbitmq'; then
  for config_file in /etc/rabbitmq/rabbitmq.conf /etc/rabbitmq/advanced.config \
    /etc/rabbitmq/enabled_plugins /etc/rabbitmq/rabbitmq-env.conf; do
    copy_file_artifact config active_config rabbitmq "$config_file" medium "standard path for detected RabbitMQ" || true
  done
fi
if is_component_detected 'elasticsearch'; then
  collect_elasticsearch_conf /etc/elasticsearch
fi
if is_component_detected 'mysqld|mariadbd'; then
  for config_file in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf /usr/local/mysql/my.cnf; do
    copy_file_artifact config active_config mysql "$config_file" medium "standard path for detected MySQL" || true
  done
fi
if is_component_detected 'resin'; then
  for config_file in /etc/resin/resin.xml /etc/resin/resin.properties; do
    copy_file_artifact config active_config resin "$config_file" medium "standard path for detected Resin" || true
  done
fi

for service_pair in \
  'nginx:nginx' \
  'redis:redis' \
  'rabbitmq:rabbit' \
  'elasticsearch:elastic' \
  'tomcat:tomcat|catalina' \
  'tongweb:tongweb' \
  'jboss-wildfly:wildfly|jboss' \
  'weblogic:weblogic' \
  'resin:resin' \
  'mysql:mysql|mariadb' \
  'oracle:oracle|tnslsnr' \
  'dm:dmserver|dameng'; do
  service_component=${service_pair%%:*}
  service_pattern=${service_pair#*:}
  is_component_detected "$service_pattern" && collect_service_definitions "$service_component" "$service_pattern"
done

# 对非标准安装目录使用文件索引定向回查，仍与活动配置区分。
is_component_detected 'nginx' && collect_indexed_configs nginx '/nginx\.conf$' "Nginx detected; matching config found in file index"
is_component_detected 'catalina|tomcat' && collect_indexed_configs tomcat \
  '/conf/(server|web|context)\.xml$|/conf/(catalina|logging)\.properties$|/bin/setenv\.sh$' \
  "Tomcat detected; matching config found in file index"
is_component_detected 'tongweb' && collect_indexed_configs tongweb \
  'tongweb.*/(conf|config)/.*\.(xml|properties|conf|yml|yaml|ini|json)$' \
  "TongWeb detected; matching config found in file index"
is_component_detected 'wildfly|jboss' && collect_indexed_configs jboss-wildfly \
  '(wildfly|jboss).*/(configuration|conf)/.*\.(xml|properties|conf)$' \
  "JBoss/WildFly detected; matching config found in file index"
is_component_detected 'weblogic' && collect_indexed_configs weblogic \
  'weblogic.*/config/.*\.(xml|properties)$' \
  "WebLogic detected; matching config found in file index"
is_component_detected 'redis-server|redis_sentinel' && collect_indexed_configs redis \
  '/redis[^/]*\.conf$' "Redis detected; matching config found in file index"
is_component_detected 'rabbitmq' && collect_indexed_configs rabbitmq \
  '/(rabbitmq[^/]*\.(conf|config)|advanced\.config|enabled_plugins)$' \
  "RabbitMQ detected; matching config found in file index"
is_component_detected 'elasticsearch' && collect_indexed_configs elasticsearch \
  '/(elasticsearch\.yml|jvm\.options|log4j2\.properties)$' \
  "Elasticsearch detected; matching config found in file index"
is_component_detected 'mysqld|mariadbd' && collect_indexed_configs mysql \
  '/(my|mysqld)\.cnf$' "MySQL detected; matching config found in file index"
is_component_detected 'resin' && collect_indexed_configs resin \
  '/(resin\.xml|resin\.properties)$' "Resin detected; matching config found in file index"
is_component_detected 'dmserver' && collect_indexed_configs dm \
  '/dm\.ini$' "DM detected; matching config found in file index"
is_component_detected 'tnslsnr|ora_pmon' && collect_indexed_configs oracle \
  '/(listener|tnsnames|sqlnet)\.ora$' "Oracle detected; matching config found in file index"

# 其他潜在应用包单独采集，避免与运行中应用包混淆。
candidate_list=$(next_list_file)
awk -F '\t' '
  NR > 1 {
    path=tolower($1)
    if (path ~ /\.(jar|war)$/) print $1
  }
' "$FILE_INDEX" > "$candidate_list"
while IFS= read -r candidate_path; do
  [ -f "$candidate_path" ] || continue
  case "$(printf '%s' "$candidate_path" | tr '[:upper:]' '[:lower:]')" in
    *.war)
      copy_file_artifact application candidate java-application "$candidate_path" medium \
        "deployable archive found in configured scan roots" || true
      ;;
    *.jar)
      if is_candidate_jar "$candidate_path"; then
        copy_file_artifact application candidate java-application "$candidate_path" medium \
          "executable or deployment-path JAR found in configured scan roots" || true
      fi
      ;;
  esac
done < "$candidate_list"
rm -f "$candidate_list"

# 对已识别但没有成功采集配置的组件留下明确缺口记录。
for detected_pair in \
  'nginx:nginx' \
  'redis:redis-server|redis_sentinel' \
  'rabbitmq:rabbitmq' \
  'elasticsearch:elasticsearch' \
  'tomcat:catalina|tomcat' \
  'tongweb:tongweb' \
  'jboss-wildfly:wildfly|jboss' \
  'weblogic:weblogic' \
  'resin:resin' \
  'mysql:mysqld|mariadbd' \
  'oracle:tnslsnr|ora_pmon' \
  'dm:dmserver'; do
  detected_component=${detected_pair%%:*}
  detected_regex=${detected_pair#*:}
  if is_component_detected "$detected_regex" && ! awk -F '\t' -v component="$detected_component" \
    'NR > 1 && $1 == "config" && $3 == component && $10 == "collected" { found=1; exit } END { exit(found ? 0 : 1) }' \
    "$COLLECTED_INDEX"; then
    append_record config unresolved "$detected_component" '(unresolved)' '' 0 '' medium \
      "component detected but active configuration path was not resolved" missing
    append_audit auto_collect "$detected_component" '' partial "active configuration path unresolved"
  fi
done

rm -f "$PARSED_NGINX" "$LIST_PREFIX".* 2>/dev/null || true
trap - 0 1 2 15

PRIMARY_COUNT=$(awk -F '\t' 'NR > 1 && $1 == "application" && $2 ~ /^primary/ && $10 == "collected" { count++ } END { print count+0 }' "$COLLECTED_INDEX")
CANDIDATE_TOTAL=$(awk -F '\t' 'NR > 1 && $1 == "application" && $2 == "candidate" && $10 == "collected" { count++ } END { print count+0 }' "$COLLECTED_INDEX")
CONFIG_TOTAL=$(awk -F '\t' 'NR > 1 && $1 == "config" && $10 == "collected" { count++ } END { print count+0 }' "$COLLECTED_INDEX")
printf 'primary_application_packages=%s\ncandidate_application_packages=%s\nmiddleware_config_files=%s\n' \
  "$PRIMARY_COUNT" "$CANDIDATE_TOTAL" "$CONFIG_TOTAL" > "$SCAN_RESULTS/artifact-summary.env"
append_audit auto_collect "$SCAN_RESULTS" "$COLLECTED_INDEX" success \
  "primary=$PRIMARY_COUNT candidate=$CANDIDATE_TOTAL configs=$CONFIG_TOTAL"
