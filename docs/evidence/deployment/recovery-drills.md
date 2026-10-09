# Recovery drills, AWS dev

Incidents simulated against the running deployment and handled with [the runbook](../../runbook.md). All times are UTC. Drills 1 and 2: 2026-10-05, SQLite on the task. Drill 3: 2026-10-06, RDS PostgreSQL. Drill 4: 2026-10-08, database restore. Drill 5: 2026-10-09, drill 4 repeated after the hardening sprint (least-privilege database role, destructive-SQL alarm, liveness and readiness split).

## Drill 1: credential stuffing (security alarm)

**Injection:** 12 failed sign-ins against one account from one client.

| Time | Event | Elapsed |
| --- | --- | --- |
| 16:25:04 | Attack starts | 0:00 |
| 16:25:05 | Application responds `401` ×5, then `429` ×7 (MB-002) | ~1 s |
| 16:26:55 | `medibook-dev-security-denied-requests` → `ALARM` (7 denied events ≥ threshold 5) | 1 min 51 s |
| 16:26 | ALARM email received through SNS | ~2 min |
| 16:27:50 | Source identified with Logs Insights: one client IP, reason `rate_limited`, 7 events | 2 min 46 s |
| 16:31:55 | Alarm → `OK` after a quiet 5-minute window; recovery email received | 6 min 51 s |

**Triage query:**

```
filter type = "audit" and outcome = "denied"
| stats count(*) as denied by client_ip, reason
| sort denied desc
```

**Decision:** single-source credential stuffing. In a real incident the source IP would be blocked in AWS WAF; this was a planned test, so no block was applied.

## Drill 2: task crash (availability)

**Injection:** the only running API task was stopped (`aws ecs stop-task`).

| Time | Event | Elapsed |
| --- | --- | --- |
| 16:40:30 | Task stopped | 0:00 |
| 16:40:31 | Last `200` from the draining task | 0:01 |
| 16:40:36 | ECS deregisters the target | 0:06 |
| 16:40:37 | ECS starts a replacement task (no human action) | 0:07 |
| 16:40:41 | First `503`: no healthy target | 0:11 |
| 16:40:56 | Replacement registered with the load balancer | 0:26 |
| 16:41:02 | First `200`: service restored | 0:32 |
| 16:41:15 | ECS service steady | 0:45 |

**Recovery time:** 32 seconds, automatic. **Outage seen by clients:** about 20 to 30 seconds of `503`.

## Drill 3: task crash with RDS (data persistence)

**Injection:** the same as drill 2, after the move to RDS PostgreSQL ([RDS evidence](rds-postgresql.md)). Alex had booked slot 1 before the drill.

| Time | Event | Elapsed |
| --- | --- | --- |
| 22:51:39 | Task `01a4d830…` stopped | 0:00 |
| 22:52:02 | Last `200` from the old task; ECS deregisters it and starts draining | 0:23 |
| 22:52:03 | ECS starts replacement task `d0df256f…` (no human action) | 0:24 |
| 22:52:05 | First `503`: no healthy target | 0:26 |
| 22:52:46 | Replacement's first database connection (TLS 1.3, from a new private address) | 1:07 |
| 22:52:50 | Replacement registered with the load balancer | 1:11 |
| 22:52:53 | First `200`: service restored | 1:14 |
| 22:53:08 | ECS service steady | 1:29 |

After the replacement, with the token issued before the drill:

```
$ curl -s "$URL/appointments" -H "Authorization: Bearer $ALEX"
[{"id":1,"slot_id":1,"clinic_name":"Northside Family Clinic","starts_at":"2026-10-07T09:00:00Z","status":"booked"}]
```

**Recovery time:** 74 seconds, automatic. **Outage seen by clients:** about 48 seconds of `503`. **Data lost:** none; the session also survived, so Alex did not need to sign in again.

| | Drill 2 (SQLite) | Drill 3 (RDS) |
| --- | --- | --- |
| Recovery time | 32 s | 74 s |
| Booking after replacement | Lost (`[]`) | Kept |
| Session after replacement | Lost | Kept |
| Recovery point | Everything since the task started | Last committed transaction |

The longer recovery was not caused by the database: the replacement connected to RDS 4 seconds before it registered. ECS took 23 seconds to deregister the old task (6 s in drill 2) and 43 seconds to provision the replacement, pull the image and start Python. Fargate has no image cache, so start-up time varies between runs; measure several runs before quoting a range.

## Drill 4: operator error wipes the database (point-in-time restore)

