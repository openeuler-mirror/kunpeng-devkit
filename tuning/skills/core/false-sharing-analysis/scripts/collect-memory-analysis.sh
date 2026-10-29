#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  collect-memory-analysis.sh -p PID --devopt /path/to/devopt.sh [options]

Run the devopt collection pipeline used by false-sharing-analysis:
  1. devopt.sh record -d SECONDS -p PID
  2. devopt.sh record -d SECONDS -p PID -m -i RAWDATA
  3. devopt.sh script -t memory -i RAWDATA (retain FS records only)

Options:
  -d, --duration SECONDS   Collection duration for both record commands
                           (default: 10).
  -p, --pid PID            Target process ID.
      --devopt PATH        Required path to the extracted devopt.sh.
      --rawdata-dir DIR    Directory where step 1 creates *.rawdata
                           (default: current directory).
  -i, --rawdata FILE       Reuse an existing rawdata file and skip step 1.
  -o, --output FILE        Also save the final memory report to FILE.
  -h, --help               Show this help.

Run this script only when no devopt report was supplied. It requires root and an ARM SPE event source.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

duration='10'
target_pid=''
devopt=''
rawdata_dir='.'
rawdata=''
output=''

while (($# > 0)); do
    case "$1" in
        -d|--duration)
            (($# >= 2)) || die "$1 requires a value"
            duration=$2
            shift 2
            ;;
        -p|--pid)
            (($# >= 2)) || die "$1 requires a value"
            target_pid=$2
            shift 2
            ;;
        --devopt)
            (($# >= 2)) || die "$1 requires a value"
            devopt=$2
            shift 2
            ;;
        --rawdata-dir)
            (($# >= 2)) || die "$1 requires a value"
            rawdata_dir=$2
            shift 2
            ;;
        -i|--rawdata)
            (($# >= 2)) || die "$1 requires a value"
            rawdata=$2
            shift 2
            ;;
        -o|--output)
            (($# >= 2)) || die "$1 requires a value"
            output=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ $duration =~ ^[1-9][0-9]*$ ]] || die "duration must be a positive integer"
[[ $target_pid =~ ^[1-9][0-9]*$ ]] || die "pid must be a positive integer"

[[ $(id -u) -eq 0 ]] || die "root privileges are required for devopt SPE collection; rerun only after the user provides an authorized root environment"
shopt -s nullglob
spe_devices=(/sys/bus/event_source/devices/arm_spe_*)
shopt -u nullglob
((${#spe_devices[@]} > 0)) || die "ARM SPE event source was not found under /sys/bus/event_source/devices"

[[ -n $devopt ]] || die "--devopt PATH is required (for example: --devopt /XXXXX/devopt.sh)"
[[ -f $devopt ]] || die "devopt script not found: $devopt"
[[ -x $devopt ]] || die "devopt script is not executable: $devopt"
devopt_dir_abs=$(cd -- "$(dirname -- "$devopt")" && pwd -P)
devopt="$devopt_dir_abs/$(basename -- "$devopt")"

[[ -d $rawdata_dir ]] || die "rawdata directory not found: $rawdata_dir"

if [[ -z $rawdata ]]; then
    marker=$(mktemp "${TMPDIR:-/tmp}/false-sharing-record.XXXXXX")
    cleanup() {
        rm -f -- "$marker"
    }
    trap cleanup EXIT

    printf '[1/3] collecting rawdata for PID %s (%ss)\n' "$target_pid" "$duration" >&2
    "$devopt" record -d "$duration" -p "$target_pid"

    candidates=()
    while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
    done < <(find "$rawdata_dir" -maxdepth 1 -type f -name '*.rawdata' -newer "$marker" -print0)

    case ${#candidates[@]} in
        0)
            die "step 1 completed but no new *.rawdata was found in $rawdata_dir; rerun with -i FILE or set --rawdata-dir"
            ;;
        1)
            rawdata=${candidates[0]}
            ;;
        *)
            printf 'error: step 1 produced or modified multiple rawdata files:\n' >&2
            printf '  %s\n' "${candidates[@]}" >&2
            die "cannot choose safely; rerun with -i FILE"
            ;;
    esac
else
    [[ -f $rawdata ]] || die "rawdata file not found: $rawdata"
    printf '[1/3] using existing rawdata: %s\n' "$rawdata" >&2
fi

rawdata_dir_abs=$(cd -- "$(dirname -- "$rawdata")" && pwd -P)
rawdata="$rawdata_dir_abs/$(basename -- "$rawdata")"

printf '[2/3] appending memory analysis to %s\n' "$rawdata" >&2
"$devopt" record -d "$duration" -p "$target_pid" -m -i "$rawdata"

printf '[3/3] rendering memory analysis\n' >&2
render_false_sharing() {
    awk '
        /^FS[[:space:]]+[0-9]+:/ { in_fs = 1; print; next }
        /^[^[:space:]]/ { in_fs = 0; next }
        in_fs && (/^[[:space:]]*$/ || /^[[:space:]]+[AB]:/) { print }
    '
}
if [[ -n $output ]]; then
    output_parent=$(dirname -- "$output")
    [[ -d $output_parent ]] || die "output directory not found: $output_parent"
    "$devopt" script -t memory -i "$rawdata" | render_false_sharing | tee "$output"
    printf 'memory report saved to: %s\n' "$output" >&2
else
    "$devopt" script -t memory -i "$rawdata" | render_false_sharing
fi

printf 'rawdata: %s\n' "$rawdata" >&2
