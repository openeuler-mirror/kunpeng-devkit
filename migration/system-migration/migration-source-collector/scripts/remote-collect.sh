#!/bin/sh
set -u
umask 077

usage() {
  cat <<'EOF'
Usage:
  sh scripts/remote-collect.sh recommend
  sh scripts/remote-collect.sh list --hosts <remote-hosts.conf>
  sh scripts/remote-collect.sh credential-preflight [--hosts <file> (--host <id> | --credential <id>)] [--password-stdin]
  sh scripts/remote-collect.sh credential-set --hosts <file> --credential <id> [--password-stdin]
  sh scripts/remote-collect.sh collect --hosts <file> [--host <id>] --source-config <file> --local-output <absolute-dir> [--password-stdin]
  sh scripts/remote-collect.sh supplement --hosts <file> --run-dir <local-run-dir> --plan <plan.tsv> [--password-stdin]
  sh scripts/remote-collect.sh sync --hosts <file> --run-dir <local-run-dir> [--password-stdin]
  sh scripts/remote-collect.sh cleanup --hosts <file> --run-dir <local-run-dir> [--password-stdin]
  sh scripts/remote-collect.sh import --source-run-dir <readable-run-dir> --local-output <absolute-dir>
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
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

interactive_terminal_available() {
  (
    exec 3</dev/tty 4>/dev/tty
    [ -t 3 ] && [ -t 4 ]
  ) 2>/dev/null
}

system_name() {
  uname -s 2>/dev/null || printf 'unknown'
}

setup_credential_provider() {
  if [ "$(system_name)" = Darwin ] && has_cmd security; then
    printf 'macos-keychain'
  elif has_cmd gpg; then
    printf 'gpg'
  else
    printf 'none'
  fi
}

password_transport() {
  if [ "$(system_name)" = Darwin ] && has_cmd security; then
    if [ -x "$SCRIPT_DIR/credential-askpass.sh" ]; then
      printf 'openssh-askpass'
    else
      printf 'none'
    fi
  elif has_cmd sshpass; then
    printf 'sshpass-fd'
  else
    printf 'none'
  fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" 2>/dev/null && pwd)

safe_id() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_address() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_user() {
  case "$1" in
    ''|[0-9]*|*[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

safe_absolute_remote_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
    *) return 0 ;;
  esac
}

remove_local_managed_path() {
  managed_path=$1
  managed_root=$2
  case "$managed_path" in
    "$managed_root"/.migration-source-collector-*.sync.*|\
    "$managed_root"/.migration-source-collector-*.import.*|\
    "$managed_root"/.migration-source-collector-*.previous.*)
      rm -rf "$managed_path"
      ;;
    *)
      die "Refusing to remove unmanaged local path: $managed_path" 5
      ;;
  esac
}

cleanup_local_managed_temps() {
  managed_root=$1
  for managed_path in \
    "$managed_root"/.migration-source-collector-*.sync.* \
    "$managed_root"/.migration-source-collector-*.import.* \
    "$managed_root"/.migration-source-collector-*.previous.*; do
    [ -e "$managed_path" ] || continue
    managed_pid=${managed_path##*.}
    case "$managed_pid" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$managed_pid" 2>/dev/null && continue ;;
    esac
    remove_local_managed_path "$managed_path" "$managed_root"
  done
}

global_get() {
  global_key=$1
  global_file=$2
  global_default=${3-}
  global_value=$(awk -v key="$global_key" '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      pos=index(line, "=")
      if (pos == 0) next
      name=substr(line, 1, pos-1)
      gsub(/[[:space:]]/, "", name)
      if (name == key) {
        value=substr(line, pos+1)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        print value
        exit
      }
    }
  ' "$global_file" 2>/dev/null || true)
  [ -n "$global_value" ] && printf '%s' "$global_value" || printf '%s' "$global_default"
}

prepare_work_dir() {
  WORK_DIR=$(global_get WORK_DIR "$HOSTS_FILE" '')
  [ -n "$WORK_DIR" ] || die "WORK_DIR must be configured as an absolute Agent-side directory" 2
  case "$WORK_DIR" in
    /|*/../*|*/..|*/./*|*/.) die "Invalid WORK_DIR" 2 ;;
    /*) ;;
    *) die "WORK_DIR must be an absolute Agent-side directory" 2 ;;
  esac
  WORK_DIR=${WORK_DIR%/}
  mkdir -p "$WORK_DIR/work" "$WORK_DIR/logs" "$WORK_DIR/credentials" "$WORK_DIR/runs" ||
    die "Cannot create Agent-side work directories" 3
  chmod 700 "$WORK_DIR/credentials" 2>/dev/null || die "Cannot protect credential store" 3
  case "$HOSTS_FILE" in
    */../*|*/..|*/./*|*/.) die "Invalid remote hosts file path" 2 ;;
  esac
  case "$HOSTS_FILE" in
    "$WORK_DIR"/work/*) ;;
    *) die "Remote hosts file must be stored under WORK_DIR/work" 2 ;;
  esac
}

require_work_path() {
  work_path=$1
  work_subdir=$2
  work_label=$3
  case "$work_path" in
    */../*|*/..|*/./*|*/.) die "Invalid $work_label path" 2 ;;
  esac
  case "$work_path" in
    "$WORK_DIR"/"$work_subdir"|"$WORK_DIR"/"$work_subdir"/*) ;;
    *) die "$work_label must be stored under WORK_DIR/$work_subdir" 2 ;;
  esac
}

prepare_work_dir_from_output() {
  case "$LOCAL_OUTPUT" in
    */../*|*/..|*/./*|*/.) die "Invalid --local-output path" 2 ;;
  esac
  case "$LOCAL_OUTPUT" in
    /*/runs) WORK_DIR=${LOCAL_OUTPUT%/runs} ;;
    *) die "--local-output must be WORK_DIR/runs" 2 ;;
  esac
  [ -n "$WORK_DIR" ] && [ "$WORK_DIR" != / ] || die "Invalid WORK_DIR" 2
  mkdir -p "$WORK_DIR/work" "$WORK_DIR/logs" "$WORK_DIR/credentials" "$WORK_DIR/runs" ||
    die "Cannot create Agent-side work directories" 3
  chmod 700 "$WORK_DIR/credentials" 2>/dev/null || die "Cannot protect credential store" 3
}

host_get() {
  selected_host=$1
  selected_key=$2
  selected_file=$3
  selected_default=${4-}
  selected_value=$(awk -v section="$selected_host" -v key="$selected_key" '
    /^[[:space:]]*\[/ {
      current=$0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*$/, "", current)
      active=(current == section)
      next
    }
    !active || /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/^[[:space:]]*/, "", line)
      pos=index(line, "=")
      if (pos == 0) next
      name=substr(line, 1, pos-1)
      gsub(/[[:space:]]/, "", name)
      if (name == key) {
        value=substr(line, pos+1)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        print value
        exit
      }
    }
  ' "$selected_file" 2>/dev/null || true)
  [ -n "$selected_value" ] && printf '%s' "$selected_value" || printf '%s' "$selected_default"
}

