#!/usr/bin/env bash
# Deploy one commit to one environment, run the task graph once, then run the checks.
# Usage: ci/deploy.sh DEV|QA|PRD <40-character commit SHA>
# Connection settings come from SNOWFLAKE_* environment variables (snow sql -x).
set -euo pipefail

ENVIRONMENT="${1:-}"
COMMIT_SHA="${2:-}"
ACTOR="${GITHUB_ACTOR:-local}"
REPO="PLATFORM.GIT.ANALYTICS_REPO"

fail() { echo "FAIL: $1" >&2; exit "${2:-1}"; }

[[ "$ENVIRONMENT" =~ ^(DEV|QA|PRD)$ ]] || fail "environment must be DEV, QA or PRD" 2
[[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "a full 40-character lowercase commit SHA is required" 2
[[ "$ACTOR" =~ ^[A-Za-z0-9._-]+$ ]] || fail "unexpected actor name" 2

DATABASE="ANALYTICS_${ENVIRONMENT}"
SOURCE="@${REPO}/commits/${COMMIT_SHA}"

sql() { snow sql -x --format json -q "$1"; }

echo "Fetching ${COMMIT_SHA:0:7} into ${REPO}"
sql "ALTER GIT REPOSITORY ${REPO} FETCH" >/dev/null

echo "Deploying ${COMMIT_SHA:0:7} to ${DATABASE}"
sql "EXECUTE IMMEDIATE FROM ${SOURCE}/pipelines/deploy.sql
     USING (env => '${ENVIRONMENT}', commit_sha => '${COMMIT_SHA}', actor => '${ACTOR}')" >/dev/null

echo "Running the task graph once"
started=$(sql "SELECT DATE_PART(EPOCH_MILLISECOND, CURRENT_TIMESTAMP()) AS T" | jq -r '.[0].T')
sql "EXECUTE TASK ${DATABASE}.OPS.PIPELINE_ROOT" >/dev/null
state=""
for _ in $(seq 1 60); do
  sleep 5
  state=$(sql "SELECT STATE FROM TABLE(${DATABASE}.INFORMATION_SCHEMA.COMPLETE_TASK_GRAPHS(
                 ROOT_TASK_NAME => 'PIPELINE_ROOT'))
               WHERE DATE_PART(EPOCH_MILLISECOND, SCHEDULED_TIME) >= ${started}
               ORDER BY SCHEDULED_TIME DESC LIMIT 1" | jq -r '.[0].STATE // empty')
  [[ -n "$state" ]] && break
done
[[ "$state" == "SUCCEEDED" ]] || fail "task graph ended as '${state:-still running after 5 minutes}'"

echo "Running checks"
failures=$(sql "EXECUTE IMMEDIATE FROM ${SOURCE}/checks/pipeline_checks.sql
                USING (env => '${ENVIRONMENT}', commit_sha => '${COMMIT_SHA}')")
if [[ "$(jq 'length' <<<"$failures")" != "0" ]]; then
  jq . <<<"$failures"
  fail "checks failed in ${DATABASE}"
fi

echo "PASS: ${COMMIT_SHA:0:7} deployed and verified in ${DATABASE}"