**Scenario:** an operator runs the seed script with `--reset` against production: the right command against the wrong database. It was run as a one-off ECS task using the service's own task definition, network and credentials:

```bash
aws ecs run-task --cluster medibook-dev --launch-type FARGATE --task-definition "$TD" \
  --network-configuration "$NET" --started-by drill4-operator-error \
  --overrides '{"containerOverrides":[{"name":"api","command":["python","-m","app.seed","--reset"]}]}'
```

**Data before the incident:** Alex booked slot 1 (Northside Family Clinic) and Sam booked slot 6 (Riverside Health Centre).

| Time | Event | Since data loss |
| --- | --- | --- |
| 21:36:26 | Last good state confirmed: both bookings returned by the API | |
| 21:40:12 | Reset task launched; chosen as the restore target | |
| **21:40:33** | **`Dropped all MediBook tables.`** then re-seeded with empty demo data (exit code 0) | **0:00** |
| 21:40:34 onwards | API keeps returning `200`: Alex signs in and sees `[]`. No alarm | |
| 21:41:28 | `LatestRestorableTime` passes the restore target | 0:55 |
| 21:44:50 | Point-in-time restore started as a new instance, `medibook-dev-restored` (same subnets, security group, TLS parameter group and KMS key) | 4:17 |
| 21:55:32 | Restored instance available (restore took 10 min 42 s) | 14:59 |
| ~21:57 | Damaged instance renamed to `medibook-dev-damaged` (kept for investigation); API has no database | |
| ~22:00 | First attempt to rename the restored instance failed (F-9) | |
| 22:01:36, 22:02:42 | ECS replaced the API task twice as "unhealthy" (F-6) | |
| 22:03:25 | Restored instance live as `medibook-dev`; same endpoint, so no application change | 22:52 |
| 22:03:37 | `api-no-healthy-targets` → `ALARM`: the first alert of the incident, caused by the cutover, not the data loss | |
| **22:04:23** | **Both bookings returned by the API again** | **23:50** |
| 22:06:37 | Alarm → `OK` | |

After the cutover:

```
$ curl -s "$URL/appointments" -H "Authorization: Bearer $ALEX"
[{"id":1,"slot_id":1,"clinic_name":"Northside Family Clinic","starts_at":"2026-10-09T09:00:00Z","status":"booked"}]
$ curl -s "$URL/appointments" -H "Authorization: Bearer $SAM"
[{"id":2,"slot_id":6,"clinic_name":"Riverside Health Centre","starts_at":"2026-10-09T09:00:00Z","status":"booked"}]
```

**Recovery time (RTO): 23 min 50 s** from data loss to verified service: 4 min waiting for backups and starting, 10 min 42 s restoring, about 8 min cutting over (including the failed first attempt). **Recovery point (RPO): no data lost.** The target was 21 seconds before the wipe and nothing was written in that window; point-in-time recovery can restore to any second covered by the transaction logs, which lagged the live database by under a minute.

The client verified the restored instance's certificate (`verify-full`) after the rename without any change. Terraform's view after the cutover:

```
$ terraform plan
  # aws_db_instance.main will be updated in-place
      ~ identifier = "medibook-dev-damaged" -> "medibook-dev"
  # aws_ecs_task_definition.api[0] must be replaced
Plan: 1 to add, 3 to change, 1 to destroy.
```

Terraform still tracked the damaged instance as production (F-10). The plan was not applied. Clean-up: the restored instance, which Terraform did not know about, was deleted first, then the environment was destroyed (52 resources).

## Drill 5: drill 4 repeated after hardening (2026-10-09)

