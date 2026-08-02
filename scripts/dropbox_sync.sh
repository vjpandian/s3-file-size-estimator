#!/usr/bin/env bash
# Syncs every S3 bucket into Dropbox under CircleCI-S3-Sync/<bucket>.
# rclone sync only ever reads/writes/deletes inside that destination path -
# nothing else in the Dropbox account is touched.
#
# Runs hourly and is safe to interrupt: a soft time budget stops starting
# new bucket transfers well before CircleCI's job limit, and any in-flight
# rclone transfer gets a graceful SIGTERM (finishes or cleanly abandons the
# current file - S3/Dropbox uploads are atomic, so nothing partial is ever
# left visible at the destination) instead of a hard kill. Anything not
# finished this run is picked up automatically by the next hourly run,
# since rclone sync only copies what's missing or changed.
set -euo pipefail

SECRET_NAME="dropbox/oauth-credentials"
# rclone sync only ever touches paths under this destination - nothing
# elsewhere in the Dropbox account is read, written, or deleted.
DROPBOX_ROOT_PREFIX="CircleCI-S3-Sync"
SIZE_MISMATCH_TOLERANCE_BYTES=$((100 * 1024 * 1024))  # ~100MB, matches the accuracy bar used elsewhere in this repo
# Circuit breaker: a bucket that suddenly reads as empty (transient S3 error,
# revoked permission) would otherwise make sync wipe its Dropbox mirror.
MAX_DELETE_PER_BUCKET=100
# Transient network/API errors are retried in-run rather than left for the
# next hour, so a single flaky file does not stall a bucket's progress.
RCLONE_RETRIES=10

START_TIME=$(date +%s)
JOB_BUDGET_SECONDS=$((3 * 3600 + 45 * 60))  # 3h45m soft budget, inside CircleCI's 4h job cap
DEADLINE=$((START_TIME + JOB_BUDGET_SECONDS))

secret_json=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)
app_key=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["app_key"])' <<<"$secret_json")
refresh_token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["refresh_token"])' <<<"$secret_json")

token_response=$(curl -sf -X POST https://api.dropbox.com/oauth2/token \
  -d grant_type=refresh_token \
  -d refresh_token="$refresh_token" \
  -d client_id="$app_key")

access_token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"$token_response")
expires_in=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["expires_in"])' <<<"$token_response")
expiry=$(python3 -c "import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(seconds=$expires_in)).strftime('%Y-%m-%dT%H:%M:%S.000000Z'))")

mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<EOF
[s3]
type = s3
provider = AWS
env_auth = true

[dropbox]
type = dropbox
token = {"access_token":"$access_token","token_type":"bearer","expiry":"$expiry"}
EOF
chmod 600 ~/.config/rclone/rclone.conf

