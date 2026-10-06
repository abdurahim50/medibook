# Recovery drills, AWS dev

Incidents simulated against the running deployment and handled with [the runbook](../../runbook.md). All times are UTC. Drills 1 and 2: 2026-10-05, SQLite on the task. Drill 3: 2026-10-06, RDS PostgreSQL.

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

## Findings

| # | Finding | Impact | Action |
| --- | --- | --- | --- |
| F-1 | `api-no-healthy-targets` did not fire: it needs 2 consecutive minutes without a healthy target; the outage lasted about 30 seconds (drill 3: 48 seconds, also no alarm) | Short or repeated crashes leave no alert | Add an EventBridge rule on ECS task-stopped events and an ALB 5xx alarm (lower severity) |
| F-2 | After the replacement, Alex's earlier booking was gone (`GET /appointments` → `[]`) | SQLite on task storage: RTO 32 s, but RPO is everything since the last start | **Resolved 2026-10-06:** RDS PostgreSQL; drill 3 kept the booking and session. Multi-AZ remains a production setting |
| F-3 | The alarm email contains an unsubscribe link usable by anyone holding the message | A forwarded email could silence alerts | Confirm subscriptions with authenticated unsubscribe |
| F-4 | Security alarm detection is bounded by its 5-minute period | ~2 minutes to detect | Acceptable for dev; a 1-minute period trades cost and noise for speed |
| F-5 | Drill 3: every request, including each `/health` check, opens a new TLS connection to RDS (new connections every 2 s from the test loop, and in pairs every 15 s from the load balancer's health checks) | Connection set-up on every request adds latency and load on a small database | Use a connection pool (`psycopg_pool`) in production |
| F-6 | Drill 3: `/health` runs `SELECT 1` against RDS, and the load balancer uses it | A database outage would mark every task unhealthy, and ECS would keep replacing containers that are not at fault | Split liveness (`/health`, no database) from readiness (`/ready`, with database); point the load balancer health check at liveness |
