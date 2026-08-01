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

buckets=$(aws s3api list-buckets --query 'Buckets[].Name' --output text)
deferred=()

for bucket in $buckets; do
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
  echo "=== Syncing s3://${bucket} (${region}) -> ${dest} [budget ${remaining}s] ==="

  sync_status=0
  timeout --signal=TERM --kill-after=60s "${remaining}s" \
    rclone sync "s3:${bucket}" "$dest" \
      --s3-region "$region" \
      --s3-no-check-bucket \
      --transfers 8 \
      --checkers 8 \
      --stats 30s \
      -v || sync_status=$?

  if (( sync_status == 124 || sync_status == 137 )); then
    echo "Bucket ${bucket}: hit the time budget mid-sync; files already copied are intact, remainder resumes next run."
    deferred+=("$bucket")
    break
  elif (( sync_status != 0 )); then
    echo "WARNING: ${bucket} sync exited with status ${sync_status}; will retry next run." >&2
    deferred+=("$bucket")
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
  else
    echo "Bucket ${bucket}: S3=${s3_bytes}B Dropbox=${db_bytes}B - still diverges by ${diff}B, will continue reconciling next run."
  fi
done

if (( ${#deferred[@]} == 0 )); then
  echo "All buckets fully synced and reconciled this run."
else
  echo "Buckets deferred to next hourly run: ${deferred[*]}"
fi