host_ids() {
  sed -n 's/^[[:space:]]*\[\([A-Za-z0-9_.-][A-Za-z0-9_.-]*\)\][[:space:]]*$/\1/p' "$1"
}

require_hosts_file() {
  [ -r "$HOSTS_FILE" ] || die "Remote hosts file is required and must be readable" 2
  if awk '
    /^[[:space:]]*#/ { next }
    {
      line=tolower($0)
      if (line ~ /^[[:space:]]*[a-z0-9_.-]*(password|passwd)[[:space:]]*=/) exit 1
    }
  ' "$HOSTS_FILE"; then
    :
  else
    die "Plaintext password fields are forbidden in the remote hosts file" 2
  fi
  prepare_work_dir
}

list_hosts() {
  require_hosts_file
  printf 'number\thost_id\taddress\tuser\tauth\tport\n'
  list_number=0
  for list_id in $(host_ids "$HOSTS_FILE"); do
    list_number=$((list_number + 1))
    list_address=$(host_get "$list_id" address "$HOSTS_FILE" '')
    list_user=$(host_get "$list_id" user "$HOSTS_FILE" root)
    list_auth=$(host_get "$list_id" auth "$HOSTS_FILE" key)
    list_port=$(host_get "$list_id" port "$HOSTS_FILE" 22)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$list_number" "$list_id" "$list_address" "$list_user" "$list_auth" "$list_port"
  done
}

select_host() {
  if [ -n "$HOST_ID" ]; then
    return
  fi
  [ -t 0 ] || die "--host is required for non-interactive collection" 2
  list_hosts >&2
  host_count=$(host_ids "$HOSTS_FILE" | wc -l | tr -d ' ')
  [ "$host_count" -gt 0 ] || die "No hosts are defined" 2
  printf '请选择要扫描的机器编号: ' >/dev/tty
  IFS= read -r host_choice </dev/tty || die "Host selection cancelled" 2
  case "$host_choice" in ''|*[!0-9]*) die "Host selection must be a number" 2 ;; esac
  HOST_ID=$(host_ids "$HOSTS_FILE" | sed -n "${host_choice}p")
  [ -n "$HOST_ID" ] || die "Host selection is out of range" 2
}

