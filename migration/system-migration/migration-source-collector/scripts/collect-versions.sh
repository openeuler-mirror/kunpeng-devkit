#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/collect-versions.sh --run-dir <dir>"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

clean_tsv() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c 1-500
}

env_value() {
  env_blob=$1
  env_key=$2
  printf '%s' "$env_blob" | tr ';' '\n' | awk -F= -v key="$env_key" \
    '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

arg_property() {
  property_pid=$1
  property_name=$2
  awk -F '\t' -v pid="$property_pid" -v property="$property_name" '
    $1 == pid && index($3, property "=") == 1 {
      sub(/^[^=]*=/, "", $3)
      print $3
      exit
    }
  ' "$PROCESS_ARGS"
}

process_line() {
  line_pid=$1
  awk -v pid="$line_pid" '$1 == pid { print; exit }' "$PROCESSES"
}

component_for_line() {
  lower_line=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower_line" in
    *nginx*) printf 'nginx' ;;
    *redis-server*|*redis_sentinel*) printf 'redis' ;;
    *rabbitmq*|*rabbit*) printf 'rabbitmq' ;;
    *elasticsearch*) printf 'elasticsearch' ;;
    *tongweb*) printf 'tongweb' ;;
    *catalina*|*tomcat*) printf 'tomcat' ;;
    *wildfly*|*jboss*) printf 'jboss-wildfly' ;;
    *weblogic*) printf 'weblogic' ;;
    *resin*) printf 'resin' ;;
    *mariadbd*) printf 'mariadb' ;;
    *mysqld*) printf 'mysql' ;;
    *tnslsnr*|*ora_pmon*) printf 'oracle' ;;
    *dmserver*) printf 'dm' ;;
    *java*) printf 'java-runtime' ;;
    *) printf '' ;;
  esac
}

product_for_component() {
  case "$1" in
    nginx) printf 'Nginx' ;;
    redis) printf 'Redis' ;;
    rabbitmq) printf 'RabbitMQ' ;;
    elasticsearch) printf 'Elasticsearch' ;;
    tongweb) printf 'TongWeb' ;;
    tomcat) printf 'Apache Tomcat' ;;
    jboss-wildfly) printf 'JBoss/WildFly' ;;
    weblogic) printf 'WebLogic' ;;
    resin) printf 'Resin' ;;
    mariadb) printf 'MariaDB' ;;
    mysql) printf 'MySQL' ;;
    oracle) printf 'Oracle Database' ;;
    dm) printf 'DM' ;;
    java-runtime) printf 'JDK / JRE' ;;
    *) printf '%s' "$1" ;;
  esac
}

home_for_component() {
  home_component=$1
  home_pid=$2
  home_env=$3
  case "$home_component" in
    tomcat)
      home_value=$(env_value "$home_env" CATALINA_HOME)
      [ -n "$home_value" ] || home_value=$(env_value "$home_env" CATALINA_BASE)
      [ -n "$home_value" ] || home_value=$(arg_property "$home_pid" -Dcatalina.home)
      [ -n "$home_value" ] || home_value=$(arg_property "$home_pid" -Dcatalina.base)
      ;;
    tongweb)
      home_value=$(env_value "$home_env" TONGWEB_HOME)
      [ -n "$home_value" ] || home_value=$(env_value "$home_env" TONGWEB_BASE)
      ;;
    jboss-wildfly)
      home_value=$(env_value "$home_env" JBOSS_HOME)
      [ -n "$home_value" ] || home_value=$(arg_property "$home_pid" -Djboss.home.dir)
      ;;
    weblogic)
      home_value=$(env_value "$home_env" DOMAIN_HOME)
      [ -n "$home_value" ] || home_value=$(arg_property "$home_pid" -Ddomain.home)
      ;;
    resin)
      home_value=$(env_value "$home_env" RESIN_HOME)
      ;;
    elasticsearch)
      home_value=$(arg_property "$home_pid" -Des.path.home)
      [ -n "$home_value" ] || home_value=$(arg_property "$home_pid" -Epath.home)
      ;;
    oracle)
      home_value=$(env_value "$home_env" ORACLE_HOME)
      ;;
    dm)
      home_value=$(env_value "$home_env" DM_HOME)
      ;;
    java-runtime)
      home_value=$(env_value "$home_env" JAVA_HOME)
      ;;
    *)
      home_value=
      ;;
  esac
  printf '%s' "$home_value"
}

