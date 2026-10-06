# Policy checks on Terraform plans

Date: 2026-10-06 (America/Chicago).

## What was built

| Part | Location | Purpose |
| --- | --- | --- |
| Policies | [`policy/terraform/`](../../../policy/terraform/) | 8 Rego rules (MB-POL-01 to MB-POL-08), each mapped to a NIST SP 800-53 control |
| Unit tests | [`policy_test.rego`](../../../policy/terraform/policy_test.rego) | 41 tests: every rule has blocked and allowed cases |
| Fixtures | [`policy/fixtures/`](../../../policy/fixtures/) | A compliant plan that must pass and a plan that must trigger every rule |
| CI job | `Policy tests` in [`ci.yml`](../../../.github/workflows/ci.yml) | Checksum-verified Conftest; unit tests; compliant plan passes; violations plan fails with every rule ID present |
| Local gate | [`scripts/policy-check.sh`](../../../scripts/policy-check.sh) | Checks a saved plan before `terraform apply`; plan JSON kept in a private temporary file because it contains sensitive values |

| Rule | Requirement | NIST SP 800-53 |
| --- | --- | --- |
| MB-POL-01 | No ingress from `0.0.0.0/0` or `::/0` except ports 80 and 443 | SC-7 |
| MB-POL-02 | ECR: immutable tags, scan on push | SI-7, RA-5 |
| MB-POL-03 | Identity policies: no wildcard actions, no `NotAction`, no `"Resource": "*"` except unscopable actions | AC-6 |
| MB-POL-04 | Containers: non-root user, read-only root filesystem, all capabilities dropped, not privileged | CM-6, CM-7 |
| MB-POL-05 | Log groups have retention | AU-11 |
| MB-POL-06 | `Project` tag on every taggable resource | CM-8 |
| MB-POL-07 | ALBs drop invalid HTTP headers | SC-7, SI-10 |
| MB-POL-08 | SNS topics encrypted with KMS | SC-28 |

## Validation

**Unit tests and mutation check.** 41 of 41 tests pass. Two rules were broken on purpose (port 22 added to the allowed ports; the immutability check inverted); the tests failed for both, so they detect regressions.

**Real plans, current infrastructure: no violations.**

| Stack | Resources | Result |
| --- | --- | --- |
| Bootstrap (`infra/bootstrap`) | 4 (no-op) | 0 failures, 0 warnings |
| Environment (`infra`) | 37 to add | 0 failures, 2 warnings |

## Finding: IAM rule saw nothing on a fresh deploy

The first run on the environment plan passed with two warnings: both IAM role policies (`execution`, `flow_logs`) reference log groups created in the same plan, so their final JSON is unknown until apply. The IAM rule only read that JSON, so on a fresh deploy **it checked no IAM policy at all**. A wildcard such as `logs:*` would have passed.

**Fix.** The `aws_iam_policy_document` data sources the policies are built from still carry their actions in the plan, even when ARNs are unknown. MB-POL-03 now checks those statements too. Statements with principals (KMS key, SNS topic and trust policies) are skipped, because there `"Resource": "*"` means "this resource".

**Negative test on the real plan.** `infra/network.tf` was changed to grant the flow-logs role `logs:*`, planned and checked, then reverted:

```
FAIL - main - MB-POL-03 data.aws_iam_policy_document.flow_logs: allows action "logs:*"; grant specific actions

21 tests, 18 passed, 2 warnings, 1 failure, 0 exceptions
exit code: 1
```

The same change passed before the fix.

## Limitations

- **Real plans are checked locally, not in CI.** CI tests the policies against fixtures. Running `terraform plan` in CI needs AWS credentials available to pull request code and read access to state, which contains sensitive values; this is deferred until that trust path can be scoped (a read-only plan role, no state secrets).
- **Some values are only known after apply.** When a final IAM policy is unknown, its document's `"Resource": "*"` check runs only if the resources are known. Running the check again on the next plan covers the rest.
- **The gate depends on the operator running it.** Nothing stops `terraform apply` without the check; enforcement moves to CI with the plan role above.
