#!/usr/bin/env bash
# Ensures an hourly scheduled pipeline exists for the Dropbox sync, using the
# CircleCI v2 schedule API via the CircleCI CLI. Idempotent: creating the
# schedule is skipped when one by the same name already exists, so this can
# run on every pipeline without duplicating triggers.
#
# Requires CIRCLE_TOKEN, supplied from a CircleCI context so the credential
# only ever exists inside the ephemeral job.
set -euo pipefail

SCHEDULE_NAME="hourly-dropbox-sync"
PROJECT_SLUG="${PROJECT_SLUG:-github/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}}"

if [[ -z "${CIRCLE_TOKEN:-}" ]]; then
  echo "CIRCLE_TOKEN is not set - attach the context holding it to this job." >&2
  exit 1
fi

existing=$(circleci api "api/v2/project/${PROJECT_SLUG}/schedule" \
  --jq "[.items[] | select(.name == \"${SCHEDULE_NAME}\")] | length")

if [[ "$existing" != "0" ]]; then
  echo "Schedule '${SCHEDULE_NAME}' already exists for ${PROJECT_SLUG} - nothing to do."
  exit 0
fi

echo "Creating hourly schedule '${SCHEDULE_NAME}' for ${PROJECT_SLUG}..."
circleci api "api/v2/project/${PROJECT_SLUG}/schedule" -X POST -d '{
  "name": "'"${SCHEDULE_NAME}"'",
  "description": "Hourly S3 -> Dropbox sync",
  "attribution-actor": "system",
  "parameters": {
    "branch": "main",
    "run-sync": true
  },
  "timetable": {
    "per-hour": 1,
    "hours-of-day": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
    "days-of-week": ["MON","TUE","WED","THU","FRI","SAT","SUN"]
  }
}'

echo "Hourly schedule created."
