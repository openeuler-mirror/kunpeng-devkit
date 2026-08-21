#!/bin/sh
set -u
umask 077

usage() {
  echo "Usage: sh migration-precheck/scripts/prepare-packages.sh --plan <migration-plan.json> --work-dir <migration-work-dir> --manifest <package-manifest.tsv> [--allow-download true|false] [--download-dependencies true|false]"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_true() {
  case "$1" in true|TRUE|yes|YES|1) return 0 ;; *) return 1 ;; esac
}

safe_id() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

safe_file_name() {
  case "$1" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; *) return 0 ;; esac
}

safe_package_name() {
  case "$1" in ''|*[!A-Za-z0-9._+:-]*) return 1 ;; *) return 0 ;; esac
}

clean_tsv() { printf '%s' "$1" | tr '\t\r\n' '   '; }

file_size() {
  size_target=$1
  if has_cmd stat; then
    stat -c '%s' "$size_target" 2>/dev/null || stat -f '%z' "$size_target" 2>/dev/null || echo 0
  else
    wc -c < "$size_target" 2>/dev/null || echo 0
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

emit_result() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_tsv "$1")" "$(clean_tsv "$2")" "$(clean_tsv "$3")" \
    "$(clean_tsv "$4")" "$(clean_tsv "$5")" "$(clean_tsv "$6")" \
    "$(clean_tsv "$7")" "$(clean_tsv "$8")" "$(clean_tsv "$9")" \
    "$(clean_tsv "${10}")" "$(clean_tsv "${11}")" "$(clean_tsv "${12}")" \
    "$(clean_tsv "${13}")" "$(clean_tsv "${14}")" "$(clean_tsv "${15}")"
}

download_file() {
  download_url=$1
  download_target=$2
  download_tmp="$download_target.part.$$"
  rm -f "$download_tmp"
  mkdir -p "$(dirname "$download_target")" || return 1
  if has_cmd curl; then
    curl -fL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 10 \
      -o "$download_tmp" "$download_url" >/dev/null 2>&1 || {
        download_status=$?
        rm -f "$download_tmp"
        return "$download_status"
      }
  elif has_cmd wget; then
    wget -q --https-only -O "$download_tmp" "$download_url" || {
      download_status=$?
      rm -f "$download_tmp"
      return "$download_status"
    }
  else
    return 127
  fi
  [ -s "$download_tmp" ] || {
    rm -f "$download_tmp"
    return 1
  }
  mv "$download_tmp" "$download_target"
}

MANIFEST=
PLAN=
MIGRATION_WORK_DIR=
ALLOW_DOWNLOAD=true
DOWNLOAD_DEPENDENCIES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST=${2-}; shift 2 ;;
    --plan) PLAN=${2-}; shift 2 ;;
    --work-dir) MIGRATION_WORK_DIR=${2-}; shift 2 ;;
    --allow-download) ALLOW_DOWNLOAD=${2-}; shift 2 ;;
    --download-dependencies) DOWNLOAD_DEPENDENCIES=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" 2 ;;
  esac
done

