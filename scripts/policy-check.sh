#!/usr/bin/env bash
# Check a saved Terraform plan against the policies in policy/terraform before
# applying it. Run from the stack directory that produced the plan.
#
# Usage: ../scripts/policy-check.sh service.tfplan        (from infra/)
#        ../../scripts/policy-check.sh bootstrap.tfplan   (from infra/bootstrap/)
# Requires: terraform, conftest
set -euo pipefail

PLAN="${1:?usage: policy-check.sh <saved plan file>}"
[[ -f "$PLAN" ]] || { echo "No such plan file: $PLAN" >&2; exit 2; }
POLICY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/policy/terraform"

# The JSON form of a plan contains sensitive values in plain text (for example
# the alert email), so it is written outside the repository, readable only by
# the current user, and deleted on exit.
JSON="$(mktemp --suffix=.plan.json)"
chmod 600 "$JSON"
trap 'rm -f "$JSON"' EXIT

terraform show -json "$PLAN" > "$JSON"
conftest test --parser json --policy "$POLICY" "$JSON"
