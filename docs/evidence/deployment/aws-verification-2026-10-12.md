# AWS verification, 2026-10-12

> Historical evidence: this record describes the versions, configuration and results from its stated session. Use the [current deployment guide](../../deployment.md) and [round 6 verification](aws-verification-2026-10-14-round6.md) for the later implementation and rollout.

The fixes from the [external review](../reviews/2026-10-09-external-review.md) and drill 5 were tested only locally and in CI until now. This session deployed `main` to AWS and checked each one against the live environment, then destroyed it.

- **Image:** release `d4b66cdee920`, deployed by digest (`sha256:51babdc2...`), signature and SBOM attestation verified during the plan
- **Base stack:** 56 resources; policy check 26 passed, 2 warnings. **Service stack:** 3 resources; policy check 28 of 28
- **Migration:** one-off `medibook-dev-migrate` task as `medibook_admin`, exit `0`
- **Clean-up:** environment destroyed (58 resources); no RDS instances, load balancers or ECS clusters left

Times are UTC. Account ID, endpoint and personal IP address are redacted.

## Results

| Item | Test | Expected | Result |
| --- | --- | --- | --- |
| F-11 | `/ready` straight after the migration, first IAM sign-in | `200` on the first call | **Pass.** `{"status":"ok"}` on the first call (drill 5: `503` at 5 s) |
| MB-004 | Failed sign-in sent with a forged `X-Forwarded-For: 6.6.6.6` | Audit `client_ip` is the address the ALB saw | **Pass.** Logged `client_ip` `50.211.x.x` (the real address); `6.6.6.6` ignored |
| MB-006 | As `medibook_admin`: `SELECT pg_sleep(1.5), $1::text AS probe` with a synthetic email bound to `$1` | Slow-statement line, no parameter values | **Pass.** `duration: 1507.500 ms execute <unnamed>: SELECT pg_sleep(1.5), $1::text AS probe`; no `parameters:` line, synthetic email absent from the log |
| MB-007 | Event trigger installed by the migration | `medibook_warn_drop` on `sql_drop`, enabled | **Pass.** `pg_event_trigger`: `medibook_warn_drop`, `sql_drop`, enabled `O`; no warning in the migration log. RDS allows `rds_superuser` members to create event triggers |
| MB-007 | `DrOp TaBlE mb007_probe` (a scratch table) at 23:16:00 | `DESTRUCTIVE_SQL` warning, alarm | **Pass.** `WARNING: DESTRUCTIVE_SQL: DROP table public.mb007_probe by medibook_admin`; `db-destructive-sql` OK to ALARM at 23:17:47 (**1 min 47 s**) |
| MB-008 | 250 sign-up requests from one IP, 23:29:12 to 23:31:10 | WAF blocks sign-up as well as sign-in | **Pass.** Requests 1 to 160 reached the API (`422`, invalid body by design, so no accounts were created); 161 to 250 returned `403` from WAF |
| F-12 | Database ingress rule from the tasks revoked at 23:31:15; `/health` and `/ready` polled for 6 min | `/health` `200`, `/ready` `503`, alarm | **Pass.** `/health` `200` 16 of 16, `/ready` `503` 16 of 16; API log `readiness check failed: ConnectionTimeout`; `api-database-unreachable` OK to ALARM at 23:33:14 (**1 min 59 s**) |

## Notes

- **MB-008:** the rule's limit is 100 requests per 5 minutes, yet 160 got through. WAF counts requests over a sliding window and applies the block with a delay of up to about a minute, so a burst overshoots the limit before it is cut off. The limit slows guessing and enumeration; it is not an exact counter.
- **F-12:** the alarm fired because the test polled `/ready`. With no traffic and no polling it stays silent; a synthetic `/ready` check remains the production gap ([controls](../../controls.md)).
- **No alarm email was delivered.** Every new environment creates a new SNS email subscription, which stays `PendingConfirmation` until someone clicks the link; the confirmation request arrived at 22:51 and was not confirmed, so both alarms changed state with no one notified (F-13). The results above are the alarm state changes in CloudWatch; email delivery was last verified in drill 5.
- **Alarm emails** contain the account ID, the subscriber address and an unsubscribe link (F-3), so they are not committed.
- **The revoked rule** was deleted outside Terraform; the destroy plan dropped it on refresh and completed without errors.

## Still open

- F-13: alarms are silent until the email subscription is confirmed. Add a deployment check that fails while any subscription is `PendingConfirmation`, and in production subscribe a destination that needs no confirmation click (a chat or paging integration). **Fixed and verified 2026-10-13** ([verification](aws-verification-2026-10-13.md)).
- F-12: synthetic `/ready` check. **Fixed with a scheduled check in each API task and verified 2026-10-13** ([verification](aws-verification-2026-10-13.md)).
- F-8: `ecs:RunTask` with command overrides limited to a break-glass role. **Fixed and verified 2026-10-14** ([verification](aws-verification-2026-10-14.md)).
- F-7: alert on mass `DELETE` (row counts).
- MB-008: sign-up still answers `409` for a registered email until confirm-by-email sign-up exists.
