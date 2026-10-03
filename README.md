# MediBook

Appointment booking API for outpatient clinics. Patients create an account, browse open appointment slots, book a visit and view their own bookings.

The current release provides the patient booking API. Staff tools and an AI-assisted intake flow are planned for future releases.

> **Data notice:** this environment runs on synthetic data only. It holds no real patient information and is not intended for clinical use.

## Patient workflow

1. Create a patient account.
2. Sign in to receive an access token.
3. Browse open appointment slots.
4. Book a slot.
5. View the appointments linked to your account.

## Features

- Patient registration, sign-in and sign-out
- Server-side sessions with an 8-hour expiry and immediate revocation on sign-out
- Open appointment slots across clinics, ordered by time
- Booking with database-enforced protection against double booking
- Patient-specific appointment list
- Strict request validation and consistent HTTP errors
- Throttling of repeated failed sign-ins
- Structured JSON audit log of security events
- Health endpoint and interactive API documentation at `/docs`

## Architecture

![System architecture](diagrams/architecture.drawio.png)

Target production architecture on AWS. Edit `diagrams/architecture.drawio.png` in VS Code with the Draw.io Integration extension, or at [app.diagrams.net](https://app.diagrams.net).

| Layer | Design |
| --- | --- |
| Edge | Route 53 DNS, AWS WAF (managed rules, rate limiting), Application Load Balancer terminating TLS 1.2+ |
| Compute | ECS Fargate tasks in private subnets across two Availability Zones; non-root containers with read-only filesystems |
| Data | Amazon RDS PostgreSQL, Multi-AZ, KMS-encrypted, automated backups; reachable only from the app tier |
| Secrets | Database credentials in Secrets Manager, read through the task IAM role |
| Delivery | GitHub Actions runs tests and security scans, signs the image, pushes to ECR through OIDC (no long-lived AWS keys) and deploys by image digest |
| Operations | CloudWatch logs, metrics and alarms; CloudTrail and GuardDuty for audit and threat detection |

The current release runs locally with SQLite. Containerisation and AWS deployment are on the [roadmap](#roadmap).

### Application stack

| Component | Technology | Responsibility |
| --- | --- | --- |
| API | Python 3.14, FastAPI, Uvicorn | HTTP routes, authentication dependency, booking operations |
| Validation | Pydantic | Request types, field constraints, rejection of unexpected fields |
| Data store | SQLite | Patients, sessions, slots and appointments |
| Password hashing | argon2id (`argon2-cffi`) | Memory-hard hashing with a per-password salt |
| Sessions | Opaque bearer tokens | Random 256-bit tokens; only a SHA-256 digest is stored |
| Tests | pytest, FastAPI TestClient | Isolated database per test |
| Container | Docker, `python:3.14-slim` pinned by digest | Multi-stage image, non-root user, read-only root filesystem |
| CI | GitHub Actions | Tests, SAST, dependency and secret scans on every pull request |

See the [product brief](docs/brief.md) for users, protected data and scope.

## Getting started

**Prerequisites:** Git and Python 3.14 with `venv`. Commands target Ubuntu or Ubuntu on WSL2.

```bash
# Clone the repository
git clone https://github.com/abdurahim50/medibook.git
cd medibook

# Create and activate a virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install pinned application and test dependencies
python -m pip install -r requirements-dev.txt

# Create the database and load demo accounts and slots
python -m app.seed

# Start the API on localhost:8000
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

The seed command creates two demo patients and ten open slots across two clinics. Unless `MEDIBOOK_SEED_PASSWORD` is set, it generates a shared demo password and prints it once.

| Demo account |
| --- |
| `alex.rivera@example.com` |
| `sam.taylor@example.com` |

**Verify the service** from another terminal:

```bash
curl -sS http://127.0.0.1:8000/health
# {"status":"ok"}
```

**Try the API** at <http://127.0.0.1:8000/docs>: call `POST /auth/signin`, copy the `access_token`, then click **Authorize** and paste it to use protected endpoints.

Stop the server with `Ctrl+C`.

### Run with Docker

```bash
# Build the image
docker build -t medibook:dev .

# Run with a read-only filesystem, no Linux capabilities and a volume for the database
docker run -d --name medibook -p 8000:8000 \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v medibook-data:/data \
  medibook:dev

# Seed demo data inside the container
docker exec medibook python -m app.seed

# Follow the audit log
docker logs -f medibook | grep '"type":"audit"'
```

The container runs as an unprivileged user (UID 10001) and stores the database in the `/data` volume.

## API reference

Protected endpoints require `Authorization: Bearer <access_token>`.

| Method | Path | Description | Auth | Success |
| --- | --- | --- | --- | --- |
| `GET` | `/health` | API and database connectivity | None | `200` |
| `POST` | `/auth/signup` | Register a patient | None | `201` |
| `POST` | `/auth/signin` | Sign in and receive a session token | None | `200` |
| `POST` | `/auth/signout` | Revoke the current session | Required | `204` |
| `GET` | `/slots` | List open appointment slots | Required | `200` |
| `POST` | `/appointments` | Book a slot | Required | `201` |
| `GET` | `/appointments` | List the signed-in patient's appointments | Required | `200` |
| `GET` | `/appointments/{appointment_id}` | Get one of the signed-in patient's appointments | Required | `200` |

**Booking request:**

```json
{ "slot_id": 1 }
```

`slot_id` must be a positive integer. Patient identity always comes from the session; unknown fields, including a client-supplied `patient_id`, are rejected.

**Errors:** `401` invalid or missing authentication, `404` record not found or owned by another patient, `409` email already registered or slot already booked, `422` invalid request data, `429` too many failed sign-in attempts (see `Retry-After`).

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `MEDIBOOK_DB` | `medibook.db` | Path to the SQLite database file |
| `MEDIBOOK_SEED_PASSWORD` | Generated at seed time | Password assigned to the demo accounts |

Set these in your shell before running the seed command or server (for example `export MEDIBOOK_DB=/tmp/medibook.db`). The application does not load `.env` files automatically; `.env.example` lists every supported variable. Never commit a `.env` file.

### Resetting the development database

Seeding a database that already has slots leaves it unchanged. To rebuild a disposable development database, stop the server, then run:

```bash
python -m app.seed --reset
```

This permanently deletes all accounts, sessions and bookings in that database.

## Testing

```bash
# Activate the project's Python environment.
source .venv/bin/activate

# Run the tests; -q requests concise output.
python -m pytest -q
```

Each test runs against its own temporary SQLite database. The suite covers registration, authentication, sign-out, booking, patient-specific lists, double booking, input validation, cross-patient access control, audit logging and sign-in throttling.

### Continuous integration

Every pull request and push to `main` runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

| Check | Tool | Fails when |
| --- | --- | --- |
| Tests | pytest | Any test fails |
| SAST | Bandit, Semgrep (`p/python`, `p/owasp-top-ten`) | Bandit reports a medium or higher severity issue, or Semgrep reports any finding |
| Dependency scan | pip-audit | A pinned package has a known vulnerability or cannot be checked |
| Secret scan | gitleaks | A secret is found anywhere in the git history |
| Image scan | Trivy | The Dockerfile has a HIGH or CRITICAL misconfiguration, or the image has a fixable HIGH or CRITICAL vulnerability |

The workflow has read-only repository permissions, actions are pinned by commit SHA and the gitleaks binary is verified by checksum. `main` is protected: changes arrive only through pull requests, and all checks plus the DCO sign-off must pass before merge.

## Project structure

```
Dockerfile     container image definition
.github/workflows/
  ci.yml       tests and security scans
app/
  main.py      API routes and session dependency
  auth.py      password hashing and session management
  audit.py     structured audit log
  ratelimit.py failed sign-in throttling
  db.py        database connection and schema
  models.py    request and response models
  seed.py      demo data loader
  search.py    slot search by clinic
tests/
  test_api.py        API test suite
  test_audit.py      audit log tests
  test_ratelimit.py  sign-in throttling tests
docs/
  brief.md         product brief: users, data and assets
  threat-model.md  data flow, STRIDE analysis and controls
  evidence.md      delivery evidence by milestone
  evidence/        captured test and pipeline output
diagrams/
  architecture.drawio.png   editable architecture diagram
SECURITY.md    security controls, known issues, reporting
```

## Known limitations

- API only; no patient web interface yet.
- Sign-in throttling and audit logs are per container; see [SECURITY.md](SECURITY.md).
- Staff and admin workflows, cancellation, rescheduling, payments and AI intake are not implemented.
- Continuous deployment and cloud hosting are planned.

## Security

See [SECURITY.md](SECURITY.md) for the security model, known issues and how to report a vulnerability.

## Roadmap

- [x] Booking API with authentication and validation
- [x] Appointment ownership enforcement on single-record lookups
- [x] CI pipeline with automated tests and security scanning
- [x] Hardened container image with image scanning
- [x] Audit logging and sign-in throttling
- [ ] AWS deployment
- [ ] Alerting and recovery runbook
- [ ] Clinic staff portal
- [ ] AI-assisted patient intake