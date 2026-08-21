#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh scripts/export-db.sh --config <file> --run-dir <dir> --password-stdin"
  echo "Runs only when DATABASE_EXPORT_ENABLED=true and supports mysql or oracle."
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

CONFIG=
RUN_DIR=
PASSWORD_STDIN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG=${2-}; shift 2 ;;
    --run-dir) RUN_DIR=${2-}; shift 2 ;;
    --password-stdin) PASSWORD_STDIN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -r "$CONFIG" ] || die "Config file is required and must be readable" 2
[ -d "$RUN_DIR/details/internal/audit" ] || die "Invalid run directory" 2

ENABLED=$(config_get DATABASE_EXPORT_ENABLED "$CONFIG" false)
is_true "$ENABLED" || die "Database export is disabled; enable it only after explicit user authorization" 3

DB_TYPE=$(config_get DATABASE_TYPE "$CONFIG" '')
DB_HOST=$(config_get DATABASE_HOST "$CONFIG" '')
DB_PORT=$(config_get DATABASE_PORT "$CONFIG" '')
DB_NAME=$(config_get DATABASE_NAME "$CONFIG" '')
DB_USER=$(config_get DATABASE_USERNAME "$CONFIG" '')
OUTPUT_NAME=$(safe_name "$(config_get DATABASE_EXPORT_OUTPUT_NAME "$CONFIG" "${DB_TYPE}-export")")

[ -n "$DB_HOST" ] || die "DATABASE_HOST is required" 2
[ -n "$DB_NAME" ] || die "DATABASE_NAME is required" 2
[ -n "$DB_USER" ] || die "DATABASE_USERNAME is required" 2
[ -n "$OUTPUT_NAME" ] || die "DATABASE_EXPORT_OUTPUT_NAME is invalid" 2
[ "$PASSWORD_STDIN" = true ] ||
  die "Database password must be provided by the front-end secret field with --password-stdin" 2
IFS= read -r DB_PASSWORD || die "No database password was received on standard input" 2
[ -n "$DB_PASSWORD" ] || die "Database password cannot be empty" 2

EXPORT_DIR="$RUN_DIR/details/database-export"
AUDIT_FILE="$RUN_DIR/details/internal/audit/audit.tsv"
mkdir -p "$EXPORT_DIR" || die "Cannot create database export directory" 4

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

