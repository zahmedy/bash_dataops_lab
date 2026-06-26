#!/usr/bin/env bash
set -euo pipefail
run_date="20260624"
dry_run=false
source config/pipeline.env
today=$(date +"%Y%m%d_%H%M%S")

show_help() {
    cat <<EOF
Usage:
  ./process_daily_feed.sh [OPTIONS]

Description:
  Processes daily transaction files, validates rows, writes clean records,
  rejects bad records, creates a summary report, and archives source files.

Options:
  --date YYYYMMDD     Process files for a specific date.
                      Example: --date 20260624

  --dry-run           Show what the script would do without writing output,
                      reject, log, or archive files.

  --help              Show this help message and exit.

Examples:
  ./process_daily_feed.sh
  ./process_daily_feed.sh --date 20260624
  ./process_daily_feed.sh --date 20260624 --dry-run

--------------------------------------------------------------------
CRONTAB AUTOMATION EXAMPLE:
--------------------------------------------------------------------
To automate this script to run daily at 1:00 AM run 'crontab -e' and add:
0 1 * * * /path/to/process_daily_feed.sh --date \$(date +\\%Y\\%m\\%d) >> /path/to/logs/cron.log 2>&1

Breaking down the cron schedule syntax:
 0 1 * * * -> Minute (0), Hour (1), Day of Month (*), Month (*), Day of Week (*)
 \$(date...) -> Dynamically passes today's date in YYYYMMDD format to your script.
 >> ... 2>&1 -> Appends both standard output and errors to a cron log file.
-------------------------------------------------------------------------

Expected input files:
  inbound/transactions_YYYYMMDD.csv
  inbound/customers_YYYYMMDD.csv
  inbound/app_YYYYMMDD.log

Output:
  output/clean_transactions_TIMESTAMP.csv
  rejects/rejected_transactions_TIMESTAMP.csv
  output/summary_TIMESTAMP.txt
  logs/process_TIMESTAMP.log
  archive/
EOF
}

check_files() {
    # check input files exist 
    if [[ ! -f "$INPUT_DIR/transactions_$1.csv" || ! -f "$INPUT_DIR/customers_$1.csv" || ! -f "$INPUT_DIR/app_$1.log"  ]]; then
        echo "Warn: Some or all files don't exist, exiting..."
        exit 1
    fi 
}

# make sure dirs exist 
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR" "$REJECT_DIR" "$LOG_DIR"

