# AWS verification, 2026-10-13

> Historical evidence: this record describes the versions, configuration and results from its stated session. Use the [current deployment guide](../../deployment.md) and [round 6 verification](aws-verification-2026-10-14-round6.md) for the later implementation and rollout.

The [first verification](aws-verification-2026-10-12.md) left two items open: alarms reached no one because the email subscription was never confirmed (F-13), and the database-unreachable alarm only fired when something called `/ready` (F-12). Both were fixed in [PR #37](https://github.com/abdurahim50/medibook/pull/37) and [PR #38](https://github.com/abdurahim50/medibook/pull/38). This session deployed `main` and tested them, then destroyed the environment.

- **Image:** release `dc73bfe101a3`, deployed by digest (`sha256:7c2094...`), signature and SBOM attestation verified during the plan
- **Base stack:** 56 resources, policy check 26 passed, 2 warnings. **Service stack:** 3 resources, policy check 28 of 28. One API task
- **Migration:** exit `0`; `/health` and `/ready` both `ok` on the first call
- **Clean-up:** environment destroyed (59 resources); no RDS instances, load balancers or ECS clusters left

Times are UTC on 13 October (21:00 to 21:45 on 12 October in Chicago). Account ID, endpoint and email address are redacted.

## Results

| Item | Test | Expected | Result |
| --- | --- | --- | --- |
| F-13 | `scripts/check-alerting.sh --test` after the subscription was confirmed | Passes, test email delivered | **Pass.** `OK: 1 confirmed alert subscription(s)`; "MediBook alert test" published 02:19:38, delivered the same minute |
| MB-009 | Live sign-up with an 11-character password | `422` without the submitted value | **Pass.** `{"detail":[{"type":"string_too_short","loc":["body","password"],"msg":"String should have at least 12 characters"}]}` |
| F-12 | Database ingress rule from the tasks revoked at 02:27:08; nothing calls the API | Background probe logs failures, alarm fires, email delivered | **Pass.** Probe: `readiness check failed: ConnectionTimeout` at 02:28:04, 02:29:04, 02:30:04. Load balancer `RequestCount` `0.0` for every minute: no client traffic. `api-database-unreachable` OK to ALARM at 02:30:11 (**3 min 3 s**), email delivered the same minute |
| R-10 | Spacing of probe failures while each check waits 10 s for the connection timeout | 60 s, not 70 s | **Pass.** Exactly 60 s apart |
| F-12 recovery | Rule recreated through a reviewed plan (`1 to add`, policy 28 of 28) at 02:35:28 | Alarm returns to OK, email delivered | **Pass.** ALARM to OK at 02:37:11 (**1 min 43 s**), email delivered the same minute; `/ready` `ok` |

## Notes

- **CloudWatch to SNS is proven.** The reviewer noted that `check-alerting.sh --test` publishes to SNS directly and so does not exercise CloudWatch's path to the KMS-encrypted topic. The database-unreachable ALARM and OK emails did.
- **Why 3 minutes.** The first probe after the cut ran about 46 s later and logged after its 10 s timeout; the alarm then needs a failure in each of 2 one-minute periods. Worst case is about one probe interval plus two periods.
- **Restore through Terraform.** Terraform saw the missing rule, removed it from state and planned to recreate it; the plan was policy-checked before apply, as in the runbook.
- **Alarm emails** contain the account ID, the subscriber address and an unsubscribe link (F-3), so they are not committed.

## New finding

**F-14: every fresh deployment raises a false no-healthy-targets alarm.** The base stack creates the load balancer, target group and alarm; the service comes in the second apply. With no targets the alarm treats missing data as breaching: INSUFFICIENT_DATA to ALARM at 02:08:38, back to OK at 02:20:38 once the service was healthy, and an alarm email in between. It trains people to ignore that alarm. Fix: create the alarm with the service, or enable its actions only when the service exists. **Fixed 2026-10-13:** actions are enabled by the service apply (`actions_enabled`), to be verified at the next deployment together with a real outage (service scaled to 0).

## Still open

- F-14: fixed in code; verify at the next deployment that no ALARM email arrives during the deploy and that scaling the service to 0 still alerts. **Verified 2026-10-14** ([verification](aws-verification-2026-10-14.md)); the outage alarm took 8 min 49 s (F-16).
- F-8: `ecs:RunTask` with command overrides limited to a break-glass role. **Fixed in PR #41 and verified 2026-10-14** ([verification](aws-verification-2026-10-14.md)), within the limits IAM allows.
- F-7: alert on mass `DELETE` (row counts).
- MB-008: sign-up still answers `409` for a registered email until confirm-by-email sign-up exists.
- The database check runs inside the API task; an outage of the API itself is covered by the no-healthy-targets alarm, not by this check.
