# Security

## Reporting a vulnerability

Please do not open a public issue. Report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository. Include the affected endpoint, steps to reproduce and the impact you observed.

## Security model

| Area | Control |
| --- | --- |
| Identity | Patient identity is derived only from the session token, never from request data |
| Passwords | argon2id hashing; minimum length 12; plaintext never stored or returned |
| Sessions | 256-bit random tokens; only a SHA-256 digest is stored; 8-hour expiry; revoked on sign-out |
| Sign-in | Identical error for unknown email and wrong password, to prevent account enumeration |
| Input validation | Strict typing, length limits and rejection of unknown fields on every request body |
| Data integrity | Foreign keys enforced; `UNIQUE(slot_id)` prevents double booking, including under concurrent requests |
| Database access | Parameterised queries only |
| Secrets | No credentials in the repository; `.env` files are git-ignored |
| Data minimisation | No symptoms, diagnoses, date of birth, insurance or payment data collected |

## Known issues

| ID | Severity | Summary | Status |
| --- | --- | --- | --- |
| MB-001 | High | `GET /appointments/{id}` checks that the caller is signed in but not that they own the appointment. Any signed-in patient can read another patient's booking by ID (broken object-level authorization). | Open, fix in progress |

## Limitations

- SQLite is used for local development; a managed database is planned for production.
- No rate limiting on sign-in yet.
- Email format is checked with a pattern, not verified by confirmation email.