load_host() {
  require_hosts_file
  safe_id "$HOST_ID" || die "Invalid host id" 2
  host_ids "$HOSTS_FILE" | grep -Fxq "$HOST_ID" || die "Host id is not defined: $HOST_ID" 2

  REMOTE_ADDRESS=$(host_get "$HOST_ID" address "$HOSTS_FILE" '')
  REMOTE_PORT=$(host_get "$HOST_ID" port "$HOSTS_FILE" 22)
  REMOTE_USER=$(host_get "$HOST_ID" user "$HOSTS_FILE" root)
  REMOTE_AUTH=$(host_get "$HOST_ID" auth "$HOSTS_FILE" key)
  IDENTITY_FILE=$(host_get "$HOST_ID" identity_file "$HOSTS_FILE" '')
  CREDENTIAL_ID=$(host_get "$HOST_ID" credential_id "$HOSTS_FILE" '')
  REMOTE_PRIVILEGE=$(host_get "$HOST_ID" privilege "$HOSTS_FILE" direct)
  REMOTE_STAGING_ROOT=$(host_get "$HOST_ID" remote_staging_root "$HOSTS_FILE" /opt/kunpeng-migration/collection/remote)
  CREDENTIAL_STORE=$(global_get CREDENTIAL_STORE "$HOSTS_FILE" '')
  CREDENTIAL_GPG_RECIPIENT=$(global_get CREDENTIAL_GPG_RECIPIENT "$HOSTS_FILE" '')

  safe_address "$REMOTE_ADDRESS" || die "Invalid address for $HOST_ID; use an IPv4 address or hostname" 2
  safe_user "$REMOTE_USER" || die "Invalid SSH user for $HOST_ID" 2
  case "$REMOTE_PORT" in ''|*[!0-9]*) die "Invalid SSH port for $HOST_ID" 2 ;; esac
  [ "$REMOTE_PORT" -ge 1 ] && [ "$REMOTE_PORT" -le 65535 ] || die "SSH port is out of range" 2
  case "$REMOTE_AUTH" in key|password) ;; *) die "auth must be key or password" 2 ;; esac
  case "$REMOTE_PRIVILEGE" in direct|sudo) ;; *) die "privilege must be direct or sudo" 2 ;; esac
  safe_absolute_remote_path "$REMOTE_STAGING_ROOT" || die "Invalid remote_staging_root" 2
  [ "$REMOTE_STAGING_ROOT" != / ] || die "remote_staging_root must not be /" 2
  if [ -n "$IDENTITY_FILE" ]; then
    case "$IDENTITY_FILE" in /*) ;; *) die "identity_file must be an absolute local path" 2 ;; esac
    [ -r "$IDENTITY_FILE" ] || die "identity_file is not readable" 2
  fi
}

credential_file() {
  credential_suffix=$1
  printf '%s/%s.%s' "$CREDENTIAL_STORE" "$CREDENTIAL_ID" "$credential_suffix"
}

check_store_permissions() {
  [ -n "$CREDENTIAL_STORE" ] || die "CREDENTIAL_STORE must be configured as an absolute path" 2
  case "$CREDENTIAL_STORE" in /*) ;; *) die "CREDENTIAL_STORE must be an absolute path" 2 ;; esac
  require_work_path "$CREDENTIAL_STORE" credentials CREDENTIAL_STORE
  [ -d "$CREDENTIAL_STORE" ] || mkdir -p "$CREDENTIAL_STORE" || die "Cannot create credential store" 3
  chmod 700 "$CREDENTIAL_STORE" 2>/dev/null || die "Cannot protect credential store" 3
}

read_secret() {
  secret_prompt=$1
  interactive_terminal_available ||
    die "Secure password input requires a real interactive terminal. Run credential-set in an interactive terminal, or use key authentication." 3
  old_tty=$(stty -g </dev/tty 2>/dev/null) ||
    die "Cannot read terminal settings for secure password input" 3
  trap 'stty "$old_tty" </dev/tty 2>/dev/null || true' 0 1 2 15
  printf '%s' "$secret_prompt" >/dev/tty
  stty -echo </dev/tty 2>/dev/null ||
    die "Cannot disable terminal echo for secure password input" 3
  IFS= read -r secret_value </dev/tty || secret_value=
  stty "$old_tty" </dev/tty 2>/dev/null || true
  trap - 0 1 2 15
  printf '\n' >/dev/tty
  printf '%s' "$secret_value"
}

add_missing_requirement() {
  if [ -n "$MISSING_REQUIREMENTS" ]; then
    MISSING_REQUIREMENTS="$MISSING_REQUIREMENTS,$1"
  else
    MISSING_REQUIREMENTS=$1
  fi
}

credential_preflight() {
  PREFLIGHT_PLATFORM=$(system_name)
  PREFLIGHT_AUTH=password
  PREFLIGHT_PROVIDER=$(setup_credential_provider)
  PREFLIGHT_TRANSPORT=$(password_transport)
  PREFLIGHT_STATE=not-checked
  PREFLIGHT_STORED_PROVIDER=none
  PREFLIGHT_TERMINAL=false
  interactive_terminal_available && PREFLIGHT_TERMINAL=true

  if [ -n "$HOST_ID" ]; then
    [ -n "$HOSTS_FILE" ] ||
      die "--hosts is required when --host is used for credential-preflight" 2
    load_host
    PREFLIGHT_AUTH=$REMOTE_AUTH
  elif [ -n "$HOSTS_FILE" ]; then
    require_hosts_file
    CREDENTIAL_STORE=$(global_get CREDENTIAL_STORE "$HOSTS_FILE" '')
    CREDENTIAL_GPG_RECIPIENT=$(global_get CREDENTIAL_GPG_RECIPIENT "$HOSTS_FILE" '')
  fi

  if [ "$PREFLIGHT_AUTH" = key ]; then
    MISSING_REQUIREMENTS=
    has_cmd ssh || add_missing_requirement ssh
    has_cmd scp || add_missing_requirement scp
    if [ -n "$MISSING_REQUIREMENTS" ]; then
      PREFLIGHT_COLLECTION_READY=false
      PREFLIGHT_ACTION=install-openssh-client
    else
      PREFLIGHT_COLLECTION_READY=true
      PREFLIGHT_ACTION=run-collect
    fi
    printf '%s\n' \
      "platform=$PREFLIGHT_PLATFORM" \
      "configured_auth=key" \
      "terminal_available=$PREFLIGHT_TERMINAL" \
      "setup_provider=not-required" \
      "password_transport=not-required" \
      "credential_state=not-required" \
      "credential_provider=not-required" \
      "setup_ready=true" \
      "setup_missing_requirements=none" \
      "collection_ready=$PREFLIGHT_COLLECTION_READY" \
      "collection_missing_requirements=${MISSING_REQUIREMENTS:-none}" \
      "next_action=$PREFLIGHT_ACTION"
    return
  fi

  if [ -n "$CREDENTIAL_ID" ]; then
    safe_id "$CREDENTIAL_ID" || die "Invalid credential id" 2
    if [ "$PREFLIGHT_PLATFORM" = Darwin ] && has_cmd security; then
      if security find-generic-password \
        -a "$CREDENTIAL_ID" \
        -s migration-source-collector >/dev/null 2>&1; then
        PREFLIGHT_STATE=present
        PREFLIGHT_STORED_PROVIDER=macos-keychain
      else
        PREFLIGHT_STATE=missing
      fi
    elif [ -n "${CREDENTIAL_STORE:-}" ]; then
      case "$CREDENTIAL_STORE" in
        /*) ;;
        *) PREFLIGHT_STATE=invalid-store ;;
      esac
      if [ "$PREFLIGHT_STATE" != invalid-store ]; then
        if [ -r "$CREDENTIAL_STORE/$CREDENTIAL_ID.age" ]; then
          PREFLIGHT_STATE=present
          PREFLIGHT_STORED_PROVIDER=age
        elif [ -r "$CREDENTIAL_STORE/$CREDENTIAL_ID.gpg" ]; then
          PREFLIGHT_STATE=present
          PREFLIGHT_STORED_PROVIDER=gpg
        else
          PREFLIGHT_STATE=missing
        fi
      fi
    elif [ -n "$HOSTS_FILE" ]; then
      PREFLIGHT_STATE=invalid-store
    fi
  fi

  MISSING_REQUIREMENTS=
  has_cmd ssh || add_missing_requirement ssh
  has_cmd scp || add_missing_requirement scp
  [ "$PREFLIGHT_PROVIDER" != none ] || add_missing_requirement credential-encryption-provider
  [ "$PREFLIGHT_TRANSPORT" != none ] || add_missing_requirement sshpass
  [ "$PREFLIGHT_STATE" != invalid-store ] || add_missing_requirement credential-store
  if [ "$PREFLIGHT_PLATFORM" != Darwin ]; then
    [ -n "${CREDENTIAL_GPG_RECIPIENT:-}" ] || add_missing_requirement gpg-recipient
    if [ -n "${CREDENTIAL_GPG_RECIPIENT:-}" ]; then
      gpg --batch --list-keys "$CREDENTIAL_GPG_RECIPIENT" >/dev/null 2>&1 || add_missing_requirement gpg-public-key
      gpg --batch --list-secret-keys "$CREDENTIAL_GPG_RECIPIENT" >/dev/null 2>&1 || add_missing_requirement gpg-secret-key
    fi
  fi
  if [ -z "$MISSING_REQUIREMENTS" ]; then
    PREFLIGHT_SETUP_READY=true
  else
    PREFLIGHT_SETUP_READY=false
  fi
  PREFLIGHT_SETUP_MISSING=${MISSING_REQUIREMENTS:-none}

  MISSING_REQUIREMENTS=
  has_cmd ssh || add_missing_requirement ssh
  has_cmd scp || add_missing_requirement scp
  case "$PREFLIGHT_STATE:$PREFLIGHT_STORED_PROVIDER" in
    present:macos-keychain)
      has_cmd security || add_missing_requirement security
      [ -x "$SCRIPT_DIR/credential-askpass.sh" ] || add_missing_requirement credential-askpass
      ;;
    present:age)
      has_cmd age || add_missing_requirement age
      has_cmd sshpass || add_missing_requirement sshpass
      [ "$PREFLIGHT_TERMINAL" = true ] ||
        add_missing_requirement interactive-terminal-for-decryption
      ;;
    present:gpg)
      has_cmd gpg || add_missing_requirement gpg
      has_cmd sshpass || add_missing_requirement sshpass
      ;;
    *)
      add_missing_requirement saved-credential
      ;;
  esac
  if [ -z "$MISSING_REQUIREMENTS" ]; then
    PREFLIGHT_COLLECTION_READY=true
    PREFLIGHT_ACTION=run-collect
  else
    PREFLIGHT_COLLECTION_READY=false
    if [ "$PREFLIGHT_STATE" = missing ] && [ "$PREFLIGHT_SETUP_READY" = true ]; then
      PREFLIGHT_ACTION=call-question-tool-for-password-and-run-credential-set-with-password-stdin
    elif [ "$PREFLIGHT_TRANSPORT" = none ]; then
      PREFLIGHT_ACTION=install-sshpass-or-use-key
    elif [ "$PREFLIGHT_PROVIDER" = none ]; then
      PREFLIGHT_ACTION=install-gpg-or-use-key
    else
      PREFLIGHT_ACTION=fix-missing-requirements-or-use-key
    fi
  fi
  PREFLIGHT_COLLECTION_MISSING=${MISSING_REQUIREMENTS:-none}

  printf '%s\n' \
    "platform=$PREFLIGHT_PLATFORM" \
    "configured_auth=password" \
    "terminal_available=$PREFLIGHT_TERMINAL" \
    "setup_provider=$PREFLIGHT_PROVIDER" \
    "password_transport=$PREFLIGHT_TRANSPORT" \
    "credential_state=$PREFLIGHT_STATE" \
    "credential_provider=$PREFLIGHT_STORED_PROVIDER" \
    "setup_ready=$PREFLIGHT_SETUP_READY" \
    "setup_missing_requirements=$PREFLIGHT_SETUP_MISSING" \
    "collection_ready=$PREFLIGHT_COLLECTION_READY" \
    "collection_missing_requirements=$PREFLIGHT_COLLECTION_MISSING" \
    "next_action=$PREFLIGHT_ACTION"
}

set_credential() {
  require_hosts_file
  safe_id "$CREDENTIAL_ID" || die "Invalid credential id" 2
  if [ "$FRONTEND_PASSWORD_STDIN" != true ]; then
    interactive_terminal_available ||
      die "Credential setup requires an interactive terminal or --password-stdin." 3
  fi
  has_cmd ssh || die "ssh is required before password credential setup" 3
  has_cmd scp || die "scp is required before password credential setup" 3
  if [ "$(system_name)" = Darwin ]; then
    has_cmd security || die "macOS Keychain command 'security' is required; use key authentication if unavailable" 3
    [ -x "$SCRIPT_DIR/credential-askpass.sh" ] ||
      die "credential-askpass.sh must be executable" 3
    if [ "$FRONTEND_PASSWORD_STDIN" = true ]; then
      IFS= read -r first_password || die "No SSH password was received on standard input" 3
      [ -n "$first_password" ] || die "Password cannot be empty" 3
      security add-generic-password \
        -a "$CREDENTIAL_ID" \
        -s migration-source-collector \
        -U \
        -w "$first_password" || die "Cannot save credential to macOS Keychain" 3
      first_password=
    else
      security add-generic-password \
        -a "$CREDENTIAL_ID" \
        -s migration-source-collector \
        -U \
        -w || die "Cannot save credential to macOS Keychain" 3
    fi
    printf 'credential_id=%s\nprovider=macos-keychain\n' "$CREDENTIAL_ID"
    return
  fi
  has_cmd sshpass ||
    die "sshpass is required before GPG password credential setup. Install it outside this Skill or use key authentication." 3
  has_cmd gpg || die "gpg is required before password credential setup; use key authentication if unavailable" 3
  CREDENTIAL_STORE=$(global_get CREDENTIAL_STORE "$HOSTS_FILE" '')
  CREDENTIAL_GPG_RECIPIENT=$(global_get CREDENTIAL_GPG_RECIPIENT "$HOSTS_FILE" '')
  check_store_permissions
  [ -n "$CREDENTIAL_GPG_RECIPIENT" ] || die "CREDENTIAL_GPG_RECIPIENT must be configured" 2
  gpg --batch --list-keys "$CREDENTIAL_GPG_RECIPIENT" >/dev/null 2>&1 ||
    die "GPG public key not found: $CREDENTIAL_GPG_RECIPIENT" 3
  gpg --batch --list-secret-keys "$CREDENTIAL_GPG_RECIPIENT" >/dev/null 2>&1 ||
    die "GPG secret key not found: $CREDENTIAL_GPG_RECIPIENT" 3
  if [ "$FRONTEND_PASSWORD_STDIN" = true ]; then
    IFS= read -r first_password || die "No SSH password was received on standard input" 3
  else
    first_password=$(read_secret '请输入 SSH 密码（输入不会回显）: ') || exit $?
  fi
  [ -n "$first_password" ] || die "Password cannot be empty" 3

  temp_secret="$CREDENTIAL_STORE/.${CREDENTIAL_ID}.tmp.$$"
  trap 'rm -f "$temp_secret"' 0 1 2 15
  printf '%s' "$first_password" | gpg --batch --yes --trust-model always \
    --recipient "$CREDENTIAL_GPG_RECIPIENT" --encrypt --output "$temp_secret" ||
    die "GPG encryption failed" 3
  final_secret=$(credential_file gpg)
  provider=gpg
  chmod 600 "$temp_secret" || die "Cannot protect encrypted credential" 3
  mv "$temp_secret" "$final_secret" || die "Cannot save encrypted credential" 3
  trap - 0 1 2 15
  first_password=
  printf 'credential_id=%s\nprovider=%s\nfile=%s\n' "$CREDENTIAL_ID" "$provider" "$final_secret"
}

load_password() {
  safe_id "$CREDENTIAL_ID" || die "credential_id is required for password authentication" 2
  check_store_permissions
  age_file=$(credential_file age)
  gpg_file=$(credential_file gpg)
  if [ -r "$age_file" ]; then
    has_cmd age || die "age is required to decrypt $age_file" 3
    AUTH_PASSWORD=$(age -d "$age_file") || die "Cannot decrypt credential: $CREDENTIAL_ID" 3
  elif [ -r "$gpg_file" ]; then
    has_cmd gpg || die "gpg is required to decrypt $gpg_file" 3
    AUTH_PASSWORD=$(gpg --batch --quiet --decrypt "$gpg_file") || die "Cannot decrypt credential: $CREDENTIAL_ID" 3
  else
    die "Encrypted credential not found: $CREDENTIAL_ID" 3
  fi
  [ -n "$AUTH_PASSWORD" ] || die "Decrypted credential is empty" 3
}

prepare_auth() {
  has_cmd ssh || die "ssh is required" 3
  has_cmd scp || die "scp is required" 3
  AUTH_PASSWORD=
  AUTH_METHOD=key
  if [ "$REMOTE_AUTH" = password ]; then
    if [ "$FRONTEND_PASSWORD_STDIN" = true ]; then
      has_cmd sshpass ||
        die "sshpass is required for transient front-end password authentication; install it outside this Skill or use key authentication" 3
      IFS= read -r AUTH_PASSWORD ||
        die "No SSH password was received on standard input" 3
      [ -n "$AUTH_PASSWORD" ] || die "SSH password cannot be empty" 3
      AUTH_METHOD=sshpass
      return
    fi
    safe_id "$CREDENTIAL_ID" ||
      die "credential_id is required for password authentication. Configure it and run credential-set --password-stdin, or use key authentication." 2
    if [ "$(system_name)" = Darwin ]; then
      has_cmd security ||
        die "macOS Keychain command 'security' is required; run credential-preflight or use key authentication" 3
      [ -x "$SCRIPT_DIR/credential-askpass.sh" ] || die "credential-askpass.sh must be executable" 3
      security find-generic-password \
        -a "$CREDENTIAL_ID" \
        -s migration-source-collector >/dev/null 2>&1 ||
        die "macOS Keychain credential not found: $CREDENTIAL_ID. Run credential-set --password-stdin, or use key authentication." 3
      AUTH_METHOD=macos-keychain
    else
      has_cmd sshpass ||
        die "sshpass is required for encrypted password authentication. Run credential-preflight before collection or use key authentication." 3
      load_password
      AUTH_METHOD=sshpass
    fi
  fi
}

run_ssh() {
  remote_command=$1
  if [ "$AUTH_METHOD" = macos-keychain ]; then
    MIGRATION_CREDENTIAL_PROVIDER=macos-keychain \
    MIGRATION_CREDENTIAL_ID="$CREDENTIAL_ID" \
    SSH_ASKPASS="$SCRIPT_DIR/credential-askpass.sh" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=migration-source-collector \
    ssh \
      -p "$REMOTE_PORT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "$REMOTE_USER@$REMOTE_ADDRESS" "$remote_command"
  elif [ "$AUTH_METHOD" = sshpass ]; then
    printf '%s\n' "$AUTH_PASSWORD" | sshpass -d 0 ssh \
      -p "$REMOTE_PORT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$REMOTE_USER@$REMOTE_ADDRESS" "$remote_command"
  elif [ -n "$IDENTITY_FILE" ]; then
    ssh -p "$REMOTE_PORT" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -i "$IDENTITY_FILE" \
      "$REMOTE_USER@$REMOTE_ADDRESS" "$remote_command"
  else
    ssh -p "$REMOTE_PORT" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      "$REMOTE_USER@$REMOTE_ADDRESS" "$remote_command"
  fi
}

run_scp() {
  local_source=$1
  remote_target=$2
  if [ "$AUTH_METHOD" = macos-keychain ]; then
    MIGRATION_CREDENTIAL_PROVIDER=macos-keychain \
    MIGRATION_CREDENTIAL_ID="$CREDENTIAL_ID" \
    SSH_ASKPASS="$SCRIPT_DIR/credential-askpass.sh" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=migration-source-collector \
    scp \
      -P "$REMOTE_PORT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      "$local_source" "$REMOTE_USER@$REMOTE_ADDRESS:$remote_target"
  elif [ "$AUTH_METHOD" = sshpass ]; then
    printf '%s\n' "$AUTH_PASSWORD" | sshpass -d 0 scp \
      -P "$REMOTE_PORT" \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no \
      "$local_source" "$REMOTE_USER@$REMOTE_ADDRESS:$remote_target"
  elif [ -n "$IDENTITY_FILE" ]; then
    scp -P "$REMOTE_PORT" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -i "$IDENTITY_FILE" \
      "$local_source" "$REMOTE_USER@$REMOTE_ADDRESS:$remote_target"
  else
    scp -P "$REMOTE_PORT" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      "$local_source" "$REMOTE_USER@$REMOTE_ADDRESS:$remote_target"
  fi
}

privilege_prefix() {
  if [ "$REMOTE_PRIVILEGE" = sudo ]; then
    printf 'sudo -n '
  else
    printf ''
  fi
}

preflight_remote() {
  preflight=$(run_ssh 'printf "os=%s\narch=%s\nuid=%s\n" "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)" "$(id -u 2>/dev/null)"') || die "SSH preflight failed" 4
  remote_os=$(printf '%s\n' "$preflight" | awk -F= '$1=="os" {print $2; exit}')
  REMOTE_SOURCE_ARCHITECTURE=$(printf '%s\n' "$preflight" | awk -F= '$1=="arch" {print $2; exit}')
  remote_uid=$(printf '%s\n' "$preflight" | awk -F= '$1=="uid" {print $2; exit}')
  [ "$remote_os" = Linux ] || die "Remote source host must be Linux" 4
  if [ "$remote_uid" != 0 ] && ! run_ssh 'command -v sudo >/dev/null 2>&1 && sudo -n true' >/dev/null; then
    warn "Remote collection user $REMOTE_USER is not root and has no passwordless sudo permission"
    die "Remote collection requires root or passwordless sudo permission" 4
  fi
  if [ "$REMOTE_PRIVILEGE" = direct ]; then
    [ "$remote_uid" = 0 ] || die "Direct collection requires remote root; configure privilege=sudo for a non-root user" 4
  else
    run_ssh 'sudo -n true' >/dev/null || die "Passwordless sudo -n is required" 4
  fi
}

write_remote_state() {
  local_run=$1
  remote_run=$2
  remote_stage=$3
  local_output=$4
  state_file="$local_run/details/internal/remote-session.env"
  [ -d "$local_run/details/internal" ] || mkdir -p "$local_run/details/internal" || die "Cannot create local remote session state" 5
  {
    printf 'OUTPUT_DIR=%s\n' "$local_output"
    printf 'COLLECTION_MODE=remote\n'
    printf 'CONTROL_HOST_ARCHITECTURE=%s\n' "$(uname -m 2>/dev/null || echo unknown)"
    printf 'REMOTE_HOST_ID=%s\n' "$HOST_ID"
    printf 'REMOTE_ADDRESS=%s\n' "$REMOTE_ADDRESS"
    printf 'REMOTE_PORT=%s\n' "$REMOTE_PORT"
    printf 'REMOTE_USER=%s\n' "$REMOTE_USER"
    printf 'REMOTE_AUTH=%s\n' "$REMOTE_AUTH"
    printf 'REMOTE_PRIVILEGE=%s\n' "$REMOTE_PRIVILEGE"
    printf 'REMOTE_SOURCE_ARCHITECTURE=%s\n' "$REMOTE_SOURCE_ARCHITECTURE"
    printf 'REMOTE_TRANSPORT=ssh\n'
    printf 'REMOTE_RUN_DIR=%s\n' "$remote_run"
    printf 'REMOTE_STAGING_DIR=%s\n' "$remote_stage"
  } > "$state_file" || die "Cannot write local remote session state" 5
  chmod 600 "$state_file" 2>/dev/null || true
}

state_get() {
  state_key=$1
  state_file=$2
  state_default=${3-}
  state_value=$(awk -F= -v key="$state_key" '$1==key {sub(/^[^=]*=/, ""); print; exit}' "$state_file" 2>/dev/null || true)
  [ -n "$state_value" ] && printf '%s' "$state_value" || printf '%s' "$state_default"
}

sync_remote_run() {
  sync_remote_run=$1
  sync_local_output=$2
  safe_absolute_remote_path "$sync_remote_run" || die "Invalid remote run directory in session" 5
  case "$sync_local_output" in /*) ;; *) die "Agent local output directory must be absolute" 5 ;; esac
  [ -d "$sync_local_output" ] || mkdir -p "$sync_local_output" || die "Cannot create local output directory" 5
  cleanup_local_managed_temps "$sync_local_output"
  sync_run_name=${sync_remote_run##*/}
  safe_id "$sync_run_name" || die "Invalid remote run directory name" 5
  case "$sync_run_name" in migration-source-collector-*) ;; *) die "Unexpected remote run directory name" 5 ;; esac
  sync_local_run="$sync_local_output/$sync_run_name"
  sync_temp_root="$sync_local_output/.${sync_run_name}.sync.$$"
  sync_temp_run="$sync_temp_root/$sync_run_name"
  sync_archive="$sync_temp_root/$sync_run_name.tar.gz"
  sync_backup="$sync_local_output/.${sync_run_name}.previous.$$"
  [ ! -e "$sync_temp_root" ] || remove_local_managed_path "$sync_temp_root" "$sync_local_output"
  mkdir -p "$sync_temp_root" || die "Cannot create temporary sync directory" 5
  prefix=$(privilege_prefix)
  sync_parent=${sync_remote_run%/*}
  remote_sha256=$(run_ssh "${prefix}tar -czf - -C $sync_parent $sync_run_name | if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print \$1}'; elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print \$NF}'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print \$1}'; else exit 127; fi") || {
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Cannot calculate remote result SHA-256" 5
  }
  if ! run_ssh "${prefix}tar -czf - -C $sync_parent $sync_run_name" > "$sync_archive"; then
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Remote result transfer failed" 5
  fi
  local_sha256=$(hash_file "$sync_archive")
  if [ -z "$local_sha256" ] || [ "$remote_sha256" != "$local_sha256" ]; then
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Remote result SHA-256 verification failed" 5
  fi
  if ! tar -xzf "$sync_archive" -C "$sync_temp_root"; then
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Transferred result extraction failed" 5
  fi
  if [ ! -s "$sync_temp_run/details/internal/scan-results/summary.txt" ]; then
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Transferred result is incomplete" 5
  fi
  if [ -e "$sync_local_run" ]; then
    mv "$sync_local_run" "$sync_backup" || {
      remove_local_managed_path "$sync_temp_root" "$sync_local_output"
      die "Cannot prepare existing local result for replacement" 5
    }
  fi
  if mv "$sync_temp_run" "$sync_local_run"; then
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    [ ! -e "$sync_backup" ] || remove_local_managed_path "$sync_backup" "$sync_local_output"
    rm -f "$sync_local_output/$sync_run_name.tar.gz"
  else
    [ ! -e "$sync_backup" ] || mv "$sync_backup" "$sync_local_run" 2>/dev/null || true
    remove_local_managed_path "$sync_temp_root" "$sync_local_output"
    die "Cannot publish synchronized result" 5
  fi
  printf '%s' "$sync_local_run"
}

collect_remote() {
  [ -r "$SOURCE_CONFIG" ] || die "--source-config is required and must be readable" 2
  [ -n "$LOCAL_OUTPUT" ] || die "--local-output is required for remote collection" 2
  case "$LOCAL_OUTPUT" in /*) ;; *) die "--local-output must be an absolute Agent-side directory" 2 ;; esac
  select_host
  load_host
  require_work_path "$SOURCE_CONFIG" work "Source collector config"
  require_work_path "$LOCAL_OUTPUT" runs "Agent local output"
  prepare_auth
  has_cmd tar || die "tar is required on the control host" 3
  preflight_remote

  for required_script in collect.sh collect-artifacts.sh collect-versions.sh supplement.sh export-db.sh; do
    [ -r "$SCRIPT_DIR/$required_script" ] || die "Missing required script: $required_script" 3
  done
  local_arch=$(uname -m 2>/dev/null || echo unknown)
  REMOTE_STAGING_DIR="$REMOTE_STAGING_ROOT/$HOST_ID"
  safe_absolute_remote_path "$REMOTE_STAGING_DIR" || die "Invalid generated staging directory" 3
  temp_root="$WORK_DIR/work/.remote-collect.$HOST_ID.$$"
  [ ! -e "$temp_root" ] || die "Agent-side temporary directory already exists" 3
  mkdir -p "$temp_root" || die "Cannot create Agent-side temporary directory" 3
  trap 'rm -rf "$temp_root"' 0 1 2 15
  sed '/^[[:space:]]*\(WORK_DIR\|OUTPUT_DIR\|COLLECTION_MODE\|CONTROL_HOST_ARCHITECTURE\|REMOTE_HOST_ID\|SOURCE_HOST_IP\)[[:space:]]*=/d' \
    "$SOURCE_CONFIG" > "$temp_root/collector.env" || die "Cannot prepare remote collector config" 3
  {
    printf '\nWORK_DIR=%s\n' "$REMOTE_STAGING_DIR"
    printf 'OUTPUT_DIR=%s/runs\n' "$REMOTE_STAGING_DIR"
    printf 'COLLECTION_MODE=remote\n'
    printf 'CONTROL_HOST_ARCHITECTURE=%s\n' "$local_arch"
    printf 'REMOTE_HOST_ID=%s\n' "$HOST_ID"
    case "$REMOTE_ADDRESS" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf 'SOURCE_HOST_IP=%s\n' "$REMOTE_ADDRESS" ;;
    esac
  } >> "$temp_root/collector.env"
  if LC_ALL=C grep -Eiq '^[[:space:]]*(password|passwd|secret|token)[[:space:]]*=' "$temp_root/collector.env"; then
    die "Source collector config must not contain plaintext secrets" 3
  fi

  prefix=$(privilege_prefix)
  run_ssh "${prefix}rm -rf $REMOTE_STAGING_DIR && ${prefix}mkdir -p $REMOTE_STAGING_DIR/work $REMOTE_STAGING_DIR/logs $REMOTE_STAGING_DIR/runs && ${prefix}chown -R $REMOTE_USER $REMOTE_STAGING_DIR && chmod 700 $REMOTE_STAGING_DIR" >/dev/null || die "Cannot create remote staging directory" 4
  for upload_script in collect.sh collect-artifacts.sh collect-versions.sh supplement.sh export-db.sh; do
    run_scp "$SCRIPT_DIR/$upload_script" "$REMOTE_STAGING_DIR/work/$upload_script" >/dev/null || die "Cannot upload $upload_script" 4
  done
  run_scp "$temp_root/collector.env" "$REMOTE_STAGING_DIR/work/collector.env" >/dev/null || die "Cannot upload collector config" 4
  run_ssh "chmod 700 $REMOTE_STAGING_DIR/work/*.sh && chmod 600 $REMOTE_STAGING_DIR/work/collector.env" >/dev/null || die "Cannot protect remote staging files" 4
  collect_output=$(run_ssh "${prefix}sh $REMOTE_STAGING_DIR/work/collect.sh --config $REMOTE_STAGING_DIR/work/collector.env") || die "Remote collection failed" 5
  REMOTE_RUN_DIR=$(printf '%s\n' "$collect_output" | awk '/^\// {line=$0} END {print line}')
  safe_absolute_remote_path "$REMOTE_RUN_DIR" || die "Remote collector did not return a valid run directory" 5

  LOCAL_RUN_DIR=$(sync_remote_run "$REMOTE_RUN_DIR" "$LOCAL_OUTPUT") || exit $?
  write_remote_state "$LOCAL_RUN_DIR" "$REMOTE_RUN_DIR" "$REMOTE_STAGING_DIR" "$LOCAL_OUTPUT"
  AUTH_PASSWORD=
  trap - 0 1 2 15
  rm -rf "$temp_root"
  printf '%s\n' "$LOCAL_RUN_DIR"
}

load_session_host() {
  session_file="$RUN_DIR/details/internal/remote-session.env"
  [ -r "$session_file" ] || die "Remote session state is missing from the local run directory" 2
  HOST_ID=$(state_get REMOTE_HOST_ID "$session_file" '')
  [ -n "$HOST_ID" ] || die "REMOTE_HOST_ID is missing from session state" 2
  load_host
  session_address=$(state_get REMOTE_ADDRESS "$session_file" '')
  session_port=$(state_get REMOTE_PORT "$session_file" '')
  session_user=$(state_get REMOTE_USER "$session_file" '')
  [ "$session_address" = "$REMOTE_ADDRESS" ] && [ "$session_port" = "$REMOTE_PORT" ] && [ "$session_user" = "$REMOTE_USER" ] || die "Remote host configuration changed; verify before continuing" 2
  REMOTE_RUN_DIR=$(state_get REMOTE_RUN_DIR "$session_file" '')
  REMOTE_STAGING_DIR=$(state_get REMOTE_STAGING_DIR "$session_file" '')
  LOCAL_OUTPUT=$(state_get OUTPUT_DIR "$session_file" "$(dirname "$RUN_DIR")")
  safe_absolute_remote_path "$REMOTE_RUN_DIR" || die "Invalid REMOTE_RUN_DIR in session state" 2
  safe_absolute_remote_path "$REMOTE_STAGING_DIR" || die "Invalid REMOTE_STAGING_DIR in session state" 2
  prepare_auth
  preflight_remote
}

supplement_remote() {
  [ -d "$RUN_DIR" ] || die "--run-dir must be a local remote collection directory" 2
  [ -r "$PLAN_FILE" ] || die "--plan is required and must be readable" 2
  require_hosts_file
  require_work_path "$RUN_DIR" runs "Local run directory"
  require_work_path "$PLAN_FILE" work "Supplement plan"
  load_session_host
  run_scp "$PLAN_FILE" "$REMOTE_STAGING_DIR/work/supplement-plan.tsv" >/dev/null || die "Cannot upload supplement plan" 4
  prefix=$(privilege_prefix)
  run_ssh "${prefix}sh $REMOTE_STAGING_DIR/work/supplement.sh --config $REMOTE_STAGING_DIR/work/collector.env --run-dir $REMOTE_RUN_DIR --plan $REMOTE_STAGING_DIR/work/supplement-plan.tsv" >/dev/null || die "Remote supplemental collection failed" 5
  synced_run=$(sync_remote_run "$REMOTE_RUN_DIR" "$LOCAL_OUTPUT") || exit $?
  [ "$synced_run" = "$RUN_DIR" ] || die "Session local path does not match synchronized path" 5
  write_remote_state "$RUN_DIR" "$REMOTE_RUN_DIR" "$REMOTE_STAGING_DIR" "$LOCAL_OUTPUT"
  AUTH_PASSWORD=
  printf '%s\n' "$RUN_DIR"
}

sync_session() {
  [ -d "$RUN_DIR" ] || die "--run-dir must be a local remote collection directory" 2
  require_hosts_file
  require_work_path "$RUN_DIR" runs "Local run directory"
  load_session_host
  synced_run=$(sync_remote_run "$REMOTE_RUN_DIR" "$LOCAL_OUTPUT") || exit $?
  [ "$synced_run" = "$RUN_DIR" ] || die "Session local path does not match synchronized path" 5
  write_remote_state "$RUN_DIR" "$REMOTE_RUN_DIR" "$REMOTE_STAGING_DIR" "$LOCAL_OUTPUT"
  AUTH_PASSWORD=
  printf '%s\n' "$RUN_DIR"
}

cleanup_remote() {
  [ -d "$RUN_DIR" ] || die "--run-dir must be a local remote collection directory" 2
  require_hosts_file
  require_work_path "$RUN_DIR" runs "Local run directory"
  load_session_host
  [ "$REMOTE_STAGING_DIR" = "$REMOTE_STAGING_ROOT/$HOST_ID" ] ||
    die "Remote staging directory does not match the configured host" 2
  remote_run_name=${REMOTE_RUN_DIR##*/}
  case "$remote_run_name" in
    migration-source-collector-*) ;;
    *) die "Refusing to remove an unexpected remote run directory" 2 ;;
  esac
  [ "${REMOTE_RUN_DIR%/*}" = "$REMOTE_STAGING_DIR/runs" ] ||
    die "Remote run directory is outside the managed staging directory" 2
  prefix=$(privilege_prefix)
  run_ssh "${prefix}rm -rf $REMOTE_RUN_DIR $REMOTE_STAGING_DIR" >/dev/null ||
    die "Cannot clean remote collection directories" 5
  session_file="$RUN_DIR/details/internal/remote-session.env"
  if ! grep -q '^REMOTE_CLEANED=true$' "$session_file" 2>/dev/null; then
    printf 'REMOTE_CLEANED=true\n' >> "$session_file" || die "Cannot update remote cleanup state" 5
  fi
  AUTH_PASSWORD=
  printf 'remote_cleanup=success\nrun_dir=%s\nstaging_dir=%s\n' "$REMOTE_RUN_DIR" "$REMOTE_STAGING_DIR"
}

