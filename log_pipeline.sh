#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
LOCKFILE="/tmp/log_pipeline.lock"
SYSLOG_REGEX="^([A-Z][a-z]{2}[[:space:]]+[0-9]+[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})"

S3=""
VERBOSE=false
DRY_RUN=false
DIR=""
MAX_JOBS=0
BATCH_SIZE=0
pids=()

while getopts "s:j:b:vd" opt; do
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
                        exit 1
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
        shopt -s nullglob
        for file in "${DIR}"/*.tar.*; do
            epoch=$(stat -c "%Y" "$file")
            now=$(date +%s)
            difference=$(( now - epoch))
            # if older than 1 hour remove it
            if [[ $difference -gt 3600 ]]; then
                rm -f "$file"
            fi
            rm -f "${DIR}"/*.tmp
        done
        shopt -u nullglob
        for pid in "${pids[@]}"; do
            kill -TERM "$pid"
        done
        sleep 5
        for pid in "${pids[@]}"; do
            if kill -0 "$pid"; then
                echo "Process $pid still running, trying sigkill"
                kill -9 "$pid"
            fi
        done
}

trap clean_up INT TERM EXIT

###########################
# Upload
###########################

simulate_upload() {
    echo "Uploading to S3"
    if (( RANDOM % 10 < 3 )); then 
        return 1
    fi
    echo "upload ok"
    return 0
}

upload_with_retry() {
    local batch="$1"
    local attempt delay jitter

    for attempt in 1 2 3; do
        if simulate_upload; then
            return 0
        fi

        jitter=$((RANDOM % 3))
        delay=$((2 ** attempt + jitter))
        echo "upload failed for $batch, retrying in ${delay}s" >&2
        sleep "$delay"
    done

    touch "${batch}.failed"
    echo "upload failed for $batch after 3 retries" >&2
    return 1
}

###########################
# Worker
###########################

process_file () {
        # check if dir exist
        tmp_file="$DIR/.processed_manifest"
        if [[ ! -f $tmp_file ]]; then
            if ! touch "$tmp_file"; then
                echo "Error: enable to create $tmp_file"
                exit 1
            fi
        fi
        
        file="${DIR}"/"$1"
        corrupt_dir="$DIR/.corrupt"
        if [[ ! -d $corrupt_dir ]]; then
            if ! mkdir -p "$corrupt_dir"; then
                echo "Error: enable to create $corrupt_dir"
                exit 1
            fi
        fi
        
        # check file for corruption
        corrupted=false
        while read -r line; do
            [[ -z "$line" ]] && continue
            
            if echo "$line" | jq -e . >/dev/null 2>&1; then
                continue
            fi

            if [[ "$line" =~ $SYSLOG_REGEX ]]; then 
                continue
            fi

            echo "  [->] Quarantining $file to $corrupt_dir"
            corrupted=true
            break
        done < "$file"

        if [[ "$corrupted" == "false" ]]; then
            hash=$(sha256sum "${file}" | cut -d' ' -f1)
            
            if ! grep -r "^$hash" "$tmp_file"; then
                gzip -c  "$file" > "${file}.tmp" && mv "${file}.tmp" "${file}.gz"
                sha256sum "${file}.gz" 
                printf '%s %s\n' "$hash" "$file" >> "$tmp_file"
            else
                echo "$file already processed"
            fi
            echo "Copying compressed logs in ${DIR} to remote storage"
            for hash_file in "$tmp_dir"/*; do
                scp "$hash_file" "$S3"
            done
            echo "Complete"
        fi
}

while read -r file; do
        nprocs=0
        if [ -n "$MAX_JOBS" ]; then 
            nprocs="$MAX_JOBS"
        else
            nprocs=$(nproc)
        fi
        while (( $(jobs -rp | wc -l) >= nprocs )); do
            wait -n
            # prune done pids
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[i]}" 2>/dev/null; then
                    unset "pids[i]"
                fi
            done
        done
        process_file "$file" &
        pids+=($!)
done < <(find "${DIR}" -maxdepth 1 -type file -name "*.log")

echo "All files in $DIR processed successfully"