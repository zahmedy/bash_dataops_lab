#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
LOCKFILE="/tmp/log_pipeline.lock"

VERBOSE=false
DRY_RUN=false
DIR=""
MAX_JOBS=0
BATCH_SIZE=0
CURRENT_PID=-1

while getopts "sjb:vd" opt; do
        case ${opt} in
                s )
                        DIR=${OPTARG}
                        ;;
                j )
                        MAX_JOBS=${OPTARG}
                        ;;
                b )
                        BATCH_SIZE=${OPTARG}
                        ;;
                d )
                        DRY_RUN=true
                        echo "Info:Running in dry-run"
                        ;;
                v )
                        VERBOSE=true
                        ;;
                \? )
                        echo "Ivalid option: - ${OPTARG}" >&2
                        exit 1
                        ;;
                *)
                        echo "Option - ${OPTARG} requires an argument." >&2
                        exit1
                        ;;
        esac
done

shift $((OPTIND - 1))

###########################
# Global lock
###########################
exec 200>"$LOCKFILE"

if ! flock -n 200; then
        echo "Another process is running this script!"
        exit 1
fi

if [[ "$VERBOSE" == "true" ]]; then
        set -x
        echo "Enabling verbose mode..."
fi

###########################
# Signal handling
###########################

clean_up() {
        echo "Cleaning up.."
        rm -f "${DIR}"/*.tar.*
        kill -9 $CURRENT_PID
}

trap cleanup INT TERM EXIT

###########################
# Worker
###########################

process_file () {
        echo "Compressing $DIR/$1"
        gzip -k "${DIR}"/"$1"
        echo "Hashing ${DIR}/$1.gz"
        sha256sum "${DIR}"/"$1".tar.gz "$DIR"/"$1".tar.gz.sha256
        echo "Copying compressed logs in ${DIR} to remote storage"
        echo "Complete"
}

for file in ${DIR}; do
        while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
                wait -n
        done
        process_file "$file" &
        CURRENT_PID=$!
done

echo "All files in $DIR processed successfully"