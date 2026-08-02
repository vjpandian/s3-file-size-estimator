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
# Parallelism. Overridable so the box size and these can be tuned together;
# Dropbox rate-limits aggressively, and rclone backs off on 429 rather than
# failing, so pushing this too high trades throughput for retry churn.
TRANSFERS="${RCLONE_TRANSFERS:-16}"
CHECKERS="${RCLONE_CHECKERS:-32}"
# rclone's default Dropbox encoding leaves : | < > " ? * untouched, and Dropbox
# rejects those outright - such keys would fail every run forever and the
# mirror would never converge. Encoding them to full-width equivalents makes
# the upload succeed; the mapping is deterministic, so repeat runs still match.
DROPBOX_ENCODING="Slash,BackSlash,Del,RightSpace,InvalidUtf8,Dot,Colon,Question,Asterisk,Pipe,LtGt,DoubleQuote"

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

# Verification state lives in Dropbox alongside the mirror but OUTSIDE any
# bucket destination, so no rclone sync ever touches it. It carries per-bucket
# verification results across runs, which is what makes "everything is
# confirmed copied" a statement about all buckets rather than just this run's.
VERIFY_DIR="_verification"
STATE_REMOTE="dropbox:/${DROPBOX_ROOT_PREFIX}/${VERIFY_DIR}/state.tsv"
STATE_LOCAL="/tmp/verify_state.tsv"

rclone copyto "$STATE_REMOTE" "$STATE_LOCAL" --dropbox-encoding "$DROPBOX_ENCODING" >/dev/null 2>&1 || : > "$STATE_LOCAL"
[[ -f "$STATE_LOCAL" ]] || : > "$STATE_LOCAL"

# bucket <tab> status <tab> objects <tab> missing <tab> differ <tab> timestamp
record_state() {
  local b="$1" status="$2" objects="$3" missing="$4" differ="$5"
  grep -v "^${b}	" "$STATE_LOCAL" > "${STATE_LOCAL}.tmp" 2>/dev/null || true
  mv "${STATE_LOCAL}.tmp" "$STATE_LOCAL"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$b" "$status" "$objects" "$missing" "$differ" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_LOCAL"
}

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

  # Snapshot the destination first so we can tell afterwards whether this run
  # actually had to move anything. Deliberately NOT used to skip the sync: a
  # file edited in place at the same byte size would leave count and total
  # unchanged, and skipping on that basis would strand the stale copy in
  # Dropbox forever. rclone's own modtime+size comparison catches that, so it
  # always runs and decides for itself what needs transferring.
  read -r db_n_before db_b_before < <(rclone size "$dest" --dropbox-encoding "$DROPBOX_ENCODING" --json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["count"], d["bytes"])' 2>/dev/null || echo "0 0")

  sync_status=0
  timeout --signal=TERM --kill-after=60s "${remaining}s" \
    rclone sync "s3:${bucket}" "$dest" \
      --s3-region "$region" \
      --s3-no-check-bucket \
      --transfers "$TRANSFERS" \
      --checkers "$CHECKERS" \
      --stats 30s \
      --max-delete "$MAX_DELETE_PER_BUCKET" \
      --dropbox-encoding "$DROPBOX_ENCODING" \
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

  # Per-file verification: every object in S3 must exist in Dropbox at the same
  # size. --one-way ignores extra files on the Dropbox side; --size-only is
  # required because S3 (MD5) and Dropbox (its own content hash) use different
  # algorithms, so a cross-backend hash comparison is not possible. rclone
  # check reads both sides and alters neither.
  missing_file="/tmp/missing_${bucket}.txt"
  differ_file="/tmp/differ_${bucket}.txt"
  : > "$missing_file"; : > "$differ_file"

  rclone check "s3:${bucket}" "$dest" \
    --one-way \
    --size-only \
    --s3-region "$region" \
    --dropbox-encoding "$DROPBOX_ENCODING" \
    --checkers "$CHECKERS" \
    --missing-on-dst "$missing_file" \
    --differ "$differ_file" \
    >/dev/null 2>&1 || true

  n_missing=$(wc -l < "$missing_file" | tr -d ' ')
  n_differ=$(wc -l < "$differ_file" | tr -d ' ')
  n_source=$(rclone size "s3:${bucket}" --s3-region "$region" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo "?")

  if (( n_missing == 0 && n_differ == 0 )); then
    echo "Bucket ${bucket}: VERIFIED - all ${n_source} S3 objects present in Dropbox at matching size."
    record_state "$bucket" VERIFIED "$n_source" 0 0
    if [[ "${db_b_before}" == "$(rclone size "$dest" --dropbox-encoding "$DROPBOX_ENCODING" --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])' 2>/dev/null)" ]]; then
      echo "Bucket ${bucket}: nothing needed to be copied this run."
      in_sync+=("$bucket")
    else
      synced+=("$bucket")
    fi
  else
    echo "Bucket ${bucket}: NOT YET VERIFIED - ${n_missing} missing, ${n_differ} size-mismatched (of ${n_source}). Next run retries them."
    echo "  first few missing:"; head -5 "$missing_file" | sed 's/^/    /'
    # Keep the outstanding list in Dropbox so it is inspectable between runs.
    rclone copyto "$missing_file" "dropbox:/${DROPBOX_ROOT_PREFIX}/${VERIFY_DIR}/missing-${bucket}.txt" \
      --dropbox-encoding "$DROPBOX_ENCODING" >/dev/null 2>&1 || true
    record_state "$bucket" INCOMPLETE "$n_source" "$n_missing" "$n_differ"
    unverified+=("$bucket")
  fi
done

# Persist verification state for the next run before reporting.
rclone copyto "$STATE_LOCAL" "$STATE_REMOTE" --dropbox-encoding "$DROPBOX_ENCODING" >/dev/null 2>&1 \
  || echo "WARNING: could not persist verification state to Dropbox." >&2

echo
echo "============== THIS RUN =================="
echo "Nothing to copy:   ${#in_sync[@]}${in_sync:+ - ${in_sync[*]}}"
echo "Transferred:       ${#synced[@]}${synced:+ - ${synced[*]}}"
echo "Not yet verified:  ${#unverified[@]}${unverified:+ - ${unverified[*]}}"
echo "Deferred on time:  ${#deferred[@]}${deferred:+ - ${deferred[*]}}"
echo "Failed:            ${#failed[@]}${failed:+ - ${failed[*]}}"

echo
echo "======= CUMULATIVE VERIFICATION (all runs) ======="
printf '%-50s %-12s %10s %9s %8s\n' BUCKET STATUS OBJECTS MISSING DIFFER
all_verified=1
for b in $(printf '%s\n' "${buckets[@]}" | sort); do
  line=$(grep "^${b}	" "$STATE_LOCAL" 2>/dev/null || true)
  if [[ -z "$line" ]]; then
    printf '%-50s %-12s %10s %9s %8s\n' "$b" NEVER-CHECKED - - -
    all_verified=0
  else
    IFS=$'\t' read -r _ st obj mis dif _ts <<<"$line"
    printf '%-50s %-12s %10s %9s %8s\n' "$b" "$st" "$obj" "$mis" "$dif"
    [[ "$st" == "VERIFIED" ]] || all_verified=0
  fi
done
echo "=================================================="

if (( all_verified == 1 )); then
  echo
  echo "CONFIRMED: every object in every S3 bucket exists in Dropbox at a matching size."
else
  echo
  echo "NOT YET FULLY CONFIRMED - buckets above without VERIFIED status are still"
  echo "being worked through. State carries over, so each run advances the total."
fi

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
