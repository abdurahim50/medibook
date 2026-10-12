# External review, 2026-10-09

An independent AI review of commit `99bc1af` (OpenAI) from source, CI logs and isolated local checks; it did not operate the AWS environment. Every finding was reproduced or checked before it was fixed.

| # | Finding | Verified how | Fix | Test |
| --- | --- | --- | --- | --- |
| MB-004 | `--forwarded-allow-ips=*`: Uvicorn took the leftmost `X-Forwarded-For` entry, which the client writes, so audit `client_ip` and the per-client throttle could be spoofed | Uvicorn's `ProxyHeadersMiddleware` with `X-Forwarded-For: 6.6.6.6, 203.0.113.9` from an ALB address: `*` returned `6.6.6.6`; the ALB subnets returned `203.0.113.9` | Trust only the public subnets the ALB runs in ([`infra/ecs.tf`](../../../infra/ecs.tf)) | [`tests/test_proxy_headers.py`](../../../tests/test_proxy_headers.py) |
| MB-006 | Slow-statement logs can include bind parameters; the Terraform comment said they did not | PostgreSQL 17 documentation: `log_parameter_max_length` defaults to `-1` (full values) | `log_parameter_max_length = 0` and `log_parameter_max_length_on_error = 0` ([`infra/database.tf`](../../../infra/database.tf)) | Next deployment: a slow statement with synthetic data, then check the RDS log has no parameters |
| MB-007 | Destructive-SQL filter matched two spellings only; patterns are case-sensitive | CloudWatch Logs pattern syntax documentation | Event trigger on `sql_drop` raises `DESTRUCTIVE_SQL` for every dropped table or schema; refused attempts match `must be owner of` and `permission denied for` ([`app/db.py`](../../../app/db.py), [`infra/monitoring.tf`](../../../infra/monitoring.tf)) | [`tests/test_least_privilege.py`](../../../tests/test_least_privilege.py): four spellings, including mixed case and line breaks |
| MB-005 | Past slots listed and bookable | Code review of `GET /slots` and `POST /appointments` | `starts_at > now()` when listing; `409` when booking a past slot ([`app/main.py`](../../../app/main.py)) | [`tests/test_api.py`](../../../tests/test_api.py) |
| R-5 | Rollback in the runbook ran `terraform apply` without the policy check | Runbook review | Rollback and drift recovery use a saved plan, `policy-check.sh`, then apply ([`docs/runbook.md`](../../runbook.md)) | n/a |
| R-6 | README start-up commands contained a placeholder and a fixed `sleep` | Copied the block into a shell | Pinned image digest and a bounded `pg_isready` wait ([`README.md`](../../../README.md)) | n/a |
| F-12 | A database outage left `/health` green with no alarm | Already recorded from drill 5 | `api-database-unreachable` alarm (same pull request) | Next deployment: stop the database, confirm the alarm |

**Not changed:** the reviewer's point that the readiness alarm needs traffic stands; a synthetic `/ready` check is listed as a production gap in [controls](../../controls.md).

**To verify in AWS at the next deployment:** MB-004 (audit `client_ip` with a forged header), MB-006 (no parameters in the RDS log), MB-007 (event trigger created by the migration as `medibook_admin`; if RDS refuses it, the migration logs a warning and the statement patterns remain), F-12 (alarm fires).

## Second round (commit `6342d03`)

The reviewer confirmed all six fixes above and CI green on 67 tests, then raised three more.

| # | Finding | Verified how | Fix | Test |
| --- | --- | --- | --- | --- |
| MB-008 | Sign-in skipped argon2 for unknown emails, a timing signal despite the identical `401`; sign-up's `409` confirms registered emails | Code review of `signin` and `signup` | Unknown emails are verified against a dummy hash ([`app/auth.py`](../../../app/auth.py)). Sign-up `409` accepted and documented in [SECURITY.md](../../../SECURITY.md#known-issues); sign-up added to the WAF per-IP rate limit ([`infra/waf.tf`](../../../infra/waf.tf)) | [`tests/test_api.py`](../../../tests/test_api.py): the dummy hash is verified on an unknown email |
| R-7 | README `pg_isready` without `-h` can succeed against the temporary init server on the Unix socket, before TCP is up | PostgreSQL container start-up runs an init server on the socket only | `-h 127.0.0.1` on both checks ([`README.md`](../../../README.md)) | n/a |
| R-8 | The database-unreachable threshold (3 a minute) can never be reached by a once-a-minute synthetic check, and low real traffic might not reach it either | Arithmetic; MediBook's traffic is low | Threshold lowered to at least 1 failure in each of 2 consecutive minutes; still ignores a single slow first sign-in (F-11) ([`infra/monitoring.tf`](../../../infra/monitoring.tf), [`docs/runbook.md`](../../runbook.md)) | n/a |
| R-9 | `pydantic_core` pinned separately from `pydantic`, so Dependabot proposed an incompatible pair (PR #29, blocked by CI) | `pip` refused: `pydantic==2.13.5` requires an exact `pydantic_core` | Separate pin removed; `pydantic` brings its exact core. PR #29 closed. Planned: `pip-tools` with hashes so every indirect pin moves with its parent ([`requirements.txt`](../../../requirements.txt)) | CI dependency install |
