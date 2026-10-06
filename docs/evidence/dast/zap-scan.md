# DAST: OWASP ZAP API scan

Date: 2026-10-06 (America/Chicago). All data synthetic.

## What runs

[`scripts/dast-scan.sh`](../../../scripts/dast-scan.sh), locally and in the CI `DAST` job on every pull request:

1. Starts the API image with production hardening (read-only root filesystem, all capabilities dropped, `no-new-privileges`), seeded with synthetic patients and a random throwaway password.
2. Signs in as a synthetic patient. ZAP sends the bearer token on every request, so endpoints behind authentication are tested, not only their `401` responses.
3. Runs the ZAP 2.17.0 API scan (image pinned by digest) against the OpenAPI definition: passive checks plus active attacks (SQL injection, XSS, path traversal, command injection, SSTI, Log4Shell and others).
4. Fails on any alert not accepted in [`.zap/rules.tsv`](../../../.zap/rules.tsv) (none are accepted).
5. Checks the API's audit log to prove the scan stayed authenticated, and fails if it did not.

## Run 1: findings

```
WARN-NEW: X-Content-Type-Options Header Missing [10021] x 2
        http://medibook-dast-api:8000/openapi.json (200 OK)
        http://medibook-dast-api:8000/health (200 OK)
WARN-NEW: Cross-Origin-Resource-Policy Header Missing or Invalid [90004] x 3
        http://medibook-dast-api:8000/openapi.json (200 OK)
        http://medibook-dast-api:8000/health (200 OK)
        http://medibook-dast-api:8000/auth/signout (204 No Content)
FAIL-NEW: 0  WARN-NEW: 2  PASS: 116
exit code: 2
```

| Finding | Risk | Fix |
| --- | --- | --- |
| No `X-Content-Type-Options` | A browser may interpret a response as a different content type (MIME sniffing) | `nosniff` on every response |
| No `Cross-Origin-Resource-Policy` | Other origins can load responses into their pages (cross-origin leaks, Spectre-class side channels) | `same-origin` on every response |

The API also lacked headers ZAP does not flag on JSON but OWASP REST Security guidance recommends for an API returning patient data. All are now set by one middleware in [`app/main.py`](../../../app/main.py), including error responses:

| Header | Value |
| --- | --- |
| `X-Content-Type-Options` | `nosniff` |
| `Cache-Control` | `no-store` (appointment data must not be cached by browsers or proxies) |
| `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'` (API docs get a policy that allows Swagger UI's CDN) |
| `X-Frame-Options` | `DENY` |
| `Cross-Origin-Resource-Policy` | `same-origin` |
| `Referrer-Policy` | `no-referrer` |

Regression tests: [`tests/test_security_headers.py`](../../../tests/test_security_headers.py) (4 tests, including `401`, `404` and `422` responses).

## Finding in the scan itself: session lost mid-scan

Run 1 listed `/auth/signout (204 No Content)`: ZAP had called sign-out with the scan's token, revoking it. Every later request ran unauthenticated, so most of the API was only tested for its `401` response. Run 1's 116 passes overstated the coverage. A ZAP URL-exclusion setting intended to prevent this did not take effect.

**Fix.** ZAP now scans from a copy of the OpenAPI definition with `/auth/signout` removed (sign-out is covered by unit tests). After the scan, the script counts authenticated requests and sign-outs in the API's audit log and exits with an error if the session was lost, so this cannot silently recur.

## Run 2: clean and authenticated

```
FAIL-NEW: 0  WARN-NEW: 0  INFO: 0  IGNORE: 0  PASS: 118
Authenticated list requests during scan: 2; sign-outs: 0
ZAP: no alerts beyond those accepted in .zap/rules.tsv.
exit code: 0
```

## Limitations

- **Scan target is a local container, not AWS.** The edge controls (ALB, WAF) are not in the path; the scan tests the application. Scanning the deployed environment is a separate, scheduled activity.
- **One identity.** ZAP scans as one patient. Cross-patient access (TM-01) is covered by targeted tests, not by ZAP, which does not know which records belong to whom.
- **Sign-out is not scanned** (see above).
- **Default scan policy.** No custom attack strength or thresholds; tuning is a follow-up if scan time or false positives grow.
