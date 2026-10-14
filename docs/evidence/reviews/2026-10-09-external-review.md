# External review, 2026-10-09

An independent AI review of commit `99bc1af` (OpenAI) from source, CI logs and isolated local checks; it did not operate the AWS environment. Every finding was reproduced or checked before it was fixed.

| # | Finding | Verified how | Fix | Test |
| --- | --- | --- | --- | --- |
| MB-004 | `--forwarded-allow-ips=*`: Uvicorn took the leftmost `X-Forwarded-For` entry, which the client writes, so audit `client_ip` and the per-client throttle could be spoofed | Uvicorn's `ProxyHeadersMiddleware` with `X-Forwarded-For: 6.6.6.6, 203.0.113.9` from an ALB address: `*` returned `6.6.6.6`; the ALB subnets returned `203.0.113.9` | Trust only the public subnets the ALB runs in ([`infra/ecs.tf`](../../../infra/ecs.tf)) | [`tests/test_proxy_headers.py`](../../../tests/test_proxy_headers.py) |
| MB-006 | Slow-statement logs can include bind parameters; the Terraform comment said they did not | PostgreSQL 17 documentation: `log_parameter_max_length` defaults to `-1` (full values) | `log_parameter_max_length = 0` and `log_parameter_max_length_on_error = 0` ([`infra/database.tf`](../../../infra/database.tf)) | AWS, 2026-10-12: slow statement with a synthetic email, logged without parameters |
| MB-007 | Destructive-SQL filter matched two spellings only; patterns are case-sensitive | CloudWatch Logs pattern syntax documentation | Event trigger on `sql_drop` raises `DESTRUCTIVE_SQL` for every dropped table or schema; refused attempts match `must be owner of` and `permission denied for` ([`app/db.py`](../../../app/db.py), [`infra/monitoring.tf`](../../../infra/monitoring.tf)) | [`tests/test_least_privilege.py`](../../../tests/test_least_privilege.py): four spellings, including mixed case and line breaks |
| MB-005 | Past slots listed and bookable | Code review of `GET /slots` and `POST /appointments` | `starts_at > now()` when listing; `409` when booking a past slot ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py) |
| R-5 | Rollback in the runbook ran `terraform apply` without the policy check | Runbook review | Rollback and drift recovery use a saved plan, `policy-check.sh`, then apply ([`docs/runbook.md`](../../runbook.md)) | n/a |
| R-6 | README start-up commands contained a placeholder and a fixed `sleep` | Copied the block into a shell | Pinned image digest and a bounded `pg_isready` wait ([`README.md`](../../../README.md)) | n/a |
| F-12 | A database outage left `/health` green with no alarm | Already recorded from drill 5 | `api-database-unreachable` alarm (same pull request) | AWS, 2026-10-12: database ingress revoked, alarm in 1 min 59 s |

**Not changed:** the reviewer's point that the readiness alarm needs traffic stands; a synthetic `/ready` check is listed as a production gap in [controls](../../controls.md).

**Verified in AWS, 2026-10-12** ([evidence](../deployment/aws-verification-2026-10-12.md)): MB-004 (forged `X-Forwarded-For` ignored, real address logged), MB-006 (slow statement logged without parameters), MB-007 (event trigger installed by the migration; `DrOp TaBlE` alarmed in 1 min 47 s), F-12 (alarm in 1 min 59 s while `/health` stayed `200`). MB-008's WAF scope was checked in the same session: sign-up blocked from request 161.

## Second round (commit `6342d03`)

The reviewer confirmed all six fixes above and CI green on 67 tests, then raised three more.

| # | Finding | Verified how | Fix | Test |
| --- | --- | --- | --- | --- |
| MB-008 | Sign-in skipped argon2 for unknown emails, a timing signal despite the identical `401`; sign-up's `409` confirms registered emails | Code review of `signin` and `signup` | Unknown emails are verified against a dummy hash ([`app/auth.py`](../../../app/auth.py)). Sign-up `409` accepted and documented in [SECURITY.md](../../../SECURITY.md#known-issues); sign-up added to the WAF per-IP rate limit ([`infra/waf.tf`](../../../infra/waf.tf)) | [`tests/test_api.py`](../../../tests/test_api.py): the dummy hash is verified on an unknown email |
| R-7 | README `pg_isready` without `-h` can succeed against the temporary init server on the Unix socket, before TCP is up | PostgreSQL container start-up runs an init server on the socket only | `-h 127.0.0.1` on both checks ([`README.md`](../../../README.md)) | n/a |
| R-8 | The database-unreachable threshold (3 a minute) can never be reached by a once-a-minute synthetic check, and low real traffic might not reach it either | Arithmetic; MediBook's traffic is low | Threshold lowered to at least 1 failure in each of 2 consecutive minutes; still ignores a single slow first sign-in (F-11) ([`infra/monitoring.tf`](../../../infra/monitoring.tf), [`docs/runbook.md`](../../runbook.md)) | n/a |
| R-9 | `pydantic_core` pinned separately from `pydantic`, so Dependabot proposed an incompatible pair (PR #29, blocked by CI) | `pip` refused: `pydantic==2.13.5` requires an exact `pydantic_core` | Separate pin removed; `pydantic` brings its exact core. PR #29 closed. Then (2026-10-12) `pip-tools`: direct dependencies in `requirements.in`, hashed locks generated from it, installed with `--require-hashes --no-deps`; two unused pins (`certifi`, `packaging`) dropped as a result ([`requirements.txt`](../../../requirements.txt)) | CI dependency install |

## Third round (commit `9b8c2c6`)

The reviewer confirmed the second-round fixes, CI green on 68 tests and the AWS evidence, repeated three open items, and raised two new findings. Both were reproduced before fixing.

| # | Finding | Verified how | Fix | Test |
| --- | --- | --- | --- | --- |
| MB-009 | `422` responses echo the submitted value, including a rejected password | `POST /auth/signup` with an 11-character password returned it under `detail[].input`; a body missing `email` returned the whole body, password included | A validation handler returns only `type`, `loc` and `msg` ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py): five rejected bodies, none echoed |
| MB-010 | Throttle entries for keys never seen again are never removed | 1,000 keys recorded, clock moved past the window, an unrelated key checked: all 1,000 remained | Keys ordered by latest failure, expired ones removed on every write; 100,000-key cap per limiter, longest-idle evicted, warning logged ([`app/ratelimit.py`](../../../app/ratelimit.py)) | [`tests/test_ratelimit.py`](../../../tests/test_ratelimit.py): expiry and cap |
| F-13 | Alarm notifications not delivered in the AWS verification | Already recorded | [`scripts/check-alerting.sh`](../../../scripts/check-alerting.sh), a deployment step: fails until a subscription is confirmed, then publishes a test notification ([deployment](../../deployment.md)) | AWS, 2026-10-13: test email delivered |
| F-12 | Idle database outages undetected without a scheduled readiness probe | Already recorded | Each API task checks the database every 60 s and logs the line the alarm counts ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py): outage logged with no requests; AWS, 2026-10-13: alarm and email with no traffic |
| F-8 | Migration task with command overrides still runs as the database owner | Already recorded | Open | n/a |

