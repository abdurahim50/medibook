# Terraform plan and policy checks in CI

Date: 2026-10-06 (America/Chicago). AWS account ID replaced with `111122223333`.

## What changed

| Part | Location | Purpose |
| --- | --- | --- |
| CI job `Terraform plan` | [`ci.yml`](../../../.github/workflows/ci.yml) | On every pull request and push to `main`: format check, validate, plan both stacks, run Conftest on the real plans. Terraform, Cosign and Conftest installed from release binaries with checksum verification |
| Plan role `medibook-github-plan` | [`infra/bootstrap/main.tf`](../../../infra/bootstrap/main.tf) | Assumed through GitHub OIDC; trusted only for this repository's pull requests and `main`, by immutable owner and repository ID |
| Empty-state planning | `ci_backend_override.tf` written by the job | Replaces the S3 backend with a local one in CI, so plans start from an empty state |
| Required check | `main` ruleset | `Terraform plan` is one of 9 required checks |

### Why plan from an empty state

The policies judge the desired configuration, not the diff, so an empty state loses nothing for this gate. It means pull request code never gets access to the state bucket, which contains sensitive values (the real alert email). The environment plan uses placeholder inputs (`198.51.100.10/32`, `alerts@example.com`) and the most recent release image.

### What the plan role can do

| Statement | Actions | Resource |
| --- | --- | --- |
| EcrAuth | `ecr:GetAuthorizationToken` | `*` (not scopable) |
| ReadImagesAndSignatures | Describe, list and pull images and tags | `medibook/api` repository only |
| ListAvailabilityZones | `ec2:DescribeAvailabilityZones` | `*` (not scopable) |
| FindOidcProvider | `iam:ListOpenIDConnectProviders` | `*` (not scopable) |
| ReadOidcProvider | `iam:GetOpenIDConnectProvider` | GitHub provider only |

No write actions and no S3 access. Worst case, malicious pull request code can read container images that are built from the same repository.

## Finding: first run missing one permission

The first run planned the bootstrap stack and passed its policy check, then failed on the environment stack:

```
Error: fetching Availability Zones: operation error EC2: DescribeAvailabilityZones, https response error StatusCode: 403, ...
User: arn:aws:sts::111122223333:assumed-role/medibook-github-plan/github-plan-... is not authorized to perform: ec2:DescribeAvailabilityZones
  with data.aws_availability_zones.available, on network.tf line 5
```

The role assumption itself worked (the error names the plan role). The role had been scoped from the data sources in each stack, and `aws_availability_zones` in `network.tf` was missed. The action was added on its own statement (it cannot be scoped to a resource), MB-POL-03 was taught that it is an unscopable read, and a test was added (47 policy tests). Bootstrap plan: 1 to change (that statement only).

## Result

Pull request run after the fix:

```
Plan and check the bootstrap stack
Success! The configuration is valid.
Plan: 6 to add, 0 to change, 0 to destroy.
WARN - plan.json - main - MB-POL-03 aws_iam_role_policy.plan: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
WARN - plan.json - main - MB-POL-03 aws_iam_role_policy.release: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
23 tests, 21 passed, 2 warnings, 0 failures, 0 exceptions

Plan and check the environment stack
Latest release image: sha256:2a0641e984437bf99f56e89c3a2f370170ef995a9c26acac43a2e35dc4678078
Success! The configuration is valid.
data.external.image_signature[0]: Reading...
data.external.image_signature[0]: Read complete after 4s [id=-]
Plan: 37 to add, 0 to change, 0 to destroy.
WARN - plan.json - main - MB-POL-03 aws_iam_role_policy.execution: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
WARN - plan.json - main - MB-POL-03 aws_iam_role_policy.flow_logs: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
23 tests, 21 passed, 2 warnings, 0 failures, 0 exceptions
```

The same job passed on `main` after merge (CI #45), which exercised the second trusted subject (`ref:refs/heads/main`).

## Limitations

- **No drift detection.** Planning from an empty state checks the configuration, not differences from deployed resources. Drift is visible in operator plans against real state.
- **Deployment is still run from a workstation.** CI plans but never applies.
- **Placeholder inputs.** Policies that depend on real values (for example the allowed client CIDRs) are checked against placeholders in CI and against real values in operator plans.