case "$DB_TYPE" in
  mysql)
    has_cmd mysqldump || {
      append_audit database_export mysql '' failed "mysqldump unavailable"
      die "mysqldump is unavailable; dependencies are not installed automatically" 5
    }
    [ -n "$DB_PORT" ] || DB_PORT=3306
    case "$DB_NAME" in -*) die "DATABASE_NAME must not start with '-'" 2 ;; esac
    SQL_FILE="$EXPORT_DIR/$OUTPUT_NAME.sql"
    ERROR_FILE="$EXPORT_DIR/$OUTPUT_NAME.client.log"
    has_cmd mkfifo || die "mkfifo is required for protected MySQL client input" 5
    SECRET_PIPE="$RUN_DIR/details/internal/.mysql-client-$$.cnf"
    rm -f "$SECRET_PIPE"
    mkfifo -m 600 "$SECRET_PIPE" || die "Cannot create protected MySQL input channel" 5
    trap 'rm -f "$SECRET_PIPE"' 0 1 2 15
    { printf '[client]\npassword=%s\n' "$DB_PASSWORD" > "$SECRET_PIPE"; } &
    SECRET_WRITER_PID=$!
    DB_PASSWORD=
    if mysqldump \
      --defaults-extra-file="$SECRET_PIPE" \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user="$DB_USER" \
      --single-transaction \
      --routines \
      --events \
      --triggers \
      --databases "$DB_NAME" \
      > "$SQL_FILE" 2> "$ERROR_FILE"; then
      wait "$SECRET_WRITER_PID" 2>/dev/null || true
      rm -f "$SECRET_PIPE"
      trap - 0 1 2 15
      append_audit database_export "mysql:$DB_HOST:$DB_PORT/$DB_NAME" "$SQL_FILE" success "schema and data exported"
      printf '%s\n' "$SQL_FILE"
    else
      kill "$SECRET_WRITER_PID" 2>/dev/null || true
      wait "$SECRET_WRITER_PID" 2>/dev/null || true
      rm -f "$SECRET_PIPE"
      trap - 0 1 2 15
      rm -f "$SQL_FILE"
      append_audit database_export "mysql:$DB_HOST:$DB_PORT/$DB_NAME" "$ERROR_FILE" failed "mysqldump failed"
      die "MySQL export failed; see the client log in database-export details" 6
    fi
    ;;
  oracle)
    has_cmd expdp || {
      append_audit database_export oracle '' failed "expdp unavailable"
      die "expdp is unavailable; dependencies are not installed automatically" 5
    }
    [ -n "$DB_PORT" ] || DB_PORT=1521
    ORACLE_SCHEMAS=$(config_get DATABASE_ORACLE_SCHEMAS "$CONFIG" "$DB_USER")
    ORACLE_DIRECTORY=$(config_get DATABASE_ORACLE_DIRECTORY "$CONFIG" '')
    LOCAL_DUMP_PATH=$(config_get DATABASE_ORACLE_LOCAL_DUMP_PATH "$CONFIG" '')
    [ -n "$ORACLE_DIRECTORY" ] || die "DATABASE_ORACLE_DIRECTORY is required for Oracle Data Pump" 2
    CONNECT="//$DB_HOST:$DB_PORT/$DB_NAME"
    SERVER_DUMP="$OUTPUT_NAME.dmp"
    SERVER_LOG="$OUTPUT_NAME.log"
    CLIENT_LOG="$EXPORT_DIR/$OUTPUT_NAME.client.log"
    if printf '%s\n' "$DB_PASSWORD" | expdp \
      "$DB_USER@$CONNECT" \
      "SCHEMAS=$ORACLE_SCHEMAS" \
      "DIRECTORY=$ORACLE_DIRECTORY" \
      "DUMPFILE=$SERVER_DUMP" \
      "LOGFILE=$SERVER_LOG" \
      "CONTENT=ALL" \
      > "$CLIENT_LOG" 2>&1; then
      DB_PASSWORD=
      {
        printf 'type\thost\tservice\tschemas\tdirectory\tdumpfile\tlogfile\tcontent\n'
        printf 'oracle\t%s\t%s\t%s\t%s\t%s\t%s\tALL\n' \
          "$DB_HOST" "$DB_NAME" "$ORACLE_SCHEMAS" "$ORACLE_DIRECTORY" "$SERVER_DUMP" "$SERVER_LOG"
      } > "$EXPORT_DIR/$OUTPUT_NAME.location.tsv"
      if [ -n "$LOCAL_DUMP_PATH" ] && [ -r "$LOCAL_DUMP_PATH" ]; then
        cp "$LOCAL_DUMP_PATH" "$EXPORT_DIR/$SERVER_DUMP" || die "Cannot copy Oracle dump from configured local path" 6
      fi
      append_audit database_export "oracle:$DB_HOST:$DB_PORT/$DB_NAME" "$EXPORT_DIR/$OUTPUT_NAME.location.tsv" success "schema and data exported by Data Pump"
      printf '%s\n' "$EXPORT_DIR/$OUTPUT_NAME.location.tsv"
    else
      DB_PASSWORD=
      append_audit database_export "oracle:$DB_HOST:$DB_PORT/$DB_NAME" "$CLIENT_LOG" failed "expdp failed"
      die "Oracle export failed; see the client log in database-export details" 6
    fi
    ;;
  *)
    DB_PASSWORD=
    append_audit database_export "$DB_TYPE" '' skipped "database type not supported"
    die "Only mysql and oracle exports are supported" 2
    ;;
esac
