# MediBook engineering case study

How MediBook was built, what was hard, and what the evidence shows. The [README](../README.md) covers what the service does and how to run it; this page covers the engineering behind it.

## Background

Before moving into security engineering, I worked in HIPAA-regulated compliance, where I saw how much depends on patient data staying private and systems staying available. I built MediBook to learn the other side: how those requirements are enforced in code, infrastructure and operations rather than in policy documents.

Appointment booking gave me concrete problems to solve: keeping each patient's bookings private, preventing double booking, keeping secrets out of reach of the running application, and detecting and recovering from failures. Each control is tested, deployed to AWS and checked against the live environment, and the findings, including my own mistakes, are recorded in the [evidence index](evidence.md).

My goal was to connect application security, cloud infrastructure and operations in one project I can explain end to end. All patient data is synthetic; MediBook is a learning environment, not a clinical system.

## Skills demonstrated

| Area | What I implemented | Evidence |
| --- | --- | --- |
| Application security | Session-based patient identity, ownership checks, input validation and double-booking protection | [API tests](../tests/test_api.py), [threat model](threat-model.md) |
| Least privilege | RDS IAM authentication for the API and a separate approval-gated migration role | [Database role tests](../tests/test_least_privilege.py), [architecture](architecture.md) |
| Infrastructure as code | Terraform infrastructure and Conftest policies checked before apply | [Policy rules and tests](../policy/README.md), [deployment guide](deployment.md) |
| Software supply chain | Dependency hashes, pinned images and actions, SBOM generation, image signing and plan-time verification | [Release workflow](../.github/workflows/release.yml), [verification script](../scripts/verify-image-terraform.sh) |
| Security testing | Automated SAST, dependency, secret, container and authenticated API scans | [CI workflow](../.github/workflows/ci.yml), [scan evidence](evidence.md) |
| Operations and recovery | Database probes, CloudWatch alarms, confirmed SNS delivery, outage and database recovery drills | [Round 6 verification](evidence/deployment/aws-verification-2026-10-14-round6.md), [recovery drills](evidence/deployment/recovery-drills.md) |

## Challenges solved

- **Separating migrations from the API.** I moved schema changes into an approval-gated workflow with a dedicated AWS role, then verified the migration before starting API tasks. [Delivery flow](architecture.md#delivery-path).
- **Handling database startup failures.** A restartable quiet period could hide a task that never connected. Startup now has no grace by default; an exceptional grace period uses a fixed UTC deadline and ends on first success. [Readiness tests](../tests/test_readiness.py).
- **Detecting an outage when the load balancer stops publishing data.** I tested alarm candidates and retained a filled healthy-host metric. The round 6 drill alarmed 4 min 3 s after scaling began and returned to OK after recovery. This is a measured result from one drill. [Deployment evidence](evidence/deployment/aws-verification-2026-10-14-round6.md).

## What I learned

A healthy endpoint is one part of verification. I also needed to check which identity could run a migration, whether an alert reached its destination, and how the service recovered after failure. Unit tests, policy checks and live drills each answered different questions.

I learned to distinguish configured controls, observed results and remaining gaps. The evidence records what I tested; the limitations below explain where more work is needed before production use.

## Milestones

- Booking API with authentication and validation
- Appointment ownership enforcement on single-record lookups
- CI pipeline with automated tests and security scanning
- Hardened container image with image scanning
- Audit logging and sign-in throttling
- AWS deployment with Terraform (ECS Fargate, ALB, WAF)
- Alerting, recovery runbook and recovery drills
- CI build, SBOM and image signing, published through GitHub OIDC
- Policy checks on Terraform plans (Conftest, NIST SP 800-53 mapped)
- Authenticated DAST (OWASP ZAP) on every pull request
- Signature verification enforced at deploy time (Terraform plan)
- Terraform plan and policy checks in CI with a read-only role
- RDS PostgreSQL: private, KMS-encrypted, verified TLS, point-in-time recovery
- Tested point-in-time restore with measured RTO and RPO (23 min 50 s, no data lost)
- Least-privilege database role with IAM authentication, destructive-SQL alarm and liveness/readiness split, verified by repeating the restore drill (drill 5)
- Migration-first deployment, v2 approval environment and revised availability alarm, verified in the round 6 deployment drill

Dated results for each milestone are in the [evidence index](evidence.md).
