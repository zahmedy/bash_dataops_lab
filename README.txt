Bash DataOps Lab

Your main task:
Write a Bash script named process_daily_feed.sh that processes the files in ./inbound.

Files:
- inbound/transactions_20260624.csv
- inbound/customers_20260624.csv
- inbound/app_20260624.log
- config/pipeline.env

Do not edit the source files manually.
Your script should create output files under output/, rejects/, logs/, and archive/.

It must practice:

variables
source config file
functions
if/else
case/esac
for loop
while read loop
awk
sed
grep
cut
sort
uniq
date
exit codes
logging
file validation
reject files
archive files


Stretch goals

After you finish basic version, add:

--dry-run
--date 20260624
--help

Example:

./process_daily_feed.sh --date 20260624 --dry-run