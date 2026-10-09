"""API tests for the MediBook booking journey.

Each test starts from empty tables in the PostgreSQL test database (see
tests/conftest.py), so tests never depend on each other.
"""
from datetime import datetime, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.db import drop_all, get_connection, init_db

PASSWORD = "Test-Only-Passw0rd"  # synthetic, used only inside this test run


@pytest.fixture
def client():
    drop_all()
    init_db()
    from app.main import app

    with TestClient(app) as test_client:
        with get_connection() as conn, conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO slots (clinic_name, starts_at) VALUES (%s, %s)",
                [
                    ("Northside Family Clinic", datetime(2030, 1, 1, 9, tzinfo=timezone.utc)),
                    ("Northside Family Clinic", datetime(2030, 1, 1, 10, tzinfo=timezone.utc)),
                ],
            )
        yield test_client


def signup_and_signin(client: TestClient, email: str) -> dict:
    """Create a patient and return an Authorization header for them."""
    client.post(
        "/auth/signup",
        json={"full_name": "Test Patient", "email": email, "password": PASSWORD},
    )
    token = client.post(
        "/auth/signin", json={"email": email, "password": PASSWORD}
    ).json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


# ---------- Health ----------

def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_does_not_use_the_database(client, monkeypatch):
    """Liveness must stay up during a database outage (finding F-6)."""
    def no_database():
        raise AssertionError("/health must not open a database connection")

    monkeypatch.setattr("app.main.get_connection", no_database)
    assert client.get("/health").status_code == 200


def test_ready_returns_ok_when_database_is_reachable(client):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_ready_returns_503_without_details_when_database_is_down(client, monkeypatch):
    def database_down():
        raise psycopg.OperationalError("connection to server at db.internal failed")

    monkeypatch.setattr("app.main.get_connection", database_down)
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    assert "db.internal" not in response.text


# ---------- Authentication ----------

def test_signup_does_not_return_password_or_hash(client):
    response = client.post(
        "/auth/signup",
        json={"full_name": "Alex", "email": "alex@example.com", "password": PASSWORD},
    )
    assert response.status_code == 201
    assert "password" not in response.text
    assert "password_hash" not in response.json()


def test_duplicate_email_is_rejected_case_insensitively(client):
    body = {"full_name": "Alex", "email": "alex@example.com", "password": PASSWORD}
    client.post("/auth/signup", json=body)
    body["email"] = "ALEX@example.com"
    assert client.post("/auth/signup", json=body).status_code == 409


def test_wrong_password_and_unknown_email_give_same_error(client):
    signup_and_signin(client, "alex@example.com")
    wrong_password = client.post(
        "/auth/signin", json={"email": "alex@example.com", "password": "not-the-password"}
    )
    unknown_email = client.post(
        "/auth/signin", json={"email": "nobody@example.com", "password": PASSWORD}
    )
    assert wrong_password.status_code == unknown_email.status_code == 401
    assert wrong_password.json() == unknown_email.json()


def test_protected_route_requires_token(client):
    assert client.get("/slots").status_code == 401
    assert client.get("/slots", headers={"Authorization": "Bearer fake"}).status_code == 401


def test_signout_invalidates_token(client):
    headers = signup_and_signin(client, "alex@example.com")
    assert client.post("/auth/signout", headers=headers).status_code == 204
    assert client.get("/appointments", headers=headers).status_code == 401


# ---------- Booking journey ----------

def test_patient_can_book_and_view_own_appointment(client):
    headers = signup_and_signin(client, "alex@example.com")

    slots = client.get("/slots", headers=headers).json()
    assert len(slots) == 2

    booked = client.post("/appointments", json={"slot_id": slots[0]["id"]}, headers=headers)
    assert booked.status_code == 201
    assert booked.json()["status"] == "booked"

    mine = client.get("/appointments", headers=headers).json()
    assert [a["id"] for a in mine] == [booked.json()["id"]]

    remaining = client.get("/slots", headers=headers).json()
    assert len(remaining) == 1


def test_patient_list_excludes_other_patients_appointments(client):
    alex = signup_and_signin(client, "alex@example.com")
    sam = signup_and_signin(client, "sam@example.com")
    client.post("/appointments", json={"slot_id": 1}, headers=alex)
    assert client.get("/appointments", headers=sam).json() == []


def test_double_booking_is_rejected(client):
    alex = signup_and_signin(client, "alex@example.com")
    sam = signup_and_signin(client, "sam@example.com")
    assert client.post("/appointments", json={"slot_id": 1}, headers=alex).status_code == 201
    response = client.post("/appointments", json={"slot_id": 1}, headers=sam)
    assert response.status_code == 409
    assert response.json() == {"detail": "Slot already booked"}


