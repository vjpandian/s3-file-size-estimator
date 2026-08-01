#!/usr/bin/env python3
"""One-time, LOCAL-ONLY setup: authorize a Dropbox app via OAuth2 + PKCE and
store the resulting long-lived refresh token in AWS Secrets Manager.

Do not run this in CI - it requires you to interactively approve access in
a browser. Run it once from your machine; CI jobs then read the stored
refresh token from Secrets Manager and exchange it for short-lived access
tokens on every run (no browser, no expiry issues).

Prerequisites:
  1. Create an app at https://www.dropbox.com/developers/apps
     - Choose "Scoped access" and the access type you need (Full Dropbox
       vs App folder).
     - Under the app's Permissions tab, enable the scopes it needs, e.g.
       files.content.write, files.content.read, files.metadata.read.
  2. Have the AWS CLI configured with credentials that can write to
     Secrets Manager (the same profile used elsewhere in this repo).

Usage:
  python3 scripts/dropbox_oauth_setup.py --app-key <YOUR_APP_KEY>
"""

import argparse
import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

AUTHORIZE_URL = "https://www.dropbox.com/oauth2/authorize"
TOKEN_URL = "https://api.dropbox.com/oauth2/token"
ACCOUNT_URL = "https://api.dropboxapi.com/2/users/get_current_account"


def make_pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def request_json(url: str, data: dict) -> dict:
    body = urllib.parse.urlencode(data).encode("ascii")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        print(f"Dropbox request failed ({exc.code}): {exc.read().decode()}", file=sys.stderr)
        raise


def get_current_account_email(access_token: str) -> str:
    req = urllib.request.Request(ACCOUNT_URL, method="POST")
    req.add_header("Authorization", f"Bearer {access_token}")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["email"]


def store_in_secrets_manager(secret_name: str, region: str, payload: dict) -> None:
    fd, path = tempfile.mkstemp(suffix=".json")
    try:
        os.chmod(path, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)

        create = subprocess.run(
            [
                "aws", "secretsmanager", "create-secret",
                "--name", secret_name,
                "--secret-string", f"file://{path}",
                *(["--region", region] if region else []),
            ],
            capture_output=True, text=True,
        )
        if create.returncode == 0:
            print(create.stdout)
            return

        if "ResourceExistsException" in create.stderr:
            update = subprocess.run(
                [
                    "aws", "secretsmanager", "put-secret-value",
                    "--secret-id", secret_name,
                    "--secret-string", f"file://{path}",
                    *(["--region", region] if region else []),
                ],
                capture_output=True, text=True, check=True,
            )
            print(update.stdout)
        else:
            print(create.stderr, file=sys.stderr)
            create.check_returncode()
    finally:
        os.remove(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-key", required=True, help="Dropbox app key from the App Console")
    parser.add_argument("--secret-name", default="dropbox/oauth-credentials")
    parser.add_argument("--region", default=None, help="AWS region (defaults to your AWS CLI config)")
    args = parser.parse_args()

    verifier, challenge = make_pkce_pair()

    authorize_params = {
        "client_id": args.app_key,
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "token_access_type": "offline",
    }
    authorize_url = f"{AUTHORIZE_URL}?{urllib.parse.urlencode(authorize_params)}"

    print("Opening Dropbox authorization page in your browser...")
    print(f"If it doesn't open automatically, visit:\n  {authorize_url}\n")
    webbrowser.open(authorize_url)

    auth_code = input("After approving access, paste the code Dropbox shows you: ").strip()

    token_response = request_json(TOKEN_URL, {
        "code": auth_code,
        "grant_type": "authorization_code",
        "client_id": args.app_key,
        "code_verifier": verifier,
    })

    access_token = token_response["access_token"]
    refresh_token = token_response.get("refresh_token")
    if not refresh_token:
        print("No refresh_token in response - token_access_type=offline may not have been honored.", file=sys.stderr)
        return 1

    email = get_current_account_email(access_token)
    print(f"Authorized as: {email}")

    store_in_secrets_manager(args.secret_name, args.region, {
        "app_key": args.app_key,
        "refresh_token": refresh_token,
    })
    print(f"Stored app_key + refresh_token in Secrets Manager as '{args.secret_name}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
