# Delivery evidence

Demonstrated outcomes for each milestone, with links to the commits, pull requests and test output that prove them. Dates are in America/Chicago time.

| # | Milestone | Evidence | Date | Outcome |
| --- | --- | --- | --- | --- |
| 1 | Product definition | [Product brief](brief.md), commit [`94dc017`](https://github.com/abdurahim50/medibook/commit/94dc017) | 2026-09-29 | Patient role and booking journey defined; data classified by CIA; three critical assets ranked; out-of-scope items recorded with reasons. |
| 2 | Booking API | [PR #1](https://github.com/abdurahim50/medibook/pull/1), merge commit [`0ccb216`](https://github.com/abdurahim50/medibook/commit/0ccb216), [test output](evidence/booking-api/pytest-output.txt), [fresh-clone run](evidence/booking-api/fresh-clone.txt) | 2026-09-30 | Booking journey works end to end: book `201`, double booking `409`, invalid input `422`, missing token `401`, health `200`. 16 tests pass. Setup verified from a fresh clone. Known issue MB-001 recorded in [SECURITY.md](../SECURITY.md). |
| 3 | Access control fix | [Threat model](threat-model.md), [before](evidence/access-control/before-fix.txt) and [after](evidence/access-control/after-fix.txt) test output, fixing PR (add link) | 2026-09-30 | Threat TM-01 (MB-001) reproduced with synthetic accounts: Sam read Alex's appointment (`200`). Lookup now scoped to the session's patient; the same request returns `404`. Regression test added; 18 tests pass. Remaining limitations listed in the threat model. |
| 4 | CI security pipeline | Pending | | |
| 5 | Deployment and recovery | Pending | | |
| 6 | Architecture overview and walkthrough | Pending | | |