**Purpose:** prove the fixes for F-6, F-7 and F-8 against the same attack as drill 4. Deployed from image `sha256:a8f878dd...` (PR #25, signature and SBOM attestation verified before the plan).

**Set-up.** The API now signs in as `medibook_app` (row access only) with an RDS IAM token; schema, grants and seed data come from a one-off migration task that alone holds the admin credentials ([deployment guide](../../deployment.md#database-connection)).

| Time | Event |
| --- | --- |
| 02:35 | Service deployed; database empty. `/health` `200`, `/ready` `503`: `medibook_app` did not exist yet, so its sign-in was refused. ECS kept the task |
| 02:38:58 | Migration task: schema, role, grants, seed data; exit code `0` |
| 02:39:35 | `/ready` still `503`: `ConnectionTimeout`. The first IAM sign-in took longer than the 5-second connect timeout (F-11) |
| 02:39:38 | Database log: `connection authenticated: identity="medibook_app" method=pam`, TLS 1.3. Later sign-ins take 0.2 to 0.4 s |
| 02:43 | Alex books slot 1 |

### Part A: the drill 4 command, run with the API's own task definition

```bash
aws ecs run-task ... --task-definition medibook-dev-api:1 \
  --overrides '{"containerOverrides":[{"name":"api","command":["python","-m","app.seed","--reset"]}]}'
```

| Time | Event | Since attempt |
| --- | --- | --- |
| 02:44:01 | Task launched | 0:00 |
| 02:44:23 | Refused: `medibook_app ... ERROR: must be owner of table appointments`, statement logged; exit code `1` | 0:22 |
| 02:44:23 | Alex's booking still returned (`1` appointment) | |
| **02:45:54** | **`db-destructive-sql` → `ALARM`, email delivered** | **1:53** |
| 02:46:54 | Alarm → `OK` | |

In drill 4 this command deleted everything and raised no alarm. Now the API's credentials cannot drop a table, and the attempt itself alerts.

### Part B: the same command, run with the admin credentials (migration task)

This is the path F-8 leaves open: anyone allowed to run the migration task with a command override has the owner's rights.

| Time | Event | Since data loss |
| --- | --- | --- |
| 02:52:59 | Last good moment; chosen as the restore target | |
| 02:53:04 | Migration task launched with `--reset` | |
| **02:53:33** | **`medibook_admin ... statement: DROP TABLE IF EXISTS appointments, sessions, slots, patients CASCADE`**; re-seeded, exit code `0`. Alex's session returns `401` | **0:00** |
| **02:54:54** | **`db-destructive-sql` → `ALARM`, email delivered** | **1:21** |
| 02:56:16 | `LatestRestorableTime` past the restore target | 2:43 |
| 02:58:47 | Point-in-time restore started with `--enable-iam-database-authentication` | 5:14 |
| 03:10:28 | Restored instance available (11 min 41 s) | 16:55 |
| 03:11:14 | Cutover: damaged instance renamed | 17:41 |
| 03:12:36 | Restored instance renamed to `medibook-dev` | 19:03 |
| 03:13:58 | Restored instance available as `medibook-dev` | 20:25 |
| **03:14:59** | **API signs in to the restored instance as `medibook_app` (IAM, TLS 1.3); Alex's booking returned, and his session from before the wipe works again** | **21:26** |

A probe called `/health` and `/ready` every 5 seconds through the load balancer from 03:11:21 to 03:14:59:

| Endpoint | Results | Meaning |
| --- | --- | --- |
| `/health` | 41 × `200` | The API stayed live for the whole cutover |
| `/ready` | 37 × `503` (03:11:21 to 03:14:34), then 4 × `200` | No database from the first rename until the endpoint resolved to the restored instance (F-12) |

The API task was the same before and after (`ad3e76c2...`), and ECS recorded no events after the deployment at 02:35. In drill 4, ECS replaced the task twice during the cutover.

### Drill 4 and drill 5 compared

| | Drill 4 | Drill 5 |
| --- | --- | --- |
| Wipe with the API's credentials | Succeeded | **Refused**, data intact |
| First alert after data loss | 23 min, and only from the cutover outage | **1 min 21 s**, destructive-SQL alarm |
| Alert on a refused attempt | n/a | **1 min 53 s** |
| API tasks replaced during cutover | 2 | **0** (`/health` 41 × `200`) |
| Data loss to verified recovery | 23 min 50 s | **21 min 26 s** |
| Data lost | None | None |
| IAM sign-in after restore | n/a | Worked without a policy change (`dbuser:*/medibook_app`) |

**Clean-up.** Terraform still tracked the damaged instance (F-10, unchanged). The restored instance, now named `medibook-dev`, was checked by resource ID against the state (`db-HRTF...` live, `db-5345...` in state) and deleted first; then the environment was destroyed (57 resources).

## Findings

| # | Finding | Impact | Action |
| --- | --- | --- | --- |
| F-1 | `api-no-healthy-targets` did not fire: it needs 2 consecutive minutes without a healthy target; the outage lasted about 30 seconds (drill 3: 48 seconds, also no alarm; drill 4: it fired only during the cutover, 23 minutes after the data loss) | Short or repeated crashes leave no alert | Add an EventBridge rule on ECS task-stopped events and an ALB 5xx alarm (lower severity). Drill 5: the liveness split means a database outage no longer empties the target group, so this alarm cannot see one at all; see F-12 |
| F-2 | After the replacement, Alex's earlier booking was gone (`GET /appointments` → `[]`) | SQLite on task storage: RTO 32 s, but RPO is everything since the last start | **Resolved 2026-10-06:** RDS PostgreSQL; drill 3 kept the booking and session. Multi-AZ remains a production setting |
| F-3 | The alarm email contains an unsubscribe link usable by anyone holding the message | A forwarded email could silence alerts | Confirm subscriptions with authenticated unsubscribe |
| F-4 | Security alarm detection is bounded by its 5-minute period | ~2 minutes to detect | Acceptable for dev; a 1-minute period trades cost and noise for speed |
| F-5 | Drill 3: every request, including each `/health` check, opens a new TLS connection to RDS (new connections every 2 s from the test loop, and in pairs every 15 s from the load balancer's health checks) | Connection set-up on every request adds latency and load on a small database | Use a connection pool (`psycopg_pool`) in production |
| F-6 | Drill 3: `/health` runs `SELECT 1` against RDS, and the load balancer uses it | A database outage would mark every task unhealthy, and ECS would keep replacing containers that are not at fault | Split liveness (`/health`, no database) from readiness (`/ready`, with database); point the load balancer health check at liveness. **Confirmed in drill 4:** ECS replaced the task twice during the cutover, and each new task runs the seed script at start-up against the database being recovered. **Fixed 2026-10-08:** `/health` no longer touches the database; `/ready` returns `503` without details when it cannot reach it. To be re-verified in the next restore drill. **Verified in drill 5:** `/health` returned `200` 41 times during the cutover and the task was not replaced |
| F-7 | Drill 4: the data loss was silent. The API returned `200` with empty data and no alarm fired; the only alert came 23 minutes later from the cutover outage | Patients would notice before operators did | Alert on destructive SQL (`log_statement = ddl` in the parameter group, a metric filter on `DROP` and `TRUNCATE`); alert on sudden drops in row counts. **Partly fixed 2026-10-08, verified in drill 5** (refused attempt alarmed in 1 min 53 s, successful wipe in 1 min 21 s): `log_statement = ddl`, a `TRUNCATE` warning trigger on every table, and the `db-destructive-sql` alarm. Open: row-count drop alerts for mass `DELETE` |
| F-8 | Drill 4: anyone allowed to run ECS tasks can run any command with the database admin credentials; that is how the drill wiped the data | Operator error or a compromised CI or admin identity can destroy all data | An application database role without DDL rights; restrict `ecs:RunTask` and command overrides to a break-glass role; run migrations from CI only. **Partly fixed 2026-10-08, verified in drill 5** (the drill 4 command run with the API's task definition was refused; run with the migration task it still succeeded): the API signs in as `medibook_app` (row access only, IAM token, no password); the admin credentials go only to the migration task. Open: `ecs:RunTask` with command overrides is not yet limited to a break-glass role |
| F-9 | Drill 4: `aws rds wait db-instance-available` fails immediately on a name that does not exist yet, so the cutover script stopped half way | Added minutes to the recovery | Fixed in the [runbook](../../runbook.md#incident-data-deleted-or-corrupted-point-in-time-restore): poll until the new name is available |
| F-10 | Drill 4: the cutover was done outside Terraform, which still tracked the damaged instance as production; the next plan wanted to rename it back and rebuild the task definition around it | A routine apply after the incident could undo the recovery | Reconcile state before any apply (runbook); in production, point the application at a DNS name or parameter that one Terraform change can repoint. Drill 5: same drift; clean-up checked resource IDs before deleting |
| F-11 | Drill 5: the first IAM sign-in after the migration took about 8 seconds; the client gave up at its 5-second `connect_timeout`, so the first readiness check after the migration returned `503` although the database had accepted the sign-in. Later sign-ins took 0.2 to 0.4 s | A short false "not ready" after each deployment or restore | Raise `connect_timeout` to 10 s when IAM authentication is on, or keep connections in a pool (F-5) |
| F-12 | Drill 5: `/ready` returned `503` for 3 min 13 s during the cutover (both renames, then about 36 s until the endpoint resolved to the restored instance), and no alarm fired: the load balancer only checks liveness | A database outage is now invisible to alarms; patients see errors first | Alarm on `readiness check failed` in the API log (or on ALB 5xx, F-1); in production, cut over by repointing one DNS name or parameter instead of renaming two instances |
