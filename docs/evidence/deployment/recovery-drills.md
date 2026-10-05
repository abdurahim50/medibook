# Recovery drills, AWS dev, 2026-10-05

Two incidents were simulated against the running deployment and handled with [the runbook](../../runbook.md). All times are UTC.

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

## Findings

| # | Finding | Impact | Action |
| --- | --- | --- | --- |
| F-1 | `api-no-healthy-targets` did not fire: it needs 2 consecutive minutes without a healthy target; the outage lasted about 30 seconds | Short or repeated crashes leave no alert | Add an EventBridge rule on ECS task-stopped events and an ALB 5xx alarm (lower severity) |
| F-2 | After the replacement, Alex's earlier booking was gone (`GET /appointments` → `[]`) | SQLite on task storage: RTO 32 s, but RPO is everything since the last start | Production database: RDS PostgreSQL, Multi-AZ, automated backups |
| F-3 | The alarm email contains an unsubscribe link usable by anyone holding the message | A forwarded email could silence alerts | Confirm subscriptions with authenticated unsubscribe |
| F-4 | Security alarm detection is bounded by its 5-minute period | ~2 minutes to detect | Acceptable for dev; a 1-minute period trades cost and noise for speed |
