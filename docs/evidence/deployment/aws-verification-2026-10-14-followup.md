# AWS verification, 2026-10-14 (follow-up)

> Historical evidence: this record describes the versions, configuration and results from its stated session. Use the [current deployment guide](../../deployment.md) and [round 6 verification](aws-verification-2026-10-14-round6.md) for the later implementation and rollout.

The [morning verification](aws-verification-2026-10-14.md) found three issues: a false database-unreachable alarm while the migration waits for approval (F-15), a total outage taking about 9 minutes to alarm (F-16), and the approval gate living only in GitHub settings (F-17). [PR #43](https://github.com/abdurahim50/medibook/pull/43) fixed F-15 and F-17 and added two candidate alarms for F-16; [PR #44](https://github.com/abdurahim50/medibook/pull/44) made the API's INFO lines reach the log. This session deployed `main`, tested all three, then destroyed the environment.

- **Image:** release `267dd6c`, deployed by digest (`sha256:64ce17...`), signature and SBOM attestation verified before and during the plan
- **Base stack:** 61 resources, policy check 25 passed, 3 warnings (known-after-apply IAM policies). **Service stack:** 3 added, 3 alarms' notifications enabled, policy check 28 of 28
- **Alerting:** `check-alerting.sh --test` passed; test email delivered at 17:43:47
- **Clean-up:** environment destroyed (64 resources); no RDS instances, load balancers or ECS clusters left

Times are UTC on 14 October (afternoon in Chicago). Account ID, endpoint and email address are redacted.

## Results

| Item | Test | Expected | Result |
| --- | --- | --- | --- |
| F-15 | Service applied at 17:46:00; migration deliberately not started for 12 minutes; `/ready` and the alarm polled every 30 s | No database alarm; the wait is visible in the log | **Pass.** `api-database-unreachable` `OK` in all 14 polls (17:48:44 to 17:55:29) while `/ready` returned `503`. Log: `INFO medibook.api: database not ready yet: OperationalError` once a minute from the probe (17:47:43, 17:48:42, ...) and once per `/ready` call; no `readiness check failed` line all session. Alarm history: created, INSUFFICIENT_DATA to OK at 17:33:32, never ALARM |
| F-15 | Migration finished at 18:00:19, inside the 15-minute grace period | Probe succeeds, no alarm | **Pass.** `/ready` `{"status":"ok"}`; alarm `OK` |
| F-17 | "Migrate database" run `38611162998` | Gate check passes in Actions before any AWS call | **Pass.** `OK: migrate-dev requires 1 reviewer(s), no administrator bypass, main only.` at 17:59:27, then the role was assumed; migration exit `0` |
| F-14 | Deploy from scratch | No ALARM email | **Pass.** Only OK emails as the service became healthy (17:48 and 17:49) |
| F-16 | Service scaled to 0 at 18:01:43; three outage alarms polled every 20 s | One alarm within about 3 minutes | **Partial.** Gaps filled with 0 (`FILL`): ALARM by 18:06:58 (**about 5 min 15 s**). Container Insights `RunningTaskCount`: 18:09:45 (about 8 min). Raw `HealthyHostCount`: 18:11:51 (about 10 min). ALARM emails at 18:06, 18:09 and 18:11 |
| F-16 recovery | Service scaled to 1 at 18:11:51 | Alarms clear | **Pass.** Running tasks OK at 18:14:39; both load balancer alarms OK at 18:15:42; OK emails delivered; `/ready` `ok` |

## Notes

**Later timing clarification:** the approximately five-minute result below was one observation of the previous alarm configuration, not a floor or a guaranteed bound. The later 2-of-3 round 6 drill observed an alarm transition 4 min 3 s after the scaling request.

- **The quiet period covered the whole wait.** The task started about 17:46:43, so its grace period ran to about 18:01:43; the migration finished 84 s before that. A longer wait would have raised the alarm at that point, by design.
- **Container Insights did not help.** Its running-task count also stops reporting once no task is left, so its alarm waited on missing data like the original. It is turned off again (it adds cost).
- **About 5 minutes is the floor for an alarm on load balancer metrics:** they arrive with a delay, and the alarm needs 2 one-minute periods. The filled metric sees the same data as the raw one plus zeros, so it can never be slower; it replaces the original alarm's metric, keeping its name.
- **Alarm emails** contain the account ID, the subscriber address and an unsubscribe link (F-3), so they are not committed.

## Still open

- F-16: partly fixed (about 10 minutes down to about 5). Faster detection needs an event-driven alert, such as an EventBridge rule on ECS task-stopped events (also F-1), at the cost of an alert on every deployment.
- F-8 limits that IAM cannot close: AWS administrators are unconstrained, and command overrides on `ecs:RunTask` have no condition key.
- F-7: alert on mass `DELETE` (row counts).
- MB-008: sign-up still answers `409` for a registered email until confirm-by-email sign-up exists.