import_readable() {
  [ -d "$SOURCE_RUN_DIR" ] || die "--source-run-dir must be readable" 2
  [ -s "$SOURCE_RUN_DIR/details/internal/scan-results/summary.txt" ] || die "Source run directory is incomplete" 2
  [ -n "$LOCAL_OUTPUT" ] || die "--local-output is required" 2
  case "$LOCAL_OUTPUT" in /*) ;; *) die "--local-output must be an absolute Agent-side directory" 2 ;; esac
  prepare_work_dir_from_output
  mkdir -p "$LOCAL_OUTPUT" || die "Cannot create local output directory" 3
  cleanup_local_managed_temps "$LOCAL_OUTPUT"
  source_parent=$(CDPATH= cd -- "$(dirname "$SOURCE_RUN_DIR")" 2>/dev/null && pwd) || die "Cannot resolve source run parent" 3
  source_name=$(basename "$SOURCE_RUN_DIR")
  safe_id "$source_name" || die "Invalid source run directory name" 2
  case "$source_name" in migration-source-collector-*) ;; *) die "Unexpected source run directory name" 2 ;; esac
  imported_run="$LOCAL_OUTPUT/$source_name"
  import_temp_root="$LOCAL_OUTPUT/.${source_name}.import.$$"
  import_temp_run="$import_temp_root/$source_name"
  import_backup="$LOCAL_OUTPUT/.${source_name}.previous.$$"
  [ ! -e "$import_temp_root" ] || remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
  mkdir -p "$import_temp_root" || die "Cannot create temporary import directory" 3
  if ! tar -cf - -C "$source_parent" "$source_name" | tar -xf - -C "$import_temp_root"; then
    remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
    die "Readable result import failed" 3
  fi
  [ -s "$import_temp_run/details/internal/scan-results/summary.txt" ] || {
    remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
    die "Imported result is incomplete" 3
  }
  if [ -e "$imported_run" ]; then
    mv "$imported_run" "$import_backup" || {
      remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
      die "Cannot prepare existing imported result for replacement" 3
    }
  fi
  if mv "$import_temp_run" "$imported_run"; then
    remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
    [ ! -e "$import_backup" ] || remove_local_managed_path "$import_backup" "$LOCAL_OUTPUT"
    rm -f "$LOCAL_OUTPUT/$source_name.tar.gz"
  else
    [ ! -e "$import_backup" ] || mv "$import_backup" "$imported_run" 2>/dev/null || true
    remove_local_managed_path "$import_temp_root" "$LOCAL_OUTPUT"
    die "Cannot publish imported result" 3
  fi
  import_state="$imported_run/details/internal/remote-session.env"
  import_host=$(awk -F= '$1=="hostname" {print $2; exit}' "$imported_run/details/internal/scan-results/host.env" 2>/dev/null || true)
  import_address=$(awk -F= '$1=="primary_ip" {print $2; exit}' "$imported_run/details/internal/scan-results/host.env" 2>/dev/null || true)
  {
    printf 'OUTPUT_DIR=%s\n' "$LOCAL_OUTPUT"
    printf 'COLLECTION_MODE=remote\n'
    printf 'CONTROL_HOST_ARCHITECTURE=%s\n' "$(uname -m 2>/dev/null || echo unknown)"
    printf 'REMOTE_HOST_ID=%s\n' "${import_host:-direct-readable}"
    printf 'REMOTE_ADDRESS=%s\n' "${import_address:-unknown}"
    printf 'REMOTE_USER=unknown\n'
    printf 'REMOTE_TRANSPORT=readable\n'
  } > "$import_state" || die "Cannot write import session state" 3
  chmod 600 "$import_state" 2>/dev/null || true
  printf '%s\n' "$imported_run"
}

COMMAND=${1-}
[ -n "$COMMAND" ] || { usage; exit 2; }
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
esac
shift

HOSTS_FILE=
HOST_ID=
CREDENTIAL_ID=
SOURCE_CONFIG=
LOCAL_OUTPUT=
RUN_DIR=
PLAN_FILE=
SOURCE_RUN_DIR=
FRONTEND_PASSWORD_STDIN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) HOSTS_FILE=${2-}; shift 2 ;;
    --host) HOST_ID=${2-}; shift 2 ;;
    --credential) CREDENTIAL_ID=${2-}; shift 2 ;;
    --source-config) SOURCE_CONFIG=${2-}; shift 2 ;;
    --local-output) LOCAL_OUTPUT=${2-}; shift 2 ;;
    --run-dir) RUN_DIR=${2-}; shift 2 ;;
    --plan) PLAN_FILE=${2-}; shift 2 ;;
    --source-run-dir) SOURCE_RUN_DIR=${2-}; shift 2 ;;
    --password-stdin) FRONTEND_PASSWORD_STDIN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

case "$COMMAND" in
  recommend)
    local_arch=$(uname -m 2>/dev/null || echo unknown)
    case "$local_arch" in
      x86_64|amd64) recommended_mode=local; recommendation_reason=x86-control-host ;;
      aarch64|arm64) recommended_mode=remote; recommendation_reason=arm-control-host ;;
      *) recommended_mode=confirm; recommendation_reason=unknown-control-host-architecture ;;
    esac
    printf 'local_architecture=%s\nrecommended_mode=%s\nreason=%s\n' "$local_arch" "$recommended_mode" "$recommendation_reason"
    ;;
  list)
    list_hosts
    ;;
  credential-preflight)
    credential_preflight
    ;;
  credential-set)
    set_credential
    ;;
  collect)
    collect_remote
    ;;
  supplement)
    supplement_remote
    ;;
  sync)
    sync_session
    ;;
  cleanup)
    cleanup_remote
    ;;
  import)
    import_readable
    ;;
  *)
    usage
    die "Unknown command: $COMMAND" 2
    ;;
esac
AUTH_PASSWORD=