extract_version() {
  version_component=$1
  version_input=$2
  case "$version_component" in
    nginx)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei 'nginx/' | head -n 1)
      ;;
    tomcat)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei 'server version|apache tomcat|server.info' | head -n 1)
      ;;
    java-runtime)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei '^(openjdk|java) version|version "' | head -n 1)
      ;;
    mysql|mariadb)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei '(^|[[:space:]])ver[[:space:]]|distrib|mariadb' | head -n 1)
      ;;
    redis)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei 'redis.*(v=|version)' | head -n 1)
      ;;
    elasticsearch)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei 'version' | head -n 1)
      ;;
    *)
      version_line=$(printf '%s\n' "$version_input" | grep -Ei 'version|release|implementation-version|specification-version' | head -n 1)
      [ -n "$version_line" ] || version_line=$(printf '%s\n' "$version_input" | head -n 1)
      ;;
  esac
  [ -n "$version_line" ] ||
    version_line=$(printf '%s\n' "$version_input" | grep -Ei 'version|release' | head -n 1)
  [ -n "$version_line" ] || version_line=$(printf '%s\n' "$version_input" | head -n 1)
  version_value=$(printf '%s\n' "$version_line" |
    grep -Eo '[0-9]+([.][0-9]+)+([._+-][0-9A-Za-z]+)*' 2>/dev/null |
    head -n 1)
  case "$version_value" in
    ''|*[xX\*]*) printf '' ;;
    *) printf '%s' "$version_value" ;;
  esac
}

capture_command() {
  : > "$PROBE_OUTPUT"
  if has_cmd timeout; then
    timeout 5 "$@" > "$PROBE_OUTPUT" 2>&1 || true
  else
    "$@" > "$PROBE_OUTPUT" 2>&1 || true
  fi
  CAPTURED_RAW=$(sed -n '1,8p' "$PROBE_OUTPUT")
}

accept_capture() {
  accept_component=$1
  accept_source=$2
  accept_method=$3
  accept_version=$(extract_version "$accept_component" "$CAPTURED_RAW")
  [ -n "$accept_version" ] || return 1
  DETECTED_VERSION=$accept_version
  DETECTION_SOURCE=$accept_source
  DETECTION_METHOD=$accept_method
  DETECTION_RAW=$CAPTURED_RAW
  return 0
}

probe_command() {
  command_component=$1
  command_source=$2
  command_method=$3
  shift 3
  [ -x "$1" ] || return 1
  capture_command "$@"
  accept_capture "$command_component" "$command_source" "$command_method"
}

package_candidates() {
  case "$1" in
    nginx) printf 'nginx' ;;
    redis) printf 'redis redis-server' ;;
    rabbitmq) printf 'rabbitmq-server' ;;
    elasticsearch) printf 'elasticsearch' ;;
    tomcat) printf 'tomcat tomcat9 tomcat10' ;;
    jboss-wildfly) printf 'wildfly jboss-as' ;;
    resin) printf 'resin' ;;
    mysql) printf 'mysql-community-server mysql-server' ;;
    mariadb) printf 'mariadb-server' ;;
    oracle) printf 'oracle-database-ee oracle-database-ee-19c oracle-database-ee-21c' ;;
    dm) printf 'dm8 dameng' ;;
    java-runtime) printf 'java-1.8.0-openjdk java-11-openjdk java-17-openjdk java-21-openjdk' ;;
    *) printf '' ;;
  esac
}

