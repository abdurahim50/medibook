# RDS PostgreSQL in AWS dev

Date: 2026-10-06 (America/Chicago; log times in UTC). AWS account ID replaced with `111122223333`, the RDS endpoint hash with `xxxxxxxxxxxx`, the secret ARN suffix with `-XXXXXX` and client public IPs with documentation addresses.

Shipped in [PR #19](https://github.com/abdurahim50/medibook/pull/19), merge commit [`3ed7e3a`](https://github.com/abdurahim50/medibook/commit/3ed7e3a). Deployed image `sha256:2088b8d3936837c9855dd3f3ba74b4296bfe80b528f648557d4b757fbaa81199`, built and signed by Release run #12 from that commit.

## What was deployed

| Setting | Value | Why |
| --- | --- | --- |
| Engine and size | PostgreSQL 17, `db.t3.micro`, 20 GB gp3, single-AZ | Smallest available class; Multi-AZ is a variable for production |
| Network | Private subnets with no internet route; inbound 5432 only from the API task security group | No path to the database except through the application |
| Encryption at rest | Storage and the master secret encrypted with a customer-managed KMS key | Key policy and rotation under our control |
| Credentials | `manage_master_user_password`: RDS generates the password and stores it in Secrets Manager; ECS injects it at task start | No password in Terraform, state, plan or image |
| Encryption in transit | Server: `rds.force_ssl=1`. Client: `PGSSLMODE=verify-full` with the RDS CA bundle built into the image | Unencrypted connections refused; the client verifies the certificate chain and host name |
| Backups | 7-day point-in-time recovery; logs exported to CloudWatch | Restore drill follows in phase 3 |
| Policy | MB-POL-10 checks encryption, private access, backup retention, the managed password and TLS enforcement | Blocks a non-compliant database before apply |

## Deployment, two steps

The task definition references the database address and secret ARN, which exist only after the database is created. Deploying in one step would leave the container settings unknown at plan time, so MB-POL-04 could not check them.

| Step | Plan | Policy check |
| --- | --- | --- |
| 1. Base, including the database | 2 to add (database and execution role policy) after the retry below | 27 passed, 1 warning (MB-POL-03: execution policy JSON known only after apply; its statements were checked) |
| 2. Service | 2 to add (task definition and service); Cosign verified the image signature and SBOM attestation during the plan (8 s) | **28 passed, 0 warnings**: container hardening (MB-POL-04) and digest pinning (MB-POL-09) evaluated |

A later plan to add a client address showed 0 changes to the task definition and service, and verified the signature again.

## Issues found and fixed during deployment

| # | Issue | Cause | Fix |
| --- | --- | --- | --- |
| 1 | `InsufficientDBInstanceCapacity` for `db.t4g.micro` with gp3 | No capacity in the subnet group's Availability Zones at that time. The other resources of step 1 had been created; the database was not (`DBInstanceNotFound` confirmed nothing half-built) | Default changed to `db.t3.micro`; re-plan showed only the missing resources |
| 2 | Parameter group update on every plan | `rds.force_ssl` defaulted to `apply_method = "immediate"` in Terraform; RDS stores it as `pending-reboot` | Set `pending-reboot` in the configuration to match the API; no reboot needed because the database did not exist yet |
| 3 | CA bundle missing from the first commit | `.gitignore` excludes `*.pem` (to keep private keys out), which also skipped the public CA bundle | One exception for `certs/rds-global-bundle.pem`; SHA-256 `fe45bbeb…5395c` checked before commit. The image build would have failed on `COPY` |
| 4 | Release image from `main` had no CA bundle | The Dockerfile change was only on the branch, and only `main` can produce signed images | Merged first; deployed the image built and signed from the merge commit. A branch image was not signed |
| 5 | Health check timed out from the workstation | The tester's public IP had changed (home and work networks); the load balancer accepts only listed addresses | Both addresses listed in `allowed_cidrs`; plan: 1 security group rule added |

## Verification

**The database is private and encrypted:**

```
$ getent hosts "$(terraform output -raw db_endpoint)"
10.20.100.240   medibook-dev.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
$ aws rds describe-db-instances --db-instance-identifier medibook-dev \
    --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible,StorageEncrypted,DBInstanceClass]' --output text
available       False   True    db.t3.micro
```

Public DNS returns only the private address.

**Connections use TLS, seen from the database:**

```
2026-10-06 22:35:49 UTC:10.20.1.110(39198):medibook_admin@medibook:[2179]:LOG:  connection authorized: user=medibook_admin database=medibook application_name=medibook-api SSL enabled (protocol=TLSv1.3, cipher=TLS_AES_256_GCM_SHA384, bits=256)
```

The source is the task's private address and `application_name` is set by the API ([`app/db.py`](../../../app/db.py)). The server refuses non-TLS connections (`rds.force_ssl=1`), and the client accepts only a certificate for this host name signed by the RDS certificate authorities (`verify-full`).

**Smoke test** (demo password read from SSM into a shell variable and unset after use; token not shown):

```
$ curl -s "$URL/health"
{"status":"ok"}
$ curl -s -X POST "$URL/appointments" -H "Authorization: Bearer $ALEX" -H 'Content-Type: application/json' -d '{"slot_id":1}'
{"id":1,"slot_id":1,"clinic_name":"Northside Family Clinic","starts_at":"2026-10-07T09:00:00Z","status":"booked"}
$ curl -s "$URL/appointments" -H "Authorization: Bearer $ALEX"
[{"id":1,"slot_id":1,"clinic_name":"Northside Family Clinic","starts_at":"2026-10-07T09:00:00Z","status":"booked"}]
```

Times are returned in UTC (`Z`).

**Data survives task replacement:** see [drill 3](recovery-drills.md#drill-3-task-crash-with-rds-data-persistence). The booking and Alex's session token were still valid on a new task.

## Teardown

Destroy plan: 0 to add, 0 to change, 52 to destroy, including the database and both KMS keys. With dev settings (`skip_final_snapshot`, `delete_automated_backups`) the synthetic data and its backups are deleted with the database; the KMS keys enter a 7-day pending-deletion period.
