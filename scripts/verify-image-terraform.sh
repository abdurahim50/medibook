#!/usr/bin/env bash
# Terraform external data source (infra/ecs.tf): verify an image's signature and
# SBOM attestation during plan. Terraform sends a JSON query on stdin and expects
# a JSON object of strings on stdout; any non-zero exit fails the plan, and
# stderr is shown as the reason.
set -euo pipefail

QUERY="$(cat)"
DIGEST="$(jq -r '.digest' <<< "$QUERY")"
PROFILE="$(jq -r '.profile' <<< "$QUERY")"
if [[ -n "$PROFILE" ]]; then export AWS_PROFILE="$PROFILE"; else unset AWS_PROFILE; fi
export AWS_REGION="$(jq -r '.region' <<< "$QUERY")"

command -v cosign > /dev/null || { echo "cosign is required to deploy (signature verification); see docs/deployment.md" >&2; exit 1; }

# verify-image.sh writes its report to stdout; send it to stderr so stdout
# carries only the JSON result.
"$(dirname "${BASH_SOURCE[0]}")/verify-image.sh" "$DIGEST" >&2

jq -n --arg digest "$DIGEST" '{verified: "true", digest: $digest}'
