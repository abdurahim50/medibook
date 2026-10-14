# Deployment (AWS, dev)

The `infra/` Terraform deploys the API to AWS for a working session, then removes it. It is a cost-reduced slice of the [target architecture](../diagrams/architecture.drawio.png).

Latest completed session: [round 6 verification, 2026-10-14](evidence/deployment/aws-verification-2026-10-14-round6.md). It verified `migrate-dev-v2`, migration before API startup, notification delivery, total-outage detection and recovery, then removed the dev stack. The image and resource counts in that record describe that session; take the digest from the Release run for the commit you intend to deploy.

## What is deployed

| Component | Dev deployment | Production target |
| --- | --- | --- |
| Entry | Application Load Balancer, HTTP on port 80, restricted to `allowed_cidrs` | Route 53, HTTPS with ACM certificate, TLS 1.2+ |
| Edge protection | AWS WAF: sign-in and sign-up rate limit per IP, AWS known-bad-inputs rules | Same, plus core rule set |
| Compute | ECS Fargate, 1 task (0.25 vCPU, 0.5 GB), read-only root filesystem, non-root, no capabilities | 2+ tasks across 2 AZs, autoscaling |
| Network | VPC with 2 public subnets, no NAT gateway; task accepts traffic from the ALB only | Private subnets, VPC endpoints, no public IPs on tasks |
| Image | Release workflow scans, signs and attests images on `main`; ECR uses immutable tags and scan on push; Terraform verifies signatures and SBOM attestations during deployment plans | Same, with a controlled CI deployment identity enforcing the deployment path |
| Data | RDS PostgreSQL 17 (`db.t3.micro`, single-AZ) in private subnets, reachable from the shared API/migration task security group; customer-managed KMS encryption; seven-day point-in-time recovery; enforced and verified TLS | Same, Multi-AZ, deletion protection, final snapshot, longer retention |
| Secrets | RDS-managed admin password in Secrets Manager, read only by the migration execution role; API uses IAM tokens with no password; demo password in SSM SecureString outside Terraform; migrations run from the approval-gated GitHub workflow | Same, with an independent reviewer and a separate administrator boundary |
| Logs | CloudWatch Logs (API and audit events, VPC flow logs), 7-day retention | Longer retention, KMS encryption |
| Alerting | Four CloudWatch alarms (denied requests, no healthy target, destructive SQL in the database log, API cannot reach the database) to an SNS topic encrypted with a customer-managed KMS key | Same, plus 5xx and task-stopped alerts, paging integration |
| Access | API execution role reads the image and writes API logs; migration execution role also reads seed and admin credentials; API task role limited to `rds-db:connect` as `medibook_app` | Same, with separated operator and administrator access |

Accepted risks for this environment are listed with expiry dates in [`.trivyignore`](../.trivyignore).

## Cost

