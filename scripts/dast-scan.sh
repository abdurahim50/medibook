#!/usr/bin/env bash
# Dynamic application security test (DAST): run the API container with the same
# hardening as production, sign in as a synthetic patient, and run the OWASP ZAP
# API scan against the OpenAPI definition, authenticated.
#
# Usage: scripts/dast-scan.sh <image> [report dir]
#   e.g. docker build -t medibook:dast . && scripts/dast-scan.sh medibook:dast
#
# Exit code: 0 no alerts; 1 or 2 alerts not accepted in .zap/rules.tsv; 3 scan error.
set -euo pipefail

IMAGE="${1:?usage: dast-scan.sh <image> [report dir]}"
OUT="${2:-zap-report}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ZAP 2.17.0, pinned by digest so a re-pushed tag cannot change what runs.
ZAP_IMAGE="ghcr.io/zaproxy/zaproxy:2.17.0@sha256:781a2bdaea47324e7bab583e2263f21d257b0aee61ed51521a5be45f5f5081ef"

# PostgreSQL for the scan, pinned by digest (same image as the CI test service).
POSTGRES_IMAGE="postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"

NET=medibook-dast
API=medibook-dast-api
DB=medibook-dast-db
TARGET="http://${API}:8000"

cleanup() {
	docker logs "$API" > "$OUT/api.log" 2>&1 || true
	docker rm -f "$API" "$DB" > /dev/null 2>&1 || true
	docker network rm "$NET" > /dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$OUT"
chmod 777 "$OUT" # ZAP runs as its own non-root user and writes reports here
cp "$ROOT/.zap/rules.tsv" "$OUT/rules.tsv"

# Synthetic data only: throwaway passwords for the scan database and the
# seeded demo patients. Secrets are exported and passed with "-e NAME" (no
# value), so they never appear in a process's command line.
export MEDIBOOK_SEED_PASSWORD="$(openssl rand -base64 18)"
export POSTGRES_PASSWORD="$(openssl rand -hex 16)"
export PGPASSWORD="$POSTGRES_PASSWORD"

docker network create "$NET" > /dev/null
docker run -d --name "$DB" --network "$NET" \
	-e POSTGRES_USER=medibook -e POSTGRES_DB=medibook -e POSTGRES_PASSWORD \
	"$POSTGRES_IMAGE" > /dev/null
echo "Waiting for PostgreSQL..."
for _ in $(seq 1 30); do
	docker exec "$DB" pg_isready -U medibook -d medibook > /dev/null 2>&1 && break
	sleep 1
done
docker exec "$DB" pg_isready -U medibook -d medibook > /dev/null

docker run -d --name "$API" --network "$NET" \
	--read-only --cap-drop ALL --security-opt no-new-privileges \
	-e MEDIBOOK_SEED_PASSWORD \
	-e PGHOST="$DB" -e PGUSER=medibook -e PGDATABASE=medibook -e PGPASSWORD \
	"$IMAGE" sh -c "python -m app.seed && exec uvicorn app.main:app --host 0.0.0.0 --port 8000" > /dev/null

echo "Waiting for the API..."
for _ in $(seq 1 30); do
	if docker exec "$API" python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)" 2> /dev/null; then
		break
	fi
	sleep 1
done
docker exec "$API" python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)" > /dev/null

# Sign in from inside the network: the API is not published on the host.
TOKEN="$(docker run --rm --network "$NET" -e MEDIBOOK_SEED_PASSWORD "$IMAGE" python -c "
import json, os, urllib.request
body = json.dumps({'email': 'alex.rivera@example.com', 'password': os.environ['MEDIBOOK_SEED_PASSWORD']}).encode()
req = urllib.request.Request('${TARGET}/auth/signin', data=body, headers={'Content-Type': 'application/json'})
print(json.load(urllib.request.urlopen(req, timeout=5))['access_token'])
")"
[[ -n "$TOKEN" ]] || { echo "Sign-in failed" >&2; exit 3; }
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::add-mask::${TOKEN}"; fi

# ZAP scans from a copy of the OpenAPI definition without /auth/signout:
# scanning sign-out would revoke the token and leave the rest of the scan
# unauthenticated. Sign-out is covered by the unit tests.
docker run --rm --network "$NET" "$IMAGE" python -c "
import json, urllib.request
spec = json.load(urllib.request.urlopen('${TARGET}/openapi.json', timeout=5))
spec['paths'].pop('/auth/signout', None)
spec['servers'] = [{'url': '${TARGET}'}]
print(json.dumps(spec))
" > "$OUT/openapi.json"

# ZAP sends the bearer token on every request to the API (ZAP_AUTH_HEADER_*).
export ZAP_AUTH_HEADER_VALUE="Bearer ${TOKEN}"
set +e
docker run --rm --network "$NET" -v "$(cd "$OUT" && pwd):/zap/wrk:rw" \
	-e ZAP_AUTH_HEADER_VALUE \
	-e ZAP_AUTH_HEADER_SITE="${API}" \
	"$ZAP_IMAGE" zap-api-scan.py \
	-t /zap/wrk/openapi.json -f openapi \
	-c rules.tsv \
	-r report.html -J report.json -w report.md
RC=$?
set -e

# A scan that silently lost its session would look clean, so prove it stayed
# authenticated: the audit log must show successful authenticated requests and
# no sign-out.
docker logs "$API" > "$OUT/api.log" 2>&1
authed=$(grep -c '"event":"appointment.list","outcome":"success"' "$OUT/api.log" || true)
signouts=$(grep -c '"event":"auth.signout"' "$OUT/api.log" || true)
echo "Authenticated list requests during scan: ${authed}; sign-outs: ${signouts}"
if [[ "$authed" -eq 0 || "$signouts" -ne 0 ]]; then
	echo "Scan was not authenticated throughout; results are incomplete." >&2
	exit 3
fi

case "$RC" in
	0) echo "ZAP: no alerts beyond those accepted in .zap/rules.tsv." ;;
	1 | 2) echo "ZAP: alerts found that are not accepted in .zap/rules.tsv. See $OUT/report.html." >&2 ;;
	*) echo "ZAP: scan error (exit $RC)." >&2 ;;
esac
exit "$RC"
