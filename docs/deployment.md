# Deployment (AWS, dev)

The `infra/` Terraform deploys the API to AWS for a working session, then removes it. It is a cost-reduced slice of the [target architecture](../diagrams/architecture.drawio.png).

## What is deployed

| Component | Dev deployment | Production target |
| --- | --- | --- |
| Entry | Application Load Balancer, HTTP on port 80, restricted to `allowed_cidrs` | Route 53, HTTPS with ACM certificate, TLS 1.2+ |
| Edge protection | AWS WAF: sign-in rate limit per IP, AWS known-bad-inputs rules | Same, plus core rule set |
| Compute | ECS Fargate, 1 task (0.25 vCPU, 0.5 GB), read-only root filesystem, non-root, no capabilities | 2+ tasks across 2 AZs, autoscaling |
| Network | VPC with 2 public subnets, no NAT gateway; task accepts traffic from the ALB only | Private subnets, VPC endpoints, no public IPs on tasks |
| Image | Built by the release workflow on `main`, scanned, pushed to ECR (immutable tags, scan on push), keyless-signed with Cosign and attested with a CycloneDX SBOM; deployed by digest after signature verification | Same, plus signature verification enforced at deploy by policy |
| Data | SQLite on task storage, seeded on start; lost when the task stops | RDS PostgreSQL Multi-AZ |
| Secrets | Demo password in SSM Parameter Store (SecureString), created outside Terraform | Secrets Manager with rotation |
| Logs | CloudWatch Logs (API and audit events, VPC flow logs), 7-day retention | Longer retention, KMS encryption |
| Alerting | Two CloudWatch alarms (denied requests, no healthy target) to an SNS topic encrypted with a customer-managed KMS key | Same, plus 5xx and task-stopped alerts, paging integration |
| Access | IAM execution role scoped to one repository, one log group and one parameter; no task role | Same |

Accepted risks for this environment are listed with expiry dates in [`.trivyignore`](../.trivyignore).

## Cost

Approximate us-east-1 prices while running:

| Item | Per day |
| --- | --- |
| Application Load Balancer (hours and capacity units) | ~$0.55 |
| Public IPv4 addresses (ALB and task) | ~$0.36 |
| Fargate task (0.25 vCPU, 0.5 GB) | ~$0.30 |
| WAF web ACL and rules (prorated) | ~$0.23 |
| CloudWatch Logs, ECR storage, alarms, KMS key (prorated) | < $0.10 |
| **Total** | **~$1.50** |

Resources are destroyed at the end of every session. The S3 state bucket stays and costs cents. A $10 monthly AWS Budget sends email alerts.

## Stacks

| Stack | Path | Lifecycle | Contents |
| --- | --- | --- | --- |
| Account baseline | separate repository `aws-account-baseline` | Created once, shared by all projects | GitHub OIDC provider |
| Bootstrap | `infra/bootstrap/` | Created once, kept | ECR repository, release role used by CI |
| Environment | `infra/` | Created and destroyed each session | Network, load balancer, WAF, ECS, alarms |

They are separate root configurations with separate state because their lifecycles differ: CI must be able to publish images while the environment is destroyed.

## One-time setup

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
terraform apply bootstrap.tfplan
terraform output -raw release_role_arn
```

Set the role ARN as the repository variable `AWS_RELEASE_ROLE_ARN` (GitHub: Settings → Secrets and variables → Actions → Variables). It is an identifier, not a secret.

## Deploy a session

```bash
cd infra

# 1. Base infrastructure (no service yet)
terraform apply

# 2. Take the digest from the latest Release workflow run summary on main, and verify it
../scripts/verify-image.sh sha256:<digest>

# 3. Record the digest in terraform.tfvars (image_digest = "sha256:..."), then deploy
terraform plan -out=service.tfplan
terraform apply service.tfplan

# 4. Check it
curl -s "$(terraform output -raw api_url)/health"
```

The demo password, when needed: `aws ssm get-parameter --name /medibook/dev/seed-password --with-decryption --query Parameter.Value --output text`.

After the first apply, confirm the SNS subscription email so alarms are delivered.

**If requests time out:** your public IP has probably changed. Update `allowed_cidrs` in `terraform.tfvars`, then plan and apply.

## End of session

```bash
cd infra
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

Then confirm nothing billable remains:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters
aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'
```

The alert KMS key enters a 7-day pending-deletion period and is not billed during it. The state bucket and the SSM parameter remain for the next session.
