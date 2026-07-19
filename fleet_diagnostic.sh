#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# ONLY RUN AS ROOT
if [[ $EUID -ne 0 ]]; then 
	echo "Error: This script must be run as root."
	exit 1
fi

# GLOBAL TRACKER
PURGED_BYTES=0
DRY_RUN=false
TARGET_DIR=""

show_help () {
	cat <<EOF
Usag:
./fleet_diagnostic.sh [OPTION] [DIRECTORY]

Description:
  Localized cleanup and telemetry monitoring daemon for build engines.

Options:
  --dry-run	Show what the script will do without applying changes
  --help	Displays this message
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--help)
			show_help
			exit 0
			;;
		--dry-run)
			DRY_RUN=true
			echo "Info: Running in DRY-RUN mode."
			shift
			;;
        -*)
            echo "Error: Unkown option $1" >&2
            show_help
            exit 1
            ;;
		*)
			TARGET_DIR="$1"
            shift
            ;;
	esac
done

if ! cd "${TARGET_DIR}" 2>/dev/null; then
    echo "Error: Directory '${TARGET_DIR}' does not exist or is inaccessible." >&2
    exit 1
fi
TARGET_DIR="$(pwd -p)"

OS_TYPE="$(uname -s)"
get_file_size() {
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        stat -f %z "$1"
    else
        stat -c %s "$1"
    fi
}
get_file_mod_time() {
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

cleanup_artifacts() {
    echo -e "\nSignal caught! cleaning up temporary compression vectors..."
    find "$TARGET_DIR" -name "*.log.*.gz.tmp" -delete 2>/dev/null || true
    exit 130
}
trap cleanup_artifacts SIGINT SIGTERM

printf -v CURRENT_EPOCH '%(%s)T' -1
SEVEN_DAYS_AGO_EPOCH=$(( CURRENT_EPOCH - 604800 ))
printf -v CURRENT_DATE '%(%Y%m%d)T'

while IFS= read -r -d '' file; do
    file_size=$(get_file_size "${file}")

    # Check threshold: 50MB = 52,428,800 bytes
    if [[ "${file_size}" -gt 52428800 ]]; then
        output_gzip="${file}.${CURRENT_DATE}.gz"
        echo "Action: Compressing large log -> ${output_gzip}"

        if [[ "${DRY_RUN}" == "false" ]]; then
            # Compress to temporary file first to protect process context if killed mid-write
            if gzip -9 -c "${file}" > "${output_gzip}.tmp"; then
                mv "${output_gzip}.tmp" "${output_gzip}"
                # Truncate the original log file to free space without breaking active file descriptors 
                echo -n "" > "${file}"

                compressed_size=$(get_file_size "${output_gzip}")
                saved_bytes=$(( file_size - compressed_size ))
                PURGED_BYTES=$(( PURGED_BYTES + saved_bytes ))
            fi
        fi
    fi
done < <(find "${TARGET_DIR}" -type f -name "*.log" -print0)


while IFS= read -r -d '' gz_file; do
    mod_time=$(get_file_mod_time "${gz_file}")

    if (( mod_time < SEVEN_DAYS_AGO_EPOCH )); then
        rm -f "${gz_file}"
        PURGED_BYTES=$(( PURGED_BYTES + gz_file ))
    fi
done < <(find "${TARGET_DIR}" -type f -name "*.gz" -print0)

ROOT_UTILIZATION=$(df -h / | awk 'tolower($2) ~ "/dev" {print $5}' | tr -d '%')

TELEMETRY_PAYLOAD=$(cat <<JSON
{"timestamp": ${CURRENT_EPOCH}, "total_purged_bytes": ${PURGED_BYTES}, "disk_utilization_pct": ${ROOT_UTILIZATION}}
JSON
)

if [[ "${DRY_RUN}" == "false" ]]; then
    # Target workspace tracking safely
    echo "${TELEMETRY_PAYLOAD}" >> /var/log/fleet_telemetry.json 2>/dev/null || \
    echo "${TELEMETRY_PAYLOAD}" >> "${TARGET_DIR}/fleet_telemetry.json"
fi

echo "Execution Complete. Total Space Saved: ${PURGED_BYTES} bytes."