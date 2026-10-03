# Deployment (AWS, dev)

The `infra/` Terraform deploys the API to AWS for a working session, then removes it. It is a cost-reduced slice of the [target architecture](../diagrams/architecture.drawio.png).

## What is deployed

| Component | Dev deployment | Production target |
| --- | --- | --- |
| Entry | Application Load Balancer, HTTP on port 80, restricted to `allowed_cidrs` | Route 53, HTTPS with ACM certificate, TLS 1.2+ |
| Edge protection | AWS WAF: sign-in rate limit per IP, AWS known-bad-inputs rules | Same, plus core rule set |
| Compute | ECS Fargate, 1 task (0.25 vCPU, 0.5 GB), read-only root filesystem, non-root, no capabilities | 2+ tasks across 2 AZs, autoscaling |
| Network | VPC with 2 public subnets, no NAT gateway; task accepts traffic from the ALB only | Private subnets, VPC endpoints, no public IPs on tasks |
| Image | ECR, immutable tags, scan on push, deployed by digest | Same, plus image signing |
| Data | SQLite on task storage, seeded on start; lost when the task stops | RDS PostgreSQL Multi-AZ |
| Secrets | Demo password in SSM Parameter Store (SecureString), created outside Terraform | Secrets Manager with rotation |
| Logs | CloudWatch Logs (API and audit events, VPC flow logs), 7-day retention | Longer retention, KMS encryption |
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
| CloudWatch Logs, ECR storage | < $0.05 |
| **Total** | **~$1.50** |

Resources are destroyed at the end of every session. The S3 state bucket stays and costs cents. A $10 monthly AWS Budget sends email alerts.

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
cp terraform.tfvars.example terraform.tfvars   # then set allowed_cidrs to your IP
terraform init -backend-config=backend.hcl
```

## Deploy a session

```bash
cd infra

# 1. Base infrastructure and the ECR repository (no service yet)
terraform apply

# 2. Build and push the image
REPO=$(terraform output -raw ecr_repository_url)
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:$TAG" ..
docker push "$REPO:$TAG"
DIGEST=$(aws ecr describe-images --repository-name medibook/api --image-ids imageTag="$TAG" \
  --query 'imageDetails[0].imageDigest' --output text)

# 3. Deploy the service by digest
terraform apply -var "image_digest=$DIGEST"

# 4. Check it
curl -s "$(terraform output -raw api_url)/health"
```

The demo password, when needed: `aws ssm get-parameter --name /medibook/dev/seed-password --with-decryption --query Parameter.Value --output text`.

## End of session

```bash
cd infra
terraform destroy -var "image_digest=$DIGEST"
```

Then confirm nothing billable remains:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters
```
