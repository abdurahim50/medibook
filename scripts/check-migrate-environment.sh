#!/usr/bin/env bash
# Refuse to run a migration unless its GitHub environment still enforces the
# approval gate (finding F-17). The AWS migration role trusts any job in the
# environment; whether that job needs an approval is a GitHub setting, not code,
# and it was once missing. Runs before the job assumes the AWS role, so a job in a
# misconfigured environment never receives credentials.
#
# Usage: scripts/check-migrate-environment.sh [environment]   (default migrate-dev)
# Requires: gh (GH_TOKEN with actions: read), jq, GITHUB_REPOSITORY=owner/repo
# Tests pass the API responses as files: ENV_JSON_FILE, POLICIES_JSON_FILE.
set -euo pipefail

ENVIRONMENT="${1:-migrate-dev}"
if [[ -n "${ENV_JSON_FILE:-}" ]]; then
  env_json="$(cat "$ENV_JSON_FILE")"
  policies_json="$(cat "$POLICIES_JSON_FILE")"
else
  base="repos/${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}/environments/${ENVIRONMENT}"
  env_json="$(gh api "$base")"
  policies_json="$(gh api "$base/deployment-branch-policies")"
fi

failures=()

reviewers="$(jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length' <<<"$env_json")"
(( reviewers >= 1 )) || failures+=("no required reviewers: jobs would run without an approval")

[[ "$(jq -r '.can_admins_bypass' <<<"$env_json")" == "false" ]] \
  || failures+=("administrators can bypass the approval")

custom="$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<<"$env_json")"
branches="$(jq -c '[.branch_policies[]? | {name, type: (.type // "branch")}]' <<<"$policies_json")"
if [[ "$custom" != "true" || "$branches" != '[{"name":"main","type":"branch"}]' ]]; then
  failures+=("deployments are not limited to the main branch")
fi

if (( ${#failures[@]} )); then
  for f in "${failures[@]}"; do echo "FAIL: ${ENVIRONMENT}: ${f}" >&2; done
  echo "Fix the environment in GitHub (Settings, Environments, ${ENVIRONMENT}); see docs/deployment.md." >&2
  exit 1
fi
echo "OK: ${ENVIRONMENT} requires ${reviewers} reviewer(s), no administrator bypass, main only."