[ -r "$MANIFEST" ] || die "--manifest must be readable" 2
[ -r "$PLAN" ] || die "--plan must be a readable migration-plan.json" 2
[ -n "$MIGRATION_WORK_DIR" ] || die "--work-dir is required" 2
case "$MIGRATION_WORK_DIR" in /*) ;; *) die "--work-dir must be an absolute path" 2 ;; esac
PLAN_DIR=$(cd "$(dirname "$PLAN")" && pwd -P)
PACKAGE_DIR="$MIGRATION_WORK_DIR/packages"
TOOLS_DIR="$MIGRATION_WORK_DIR/tools"
mkdir -p "$PACKAGE_DIR" "$TOOLS_DIR"
PACKAGE_DIR=$(cd "$PACKAGE_DIR" && pwd -P)
TOOLS_DIR=$(cd "$TOOLS_DIR" && pwd -P)
RUNTIME_TMP="$MIGRATION_WORK_DIR/tmp"
mkdir -p "$RUNTIME_TMP"
export TMPDIR="$RUNTIME_TMP" TMP="$RUNTIME_TMP" TEMP="$RUNTIME_TMP"
case "$ALLOW_DOWNLOAD" in true|false) ;; *) die "--allow-download must be true or false" 2 ;; esac
case "$DOWNLOAD_DEPENDENCIES" in true|false) ;; *) die "--download-dependencies must be true or false" 2 ;; esac

printf 'package_id\tcomponent_id\tkind\tproduct\ttarget_version\tpackage_version\tfile_name\tsource_type\tdownload_url\tprepared_path\tsize\tsha256\tstatus\tlicense_required\tnote\n'

TAB=$(printf '\t')
while IFS="$TAB" read -r package_id component_id package_kind product target_version package_version file_name download_url source_type planned_local_path license_required || [ -n "${package_id:-}" ]; do
  [ "${package_id:-}" = package_id ] && continue
  [ -n "${package_id:-}" ] || continue

  [ "$target_version" != "-" ] || target_version=
  [ "$package_version" != "-" ] || package_version=
  [ "$download_url" != "-" ] || download_url=
  [ "$planned_local_path" != "-" ] || planned_local_path=

  safe_id "$package_id" || die "Invalid package_id: $package_id" 2
  safe_id "$component_id" || die "Invalid component_id: $component_id" 2
  case "$package_kind" in TARGET_PACKAGE|MIGRATION_TOOL|OS_DEPENDENCY) ;; *) die "Invalid package kind: $package_kind" 2 ;; esac
  case "$source_type" in SYSTEM_REPOSITORY|OFFICIAL|MANUAL) ;; *) die "Invalid source_type: $source_type (allowed: SYSTEM_REPOSITORY, OFFICIAL, MANUAL)" 2 ;; esac
  case "$license_required" in true|false) ;; *) die "license_required must be true or false" 2 ;; esac

  if [ "$package_kind" = OS_DEPENDENCY ] || [ "$source_type" = SYSTEM_REPOSITORY ]; then
    safe_package_name "$file_name" || die "Invalid package/repository name: $file_name" 2
  else
    safe_file_name "$file_name" || die "Invalid file_name: $file_name" 2
  fi
  if [ -n "$download_url" ]; then
    case "$download_url" in https://*) ;; *) die "Only HTTPS download URLs are allowed" 2 ;; esac
    case "$download_url" in *'@'*) die "Credential-bearing download URLs are forbidden" 2 ;; esac
  fi

  if [ "$package_kind" = MIGRATION_TOOL ]; then
    component_dir="$TOOLS_DIR/packages/$component_id"
  else
    component_dir="$PACKAGE_DIR/$component_id"
  fi
  default_local_path="$component_dir/$file_name"
  local_path=$default_local_path
  input_local_path=
  if [ -n "$planned_local_path" ]; then
    case "$planned_local_path" in
      /*) input_local_path=$planned_local_path ;;
      *) input_local_path="$PLAN_DIR/$planned_local_path" ;;
    esac
  fi
  if [ -n "$input_local_path" ] && [ -s "$input_local_path" ]; then
    # Copy every declared local package into its unified working directory.
    mkdir -p "$component_dir" || die "Cannot create component package directory" 3
    if [ "$input_local_path" != "$default_local_path" ]; then
      cp -p "$input_local_path" "$default_local_path" || die "Cannot copy package into MIGRATION_WORK_DIR: $input_local_path" 3
    fi
    local_path=$default_local_path
  fi

  package_size=0
  package_hash=
  note=
  [ "$license_required" = false ] || note="license is handled separately and does not block package preparation"

  if [ "$package_kind" = OS_DEPENDENCY ]; then
    dependency_dir="$component_dir/dependencies"
    mkdir -p "$dependency_dir" || die "Cannot create dependency directory" 3
    local_path="$dependency_dir"
    package_status=PENDING_CONFIRMATION
    note="dependency download requires user confirmation"

    if find "$dependency_dir" -type f -size +0c -print -quit 2>/dev/null | grep -q .; then
      package_status=PRESENT
      note="dependency files already exist; nothing installed"
    elif ! is_true "$ALLOW_DOWNLOAD"; then
      package_status=PENDING_UPLOAD
      note="target is offline; download the OS package and upload it"
    elif is_true "$DOWNLOAD_DEPENDENCIES"; then
      if has_cmd dnf && dnf download --resolve --alldeps --destdir "$dependency_dir" "$file_name" >/dev/null 2>&1; then
        package_status=DOWNLOADED
        note="downloaded with dnf; nothing installed"
      elif has_cmd yumdownloader && yumdownloader --resolve --destdir "$dependency_dir" "$file_name" >/dev/null 2>&1; then
        package_status=DOWNLOADED
        note="downloaded with yumdownloader; nothing installed"
      elif has_cmd apt-get && apt-get --download-only -o "Dir::Cache::archives=$dependency_dir" install -y "$file_name" >/dev/null 2>&1; then
        package_status=DOWNLOADED
        note="downloaded with apt-get --download-only; nothing installed"
      else
        package_status=DEPENDENCY_TOOL_UNAVAILABLE
        note="package manager could not resolve or download the dependency"
      fi
    fi
  elif [ "$source_type" = SYSTEM_REPOSITORY ]; then
    # Repository-backed middleware is installed later by the middleware Skill.
    # Precheck does not download or require a local artifact.
    package_status=NOT_REQUIRED
    local_path=
    note="package file is not required; target middleware migration will use the system repository"
  elif [ -s "$local_path" ]; then
    package_status=PRESENT
    note="package already exists at prepared_path"
  elif [ "$source_type" = MANUAL ]; then
    package_status=PENDING_UPLOAD
    note="manual package source; upload the package to prepared_path"
  elif [ "$source_type" = OFFICIAL ]; then
    if [ -z "$download_url" ]; then
      package_status=URL_REQUIRED
      note="download_url is required for the selected package source"
    elif ! is_true "$ALLOW_DOWNLOAD"; then
      package_status=PENDING_UPLOAD
      note="automatic download is disabled; upload the package to prepared_path"
    elif download_file "$download_url" "$local_path"; then
      package_status=DOWNLOADED
      note="downloaded from the configured package source"
    else
      package_status=PENDING_UPLOAD
      note="automatic download failed; upload the package to prepared_path"
    fi
  else
    die "Unhandled source_type: $source_type" 2
  fi

  if [ "$package_kind" != OS_DEPENDENCY ] && [ -n "$local_path" ] && [ -s "$local_path" ]; then
    package_size=$(file_size "$local_path")
    package_hash=$(hash_file "$local_path")
  fi

  emit_result "$package_id" "$component_id" "$package_kind" "$product" \
    "$target_version" "$package_version" "$file_name" "$source_type" \
    "$download_url" "$local_path" "$package_size" "$package_hash" \
    "$package_status" "$license_required" "$note"
done < "$MANIFEST"