probe_package() {
  package_component=$1
  package_exe=$2
  package_owner_only=${3-false}
  package_version=
  package_source=
  package_method=

  if has_cmd rpm; then
    if [ -n "$package_exe" ] && [ -e "$package_exe" ]; then
      package_info=$(rpm -qf --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' "$package_exe" 2>/dev/null | head -n 1)
      package_name=$(printf '%s' "$package_info" | awk -F '\t' '{print $1}')
      package_version=$(printf '%s' "$package_info" | awk -F '\t' '{print $2}')
      case "$package_component:$package_name" in
        nginx:*nginx*|redis:*redis*|mysql:*mysql*|mariadb:*mariadb*|elasticsearch:*elasticsearch*|java-runtime:*java*|java-runtime:*jdk*)
          package_source=$package_name
          package_method=rpm-owner
          ;;
        *)
          package_version=
          ;;
      esac
    fi
    if [ -z "$package_version" ] && [ "$package_owner_only" != true ]; then
      for package_name in $(package_candidates "$package_component"); do
        package_version=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$package_name" 2>/dev/null | head -n 1)
        [ -n "$package_version" ] || continue
        package_source=$package_name
        package_method=rpm-package
        break
      done
    fi
  elif has_cmd dpkg-query; then
    if [ -n "$package_exe" ] && [ -e "$package_exe" ]; then
      package_name=$(dpkg-query -S "$package_exe" 2>/dev/null | head -n 1 | cut -d: -f1)
      case "$package_component:$package_name" in
        nginx:*nginx*|redis:*redis*|mysql:*mysql*|mariadb:*mariadb*|elasticsearch:*elasticsearch*|java-runtime:*java*|java-runtime:*jdk*)
          package_version=$(dpkg-query -W -f='${Version}\n' "$package_name" 2>/dev/null | head -n 1)
          package_source=$package_name
          package_method=deb-owner
          ;;
      esac
    fi
    if [ -z "$package_version" ] && [ "$package_owner_only" != true ]; then
      for package_name in $(package_candidates "$package_component"); do
        package_version=$(dpkg-query -W -f='${Version}\n' "$package_name" 2>/dev/null | head -n 1)
        [ -n "$package_version" ] || continue
        package_source=$package_name
        package_method=deb-package
        break
      done
    fi
  fi

  package_version=$(extract_version "$package_component" "version=$package_version")
  [ -n "$package_version" ] || return 1
  DETECTED_VERSION=$package_version
  DETECTION_SOURCE=$package_source
  DETECTION_METHOD=$package_method
  DETECTION_RAW="package=$package_source version=$package_version"
  return 0
}

