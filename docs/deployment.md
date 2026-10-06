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
../../scripts/policy-check.sh bootstrap.tfplan
terraform apply bootstrap.tfplan
terraform output -raw release_role_arn
```

Set the role ARNs as repository variables (GitHub: Settings → Secrets and variables → Actions → Variables). They are identifiers, not secrets:

| Variable | Value | Used by |
| --- | --- | --- |
| `AWS_RELEASE_ROLE_ARN` | `terraform output -raw release_role_arn` | Release workflow: push, sign and attest images |
| `AWS_PLAN_ROLE_ARN` | `terraform output -raw plan_role_arn` | CI `Terraform plan` job: read-only, plans both stacks and checks policies |

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

The CI `Terraform plan` job runs the same policies on real plans of both stacks for every pull request. It plans from an empty state, so it judges the whole configuration and never reads the state bucket.

A `WARN` means a value is only known after apply. For example, an IAM policy that references a log group created in the same plan has no final JSON yet; its `aws_iam_policy_document` statements are checked instead, so wildcard actions are still caught. CI unit-tests the policies and confirms a known-bad plan is blocked on every pull request.

Install Conftest once (checksum from the [release page](https://github.com/open-policy-agent/conftest/releases/tag/v0.71.1)):

```bash
curl -sSfLo /tmp/conftest.tgz https://github.com/open-policy-agent/conftest/releases/download/v0.71.1/conftest_0.71.1_Linux_x86_64.tar.gz
echo "c3f6b2a753bd56e377a1e51a95ae3e057f926f2e9139f7d5b5dfbbaf810f7985  /tmp/conftest.tgz" | sha256sum --check --strict
sudo tar -xzf /tmp/conftest.tgz -C /usr/local/bin conftest && rm /tmp/conftest.tgz
```

## Deploy a session

```bash
cd infra

# 1. Base infrastructure (no service yet)
terraform plan -out=base.tfplan
../scripts/policy-check.sh base.tfplan
terraform apply base.tfplan

# 2. Take the digest from the latest Release workflow run summary on main and
#    record it in terraform.tfvars (image_digest = "sha256:...")

# 3. Plan: Terraform verifies the image signature and SBOM attestation during the
#    plan, and the plan fails if they do not verify. Then check policy and apply.
terraform plan -out=service.tfplan
../scripts/policy-check.sh service.tfplan
terraform apply service.tfplan

# 4. Check it
curl -s "$(terraform output -raw api_url)/health"
```

The demo password, when needed: `aws ssm get-parameter --name /medibook/dev/seed-password --with-decryption --query Parameter.Value --output text`.

After the first apply, confirm the SNS subscription email so alarms are delivered.

**If requests time out:** your public IP has probably changed. Update `allowed_cidrs` in `terraform.tfvars`, then plan and apply.

**Signature verification is part of the plan.** [`infra/ecs.tf`](../infra/ecs.tf) runs [`scripts/verify-image-terraform.sh`](../scripts/verify-image-terraform.sh) as an external data source whenever an image digest is set, and the task definition has a precondition on its result. An image that was not signed by `release.yml` on `main`, or has no SBOM attestation, cannot be deployed through Terraform. Planning a deployment therefore needs `cosign`, `docker` and `jq` on the machine running Terraform. To check a digest on its own: `../scripts/verify-image.sh sha256:<digest>`.

## End of session

```bash
cd infra
# image_digest is cleared so the destroy plan does not need to verify an image
# that may already have expired from ECR.
terraform plan -destroy -var image_digest= -out=destroy.tfplan
terraform apply destroy.tfplan
```

Then confirm nothing billable remains:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters
aws wafv2 list-web-acls --scope REGIONAL --query 'WebACLs[].Name'
```

The alert KMS key enters a 7-day pending-deletion period and is not billed during it. The state bucket and the SSM parameter remain for the next session.
