#!/usr/bin/env bash
# Answers "is the S3 -> Dropbox mirror finished yet?" without needing CI logs.
# Reads the verification state the sync writes to Dropbox, plus live bucket
# sizes from S3, and prints a per-bucket comparison. Read-only throughout.
set -euo pipefail

DROPBOX_ROOT_PREFIX="CircleCI-S3-Sync"
SECRET_NAME="dropbox/oauth-credentials"

secret_json=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)
app_key=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["app_key"])' <<<"$secret_json")
refresh_token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["refresh_token"])' <<<"$secret_json")
ACCESS_TOKEN=$(curl -sf -X POST https://api.dropbox.com/oauth2/token \
  -d grant_type=refresh_token -d refresh_token="$refresh_token" -d client_id="$app_key" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
export ACCESS_TOKEN DROPBOX_ROOT_PREFIX

python3 <<'PY'
import json, os, urllib.request, urllib.error

TOKEN = os.environ["ACCESS_TOKEN"]
ROOT = "/" + os.environ["DROPBOX_ROOT_PREFIX"]

def rpc(path, payload):
    req = urllib.request.Request("https://api.dropboxapi.com/2/" + path,
        data=json.dumps(payload).encode() if payload is not None else None, method="POST")
    req.add_header("Authorization", "Bearer " + TOKEN)
    if payload is not None:
        req.add_header("Content-Type", "application/json")
    return json.loads(urllib.request.urlopen(req).read())

def download(path):
    req = urllib.request.Request("https://content.dropboxapi.com/2/files/download", method="POST")
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Dropbox-API-Arg", json.dumps({"path": path}))
    return urllib.request.urlopen(req).read().decode()

usage = rpc("users/get_space_usage", None)
print(f"Dropbox used: {usage['used']/1024**3:.2f} GB\n")

try:
    state_raw = download(f"{ROOT}/_verification/state.tsv")
except urllib.error.HTTPError:
    state_raw = ""

state = {}
for line in state_raw.splitlines():
    parts = line.split("\t")
    if len(parts) >= 6:
        state[parts[0]] = parts[1:]

if not state:
    print("No verification state yet - the sync has not completed a verified bucket.")
    print("(State appears once a run on the verification-enabled code finishes a bucket.)")
else:
    print(f"{'BUCKET':<50} {'STATUS':<14} {'OBJECTS':>9} {'MISSING':>8} {'LAST CHECKED':>21}")
    print("-" * 105)
    all_ok = True
    for b in sorted(state):
        st, obj, mis, dif, ts = state[b][0], state[b][1], state[b][2], state[b][3], state[b][4]
        print(f"{b:<50} {st:<14} {obj:>9} {mis:>8} {ts:>21}")
        if st != "VERIFIED":
            all_ok = False
    print("-" * 105)
    print()
    print("CONFIRMED: every S3 object exists in Dropbox." if all_ok
          else "NOT YET COMPLETE - buckets above without VERIFIED are still in progress.")
PY
