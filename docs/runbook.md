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
curl -sS -m 10 -o /dev/null -w "%{http_code}\n" "$(terraform output -raw api_url)/ready"
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{ip:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}'
```

`503` and no healthy target confirm an outage. `/health` `200` with `/ready` `503` means the API is up but cannot reach the database.

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
| Health check failures, task running | App process hung or not listening on its port (`/health` does not check the database) | Check logs for the last request served; roll back if a new image caused it |
| `/health` `200` but `/ready` `503` | API cannot reach the database (RDS down, security group, TLS, credentials) | Check RDS status and API logs for `readiness check failed`; see the data incident below |
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

---

## Incident: data deleted or corrupted (point-in-time restore)

No alarm covers this yet (finding F-7): it is reported by users or noticed in the data. Rehearsed in [drill 4](evidence/deployment/recovery-drills.md#drill-4-operator-error-wipes-the-database-point-in-time-restore): 23 min 50 s to recover, no data lost.

### 1. Contain and choose the restore time

Stop whatever is changing the data (stop the one-off task, revert the release). Find the last good moment from the application or audit logs and pick a restore time just before the damage. Check that the backups cover it:

```bash
aws rds describe-db-instances --db-instance-identifier medibook-dev \
  --query 'DBInstances[0].LatestRestorableTime' --output text
RESTORE_TIME=2026-01-01T00:00:00Z   # just before the damage, UTC
```

### 2. Restore to a new instance

The damaged database is not touched; the restore creates a copy with the same network, TLS settings and KMS key.

```bash
DB_SG=$(aws rds describe-db-instances --db-instance-identifier medibook-dev \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier medibook-dev --target-db-instance-identifier medibook-dev-restored \
  --restore-time "$RESTORE_TIME" --db-instance-class db.t3.micro --storage-type gp3 \
  --db-subnet-group-name medibook-dev --vpc-security-group-ids "$DB_SG" \
  --db-parameter-group-name medibook-dev-postgres17 \
  --no-publicly-accessible --no-multi-az --enable-cloudwatch-logs-exports postgresql
aws rds wait db-instance-available --db-instance-identifier medibook-dev-restored
```

### 3. Cut over

The endpoint is derived from the instance name, so giving the restored copy the production name repoints the application without a deployment. `aws rds wait` fails at once on a name that does not exist yet (finding F-9), so poll instead:

```bash
st() { aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null; }
aws rds modify-db-instance --db-instance-identifier medibook-dev \
  --new-db-instance-identifier medibook-dev-damaged --apply-immediately
until [ "$(st medibook-dev-damaged)" = available ]; do sleep 15; done
aws rds modify-db-instance --db-instance-identifier medibook-dev-restored \
  --new-db-instance-identifier medibook-dev --apply-immediately
until [ "$(st medibook-dev)" = available ]; do sleep 15; done
```

The API has no database between the two renames: `/ready` returns `503` and requests that need data fail, but `/health` stays `200`, so ECS keeps the tasks (finding F-6, fixed).

### 4. Verify, then reconcile Terraform before any apply

Sign in as an affected patient and check the records are back. Then **do not run `terraform apply`**: the state still points at the damaged instance, and a plan will try to rename it back (finding F-10). In dev, delete the restored copy first, then destroy as usual. In a long-lived environment, move state to the restored instance and review the plan before applying:

```bash
terraform state rm aws_db_instance.main
terraform import aws_db_instance.main medibook-dev
terraform plan   # review: the restored copy has no RDS-managed password until this is applied
```

Keep `medibook-dev-damaged` until the investigation is finished, then delete it.

### 5. Record

Record the timeline, restore time, RTO and RPO in `docs/evidence/`.