## Fourth round (commit `5d378f2`)

The reviewer confirmed MB-009, MB-010, F-12 and F-13 with no blocking defect, and raised two small points.

| # | Finding | Fix | Test |
| --- | --- | --- | --- |
| R-10 | The probe slept a full interval after each check, so a 10 s check gave a 70 s gap | Checks run on a fixed schedule from start-up; an overrun slot is skipped, not made up ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py): 0.08 s checks at a 0.1 s interval keep 0.1 s spacing |
| R-11 | `MEDIBOOK_READINESS_PROBE_SECONDS` missing from [`.env.example`](../../../.env.example) | Added with its default and `0` to turn it off | n/a |

**Verified in AWS, 2026-10-13** ([evidence](../deployment/aws-verification-2026-10-13.md)): the reviewer noted that `check-alerting.sh --test` publishes to SNS directly, so it proves the subscription but not CloudWatch's path to the topic. With the database cut off and no traffic, the alarm fired in 3 min 3 s and both the ALARM and OK emails were delivered; probe failures were exactly 60 s apart (R-10).

## Fifth round (commit `c340126`)

The reviewer accepted F-12 and F-13 as verified from the AWS evidence and listed three remaining items, in priority order.

| # | Finding | Fix | Test |
| --- | --- | --- | --- |
| F-8 | Anyone allowed to run the migration task, or to pass its execution role, gets database-owner access | Separate execution roles: only the migration task's can read the admin secret ([`infra/iam.tf`](../../../infra/iam.tf)). Migrations run from the "Migrate database" workflow ([`.github/workflows/migrate.yml`](../../../.github/workflows/migrate.yml)) in an approval-gated GitHub environment; its AWS role can start only the migration task and pass only its execution role ([`infra/bootstrap/main.tf`](../../../infra/bootstrap/main.tf)). Not covered: AWS administrators, and command overrides (no IAM condition exists) | Next deployment: IAM policy simulation of both roles, and a migration run from the workflow |
| F-14 | Fresh deployments raise a false no-healthy-targets alarm | The alarm's actions are enabled by the service apply ([`infra/monitoring.tf`](../../../infra/monitoring.tf)) | Next deployment: no ALARM email during the deploy; service scaled to 0 still alerts |
| R-12 | R-10's fix was incomplete: a check longer than the interval was followed immediately by another (reproduced: 0.0014 s apart). The round 4 entry claimed overrun slots were skipped; they were not | Checks stay on the start-up grid and skip every slot a slow check overran ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py): 0.3 s checks on a 0.2 s grid start 0.4 s apart; fails on the previous code |

**Verified in AWS, 2026-10-14** ([evidence](../deployment/aws-verification-2026-10-14.md)): F-8: a migration ran from the workflow only after approval; IAM simulation showed the migration role can start only the migration task in `medibook-dev`, pass only its execution role and register no task definitions, and only that execution role can read the admin secret. F-14: no ALARM email during the deploy; with the service scaled to 0 the alarm and both emails still came. Three new findings: a false database-unreachable alarm until the gated migration runs (F-15), a total outage alarmed only after 8 min 49 s because the load balancer stops publishing the metric (F-16), and the approval gate living in GitHub settings outside Terraform, which let two early runs through unapproved (F-17). Fixed in [PR #43](https://github.com/abdurahim50/medibook/pull/43) and [PR #44](https://github.com/abdurahim50/medibook/pull/44), verified the same afternoon ([follow-up](../deployment/aws-verification-2026-10-14-followup.md)): F-15 and F-17 fixed; F-16 partly (about 10 minutes to about 5).
