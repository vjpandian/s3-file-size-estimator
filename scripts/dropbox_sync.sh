#!/usr/bin/env bash
# Syncs every S3 bucket in the account into Dropbox, one folder per bucket.
# Reads the Dropbox app_key + refresh_token from AWS Secrets Manager and
# exchanges them for a short-lived access token at the start of each run,
# so no long-lived Dropbox credential is ever written to disk.
set -euo pipefail

SECRET_NAME="dropbox/oauth-credentials"
DROPBOX_ROOT_PREFIX="s3-sync"

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

for bucket in $buckets; do
  region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text)
  if [ "$region" = "None" ] || [ -z "$region" ]; then
    region="us-east-1"
  fi

  echo "=== Syncing s3://${bucket} (${region}) -> dropbox:/${DROPBOX_ROOT_PREFIX}/${bucket} ==="
  rclone sync "s3:${bucket}" "dropbox:/${DROPBOX_ROOT_PREFIX}/${bucket}" \
    --s3-region "$region" \
    --s3-no-check-bucket \
    --transfers 8 \
    --checkers 8 \
    --stats 30s \
    -v
done
