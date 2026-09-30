"""Load synthetic training data into the local MediBook database.

Usage:
    python -m app.seed            # add seed data if the database is empty
    python -m app.seed --reset    # delete the local database file and re-seed

All data is fictional. Emails use the reserved example.com domain.
The demo password is read from MEDIBOOK_SEED_PASSWORD, or generated at random
and printed once. No password is stored in the repository.
"""
import argparse
import os
import secrets
from datetime import datetime, timedelta, timezone

from app import auth
from app.db import DEFAULT_DB_PATH, get_connection, init_db

CLINICS = ["Northside Family Clinic", "Riverside Health Centre"]
SLOTS_PER_CLINIC = 5

DEMO_PATIENTS = [
    ("Alex Rivera", "alex.rivera@example.com"),
    ("Sam Taylor", "sam.taylor@example.com"),
]


def _reset_database() -> None:
    path = os.environ.get("MEDIBOOK_DB", DEFAULT_DB_PATH)
    for suffix in ("", "-wal", "-shm", "-journal"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)
    print(f"Removed local database: {path}")


def _future_slot_times() -> list[str]:
    """Weekday-style 9:00 to 13:00 slots starting tomorrow, in UTC ISO 8601."""
    start = (datetime.now(timezone.utc) + timedelta(days=1)).replace(
        hour=9, minute=0, second=0, microsecond=0
    )
    return [(start + timedelta(hours=i)).isoformat() for i in range(SLOTS_PER_CLINIC)]


def seed() -> None:
    init_db()
    conn = get_connection()
    try:
        if conn.execute("SELECT COUNT(*) FROM slots").fetchone()[0] > 0:
            print("Database already seeded. Use --reset to start again.")
            return

        times = _future_slot_times()
        conn.executemany(
            "INSERT INTO slots (clinic_name, starts_at) VALUES (?, ?)",
            [(clinic, t) for clinic in CLINICS for t in times],
        )

        password = os.environ.get("MEDIBOOK_SEED_PASSWORD") or secrets.token_urlsafe(12)
        password_hash = auth.hash_password(password)
        conn.executemany(
            "INSERT INTO patients (full_name, email, password_hash) VALUES (?, ?, ?)",
            [(name, email, password_hash) for name, email in DEMO_PATIENTS],
        )
        conn.commit()
    finally:
        conn.close()

    print(f"Seeded {len(CLINICS) * SLOTS_PER_CLINIC} slots and {len(DEMO_PATIENTS)} demo patients.")
    for _, email in DEMO_PATIENTS:
        print(f"  {email}")
    if not os.environ.get("MEDIBOOK_SEED_PASSWORD"):
        print(f"Demo password (local training use only, shown once): {password}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed MediBook with synthetic data.")
    parser.add_argument("--reset", action="store_true", help="delete the local database first")
    args = parser.parse_args()
    if args.reset:
        _reset_database()
    seed()


if __name__ == "__main__":
    main()