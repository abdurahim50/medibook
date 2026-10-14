# Round 6 corrections

Prepared against `d12024d925d7792a83ac16af3307fd1ebd6002ea`.

## Changes

- Default startup grace is zero. An exceptional bootstrap can set
  `MEDIBOOK_READINESS_GRACE_UNTIL` to a UTC deadline at most 15 minutes ahead.
  Remaining grace is recomputed from that same deadline after a restart, and a
  successful check ends it early. Nonzero relative grace is rejected.
- Patient endpoints return generic `503` responses for PostgreSQL operational
  and interface errors, with `Retry-After: 60`. They emit the same phase-aware
  marker as the scheduled probe without logging raw connection error text.
  Unexpected programming errors are still errors, not disguised as outages.
- The deployment guide prepares task definitions with `desired_count=0`, runs
  the approved migration, then starts the API. Availability alarm actions remain
  disabled while zero tasks are intentionally configured in Terraform.
- The filled healthy-host alarm requires two breaching periods out of three.
  One delayed, zero-filled datapoint alone cannot trigger it. New detection and
  recovery times are pending measurement; earlier five-minute results describe
  the previous configuration only.
- Workflow and AWS trust move to `migrate-dev-v2`. Configure its protection rules
  before applying the bootstrap trust change. Historical jobs in `migrate-dev`
  are then excluded by AWS. The current guard rejects fixture overrides in
  Actions and stale main revisions. GitHub environment administrators remain a
  trusted boundary; this is not workflow-specific OIDC enforcement.

## Local validation

69 focused checks passed on Python 3.12 with FastAPI 0.142.1 and mocked database
dependencies. Coverage includes all database-backed patient endpoints, normal
startup, bootstrap, failure after success, fixed deadlines across restarts,
invalid configuration, scheduled probes, and migration protection checks.
Python syntax, documented shell syntax, shell script syntax and diff whitespace
checks passed.

The full PostgreSQL suite, Terraform formatting/validation, policy checks,
dependency and security scans must run in repository CI after applying this
patch. This environment has no PostgreSQL/libpq, Docker, Terraform or Conftest.
No GitHub environment configuration or AWS resource was modified here.

## Rollout and remaining verification

1. Configure `migrate-dev-v2`: required reviewer, no administrator bypass,
   selected branch `main` only, and `AWS_MIGRATE_ROLE_ARN`.
2. Read and check `docs/deployment.md`, then plan the bootstrap stack and run
   the policy check before applying its v2 role trust. Remove legacy environment
   overrides. Verify old-subject role assumption is refused.
3. Deploy the application task definitions with zero API tasks. Approve the
   migration, check exit zero, and start the API only afterward.
4. Confirm SNS delivery, then demonstrate an idle database outage and recovery,
   normal-request `503` responses, and task replacement during an outage.
5. Measure a sustained healthy period with delayed metrics and a total service
   outage for the revised 2-of-3 alarm. Record actual ALARM/OK notifications.

These are prepared corrections, not new live AWS verification results.
