# Infrastructure policies

Rego policies, run with [Conftest](https://www.conftest.dev/), that check Terraform plans before they are applied. The rules and how they are run are described in [docs/deployment.md](../docs/deployment.md#policy-checks).

| Path | Contents |
| --- | --- |
| `terraform/*.rego` | Rules. `deny` blocks the apply; `warn` reports something that could not be evaluated |
| `terraform/policy_test.rego` | Unit tests for every rule, including allowed cases |
| `fixtures/plan-compliant.json` | Minimal plan that must pass |
| `fixtures/plan-violations.json` | Minimal plan that must trigger every rule |

## Run

```bash
conftest verify --policy policy/terraform                                  # unit tests
conftest test --policy policy/terraform policy/fixtures/plan-violations.json  # expect FAIL
```

## Add a rule

1. Give it the next ID (`MB-POL-09`) and start every message with it.
2. Name the NIST SP 800-53 control it supports in the file comment.
3. Add a test that it blocks a bad value and one that it allows the correct value.
4. Add a violation to `fixtures/plan-violations.json` and the ID to the list in the CI `Policy tests` job.
5. Run it against a real plan of both stacks before merging, so it does not block the current infrastructure.
