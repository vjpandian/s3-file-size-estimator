#!/usr/bin/env bash
# Exchanges CircleCI's OIDC token for short-lived AWS credentials.
# No static AWS keys exist anywhere in this pipeline: the token is minted
# per-job by CircleCI, and the role it maps to is read-only on S3.
set -euo pipefail

AWS_ROLE_ARN="${AWS_ROLE_ARN:?AWS_ROLE_ARN must be set}"
: "${CIRCLE_OIDC_TOKEN_V2:?CIRCLE_OIDC_TOKEN_V2 is not available - OIDC is not enabled for this job}"

creds=$(aws sts assume-role-with-web-identity \
  --role-arn "$AWS_ROLE_ARN" \
  --role-session-name "circleci-${CIRCLE_WORKFLOW_ID:-local}" \
  --web-identity-token "$CIRCLE_OIDC_TOKEN_V2" \
  --duration-seconds 14400 \
  --query 'Credentials' --output json)

python3 - "$creds" >> "$BASH_ENV" <<'EOF'
import json, sys
c = json.loads(sys.argv[1])
print(f'export AWS_ACCESS_KEY_ID={c["AccessKeyId"]}')
print(f'export AWS_SECRET_ACCESS_KEY={c["SecretAccessKey"]}')
print(f'export AWS_SESSION_TOKEN={c["SessionToken"]}')
EOF

# shellcheck disable=SC1090
source "$BASH_ENV"
echo "Assumed role as: $(aws sts get-caller-identity --query Arn --output text)"
