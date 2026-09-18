#!/bin/sh
set -u
umask 077

MIRROR_URL_DEFAULT='https://mirrors.huaweicloud.com/kunpeng/archive/Kunpeng_Middleware/'
MIN_FREE_SPACE_BYTES=10737418240

usage() {
  echo "Usage: sh migration-precheck/scripts/check-target.sh --plan <migration-plan.json> --work-dir <migration-work-dir> [--mirror-url <https-url>]"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

clean_tsv() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

emit_fact() {
  printf '%s\t%s\n' "$1" "$(clean_tsv "$2")"
}

PLAN=
MIGRATION_WORK_DIR=
MIRROR_URL=$MIRROR_URL_DEFAULT

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=${2-}; shift 2 ;;
    --work-dir) MIGRATION_WORK_DIR=${2-}; shift 2 ;;
    --mirror-url) MIRROR_URL=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -r "$PLAN" ] || die "--plan must be a readable migration-plan.json" 2
[ -n "$MIGRATION_WORK_DIR" ] || die "--work-dir is required" 2
case "$MIGRATION_WORK_DIR" in /*) ;; *) die "--work-dir must be an absolute path" 2 ;; esac
PACKAGE_DIR="$MIGRATION_WORK_DIR/packages"
LICENSE_DIR="$MIGRATION_WORK_DIR/licenses"
PACKAGE_DIR=$(mkdir -p "$PACKAGE_DIR" && cd "$PACKAGE_DIR" && pwd -P)
LICENSE_DIR=$(mkdir -p "$LICENSE_DIR" && cd "$LICENSE_DIR" && pwd -P)
RUNTIME_TMP="$MIGRATION_WORK_DIR/tmp"
mkdir -p "$RUNTIME_TMP"
export TMPDIR="$RUNTIME_TMP" TMP="$RUNTIME_TMP" TEMP="$RUNTIME_TMP"
case "$MIRROR_URL" in https://*) ;; *) die "--mirror-url must use HTTPS" 2 ;; esac
case "$MIRROR_URL" in *'@'*) die "Credential-bearing mirror URLs are forbidden" 2 ;; esac

CHECKED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo unknown)
UNAME_S=$(uname -s 2>/dev/null || echo unknown)
ARCH=$(uname -m 2>/dev/null || echo unknown)
KERNEL=$(uname -r 2>/dev/null || echo unknown)
HOSTNAME_VALUE=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)

if [ -r /etc/os-release ]; then
  OS_VALUE=$(awk -F= '$1=="PRETTY_NAME" {value=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",value); print value; exit}' /etc/os-release)
else
  OS_VALUE=$UNAME_S
fi
[ -n "$OS_VALUE" ] || OS_VALUE=unknown

PRIMARY_IP=
if has_cmd hostname; then
  PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi
if [ -z "$PRIMARY_IP" ] && has_cmd ip; then
  PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
fi
[ -n "$PRIMARY_IP" ] || PRIMARY_IP=unknown

GLIBC=unknown
if has_cmd getconf; then
  GLIBC=$(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown)
elif has_cmd ldd; then
  GLIBC=$(ldd --version 2>&1 | head -n 1 || echo unknown)
fi

PACKAGE_MANAGER=none
for manager_candidate in dnf yum apt-get; do
  if has_cmd "$manager_candidate"; then
    PACKAGE_MANAGER=$manager_candidate
    break
  fi
done

if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
  PRIVILEGE=root
elif has_cmd sudo && sudo -n true >/dev/null 2>&1; then
  PRIVILEGE=sudo-nopasswd
else
  PRIVILEGE=unprivileged
fi

PACKAGE_DIR_WRITABLE=false
if mkdir -p "$PACKAGE_DIR" 2>/dev/null && [ -d "$PACKAGE_DIR" ] && [ -w "$PACKAGE_DIR" ]; then
  PACKAGE_DIR_WRITABLE=true
fi

LICENSE_DIR_WRITABLE=false
if mkdir -p "$LICENSE_DIR" 2>/dev/null && [ -d "$LICENSE_DIR" ] && [ -w "$LICENSE_DIR" ]; then
  LICENSE_DIR_WRITABLE=true
fi

FREE_BYTES=0
SPACE_PATH=$PACKAGE_DIR
[ -e "$SPACE_PATH" ] || SPACE_PATH=$(dirname "$PACKAGE_DIR")
if has_cmd df; then
  FREE_KB=$(df -Pk "$SPACE_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  case "$FREE_KB" in ''|*[!0-9]*) FREE_KB=0 ;; esac
  FREE_BYTES=$((FREE_KB * 1024))
fi
if [ "$FREE_BYTES" -le "$MIN_FREE_SPACE_BYTES" ]; then
  die "Target free space must be greater than 10 GiB; available bytes: $FREE_BYTES" 7
fi

JAVA_INSTALLED=false
JAVA_VERSION=
JAVA_COMMAND=
JAVA_HOME_VALUE=
if has_cmd java; then
  JAVA_COMMAND=$(command -v java 2>/dev/null || true)
  JAVA_REAL=$JAVA_COMMAND
  if has_cmd readlink; then JAVA_REAL=$(readlink -f "$JAVA_COMMAND" 2>/dev/null || printf '%s' "$JAVA_COMMAND"); fi
  case "$JAVA_REAL" in */bin/java) JAVA_HOME_VALUE=${JAVA_REAL%/bin/java} ;; esac
  JAVA_OUTPUT=$(java -version 2>&1)
  JAVA_EXIT=$?
  JAVA_VERSION=$(printf '%s\n' "$JAVA_OUTPUT" | awk 'NR==1 {print; exit}')
  if [ "$JAVA_EXIT" -eq 0 ] && [ -n "$JAVA_VERSION" ]; then
    JAVA_INSTALLED=true
  fi
