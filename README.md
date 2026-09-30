# MediBook

MediBook is a fictional clinic appointment booking service, built by Abdurahim Yongho as an independent security portfolio project. The first version will let a patient sign up, sign in, book an appointment and view only their own appointments.

Read the [company brief](docs/brief.md) for the main user journey, protected data and three most important assets. Track demonstrated work in the [evidence index](docs/evidence.md).

## Current status

Checkpoint 1: company definition and documentation prepared. This repository contains a plan, not a running application. No application code, tests or deployments exist yet. Verification of the repository, commits and reviewer access is tracked in the [evidence index](docs/evidence.md).

## Scope

In scope for the first working slice:

- Patient sign-up, sign-in and sign-out using synthetic accounts.
- Viewing a small, seeded set of available appointment slots.
- Booking an available slot and receiving confirmation.
- Viewing appointments belonging to the signed-in patient.
- A health endpoint and controlled errors for invalid input.

Out of scope for the first working slice:

- Payments and insurance processing.
- Real patient information or real clinical use.
- Staff/admin portals, appointment cancellation and rescheduling.
- AI intake assistance. This is a later phase after the booking journey works.
- Cloud deployment. Local operation comes first.

## Planned stack and why

| Technology | Planned purpose | Reason for choosing it |
| --- | --- | --- |
| Python + FastAPI | Application routes, input validation and booking logic | A focused Python API with a clear request/response model that I can explain. |
| SQLite | Local storage for synthetic accounts, slots and appointments | Keeps local setup small without a separate database service. Production suitability will be assessed later. |
| Docker | Package the application and its dependencies | Supports repeatable startup across development environments. |
| GitHub Actions | Run tests and relevant security checks on changes | Makes validation repeatable and provides linked failing/passing runs as evidence. |

pytest is planned for automated tests. AWS ECS Fargate is a later deployment candidate; no cloud resources will be created until architecture, cost and cleanup are documented.

## Local setup plan: not executable yet

Planned prerequisites: Ubuntu/WSL2 or a comparable Linux environment, Git, Python 3 with virtual-environment support, and a browser or HTTP client. Docker will be needed for the container phase. Exact supported versions will be recorded in Checkpoint 2.

The intended sequence is:

1. Clone the repository and enter its root directory.
2. Create a Python virtual environment with `python3 -m venv .venv`. A virtual environment isolates project dependencies from system Python.
3. Activate it with `source .venv/bin/activate` so Python and package installation use that environment.
4. Install the recorded dependencies with `python -m pip install -r requirements.txt` once that file exists.
5. Follow the documented database initialization and synthetic-data seeding steps once implemented.
6. Start the planned entry point using `python -m uvicorn app.main:app --host 127.0.0.1 --port 8000`. This serves the future FastAPI application on the local machine only.
7. Check the health endpoint, complete the patient booking journey and run `python -m pytest` once the tests exist.
8. Repeat the documented steps in a fresh clone and save the actual output.

`requirements.txt`, the application entry point, database initialization and tests do not exist yet. Checkpoint 2 will turn this plan into verified startup instructions.

## Security note

Training repo, synthetic data only, no real PHI. MediBook is not a clinical service or a claim of HIPAA compliance. Use fictional identities and reserved example email addresses. Keep passwords, tokens, local databases and real patient information out of commits, logs and screenshots.

The planned security boundary is the backend: it will derive patient identity from the authenticated session and enforce appointment ownership on every lookup. These controls are requirements, not completed implementation claims.

The repository is intended to remain private initially. Confirm that the intended reviewer has authorized access before recording reviewer-access evidence or submitting the portfolio.

## Roadmap

- [x] Checkpoint 1: Choose your company (brief, scope, assets)
- [ ] Checkpoint 2: Build a working slice (booking journey, health check, controlled errors)
- [ ] Checkpoint 3: Attack and defend the feature (threat model, before/after test)
- [ ] Checkpoint 4: Secure the delivery pipeline (PR checks, failing fixture)
- [ ] Checkpoint 5: Deploy, observe and recover (least-privilege deploy, runbook)
- [ ] Checkpoint 6: Package and explain (overview, walkthrough)

## AI use disclosure

AI tools (Claude) assisted with drafting and reviewing documentation and design decisions. I review every change, and I can explain the decisions and implementation in my own words. AI assistance for later code will be disclosed in this section.