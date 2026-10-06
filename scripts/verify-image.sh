#!/usr/bin/env bash
# Verify that an image digest was built and signed by this repository's release
# workflow on main, and carries its SBOM attestation, before deploying it.
#
# Usage: scripts/verify-image.sh sha256:<digest>
# Requires: aws CLI (signed in), cosign, docker (for registry login)
set -euo pipefail

DIGEST="${1:?usage: scripts/verify-image.sh sha256:<digest>}"
[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "Not a sha256 digest: $DIGEST" >&2; exit 2; }

REGION="${AWS_REGION:-us-east-1}"
REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${REGION}.amazonaws.com"
REF="${REGISTRY}/medibook/api@${DIGEST}"
IDENTITY="https://github.com/abdurahim50/medibook/.github/workflows/release.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" > /dev/null
trap 'docker logout "$REGISTRY" > /dev/null' EXIT

cosign verify --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" "$REF" > /dev/null
cosign verify-attestation --type cyclonedx --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" "$REF" > /dev/null

echo "OK: ${DIGEST} was signed by release.yml on main and has a CycloneDX SBOM attestation."