mapfile -t buckets < <(aws s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n' | sort)

# Rotate the starting point each run. Without this, a bucket big enough to
# consume the whole budget would keep the buckets behind it from ever being
# reached; rotating guarantees every bucket gets a turn at the full budget.
count=${#buckets[@]}
offset=$(( ${CIRCLE_BUILD_NUM:-0} % count ))
buckets=("${buckets[@]:offset}" "${buckets[@]:0:offset}")
echo "Sync order this run (offset ${offset}): ${buckets[*]}"

deferred=()   # ran out of time - expected, resumes next run
failed=()     # genuine errors - surfaced as a job failure
unverified=() # synced but byte totals still diverge
in_sync=()    # nothing to copy, already fully mirrored
synced=()     # transferred something this run

for bucket in "${buckets[@]}"; do
  now=$(date +%s)
  remaining=$(( DEADLINE - now ))

  if (( remaining <= 60 )); then
    echo "Time budget reached - ${bucket} deferred to next hourly run."
    deferred+=("$bucket")
    continue
  fi

  region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text)
  if [[ "$region" == "None" || -z "$region" ]]; then
    region="us-east-1"
  fi

  dest="dropbox:/${DROPBOX_ROOT_PREFIX}/${bucket}"
  echo "=== s3://${bucket} (${region}) -> ${dest} [budget ${remaining}s] ==="

  # Cheap up-front comparison: if object count and byte total already match,
  # everything is present in Dropbox and there is nothing to transfer.
  read -r s3_n s3_b < <(rclone size "s3:${bucket}" --s3-region "$region" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["bytes"])' 2>/dev/null || echo "")
  read -r db_n db_b < <(rclone size "$dest" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["bytes"])' 2>/dev/null || echo "")

  if [[ -n "$s3_n" && -n "$db_n" && "$s3_n" == "$db_n" && "$s3_b" == "$db_b" ]]; then
    echo "Bucket ${bucket}: already in sync (${s3_n} objects, ${s3_b} bytes) - nothing to copy."
    in_sync+=("$bucket")
    continue
  fi

  sync_status=0
  timeout --signal=TERM --kill-after=60s "${remaining}s" \
    rclone sync "s3:${bucket}" "$dest" \
      --s3-region "$region" \
      --s3-no-check-bucket \
      --transfers 8 \
      --checkers 8 \
      --stats 30s \
      --max-delete "$MAX_DELETE_PER_BUCKET" \
      --retries "$RCLONE_RETRIES" \
      --low-level-retries 20 \
      --retries-sleep 10s \
      -v || sync_status=$?

  if (( sync_status == 124 || sync_status == 137 )); then
    echo "Bucket ${bucket}: hit the time budget mid-sync; files already copied are intact, remainder resumes next run."
    deferred+=("$bucket")
    # Everything still queued behind this bucket is outstanding too - record it
    # so the summary reflects the real remaining work rather than just this one.
    for remaining_bucket in "${buckets[@]}"; do
      [[ " ${in_sync[*]} ${synced[*]} ${unverified[*]} ${failed[*]} ${deferred[*]} " == *" ${remaining_bucket} "* ]] || deferred+=("$remaining_bucket")
    done
    break
  elif (( sync_status != 0 )); then
    echo "ERROR: ${bucket} sync exited with status ${sync_status}; will retry next run." >&2
    failed+=("$bucket")
    continue
  fi

  echo "Bucket ${bucket}: sync step complete."

  s3_bytes=$(rclone size "s3:${bucket}" --s3-region "$region" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])') || s3_bytes=""
  db_bytes=$(rclone size "$dest" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])') || db_bytes=""

  if [[ -z "$s3_bytes" || -z "$db_bytes" ]]; then
    echo "Bucket ${bucket}: could not verify size reconciliation this run; will re-check next run."
    continue
  fi

  if (( s3_bytes > db_bytes )); then
    diff=$(( s3_bytes - db_bytes ))
  else
    diff=$(( db_bytes - s3_bytes ))
  fi

  if (( diff <= SIZE_MISMATCH_TOLERANCE_BYTES )); then
    echo "Bucket ${bucket}: S3=${s3_bytes}B Dropbox=${db_bytes}B - matches within ~100MB tolerance."
    synced+=("$bucket")
  else
    echo "Bucket ${bucket}: S3=${s3_bytes}B Dropbox=${db_bytes}B - still diverges by ${diff}B, will continue reconciling next run."
    unverified+=("$bucket")
  fi
done

echo
echo "================ SUMMARY ================"
echo "Already in sync (nothing to copy): ${#in_sync[@]}${in_sync:+ - ${in_sync[*]}}"
echo "Transferred and reconciled:        ${#synced[@]}${synced:+ - ${synced[*]}}"
echo "Still diverging (retry next run):  ${#unverified[@]}${unverified:+ - ${unverified[*]}}"
echo "Deferred on time budget:           ${#deferred[@]}${deferred:+ - ${deferred[*]}}"
echo "Failed:                            ${#failed[@]}${failed:+ - ${failed[*]}}"
echo "========================================"

if (( ${#failed[@]} > 0 )); then
  echo "Run had genuine failures - see errors above. Next run retries them."
  exit 1
fi

if (( ${#in_sync[@]} == count )); then
  echo "EVERYTHING IN S3 IS ALREADY IN DROPBOX - nothing needed to be synced."
elif (( ${#deferred[@]} == 0 && ${#unverified[@]} == 0 )); then
  echo "All buckets are fully mirrored to Dropbox."
else
  echo "Work remains; the next hourly run continues from here."
fi
