"""Load synthetic training data into the MediBook database.

Usage:
    python -m app.seed            # add seed data if the database is empty
    python -m app.seed --reset    # drop all MediBook tables and data, then re-seed

The database is chosen by the standard PG* environment variables.

All data is fictional. Emails use the reserved example.com domain.
The demo password is read from MEDIBOOK_SEED_PASSWORD, or generated at random
and printed once. No password is stored in the repository.
"""
import argparse
import os
import secrets
from datetime import datetime, timedelta, timezone

from app import auth
from app.db import drop_all, get_connection, init_db

CLINICS = ["Northside Family Clinic", "Riverside Health Centre"]
SLOTS_PER_CLINIC = 5

DEMO_PATIENTS = [
    ("Alex Rivera", "alex.rivera@example.com"),
    ("Sam Taylor", "sam.taylor@example.com"),
]


def _reset_database() -> None:
    drop_all()
    print("Dropped all MediBook tables.")


def _future_slot_times() -> list[datetime]:
    """Weekday-style 9:00 to 13:00 slots starting tomorrow, in UTC."""
    start = (datetime.now(timezone.utc) + timedelta(days=1)).replace(
        hour=9, minute=0, second=0, microsecond=0
    )
    return [start + timedelta(hours=i) for i in range(SLOTS_PER_CLINIC)]


def seed() -> None:
    init_db()
    password = os.environ.get("MEDIBOOK_SEED_PASSWORD") or secrets.token_urlsafe(12)
    with get_connection() as conn:
        if conn.execute("SELECT COUNT(*) AS n FROM slots").fetchone()["n"] > 0:
            print("Database already seeded. Use --reset to start again.")
            return

        times = _future_slot_times()
        password_hash = auth.hash_password(password)
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO slots (clinic_name, starts_at) VALUES (%s, %s)",
                [(clinic, t) for clinic in CLINICS for t in times],
            )
            cur.executemany(
                "INSERT INTO patients (full_name, email, password_hash) VALUES (%s, %s, %s)",
                [(name, email, password_hash) for name, email in DEMO_PATIENTS],
            )

    print(f"Seeded {len(CLINICS) * SLOTS_PER_CLINIC} slots and {len(DEMO_PATIENTS)} demo patients.")
    for _, email in DEMO_PATIENTS:
        print(f"  {email}")
    if not os.environ.get("MEDIBOOK_SEED_PASSWORD"):
        print(f"Demo password (local training use only, shown once): {password}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed MediBook with synthetic data.")
    parser.add_argument("--reset", action="store_true", help="drop all MediBook tables and data first")
    args = parser.parse_args()
    if args.reset:
        _reset_database()
    seed()


if __name__ == "__main__":
    main()