Budgeting estimate retained from the original dev guide, assuming continuous operation in us-east-1. Prices were not recalculated during round 6; use the [AWS Pricing Calculator](https://calculator.aws/) for a current estimate with your usage and region.

| Item | Per day |
| --- | --- |
| Application Load Balancer (hours and capacity units) | ~$0.55 |
| Public IPv4 addresses (ALB and task) | ~$0.36 |
| Fargate task (0.25 vCPU, 0.5 GB) | ~$0.30 |
| WAF web ACL and rules (prorated) | ~$0.23 |
| RDS `db.t3.micro` and 20 GB gp3 storage | ~$0.51 |
| CloudWatch Logs, ECR storage, alarms, KMS key (prorated) | < $0.10 |
| **Total** | **~$2.05** |

Destroy the dev resources at the end of every session. The bootstrap ECR repository and S3 state bucket remain and can incur storage charges. Keep billing and budget alerts configured for the account.

## Stacks

| Stack | Path | Lifecycle | Contents |
| --- | --- | --- | --- |
| Account baseline | separate repository `aws-account-baseline` | Created once, shared by all projects | GitHub OIDC provider |
| Bootstrap | `infra/bootstrap/` | Created once, kept | ECR repository; release, read-only plan and approval-gated migration roles |
| Environment | `infra/` | Created and destroyed each session | Network, load balancer, WAF, ECS (API service and migration task), RDS, alarms |

They are separate root configurations with separate state because their lifecycles differ: CI must be able to publish images while the environment is destroyed.

## One-time setup

Create the `migrate-dev-v2` GitHub environment and save its required reviewer, disabled administrator bypass and main-only branch rule before applying the bootstrap stack. Add its `AWS_MIGRATE_ROLE_ARN` environment variable from the bootstrap output after the role exists. For an existing stack, reuse the existing role ARN and configure the environment before changing AWS trust. Do not dispatch migration until both the protection rules and role variable are saved.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="medibook-tfstate-${ACCOUNT_ID}"

# State bucket: versioned, encrypted, never public
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Demo password, generated and stored as a SecureString (never in Terraform state or git)
aws ssm put-parameter --name /medibook/dev/seed-password --type SecureString \
  --value "$(openssl rand -base64 18)"

# Local config files (both are git-ignored)
cd infra
sed "s/ACCOUNT_ID/${ACCOUNT_ID}/" backend.hcl.example > backend.hcl
cp terraform.tfvars.example terraform.tfvars   # then set allowed_cidrs (your IP) and alarm_email
terraform init -backend-config=backend.hcl

# Bootstrap stack: same bucket, its own state key
cd bootstrap
terraform init -backend-config=../backend.hcl -backend-config="key=medibook/bootstrap/terraform.tfstate"
terraform plan -out=bootstrap.tfplan   # requires the GitHub OIDC provider from the aws-account-baseline stack
../../scripts/policy-check.sh bootstrap.tfplan
terraform apply bootstrap.tfplan
terraform output -raw release_role_arn
cd ../..   # return to the repository root
```

Set the role ARNs as repository variables (GitHub: Settings → Secrets and variables → Actions → Variables). They are identifiers, not secrets:

| Variable | Value | Used by |
| --- | --- | --- |
| `AWS_RELEASE_ROLE_ARN` | `terraform -chdir=infra/bootstrap output -raw release_role_arn` | Release workflow: push, sign and attest images |
| `AWS_PLAN_ROLE_ARN` | `terraform -chdir=infra/bootstrap output -raw plan_role_arn` | CI `Terraform plan` job: read-only, plans both stacks and checks policies |

The migration role is set on a GitHub environment instead, so only jobs in that environment can use it (F-8). GitHub: Settings → Environments → New environment `migrate-dev-v2`:

- **Required reviewers:** yourself for this single-person training project (every migration waits for approval)
- **Allow administrators to bypass:** disabled
- For a team or production environment, require an independent reviewer and prevent self-review.
- **Deployment branches and tags:** selected branches, `main` only
- **Environment variable** `AWS_MIGRATE_ROLE_ARN`: `terraform -chdir=infra/bootstrap output -raw migrate_role_arn` (from the repository root)

The AWS role trusts only jobs running in that environment; the environment's rules decide who and which branch. Those rules are GitHub settings, not code, so the workflow's first step ([`scripts/check-migrate-environment.sh`](../scripts/check-migrate-environment.sh)) checks them and stops before requesting AWS credentials if a reviewer is missing, administrators can bypass, or branches other than `main` are allowed (F-17). To check by hand: `GITHUB_REPOSITORY=abdurahim50/medibook scripts/check-migrate-environment.sh`. In Actions, the guard also rejects fixture overrides and a run whose commit is no longer the current main head. Redispatch if main changes while approval is pending.

**One-time migration environment transition:** configure and check `migrate-dev-v2` before applying the bootstrap trust change. The new trust accepts only this environment, so old runs using `migrate-dev` cannot assume the role. Keep the old runs as historical evidence. Remove any explicit `migrate_github_environment = "migrate-dev"` override from bootstrap configuration. Environment administrators remain a trusted boundary: changing those protections is outside the guard's enforcement. The AWS subject is environment-scoped, not workflow-scoped; do not claim resistance to a malicious GitHub administrator.

This transition was [completed and checked in round 6](evidence/deployment/aws-verification-2026-10-14-round6.md#migration-controls-and-deployment-sequence). The live role read showed only the v2 subject, and a bootstrap plan without a command-line override reported no changes. Keep these steps for a new account or any checkout still configured for the old environment.

## Policy checks

Every saved plan is checked against the policies in [`policy/terraform/`](../policy/terraform/) before it is applied. `scripts/policy-check.sh` converts the plan to JSON (in a temporary file outside the repository, because plan JSON contains sensitive values in plain text) and runs Conftest. Any `FAIL` blocks the apply; fix the Terraform, plan again and re-check.

| Rule | Requirement |
| --- | --- |
| MB-POL-01 | No ingress from `0.0.0.0/0` or `::/0` except ports 80 and 443 |
| MB-POL-02 | ECR repositories use immutable tags and scan on push |
| MB-POL-03 | Identity policies grant no wildcard actions, no `NotAction`, and no `"Resource": "*"` except for actions AWS cannot scope |
| MB-POL-04 | Containers run as a non-root user with a read-only root filesystem, all capabilities dropped and no privileged mode |
| MB-POL-05 | Log groups have a retention period |
| MB-POL-06 | Every taggable resource has the `Project` tag |
| MB-POL-07 | Application load balancers drop invalid HTTP headers |
| MB-POL-08 | SNS topics are encrypted with a KMS key |
| MB-POL-09 | Container images are referenced by digest, and the plan includes image signature verification |
| MB-POL-10 | RDS databases are private, storage encrypted, backed up for at least seven days, use an RDS-managed admin password, and PostgreSQL parameter groups enforce TLS |

The CI `Terraform plan` job runs the same policies on real plans of both stacks for every pull request. It plans from an empty state, so it judges the whole configuration and never reads the state bucket.

Deployment is planned in two steps for this reason: the task definition contains the database address and secret ARN, which are only known once the database exists, so its container settings (MB-POL-04) can only be checked in the service plan after the base apply. A `WARN` means a value is only known after apply. For example, an IAM policy that references a log group created in the same plan has no final JSON yet; its `aws_iam_policy_document` statements are checked instead, so wildcard actions are still caught. CI unit-tests the policies and confirms a known-bad plan is blocked on every pull request.

Install Conftest once (checksum from the [release page](https://github.com/open-policy-agent/conftest/releases/tag/v0.71.1)):

```bash
curl -sSfLo /tmp/conftest.tgz https://github.com/open-policy-agent/conftest/releases/download/v0.71.1/conftest_0.71.1_Linux_x86_64.tar.gz
echo "c3f6b2a753bd56e377a1e51a95ae3e057f926f2e9139f7d5b5dfbbaf810f7985  /tmp/conftest.tgz" | sha256sum --check --strict
sudo tar -xzf /tmp/conftest.tgz -C /usr/local/bin conftest && rm /tmp/conftest.tgz
```

## Database connection

Every connection uses TLS with full verification (`PGSSLMODE=verify-full`), against the RDS certificate authorities baked into the image from [`certs/rds-global-bundle.pem`](../certs/README.md). There are two database roles (finding F-8):

| Role | Used by | Privileges | Credential |
| --- | --- | --- | --- |
| `medibook_admin` | Migration task (`medibook-dev-migrate`), once per deploy, started by the "Migrate database" workflow | Owner: creates tables, roles and grants | Password generated by RDS, kept in Secrets Manager under the database's KMS key, injected by ECS into the migration task only, through its own execution role; the API's execution role cannot read it |
| `medibook_app` | API service | `SELECT`/`INSERT` on patients and appointments, `SELECT` on slots, `SELECT`/`INSERT`/`DELETE` on sessions; no DDL, no `TRUNCATE`, not the owner | IAM token (15 minutes) signed with the task role; the role has no password |

The migration (`python -m app.seed`) creates the schema, the `medibook_app` role and its grants, the `TRUNCATE` warning triggers, and the demo data if the database is empty. The API never changes the schema. To connect as an operator, read the admin secret with `aws secretsmanager get-secret-value --secret-id "$(terraform output -raw db_secret_arn)"`; the database has no public endpoint, so connections go through a task in the VPC.

**Credential rotation:** RDS rotates the admin password every 7 days. The migration task reads it fresh on every run, and the API does not use it, so a rotation needs no redeploy. IAM tokens are generated per connection.

## Deploy a session

```bash
# Start from the repository root.
cd infra

# 1. Base infrastructure, including the database (no service yet). The image
#    digest is cleared so no task definition is planned before the database exists.
terraform plan -var image_digest= -out=base.tfplan
../scripts/policy-check.sh base.tfplan
terraform apply base.tfplan

# 2. Take the digest from the latest Release workflow run summary on main and
#    record it in terraform.tfvars (image_digest = "sha256:...")

# 3. Prepare signed task definitions with no API tasks running. The database
#    role and schema must exist before patients can reach the new service.
terraform plan -var desired_count=0 -out=service.tfplan
../scripts/policy-check.sh service.tfplan
terraform apply service.tfplan

# 4. Run the migration once: schema, application role and grants, demo data.
#    The API remains stopped while approval is pending.
#    GitHub → Actions → "Migrate database" → Run workflow (main), then approve the
#    migrate-dev-v2 deployment. The job fails unless the task exits 0. With the gh CLI:
#    gh workflow run migrate.yml --ref main
#    Running the task by hand still works for an administrator (break glass; see
#    the runbook) but is no longer the routine path (F-8).

# 5. Only after the migration workflow succeeds, start the API. This also
#    enables availability notifications. Do not use startup grace routinely.
terraform plan -var desired_count=1 -out=start-api.tfplan
../scripts/policy-check.sh start-api.tfplan
terraform apply start-api.tfplan

# Terraform does not wait for ECS service stability; wait before checking it.
aws ecs wait services-stable --cluster medibook-dev --services medibook-dev-api --region us-east-1
aws ecs describe-services --cluster medibook-dev --services medibook-dev-api --region us-east-1 \
  --query 'services[].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}' --output table
curl -sS --max-time 10 -i "$(terraform output -raw api_url)/health"
curl -sS --max-time 10 -i "$(terraform output -raw api_url)/ready"

# 6. Alerting: each new environment has a new, unconfirmed SNS subscription and
#    alarms reach no one until it is confirmed (F-13). Click "Confirm subscription"
#    in the AWS Notifications email; the check waits up to 10 minutes, then
#    publishes a test notification. Confirm the test email arrives.
../scripts/check-alerting.sh --test
```

For this one-task session, the ECS check should show desired 1, running 1 and pending 0, then HTTP 200 from both `/health` and `/ready`. Confirm the test email arrives; a successful SNS publish alone is not proof of delivery. A controlled alarm drill additionally checks CloudWatch-to-SNS delivery; see the [runbook](runbook.md#alarm-medibook-dev-api-no-healthy-targets).

For a controlled exceptional bootstrap, `MEDIBOOK_READINESS_GRACE_UNTIL` may specify a fixed UTC deadline at most 15 minutes ahead. It is unset by default, survives restarts without renewal, and ends early after a successful check. Do not set it for routine replacement tasks. The old nonzero `MEDIBOOK_READINESS_GRACE_SECONDS` configuration is rejected. Database connection failures on patient endpoints return controlled `503` responses and use the same log signal as the probe.

The demo password, when needed: `aws ssm get-parameter --name /medibook/dev/seed-password --with-decryption --query Parameter.Value --output text`.

**If requests time out:** your public IP has probably changed. Update `allowed_cidrs` in `terraform.tfvars`, then plan and apply.

**Signature verification is part of the plan.** [`infra/ecs.tf`](../infra/ecs.tf) runs [`scripts/verify-image-terraform.sh`](../scripts/verify-image-terraform.sh) as an external data source whenever an image digest is set, and the task definition has a precondition on its result. An image that was not signed by `release.yml` on `main`, or has no SBOM attestation, cannot be deployed through Terraform. Planning a deployment therefore needs `cosign`, `docker` and `jq` on the machine running Terraform. To check a digest on its own: `../scripts/verify-image.sh sha256:<digest>`.

## End of session

```bash
# Continue from the same infra/ directory used for the session above.
# image_digest is cleared so the destroy plan does not need to verify an image
# that may already have expired from ECR.
terraform plan -destroy -var image_digest= -out=destroy.tfplan
../scripts/policy-check.sh destroy.tfplan
terraform apply destroy.tfplan
terraform state list   # expected: no resources in the dev stack
```

Then inspect the dev resources in AWS. These commands list resources in the selected region; other projects may legitimately appear:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters
aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```

The bootstrap stack, state bucket and seed-password SSM parameter remain for the next session. With `skip_final_snapshot` and `delete_automated_backups` (dev settings), the synthetic database and its backups are deleted. Deletion times vary; the two KMS keys enter the configured seven-day pending-deletion period. Record the apply summary, state check and any resources created outside Terraform in the session evidence.
