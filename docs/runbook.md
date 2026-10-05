# MediBook runbook (AWS dev)

Alarms notify the `medibook-dev-alerts` SNS topic. Each section below matches one alarm.

Set these first:

```bash
cd infra
CLUSTER=medibook-dev
SERVICE=medibook-dev-api
LOG_GROUP=/medibook/dev/api
TG=$(aws elbv2 describe-target-groups --names medibook-dev-api --query 'TargetGroups[0].TargetGroupArn' --output text)
```

---

## Alarm: `medibook-dev-api-no-healthy-targets`

**Meaning:** the load balancer has no healthy API task. Patients cannot sign in or book.

### 1. Confirm impact

```bash
curl -sS -m 10 -o /dev/null -w "%{http_code}\n" "$(terraform output -raw api_url)/health"
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}'
```

`503` and no healthy target confirm an outage.

### 2. Find the cause

```bash
# What ECS did recently: task stops, failed deployments, circuit breaker rollbacks
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].{running:runningCount,desired:desiredCount,deployments:deployments[].{status:status,rollout:rolloutState,reason:rolloutStateReason},events:events[:8].message}'

# Why the last task stopped
TASK=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --desired-status STOPPED --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK" \
  --query 'tasks[0].{stopped:stoppedReason,exit:containers[0].exitCode,reason:containers[0].reason}'

# Application output around the failure
aws logs tail $LOG_GROUP --since 15m
```

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `CannotPullContainerError` | Image digest missing from ECR, or execution role cannot pull | Check `image_digest` in `terraform.tfvars` exists in ECR; check `iam.tf` |
| `ResourceInitializationError` mentioning SSM | Seed password parameter missing or not readable | `aws ssm get-parameter --name /medibook/dev/seed-password` |
| Exit code 1, Python traceback in logs | Application error on start-up | Roll back to the previous digest (step 3) |
| Health check failures, task running | App up but `/health` failing (database path, permissions) | Check logs for `/data` errors |
| Task stopped by user or scaling | Manual action | Restore `desired_count` |

### 3. Recover

- **Task stopped or crashed:** ECS starts a replacement automatically. Watch until healthy:
  ```bash
  aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE && echo stable
  ```
- **Bad deployment:** the deployment circuit breaker rolls back automatically. If it did not, redeploy the last known good digest:
  ```bash
  terraform apply -var "image_digest=<last good digest>"
  ```
- **Configuration drift:** `terraform plan` shows the difference; apply to restore.

### 4. Verify and record

- `/health` returns `200`, target `healthy`, alarm back to `OK`.
- Record start time, detection time, recovery time, cause and follow-up actions in `docs/evidence/`.

**Known gap:** this alarm needs 2 consecutive minutes without a healthy target. A crash that ECS heals in under 2 minutes does not alarm (recovery drill, 2026-10-05: 32-second outage, no alarm). Check `aws ecs describe-services ... events` after any unexplained 503s.

**Known limitation:** the dev database is SQLite on task storage. A replaced task starts with a freshly seeded database, so bookings made before the failure are lost. Production uses RDS PostgreSQL with backups.

---

## Alarm: `medibook-dev-security-denied-requests`

**Meaning:** 5 or more denied requests in 5 minutes: cross-patient reads (`not_owner`) or throttled sign-ins (`rate_limited`). Possible probing or credential stuffing.

### 1. See who and what

CloudWatch Logs Insights on `/medibook/dev/api`:

```
fields @timestamp, event, reason, client_ip, patient_id, appointment_id, request_id
| filter type = "audit" and outcome in ["denied", "failure"]
| sort @timestamp desc
| limit 100
```

Group by source:

```
filter type = "audit" and outcome = "denied"
| stats count(*) as denied by client_ip, reason
| sort denied desc
```

### 2. Decide

| Pattern | Interpretation | Action |
| --- | --- | --- |
| One `patient_id`, many `not_owner` on different `appointment_id`s | A signed-in account enumerating records | Revoke that patient's sessions; investigate the account |
| One `client_ip`, many `rate_limited` across emails | Credential stuffing from one source | Block the IP in AWS WAF (IP set rule) |
| Many IPs, many `rate_limited` | Distributed attack | Lower the WAF rate limit; consider CAPTCHA at the edge |
| A single user retrying a forgotten password | Benign | No action |

### 3. Record

Note the time window, sources, accounts affected and actions taken in `docs/evidence/`.