probe_metadata() {
  metadata_component=$1
  metadata_home=$2
  [ -d "$metadata_home" ] || return 1

  if [ "$metadata_component" = tomcat ] && [ -r "$metadata_home/bin/version.sh" ]; then
    capture_command sh "$metadata_home/bin/version.sh"
    accept_capture tomcat "$metadata_home/bin/version.sh" version-script && return 0
  fi

  for metadata_file in \
    "$metadata_home/RELEASE-NOTES" \
    "$metadata_home/VERSION" \
    "$metadata_home/version.txt" \
    "$metadata_home/conf/version.properties" \
    "$metadata_home/config/version.properties" \
    "$metadata_home/lib/version.properties" \
    "$metadata_home/lib/product-info.properties"; do
    [ -r "$metadata_file" ] || continue
    CAPTURED_RAW=$(grep -Ei 'version|release|server.info|implementation-version|specification-version' "$metadata_file" 2>/dev/null | head -n 8)
    [ -n "$CAPTURED_RAW" ] || CAPTURED_RAW=$(sed -n '1,8p' "$metadata_file")
    accept_capture "$metadata_component" "$metadata_file" version-file && return 0
  done

  has_cmd unzip || return 1
  metadata_count=0
  for metadata_jar in \
    "$metadata_home/lib/catalina.jar" \
    "$metadata_home/jboss-modules.jar" \
    "$metadata_home"/lib/tongweb*.jar \
    "$metadata_home"/lib/server*.jar; do
    [ -f "$metadata_jar" ] || continue
    metadata_count=$((metadata_count + 1))
    [ "$metadata_count" -le 10 ] || break
    if [ "$metadata_component" = tomcat ]; then
      CAPTURED_RAW=$(unzip -p "$metadata_jar" org/apache/catalina/util/ServerInfo.properties 2>/dev/null | head -n 20)
      if [ -n "$CAPTURED_RAW" ] && accept_capture tomcat "$metadata_jar" server-info; then
        return 0
      fi
    fi
    CAPTURED_RAW=$(unzip -p "$metadata_jar" META-INF/MANIFEST.MF 2>/dev/null |
      grep -Ei 'Implementation-Version|Specification-Version|Bundle-Version|Product-Version' |
      head -n 8)
    [ -n "$CAPTURED_RAW" ] || continue
    accept_capture "$metadata_component" "$metadata_jar" jar-manifest && return 0
  done
  return 1
}

probe_component() {
  probe_component_name=$1
  probe_pid=$2
  probe_exe=$3
  probe_home=$4
  DETECTED_VERSION=
  DETECTION_SOURCE=$probe_exe
  DETECTION_METHOD=unresolved
  DETECTION_RAW=

  case "$probe_component_name" in
    nginx)
      probe_command nginx "$probe_exe" executable-version "$probe_exe" -v ||
        probe_command nginx "$probe_exe" executable-version "$probe_exe" -V || true
      ;;
    redis)
      probe_command redis "$probe_exe" executable-version "$probe_exe" --version || true
      ;;
    mysql|mariadb)
      probe_command "$probe_component_name" "$probe_exe" executable-version "$probe_exe" --version ||
        probe_command "$probe_component_name" "$probe_exe" executable-version "$probe_exe" -V || true
      ;;
    oracle)
      case "$(basename "$probe_exe" 2>/dev/null)" in
        tnslsnr) probe_command oracle "$probe_exe" executable-version "$probe_exe" -version || true ;;
      esac
      ;;
    elasticsearch)
      if [ -x "$probe_home/bin/elasticsearch" ]; then
        probe_command elasticsearch "$probe_home/bin/elasticsearch" executable-version \
          "$probe_home/bin/elasticsearch" --version || true
      fi
      ;;
    java-runtime)
      probe_command java-runtime "$probe_exe" executable-version "$probe_exe" -version || true
      ;;
  esac

  if [ -n "$DETECTED_VERSION" ]; then
    probe_package "$probe_component_name" "$probe_exe" true && return 0
  fi
  [ -n "$DETECTED_VERSION" ] ||
    probe_package "$probe_component_name" "$probe_exe" ||
    probe_metadata "$probe_component_name" "$probe_home" ||
    true
}

emit_result() {
  result_pid=$1
  result_component=$2
  result_product=$(product_for_component "$result_component")
  result_status=UNKNOWN
  [ -n "$DETECTED_VERSION" ] && result_status=DETECTED
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_tsv "$result_pid")" \
    "$(clean_tsv "$result_component")" \
    "$(clean_tsv "$result_product")" \
    "$(clean_tsv "$DETECTED_VERSION")" \
    "$result_status" \
    "$(clean_tsv "$DETECTION_SOURCE")" \
    "$(clean_tsv "$DETECTION_METHOD")" \
    "$(clean_tsv "$DETECTION_RAW")" >> "$VERSION_RESULTS"
}

