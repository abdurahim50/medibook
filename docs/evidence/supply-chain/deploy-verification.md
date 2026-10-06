# Signature verification enforced at deploy

Date: 2026-10-06 (America/Chicago). AWS account ID replaced with `111122223333`.

## What changed

| Part | Location | Purpose |
| --- | --- | --- |
| Plan-time verification | `data "external" "image_signature"` in [`infra/ecs.tf`](../../../infra/ecs.tf) | Runs [`scripts/verify-image-terraform.sh`](../../../scripts/verify-image-terraform.sh) whenever an image digest is set. It calls [`verify-image.sh`](../../../scripts/verify-image.sh) (Cosign signature and CycloneDX attestation, signer pinned to `release.yml@refs/heads/main`). Any failure fails the plan |
| Precondition | `lifecycle.precondition` on `aws_ecs_task_definition.api` | The task definition can only be planned when verification returned `verified = "true"` for the same digest |
| Policy | MB-POL-09 in [`policy/terraform/supply_chain.rego`](../../../policy/terraform/supply_chain.rego) | Blocks images not pinned by digest, and plans that do not contain the verification step (for example if the data source were removed) |
| Provider | `hashicorp/external` 2.4.2, recorded in the lock file | Runs the verification script from Terraform |

Before this change, verification was a documented manual step that an operator could skip.

## Test 1: signed image is accepted

Digest from Release #2, signed by the release workflow:

```
$ terraform plan -var image_digest=sha256:8782b736...ebaa04 -out=check.tfplan
data.external.image_signature[0]: Reading...
data.external.image_signature[0]: Read complete after 9s [id=-]
Plan: 37 to add, 0 to change, 0 to destroy.
plan exit: 0

$ ../scripts/policy-check.sh check.tfplan
WARN - MB-POL-03 aws_iam_role_policy.execution: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
WARN - MB-POL-03 aws_iam_role_policy.flow_logs: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead
23 tests, 21 passed, 2 warnings, 0 failures, 0 exceptions
```

## Test 2: unsigned image is refused

Simulates an attacker or insider with ECR push access bypassing CI: the image was built locally and pushed directly as `unsigned-test`, then planned for deployment.

```
$ docker push 111122223333.dkr.ecr.us-east-1.amazonaws.com/medibook/api:unsigned-test
$ terraform plan -var image_digest=sha256:bc69f677...ccd71d -out=bad.tfplan
│ The data source received an unexpected error while attempting to execute
│ the program.
│
│ Program: /usr/bin/bash
│ Error Message:
│ Error: no signatures found
│ error during command execution: no signatures found
│
│ State: exit status 10
plan exit: 1
```

No plan was produced, so nothing could be applied. The test image was then deleted from ECR (`batch-delete-image`, no failures).

## Limitations

- **Terraform path only.** Someone with AWS permissions to register task definitions or update the ECS service directly (console or API) is not checked. ECS has no admission control; mitigations are restricting `ecs:RegisterTaskDefinition` and `ecs:UpdateService` to the deployment identity, and moving deployment into CI.
- **Deploying needs `cosign`, `docker` and `jq`** on the machine running Terraform. A missing tool fails the plan (fails closed).
- **Destroy** is planned with `image_digest` cleared, so tearing down does not depend on an image that may have expired from ECR.
