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
- Security headers on every response (no caching, no MIME sniffing, no framing, same-origin only)
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

The dev deployment is a cost-reduced slice of this design: see [docs/deployment.md](docs/deployment.md). Remaining gaps are on the [roadmap](#roadmap).

### Application stack

| Component | Technology | Responsibility |
| --- | --- | --- |
| API | Python 3.14, FastAPI, Uvicorn | HTTP routes, authentication dependency, booking operations |
| Validation | Pydantic | Request types, field constraints, rejection of unexpected fields |
| Data store | PostgreSQL 17: Amazon RDS in AWS, a container locally and in CI (`psycopg` 3, libpq from Debian) | Patients, sessions, slots and appointments; timestamps in UTC |
| Password hashing | argon2id (`argon2-cffi`) | Memory-hard hashing with a per-password salt |
| Sessions | Opaque bearer tokens | Random 256-bit tokens; only a SHA-256 digest is stored |
| Tests | pytest, FastAPI TestClient, PostgreSQL | Tables recreated for every test in a dedicated `*_test` database |
| Container | Docker, `python:3.14-slim` pinned by digest | Multi-stage image, non-root user, read-only root filesystem |
| CI | GitHub Actions | Tests, SAST, dependency, secret and image scans, policy tests and an authenticated OWASP ZAP scan on every pull request |
| Release | GitHub Actions, GitHub OIDC, Syft, Cosign | Builds and pushes the image to ECR without stored AWS keys; CycloneDX SBOM; keyless signature and SBOM attestation |

See the [product brief](docs/brief.md) for users, protected data and scope.

Security controls are mapped to NIST SP 800-53 Rev. 5, with evidence and known gaps, in [docs/controls.md](docs/controls.md).

## Getting started

**Prerequisites:** Git, Docker, Python 3.14 with `venv`, and the PostgreSQL client library (`sudo apt install libpq5`). Commands target Ubuntu or Ubuntu on WSL2.

```bash
# Clone the repository
git clone https://github.com/abdurahim50/medibook.git
cd medibook

# Create and activate a virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install pinned application and test dependencies
python -m pip install -r requirements-dev.txt

# Start a local PostgreSQL with a development and a test database
# (same image as CI; see POSTGRES_IMAGE in scripts/dast-scan.sh)
export PGPASSWORD="$(openssl rand -hex 16)"   # local only; lost when the shell closes
docker run -d --name medibook-db -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=medibook -e POSTGRES_DB=medibook -e POSTGRES_PASSWORD="$PGPASSWORD" \
  <postgres image from scripts/dast-scan.sh>
sleep 3 && docker exec medibook-db createdb -U medibook medibook_test

# Point the app at it (standard libpq variables)
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=medibook PGDATABASE=medibook

# Create the tables and load demo accounts and slots
python -m app.seed

# Start the API on localhost:8000
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

The database is published on `127.0.0.1` only, so it is not reachable from your network. The seed command creates two demo patients and ten open slots across two clinics. Unless `MEDIBOOK_SEED_PASSWORD` is set, it generates a shared demo password and prints it once.

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

Stop the server with `Ctrl+C`, and the database with `docker stop medibook-db`.

### Run with Docker

`scripts/dast-scan.sh` shows the full container setup: the API image with a read-only root filesystem, no Linux capabilities and `no-new-privileges`, next to a PostgreSQL container on a private Docker network. The container runs as an unprivileged user (UID 10001) and keeps no data: everything is in PostgreSQL.

## Deploy to AWS

Infrastructure is split into stacks with different lifecycles:

| Stack | Path | Contents |
| --- | --- | --- |
| Account baseline | separate repository `aws-account-baseline` | GitHub Actions OIDC identity provider, shared by all projects |
| Bootstrap | [`infra/bootstrap/`](infra/bootstrap/) | ECR repository (immutable tags, scan on push) and the role CI uses to publish images |
| Environment | [`infra/`](infra/) | VPC, Application Load Balancer, AWS WAF, ECS Fargate, CloudWatch alarms; created and destroyed each session |

Images are deployed by digest. Terraform verifies each image's signature and SBOM attestation during the plan and refuses images not signed by the release workflow on `main`. Every Terraform plan is checked with `scripts/policy-check.sh` before it is applied. See [docs/deployment.md](docs/deployment.md) for cost, setup, deployment and teardown, and [docs/runbook.md](docs/runbook.md) for alarm response.

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
| `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` | libpq defaults | PostgreSQL connection ([libpq environment variables](https://www.postgresql.org/docs/current/libpq-envars.html)) |
| `PGSSLMODE`, `PGSSLROOTCERT` | `prefer` | TLS to the database; `verify-full` with a CA bundle in AWS |
| `MEDIBOOK_SEED_PASSWORD` | Generated at seed time | Password assigned to the demo accounts |

Set these in your shell before running the seed command or server. The application does not load `.env` files automatically; `.env.example` lists every supported variable. Never commit a `.env` file or a password.

### Resetting the development database

Seeding a database that already has slots leaves it unchanged. To rebuild a disposable development database, stop the server, then run:

```bash
python -m app.seed --reset
```

This drops all MediBook tables in the database `PGDATABASE` points at, permanently deleting all accounts, sessions and bookings. Check `echo $PGDATABASE` first.

## Testing

```bash
# Activate the project's Python environment.
source .venv/bin/activate

# Run the tests against the test database; -q requests concise output.
PGDATABASE=medibook_test python -m pytest -q
```

Tests use a real PostgreSQL, the same engine as production. Every test drops and recreates the tables, so [`tests/conftest.py`](tests/conftest.py) refuses to run unless `PGDATABASE` ends in `_test`. The suite covers registration, authentication, sign-out, booking, patient-specific lists, double booking, input validation, cross-patient access control, audit logging, sign-in throttling, security headers, UTC timestamps and double booking under concurrent transactions.

### Continuous integration

Every pull request and push to `main` runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

| Check | Tool | Fails when |
| --- | --- | --- |
| Tests | pytest, PostgreSQL service container | Any test fails |
| SAST | Bandit, Semgrep (`p/python`, `p/owasp-top-ten`) | Bandit reports a medium or higher severity issue, or Semgrep reports any finding |
| Dependency scan | pip-audit | A pinned package has a known vulnerability or cannot be checked |
| Secret scan | gitleaks | A secret is found anywhere in the git history |
| Image scan | Trivy | The Dockerfile has a HIGH or CRITICAL misconfiguration, or the image has a fixable HIGH or CRITICAL vulnerability |
| Policy tests | Conftest | A policy unit test fails, or the known-bad Terraform plan is not blocked by every rule |
| DAST | OWASP ZAP | An authenticated API scan of the running container raises an alert not accepted in [`.zap/rules.tsv`](.zap/rules.tsv), or the scan loses its session |
| Terraform plan | Terraform, Cosign, Conftest | Either stack is unformatted or invalid, the latest release image fails signature verification, or a real plan of either stack violates a policy |

The workflow has read-only repository permissions, actions are pinned by commit SHA, and scanner binaries and images are pinned by checksum or digest. `main` is protected: changes arrive only through pull requests, and all 8 checks plus the DCO sign-off must pass before merge. Only the Terraform plan job receives an AWS identity: a read-only role that can read the image repository and nothing else, with no access to Terraform state.

### Release

Every merge to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml): build, Trivy gate, push to ECR by digest through GitHub OIDC (no stored AWS keys), CycloneDX SBOM with Syft, and a keyless Cosign signature and SBOM attestation, which the workflow verifies before finishing. The run summary shows the digest to deploy.

## Project structure

```
Dockerfile     container image definition
infra/         Terraform for the AWS dev environment
  bootstrap/   ECR repository and CI release role (long-lived)
.github/workflows/
  ci.yml       tests and security scans on every pull request
  release.yml  build, sign and publish the image on main
policy/
  terraform/   Conftest policies and their unit tests
  fixtures/    compliant and non-compliant sample plans
scripts/
  verify-image.sh  verify an image signature before deploying
  verify-image-terraform.sh  signature check run by Terraform during plan
  policy-check.sh  check a Terraform plan before applying
  dast-scan.sh     authenticated OWASP ZAP scan
.zap/rules.tsv     accepted ZAP alerts (none)
app/
  main.py      API routes and session dependency
  auth.py      password hashing and session management
  audit.py     structured audit log
  ratelimit.py failed sign-in throttling
  db.py        PostgreSQL connection and schema
  models.py    request and response models
  seed.py      demo data loader
  search.py    slot search by clinic
tests/
  test_api.py        API test suite
  test_audit.py      audit log tests
  test_ratelimit.py  sign-in throttling tests
  test_security_headers.py  response security headers
  conftest.py        refuses to run against a non-test database
docs/
  brief.md         product brief: users, data and assets
  threat-model.md  data flow, STRIDE analysis and controls
  controls.md      NIST SP 800-53 control mapping, evidence and gaps
  evidence.md      delivery evidence by milestone
  deployment.md    AWS deployment, cost and teardown
  runbook.md       alarm response and recovery
  vulnerability-exceptions.md  accepted findings with review dates
  evidence/        captured test and pipeline output
diagrams/
  architecture.drawio.png   editable architecture diagram
SECURITY.md    security controls, known issues, reporting
```

## Known limitations

- API only; no patient web interface yet.
- Sign-in throttling and audit logs are per container; see [SECURITY.md](SECURITY.md).
- Staff and admin workflows, cancellation, rescheduling, payments and AI intake are not implemented.
- The dev database is a single-AZ RDS instance that is deleted with the environment after each session; production needs Multi-AZ, deletion protection and a final snapshot.
- The application connects as the database admin user; a separate role limited to reading and writing MediBook's tables is planned.
- Each request opens a new database connection, and `/health` checks the database; connection pooling and separate liveness and readiness checks are planned (findings F-5 and F-6 in the [recovery drills](docs/evidence/deployment/recovery-drills.md)).
- CI publishes signed images, but deployment is run with Terraform from a workstation. Signature verification and policy checks run on every pull request and in every deployment plan.
- The dev load balancer serves HTTP only, restricted to allowed addresses; HTTPS is required before real data (see [docs/controls.md](docs/controls.md)).

## Security

See [SECURITY.md](SECURITY.md) for the security model, known issues and how to report a vulnerability.

## Roadmap

- [x] Booking API with authentication and validation
- [x] Appointment ownership enforcement on single-record lookups
- [x] CI pipeline with automated tests and security scanning
- [x] Hardened container image with image scanning
- [x] Audit logging and sign-in throttling
- [x] AWS deployment with Terraform (ECS Fargate, ALB, WAF)
- [x] Alerting, recovery runbook and recovery drills
- [x] CI build, SBOM and image signing, published through GitHub OIDC
- [x] Policy checks on Terraform plans (Conftest, NIST SP 800-53 mapped)
- [x] Authenticated DAST (OWASP ZAP) on every pull request
- [x] Signature verification enforced at deploy time (Terraform plan)
- [x] Terraform plan and policy checks in CI with a read-only role
- [x] RDS PostgreSQL: private, KMS-encrypted, verified TLS, point-in-time recovery
- [ ] Tested point-in-time restore with measured RTO and RPO
- [ ] Split Terraform into modules when a second environment is added
- [ ] Clinic staff portal
- [ ] AI-assisted patient intake