def test_booking_unknown_slot_returns_404(client):
    headers = signup_and_signin(client, "alex@example.com")
    assert client.post("/appointments", json={"slot_id": 999}, headers=headers).status_code == 404


# ---------- Controlled errors for bad input ----------

@pytest.mark.parametrize(
    "body",
    [
        {"slot_id": "abc"},              # wrong type
        {"slot_id": "1"},                # no silent string-to-int conversion
        {"slot_id": 0},                  # must be positive
        {},                              # missing field
        {"slot_id": 1, "patient_id": 2}, # identity must never come from the body
    ],
)
def test_bad_booking_input_returns_422(client, body):
    headers = signup_and_signin(client, "alex@example.com")
    assert client.post("/appointments", json=body, headers=headers).status_code == 422


def test_short_password_is_rejected(client):
    response = client.post(
        "/auth/signup",
        json={"full_name": "Alex", "email": "alex@example.com", "password": "short"},
    )
    assert response.status_code == 422

# ---------- Access control (TM-01 / MB-001) ----------

def test_patient_can_read_own_appointment(client):
    alex = signup_and_signin(client, "alex@example.com")
    booked = client.post("/appointments", json={"slot_id": 1}, headers=alex).json()
    response = client.get(f"/appointments/{booked['id']}", headers=alex)
    assert response.status_code == 200
    assert response.json()["id"] == booked["id"]


def test_patient_cannot_read_another_patients_appointment(client):
    alex = signup_and_signin(client, "alex@example.com")
    sam = signup_and_signin(client, "sam@example.com")
    booked = client.post("/appointments", json={"slot_id": 1}, headers=alex).json()

    response = client.get(f"/appointments/{booked['id']}", headers=sam)

    # 404, not 403: a 403 would confirm the appointment exists.
    assert response.status_code == 404
    assert response.json() == {"detail": "Appointment not found"}

def test_concurrent_booking_of_one_slot_lets_only_one_win(client):
    # Two patients' transactions insert the same slot at the same time. The
    # second waits on the first transaction's lock on the unique index, and
    # fails with a unique violation as soon as the first commits.
    import threading

    from psycopg.errors import UniqueViolation

    signup_and_signin(client, "alex@example.com")
    signup_and_signin(client, "sam@example.com")
    first, second = get_connection(), get_connection()
    try:
        first.execute("INSERT INTO appointments (patient_id, slot_id) VALUES (1, 1)")
        outcome = {}

        def book_second():
            try:
                second.execute("INSERT INTO appointments (patient_id, slot_id) VALUES (2, 1)")
                second.commit()
                outcome["second"] = "booked"
            except UniqueViolation:
                second.rollback()
                outcome["second"] = "rejected"

        waiter = threading.Thread(target=book_second)
        waiter.start()
        waiter.join(timeout=1)
        assert waiter.is_alive(), "second insert should wait for the first transaction"
        first.commit()
        waiter.join(timeout=5)
        assert outcome == {"second": "rejected"}
    finally:
        first.close()
        second.close()

    with get_connection() as conn:
        rows = conn.execute("SELECT patient_id FROM appointments WHERE slot_id = 1").fetchall()
    assert rows == [{"patient_id": 1}]


def test_times_are_returned_in_utc(client):
    # The database session is pinned to UTC, so the API does not depend on the
    # database server's time zone.
    headers = signup_and_signin(client, "alex@example.com")
    starts_at = client.get("/slots", headers=headers).json()[0]["starts_at"]
    assert starts_at in ("2030-01-01T09:00:00Z", "2030-01-01T09:00:00+00:00")


# ---------- Past slots (MB-005) ----------

def _add_slot(starts_at: datetime) -> int:
    with get_connection() as conn:
        return conn.execute(
            "INSERT INTO slots (clinic_name, starts_at) VALUES (%s, %s) RETURNING id",
            ("Northside Family Clinic", starts_at),
        ).fetchone()["id"]


def test_past_slots_are_not_listed(client):
    past_id = _add_slot(datetime(2020, 1, 1, 9, tzinfo=timezone.utc))
    auth = signup_and_signin(client, "past.list@example.com")
    ids = [s["id"] for s in client.get("/slots", headers=auth).json()]
    assert past_id not in ids
    assert len(ids) == 2  # the two future slots from the fixture


def test_past_slot_cannot_be_booked(client):
    past_id = _add_slot(datetime(2020, 1, 1, 9, tzinfo=timezone.utc))
    auth = signup_and_signin(client, "past.book@example.com")
    response = client.post("/appointments", json={"slot_id": past_id}, headers=auth)
    assert response.status_code == 409
    assert response.json() == {"detail": "Slot is no longer available"}
    assert client.get("/appointments", headers=auth).json() == []
