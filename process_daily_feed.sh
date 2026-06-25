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
        echo "Some or all files don't exist, existing..."
        exit 1
    fi 
}

# validate args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            exit 0
            ;;
        --date)
            if [[ -z "$2" ]]; then
                echo "Error: --date requires a YYYYMMDD argument."
                exit 1
            fi

            if [[ "$2" =~ ^[0-9]{4}[0-9]{2}[0-9]{2}$ ]]; then
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

# logging function
log() {
    local log_level="$1"
    local  message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # format and append to log file
    if [[ ! dry_run ]]; then
        echo "[$timestamp] [$log_level] - $message" >> "$LOG_DIR/process_$today.csv"
    else
        echo "[$timestamp] [$log_level] - $message"
    fi
}

log "INFO" "Starting daily transaction processing job"

echo "Creating output files..."
log "INFO" "Creating needed files for processing"

touch "$OUTPUT_DIR/clean_transactions_$today.csv"
touch "$REJECT_DIR/rejected_transactions_$today.csv"
touch "$LOG_DIR/process_$today.csv"
touch "$ARCHIVE_DIR/transactions_$today.csv"

log "INFO" "cleaning transaction file: $INPUT_DIR/transactions_$run_date.csv"

pattern="^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$"
customer_ids=$(awk -F, 'NF > 1 { print $1}' "$INPUT_DIR/customers_20260624.csv" | tail -n +2)
valid_txn_ids=()
declare -A seen_txns

while IFS="," read -r txn_id customer_id txn_date amount status src_file; do
    if [[ -z "$txn_id" ]]; then
        if [[ ! dry_run ]]; then
            log "ERROR" "Not valid txn_id: $txn_id"
            echo "Not valid txn_id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: Not valid txn_id: $txn_id"
        fi
    elif [[ -z "$customer_id" ]]; then
        if [[ ! dry_run ]]; then
            log "ERROR" "No customer id"
            echo "No customer id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: No customer id"
        fi
    elif [[ ! $txn_date =~ $pattern ]]; then
        if [[ ! dry_run ]]; then
            log "ERROR" "Bad date format"
            echo "Bad date format, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: Bad date format"
        fi
    elif ! [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        if [[ ! dry_run ]]; then
            log "ERROR" "Invalid amount: $amount"
            echo "Invalid amount: $amount,$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: Invalid amount: $amount"
        fi
    elif ! awk "BEGIN { exist ($amount >= $MIN_AMOUNT && $amount <= $MAX_AMOUNT) }"; then
        if [[ ! dry_run ]]; then
            log "ERROR" "Amount out of range: $amount"
            echo "Amount out of range: $amount,$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: Amount out of range: $amount"
        fi
    elif [[  ",$VALID_STATUSES," != *",$status,"*  ]]; then
        if [[ ! dry_run ]]; then
            log "ERROR" "Invalid status: $status"
            echo "Invalid status: $status, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
        else
            echo "ERROR: Invalid status: $status"
        fi
    elif ! grep -qw "$customer_id" <<< "$customer_ids"; then 
        log "ERROR" "Invalid customer ID: $customer_id"
        echo "Invalid customer ID: $customer_id, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
    else
        if [[ -n "${seen_txns[$txn_id]+exists}" ]]; then
            if [[ ! dry_run ]]; then
                log "ERROR" "Duplicate txn ID: $txn_id"
                echo "Duplicate txn ID, $txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$REJECT_DIR/rejected_transactions_$today.csv"
            else
                echo "ERROR: Duplicate txn ID: $txn_id"
            fi
        else
            if [[ ! dry_run ]]; then
                seen_txns[$txn_id]=1
                log "INFO" "Valid Transaction processed: $txn_id"
                echo "$txn_id,$customer_id,$txn_date,$amount,$status,$src_file" >> "$OUTPUT_DIR/clean_transactions_$today.csv"
            else
                echo "INFO: Valid Transaction: $txn_id,$customer_id,$txn_date,$amount,$status,$src_file"
            fi
        fi
    fi
done < <(tail -n +2 "$INPUT_DIR/transactions_20260624.csv")

log "INFO" "cleaning transaction file completed"

# SUMMARY REPORT

touch $OUTPUT_DIR/summary_$today.txt
SUMMARY_FILE="$OUTPUT_DIR/summary_$today.txt"

log "INFO" "Creating summary report $OUTPUT_DIR/summary_$today.txt"

total_transactions=$(($(wc -l < "$INPUT_DIR/transactions_20260624.csv") - 1))
valid_rows=$(wc -l < "$OUTPUT_DIR/clean_transactions_$today.csv")
rejected_rows=$(wc -l < "$REJECT_DIR/rejected_transactions_$today.csv")

#VALID_STATUSES="PAID,FAILED,PENDING,REFUNDED"

paid_count=$(grep -c "PAID" "$OUTPUT_DIR/clean_transactions_$today.csv" || true)
failed_count=$(grep -c  "FAILED" "$OUTPUT_DIR/clean_transactions_$today.csv" || true)
pending_count=$(grep -c "PENDING" "$OUTPUT_DIR/clean_transactions_$today.csv" || true)
refunded_count=$(grep -c "REFUNDED" "$OUTPUT_DIR/clean_transactions_$today.csv" || true)

top5_paid_customers=$(
    awk -F, '$5 == "PAID" { total[$2] += 4} END { for (c in total) print c, total[c] }' "$OUTPUT_DIR/clean_transactions_$today.csv" | 
    sort -k2,2nr | 
    head -5
)


error_lines_count=$(grep -c "|ERROR|" "$INPUT_DIR/app_20260624.log" || true)
top5_errors=$(
    grep -i error inbound/app_20260624.log | 
    awk -F"|" '{ print $4 }' | 
    sort |  
    uniq -c |
    sort -nr |
    head -5
)

if [[ ! dry_run ]]; then
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
    } > "$SUMMARY_FILE"
else
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

log "INFO" "Summary report created"

# ARCHIVE
if [[ ! dry_run ]]; then
    cp -r "$INPUT_DIR"/* "$ARCHIVE_DIR"/
fi

log "INFO" "Archiving source files completed"
log "INFO" "Daily transaction processing job completed"