# validate args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --date)
            if [[ $# -lt 2 ]]; then
                echo "Error: --date requires a YYYYMMDD argument."
                exit 1
            fi

            if [[ "$2" =~ ^[0-9]{8}$ ]]; then
                if check_files "$2" ; then
                    run_date="$2"
                else
                    echo "Files missing for date: $2"
                    exit 1
                fi
            else
                echo "Invalid date provided: $2"
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            dry_run=true
            echo "INFO: Running in Dry Run"
            shift # Move past --dry-run
            ;;
        *)
            # Handle unknown arguments
            echo "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

# PATHS
LOG_FILE="$LOG_DIR/process_$today.csv"
CLEAN_FILE="$OUTPUT_DIR/clean_transactions_$today.csv"
REJECT_FILE="$REJECT_DIR/rejected_transactions_$today.csv"
INPUT_FILE="$INPUT_DIR/transactions_$run_date.csv"

CUSTOMERS_FILE="$INPUT_DIR/customers_$run_date.csv"
APP_LOG_FILE="$INPUT_DIR/app_$run_date.log"

# logging function
log() {
    local log_level="$1"
    local  message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # format and append to log file
    if [[ "$dry_run" != "true" ]]; then
        echo "[$timestamp] [$log_level] - $message" >> "$LOG_FILE"
    else
        echo "[$timestamp] [$log_level] - $message"
    fi
}

# create files only if not dry run
if [[ "$dry_run" != "true" ]]; then
    echo "txn_id,customer_id,txn_date,amount,status,source_file" > "$CLEAN_FILE"
    echo "reason,txn_id,customer_id,txn_date,amount,status,source_file" > "$REJECT_FILE"
    echo "timestamp | severity | event" >> "$LOG_FILE"
fi


log "INFO" "Starting daily transaction processing job"
log "INFO" "Creating needed files for processing"
log "INFO" "cleaning transaction file: $INPUT_FILE"

pattern="^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$"
customer_ids=$(awk -F, 'NF > 1 { print $1}' "$CUSTOMERS_FILE" | tail -n +2)
valid_txn_ids=()
declare -A seen_txns

while IFS="," read -r txn_id customer_id txn_date amount status src_file; do
    if [[ -z "$txn_id" ]]; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "Not valid txn_id: $txn_id"
            echo "Not valid txn_id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Not valid txn_id: $txn_id"
        fi
    elif [[ -z "$customer_id" ]]; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "No customer id"
            echo "No customer id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: No customer id"
        fi
    elif [[ ! $txn_date =~ $pattern ]]; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "Bad date format"
            echo "Bad date format, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Bad date format"
        fi
    elif ! [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "Invalid amount: $amount"
            echo "Invalid amount: $amount,$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Invalid amount: $amount"
        fi
    elif ! awk "BEGIN { exit !($amount >= $MIN_AMOUNT && $amount <= $MAX_AMOUNT) }"; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "Amount out of range: $amount"
            echo "Amount out of range: $amount,$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Amount out of range: $amount"
        fi
    elif [[  ",$VALID_STATUSES," != *",$status,"*  ]]; then
        if [[ "$dry_run" != "true" ]]; then
            log "ERROR" "Invalid status: $status"
            echo "Invalid status: $status, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Invalid status: $status"
        fi
    elif ! grep -qw "$customer_id" <<< "$customer_ids"; then
        if [[ "$dry_run" != "true" ]]; then 
            log "ERROR" "Invalid customer ID: $customer_id"
            echo "Invalid customer ID: $customer_id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
        else
            echo "ERROR: Invalid customer ID: $customer_id"
        fi
    else
        if [[ -n "${seen_txns[$txn_id]+exists}" ]]; then
            if [[ "$dry_run" != "true" ]]; then
                log "ERROR" "Duplicate txn ID: $txn_id"
                echo "Duplicate txn ID, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_FILE"
            else
                echo "ERROR: Duplicate txn ID: $txn_id"
            fi
        else
            seen_txns[$txn_id]=1
            if [[ "$dry_run" != "true" ]]; then
                log "INFO" "Valid Transaction processed: $txn_id"
                echo "$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$CLEAN_FILE"
            else
                echo "INFO: Valid Transaction: $txn_id,$customer_id,$txn_date,$amount,$status,$src_file"
            fi
        fi
    fi
done < <(tail -n +2 "$INPUT_FILE")

log "INFO" "cleaning transaction file completed"

# SUMMARY REPORT

if [[ "$dry_run" != "true" ]]; then
    touch $OUTPUT_DIR/summary_$today.txt
    SUMMARY_FILE="$OUTPUT_DIR/summary_$today.txt"
    log "INFO" "Creating summary report $SUMMARY_FILE"


    total_transactions=$(($(wc -l < "$INPUT_FILE") - 1))
    valid_rows=$(($(wc -l < "$CLEAN_FILE") -1))
    rejected_rows=$(($(wc -l < "$REJECT_FILE") -1))

    #VALID_STATUSES="PAID,FAILED,PENDING,REFUNDED"

    paid_count=$(grep -c "PAID" "$CLEAN_FILE" || true)
    failed_count=$(grep -c  "FAILED" "$CLEAN_FILE" || true)
    pending_count=$(grep -c "PENDING" "$CLEAN_FILE" || true)
    refunded_count=$(grep -c "REFUNDED" "$CLEAN_FILE" || true)

    top5_paid_customers=$(
        awk -F, '$5 == "PAID" { total[$2] += $4} END { for (c in total) print c, total[c] }' "$CLEAN_FILE" | 
        sort -k2,2nr | 
        head -5
    )

    if [[ ! $? -eq 0 ]]; then 
        log "ERROR:" "Unable to get top 5 paid customers"
    fi

    error_lines_count=$(grep -c "|ERROR|" "$APP_LOG_FILE" || true)

    if [[ ! $? -eq 0 ]]; then 
        log "ERROR:"  "Unable to get error count"
    fi

    top5_errors=$(
        grep -i error "$APP_LOG_FILE" | 
        awk -F"|" '{ print $4 }' | 
        sort |  
        uniq -c |
        sort -nr |
        head -5
    )

    if [[ ! $? -eq 0 ]]; then 
        log "ERROR:" "Unable to get top 5 errors"
    fi

    {
        echo "total_transactions:${total_transactions:-0}" 
        echo "valid_rows:${valid_rows:-0}" 
        echo "rejected_rows:${rejected_rows:-0}" 
        echo "paid_count:${paid_count:-0}" 
        echo "failed_count:${failed_count:-0}" 
        echo "pending_count:${pending_count:-0}" 
        echo "refunded_count:${refunded_count:-0}" 

        echo 
        echo "top5_paid_customers:"
        echo "${top5_paid_customers:-0}" 

        echo
        echo "error_lines_count: ${error_lines_count:-0}" 

        echo
        echo "top5_errors:" 
        echo "${top5_errors:-0}"
    } | tee -a "$SUMMARY_FILE" "$LOG_FILE" > /dev/null

    if [[ $? -eq 0 ]]; then 
        log "INFO" "Summary report created"
    else
        log "ERROR" "Unable to create summary report"
    fi 

    # ARCHIVE
    if  cp "$INPUT_FILE" "$ARCHIVE_DIR/transactions_${run_date}_${today}.csv" && \
        cp "$CUSTOMERS_FILE" "$ARCHIVE_DIR/customers_${run_date}_${today}.csv" && \
        cp "$APP_LOG_FILE" "$ARCHIVE_DIR/app_${run_date}_${today}.log" ; then
        log "INFO" "Archiving source files completed"
    else
        log "ERROR" "Unable to archive source files"
    fi    
    log "INFO" "Daily transaction processing job completed"
    
else
    echo "RUNNING IN DRY-RUN: some summary fields may be empty or zero"
    echo "total_transactions:${total_transactions:-0}" 
    echo "valid_rows:${valid_rows:-0}" 
    echo "rejected_rows:${rejected_rows:-0}" 
    echo "paid_count:${paid_count:-0}" 
    echo "failed_count:${failed_count:-0}" 
    echo "pending_count:${pending_count:-0}" 
    echo "refunded_count:${refunded_count:-0}" 

    echo
    echo "top5_paid_customers:"
    echo "${top5_paid_customers:-0}" 

    echo
    echo "error_lines_count: ${error_lines_count:-0}" 

    echo
    echo "top5_errors:" 
    echo "${top5_errors:-0}"
fi