fi

NETWORK_STATUS=UNKNOWN
NETWORK_METHOD=none
if has_cmd curl; then
  NETWORK_METHOD=curl
  if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 -o /dev/null "$MIRROR_URL"; then
    NETWORK_STATUS=ONLINE
  else
    NETWORK_STATUS=OFFLINE
  fi
elif has_cmd wget; then
  NETWORK_METHOD=wget
  if wget -q --https-only --spider --timeout=15 "$MIRROR_URL"; then
    NETWORK_STATUS=ONLINE
  else
    NETWORK_STATUS=OFFLINE
  fi
fi

ENVIRONMENT_STATUS=READY
case "$UNAME_S" in Linux) ;; *) ENVIRONMENT_STATUS=INCOMPATIBLE_TARGET ;; esac
case "$ARCH" in aarch64|arm64) ;; *) ENVIRONMENT_STATUS=INCOMPATIBLE_TARGET ;; esac
if [ "$ENVIRONMENT_STATUS" = READY ] && [ "$PACKAGE_DIR_WRITABLE" != true ]; then
  ENVIRONMENT_STATUS=READY_WITH_ACTIONS
fi
if [ "$ENVIRONMENT_STATUS" = READY ] && [ "$LICENSE_DIR_WRITABLE" != true ]; then
  ENVIRONMENT_STATUS=READY_WITH_ACTIONS
fi
if [ "$ENVIRONMENT_STATUS" = READY ] && [ "$PACKAGE_MANAGER" = none ]; then
  ENVIRONMENT_STATUS=READY_WITH_ACTIONS
fi

emit_fact checked_at "$CHECKED_AT"
emit_fact environment_status "$ENVIRONMENT_STATUS"
emit_fact hostname "$HOSTNAME_VALUE"
emit_fact primary_ip "$PRIMARY_IP"
emit_fact os "$OS_VALUE"
emit_fact architecture "$ARCH"
emit_fact kernel "$KERNEL"
emit_fact glibc "$GLIBC"
emit_fact package_manager "$PACKAGE_MANAGER"
emit_fact privilege "$PRIVILEGE"
emit_fact license_directory "$LICENSE_DIR"
emit_fact license_directory_writable "$LICENSE_DIR_WRITABLE"
emit_fact free_space_bytes "$FREE_BYTES"
emit_fact java_installed "$JAVA_INSTALLED"
emit_fact java_version "$JAVA_VERSION"
emit_fact java_command "$JAVA_COMMAND"
emit_fact java_home "$JAVA_HOME_VALUE"
emit_fact network_probe_url "$MIRROR_URL"
emit_fact network_status "$NETWORK_STATUS"
emit_fact network_method "$NETWORK_METHOD"
