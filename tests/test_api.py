"""API tests for the MediBook booking journey.

Each test runs against a fresh, temporary SQLite database, so tests never
touch the local development database and never depend on each other.
"""
import pytest
from fastapi.testclient import TestClient

from app.db import get_connection

PASSWORD = "Test-Only-Passw0rd"  # synthetic, used only inside this test run


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDIBOOK_DB", str(tmp_path / "test.db"))
    from app.main import app

    with TestClient(app) as test_client:
        conn = get_connection()
        conn.executemany(
            "INSERT INTO slots (clinic_name, starts_at) VALUES (?, ?)",
            [
                ("Northside Family Clinic", "2030-01-01T09:00:00+00:00"),
                ("Northside Family Clinic", "2030-01-01T10:00:00+00:00"),
            ],
        )
        conn.commit()
        conn.close()
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