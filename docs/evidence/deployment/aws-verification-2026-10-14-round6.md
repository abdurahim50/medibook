# Round 6 deployment verification, 2026-10-14

This session deployed the corrections in [PR #46](https://github.com/abdurahim50/medibook/pull/46), verified the migration environment transition, exercised the availability alarm, and removed the dev deployment. The deployed main commit was `c751d125f9fb21391fea11775f67ff3b9e3eba9c`.

AWS results below come from the operator's terminal output and screenshots. GitHub workflow results were also inspected through the GitHub API. Times in the outage timeline are UTC.

## Build and local validation

- 145 tests passed locally on Python 3.14 with PostgreSQL. One Starlette/httpx deprecation warning was reported.
- Terraform recursive formatting passed.
- All 12 PR checks passed, including DCO, tests, Terraform plan, policy tests, and security scans. Commit `35f2390b1586bd4e1ff2513f36463294d2c9b1f9` had a verified SSH signature and DCO sign-off.
- [Release run](https://github.com/abdurahim50/medibook/actions/runs/38625026645) succeeded and verified the image signature and CycloneDX SBOM attestation.
- Image digest: `sha256:0c187541d874435e6d9f731beac009a1db79d1a99d10508caaef15e1359f6590`.

## Migration controls and deployment sequence

1. Configured `migrate-dev-v2` with one required reviewer, administrator bypass disabled, main-only deployments, and the existing migration role ARN as an environment variable.
2. The environment guard returned `OK: migrate-dev-v2 requires 1 reviewer(s), no administrator bypass, main only.`
3. The bootstrap plan changed only the migration role's trusted OIDC subject. All 28 policy checks passed, and the apply reported one resource changed.
4. An AWS `get-role` read confirmed one Allow statement, with audience `sts.amazonaws.com` and the exact subject `repo:abdurahim50@45608947/medibook@1396824993:environment:migrate-dev-v2`.
5. A subsequent bootstrap plan without a command-line environment override reported no changes.
6. Created 59 base resources with the image digest cleared and API desired count zero. The policy check reported 25 passes and three warnings for IAM JSON only known after apply; the source policy-document statements were checked. There were no failures.
7. Created the API service and both task definitions using the new signed image, with API desired count zero. All 28 policy checks passed.
8. [Migration run #7](https://github.com/abdurahim50/medibook/actions/runs/38632214450) ran on the deployed main commit after approval of `migrate-dev-v2`. The guard and role assumption succeeded. The task exited with code 0 and seeded 10 slots and two demo patients.
9. Only after migration succeeded, applied the plan to start one API task and enable availability notifications. All 28 policy checks passed. The apply changed two resources.

The trust transition excludes the old `migrate-dev` subject. A legacy workflow rerun was not attempted during this session. Environment administrators remain trusted; the AWS subject is environment-scoped rather than workflow-scoped.

## Healthy service and notification delivery

- ECS reported desired 1, running 1, pending 0.
- `/health` and `/ready` both returned HTTP 200 with `{"status":"ok"}`.
- All four alarms were enabled and in OK before the outage drill.
- The availability alarm had evaluation periods 3 and datapoints to alarm 2.
- `scripts/check-alerting.sh --test` found one confirmed subscription and published a test notification. The `MediBook alert test` email arrived.

## F-16 availability outage drill

The service was scaled to zero through the ECS API, keeping alarm actions enabled. The script polled the alarm approximately every 20 seconds and restored desired count one when ALARM was observed.

| Event | UTC time | Result |
| --- | --- | --- |
| Scaling test began | 20:43:38 | Desired count set to zero |
| CloudWatch state changed to ALARM | 20:47:41 | 243 seconds, or 4 minutes 3 seconds, after the test began |
| Poll observed ALARM | 20:47:51 | 253 seconds after the test began; restoration command then set desired count one |
| Recovery endpoint checks | 20:52:23 | `/health` and `/ready` both returned HTTP 200 |
| CloudWatch state changed to OK | 20:52:41.203 | Two healthy datapoints, from 20:48 and 20:49, satisfied the recovery threshold |

The ALARM email arrived. It confirmed `FILL(hosts, 0)`, a threshold below one, and two of three 60-second periods. A later target-health read reported the replacement target healthy, and the alarm read reported OK.

**F-16 remains partly resolved.** This test measured approximately four minutes from the scaling request to the alarm transition. It does not measure latency from the precise instant the last healthy target disappeared, establish a guaranteed maximum, or meet the earlier approximately three-minute goal. Recovery also depended on metric publication and alarm evaluation. The drill confirms detection and recovery in this session; it does not establish long-term healthy-state stability.

## F-15 validation scope

The deployment completed migration with no API tasks running and started the API afterward. Default-zero grace, the optional fixed UTC deadline, restart behavior, and controlled database-error responses are covered by the passing test suite. This session did not separately inject a database connection failure into a replacement API task or exercise the optional grace deadline live.

## Teardown

The saved destroy plan contained 62 dev resources. All 28 policy checks passed with no warnings or failures. Terraform reported `0 added, 0 changed, 62 destroyed`, and a subsequent `terraform state list` returned no resources. The separate bootstrap stack, including the updated migration trust, was retained.