RUN_DIR=
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -n "$RUN_DIR" ] || die "--run-dir is required" 2
SCAN_RESULTS="$RUN_DIR/details/internal/scan-results"
PROCESS_DETAILS="$SCAN_RESULTS/process-details.tsv"
PROCESS_ARGS="$SCAN_RESULTS/process-args.tsv"
PROCESSES="$SCAN_RESULTS/processes.txt"
VERSION_RESULTS="$SCAN_RESULTS/component-versions.tsv"
SEEN="$SCAN_RESULTS/.version-seen.$$"
PROBE_OUTPUT="$SCAN_RESULTS/.version-probe.$$"

[ -r "$PROCESS_DETAILS" ] || die "Process details are missing" 2
[ -r "$PROCESS_ARGS" ] || die "Process arguments are missing" 2
[ -r "$PROCESSES" ] || die "Process list is missing" 2

: > "$SEEN"
: > "$PROBE_OUTPUT"
trap 'rm -f "$SEEN" "$PROBE_OUTPUT"' 0 1 2 15
printf 'pid\tcomponent\tproduct\tversion\tversion_status\tsource_path\tdetection_method\traw_output\n' > "$VERSION_RESULTS"
TAB=$(printf '\t')

while IFS="$TAB" read -r detail_pid detail_exe detail_cwd detail_java_home detail_env || [ -n "${detail_pid:-}" ]; do
  [ "${detail_pid:-}" = pid ] && continue
  detail_line=$(process_line "$detail_pid")
  detail_component=$(component_for_line "$detail_line")
  [ -n "$detail_component" ] || continue
  detail_home=$(home_for_component "$detail_component" "$detail_pid" "$detail_env")
  detail_key="$detail_component|$detail_exe|$detail_home"
  if ! grep -Fxq "$detail_key" "$SEEN"; then
    printf '%s\n' "$detail_key" >> "$SEEN"
    probe_component "$detail_component" "$detail_pid" "$detail_exe" "$detail_home"
    emit_result "$detail_pid" "$detail_component"
  fi

  case "$detail_exe" in
    */java|*/java.bin)
      java_key="java-runtime|$detail_exe|$detail_java_home"
      if ! grep -Fxq "$java_key" "$SEEN"; then
        printf '%s\n' "$java_key" >> "$SEEN"
        probe_component java-runtime "$detail_pid" "$detail_exe" "$detail_java_home"
        emit_result "$detail_pid" java-runtime
      fi
      ;;
  esac
done < "$PROCESS_DETAILS"

# 服务未运行时仍从已安装命令或软件包补充 Nginx、Redis 和 JDK/JRE。
for fallback_component in nginx redis java-runtime; do
  grep -Eq "^${fallback_component}\\|" "$SEEN" && continue
  case "$fallback_component" in
    nginx)
      fallback_exe=$(command -v nginx 2>/dev/null || true)
      if [ -z "$fallback_exe" ]; then
        for fallback_path in /usr/sbin/nginx /usr/local/nginx/sbin/nginx /opt/nginx/sbin/nginx; do
          [ -x "$fallback_path" ] || continue
          fallback_exe=$fallback_path
          break
        done
      fi
      ;;
    redis)
      fallback_exe=$(command -v redis-server 2>/dev/null || true)
      if [ -z "$fallback_exe" ]; then
        for fallback_path in /usr/bin/redis-server /usr/local/bin/redis-server /opt/redis/bin/redis-server; do
          [ -x "$fallback_path" ] || continue
          fallback_exe=$fallback_path
          break
        done
      fi
      ;;
    java-runtime) fallback_exe=$(command -v java 2>/dev/null || true) ;;
  esac
  probe_component "$fallback_component" installed "$fallback_exe" ''
  [ -n "$DETECTED_VERSION" ] || continue
  printf '%s\n' "$fallback_component|$fallback_exe|" >> "$SEEN"
  emit_result installed "$fallback_component"
done

rm -f "$SEEN" "$PROBE_OUTPUT"
trap - 0 1 2 15
printf '%s\n' "$VERSION_RESULTS"
