# AWS verification, 2026-10-14

The [follow-up verification](aws-verification-2026-10-13.md) left two fixes untested in AWS: migrations through an approved workflow and a dedicated role (F-8, [PR #41](https://github.com/abdurahim50/medibook/pull/41)), and no false alarm email during a deployment (F-14, [PR #40](https://github.com/abdurahim50/medibook/pull/40)). This session deployed `main`, tested both, then destroyed the environment.

- **Image:** release `0d78b8d5de11`, deployed by digest, signature and SBOM attestation verified during the plan
- **Stacks:** base and service applied through reviewed, policy-checked plans; one API task
- **Migration:** run from the "Migrate database" workflow (run `38587256169`) after an approval; exit `0`; `/ready` `ok`
- **Clean-up:** environment destroyed (62 resources); no RDS instances, load balancers or ECS clusters left

Times are UTC on 14 October (morning in Chicago). Account ID, endpoint and email address are redacted.

## Results

| Item | Test | Expected | Result |
| --- | --- | --- | --- |
| F-8 | Migration from the workflow | Job waits for approval, then runs the task | **Pass.** Run `38587256169` waited for the `migrate-dev` reviewer, assumed the role at 15:15:02, migration exit `0`, `/ready` `ok` |
| F-8 | IAM policy simulation, `secretsmanager:GetSecretValue` on the RDS admin secret, for each ECS role | Only the migration execution role | **Pass.** `medibook-dev-migrate-execution` allowed; `medibook-dev-task-execution` and `medibook-dev-api-task` `implicitDeny` |
| F-8 | Simulation of `medibook-github-migrate`, `ecs:RunTask`, one call per task definition and cluster | Migration task in `medibook-dev` only | **Pass.** `medibook-dev-migrate` in `medibook-dev` allowed; the API task definition, and either task in another cluster, `implicitDeny` |
| F-8 | Same role, `iam:PassRole` | Migration execution role only | **Pass.** `medibook-dev-migrate-execution` allowed; `medibook-dev-task-execution` and `medibook-dev-api-task` `implicitDeny` |
| F-8 | Same role, `ecs:RegisterTaskDefinition` | Denied: it cannot define a new task with other credentials | **Pass.** `implicitDeny` |
| F-8 | CloudTrail `AssumeRoleWithWebIdentity` for `medibook-github-migrate`, last 16 hours | One session per run that passed the gate | **Pass, with a finding (F-17).** Three sessions: `github-migrate-38507950315` at 03:46:19 and `github-migrate-38508163987` at 03:48:47 (runs 1 and 2, before the reviewer rule was saved), and `github-migrate-38587256169` at 15:15:02 (approved). Run 3 (cancelled while waiting) and run 4 (rejected) never reached AWS |
| F-14 | Deploy from scratch with a confirmed subscription | No ALARM email for no-healthy-targets | **Pass.** The alarm went INSUFFICIENT_DATA to ALARM at 14:59:38 with actions disabled; the service apply enabled them at 15:12:09; the only notification was ALARM to OK at 15:15:26 |
| F-14 | Service scaled to 0 at 15:28:37 | A real outage still alerts | **Pass, slowly (F-16).** OK to ALARM at 15:37:26 (**8 min 49 s**), email delivered |
| F-14 recovery | Service scaled to 1 at 15:37:37 | Alarm clears | **Pass.** ALARM to OK at 15:41:26, email delivered; `/ready` `ok` |

## Notes

- **The scale-up ran unattended.** The editor lost its connection during the outage, but the shell kept running: the poll saw ALARM and the script scaled the service back to 1 eleven seconds later. CloudTrail `UpdateService` shows both changes by the operator's own user, at 15:28:37 (`desiredCount` 0) and 15:37:37 (1).
- **One OK email per deployment** remains by design: the alarm returns to OK once the service is healthy. The runbook says so.
- **IAM simulation with several resources** in one `simulate-principal-policy` call reports the overall decision per action; per-resource decisions sit in `ResourceSpecificResults`. Each resource was simulated in its own call.
- **Alarm emails** contain the account ID, the subscriber address and an unsubscribe link (F-3), so they are not committed.

## New findings

**F-15: every fresh deployment raises a false database-unreachable alarm.** The API task starts before the migration, which waits for a person's approval, and its readiness probe cannot sign in until the migration creates the `medibook_app` role. Probe: `readiness check failed: OperationalError` at 15:13:46 and 15:14:45 (a refused sign-in, not the `ConnectionTimeout` of a network cut). `api-database-unreachable` OK to ALARM at 15:15:06 with an email, back to OK at 15:16:06 after the migration. The alarm stays on for as long as the approver takes. Same harm as F-14: it teaches people to ignore that alarm.

**F-16: a total outage takes about 9 minutes to alarm, not 2 to 3.** With no registered targets the load balancer stops publishing `HealthyHostCount`; it never reports `0`. Per-minute minimums: `1.0` up to 15:27, no data points from 15:28 to 15:37, `1.0` from 15:38. The alarm treats missing data as breaching, but CloudWatch only did so after 8 min 49 s. Candidate fixes, to be tested before any is claimed: a metric-math alarm that fills gaps with `0`, or an external check that always reports (CloudWatch Synthetics canary or Route 53 health check on `/health`).

**F-17: the approval gate is configured by hand, outside Terraform.** The AWS role trusts any job in the `migrate-dev` environment; whether that environment needs an approval is a GitHub setting. It was created without required reviewers and with administrator bypass on, so runs 1 and 2 received AWS credentials without an approval before it was corrected. Fix options: manage the environment with Terraform's GitHub provider, or have the workflow refuse to run unless the environment's protection rules are in place.

## Still open

- F-15, F-16, F-17 above.
- F-8 limits that IAM cannot close: AWS administrators are unconstrained, and command overrides on `ecs:RunTask` have no condition key.
- F-7: alert on mass `DELETE` (row counts).
- MB-008: sign-up still answers `409` for a registered email until confirm-by-email sign-up exists.
