# Security

## Reporting a vulnerability

Please do not open a public issue. Report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository. Include the affected endpoint, steps to reproduce and the impact you observed.

## Security model

| Area | Control |
| --- | --- |
| Identity | Patient identity is derived only from the session token, never from request data |
| Authorization | Every appointment query is scoped to the signed-in patient; records owned by others return `404` |
| Passwords | argon2id hashing; minimum length 12; plaintext never stored or returned |
| Sessions | 256-bit random tokens; only a SHA-256 digest is stored; 8-hour expiry; revoked on sign-out |
| Sign-in | Identical error for unknown email and wrong password, to prevent account enumeration |
| Sign-in throttling | Failed sign-ins limited per account (5) and per client (20) in a 15-minute window; further attempts return `429` |
| Input validation | Strict typing, length limits and rejection of unknown fields on every request body |
| Data integrity | Foreign keys enforced; `UNIQUE(slot_id)` prevents double booking, including under concurrent requests |
| Database access | Parameterised queries only |
| Secrets | No credentials in the repository; `.env` files are git-ignored |
| Audit logging | JSON audit events for sign-in, booking and appointment access, containing identifiers only; cross-patient attempts logged as `denied` |
| Container | Non-root user, read-only root filesystem, capabilities dropped, base image pinned by digest, image scanned in CI |
| Delivery pipeline | Every change to `main` goes through a pull request that must pass tests, SAST, dependency and secret scans |
| Data minimisation | No symptoms, diagnoses, date of birth, insurance or payment data collected |

## Known issues

| ID | Severity | Summary | Status |
| --- | --- | --- | --- |
| MB-001 | High | `GET /appointments/{id}` checked that the caller was signed in but not that they owned the appointment, so a signed-in patient could read another patient's booking by ID (broken object-level authorization). | **Fixed.** Lookup is scoped to the session's patient; other patients' IDs return `404`. Covered by a regression test. |
| MB-002 | Medium | `/auth/signin` accepted unlimited attempts, allowing online password guessing and credential stuffing. | **Fixed.** Failed sign-ins are throttled per account and per client; blocked attempts return `429` and are audited. |
| MB-003 | Medium | No record of sign-in, booking or appointment access, so probing and misuse went unnoticed. | **Fixed.** Structured audit log with request IDs; cross-patient attempts are logged as `denied`. |

## Limitations

- SQLite is used locally and in the AWS dev environment; data on a replaced task is lost. A managed database (RDS PostgreSQL) is planned for production.
- Sign-in throttling is held in memory per container; the shared control across containers is the edge rate limit. A throttle can be triggered on another patient's account for up to 15 minutes.
- Audit events go to CloudWatch Logs (7-day retention in dev). An alarm fires on 5 or more denied requests in 5 minutes.
- Unfixed operating-system CVEs in the base image are triaged in [docs/vulnerability-exceptions.md](docs/vulnerability-exceptions.md).
- Email format is checked with a pattern, not verified by confirmation email.
