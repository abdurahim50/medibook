"""The API's database role can read and write rows, and nothing else (finding F-8).

The test database user is a superuser, so each check switches to the restricted
role with SET ROLE, the same privileges the API has in AWS.
"""
from datetime import datetime, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg import errors

import app.db as db
from app.db import drop_all, get_connection, grant_app_access, migrate

APP_ROLE = "medibook_app_test"
PASSWORD = "Test-Only-Passw0rd"  # synthetic, used only inside this test run


@pytest.fixture
def app_role_db(monkeypatch):
    drop_all()
    monkeypatch.setenv("MEDIBOOK_APP_DB_USER", APP_ROLE)
    migrate()
    with get_connection() as conn:
        conn.execute(
            "INSERT INTO slots (clinic_name, starts_at) VALUES (%s, %s)",
            ("Northside Family Clinic", datetime(2030, 1, 1, 9, tzinfo=timezone.utc)),
        )
    yield


def as_app_role(statement: str, params=None):
    with get_connection() as conn:
        conn.execute(f'SET ROLE "{APP_ROLE}"')
        return conn.execute(statement, params)


@pytest.mark.parametrize(
    "statement",
    [
        "DROP TABLE appointments",
        "TRUNCATE appointments",
        "TRUNCATE patients CASCADE",
        "DELETE FROM patients",
        "DELETE FROM appointments",
        "UPDATE slots SET clinic_name = 'x'",
        "INSERT INTO slots (clinic_name, starts_at) VALUES ('x', now())",
        "ALTER TABLE patients ADD COLUMN x int",
        "CREATE TABLE stash (x int)",
    ],
)
def test_app_role_cannot_change_schema_or_destroy_data(app_role_db, statement):
    with pytest.raises(errors.InsufficientPrivilege):
        as_app_role(statement)


def test_grants_are_reapplied_and_role_is_not_duplicated(app_role_db):
    grant_app_access(APP_ROLE)  # second run: idempotent
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS p "
            "FROM information_schema.role_table_grants WHERE grantee = %s GROUP BY table_name",
            (APP_ROLE,),
        ).fetchall()
    assert {r["table_name"]: r["p"] for r in rows} == {
        "appointments": "INSERT,SELECT",
        "patients": "INSERT,SELECT",
        "sessions": "DELETE,INSERT,SELECT",
        "slots": "SELECT",
    }


def test_full_patient_journey_works_with_app_role_only(app_role_db, monkeypatch):
    """Sign up, sign in, book, list, sign out: every query runs as the restricted role."""
    real_connect = psycopg.connect

    def connect_as_app_role(*args, **kwargs):
        conn = real_connect(*args, **kwargs)
        conn.execute(f'SET ROLE "{APP_ROLE}"')
        return conn

    monkeypatch.setattr(db.psycopg, "connect", connect_as_app_role)
    from app.main import app

    with TestClient(app) as client:
        assert client.post(
            "/auth/signup",
            json={"full_name": "Test Patient", "email": "role@example.com", "password": PASSWORD},
        ).status_code == 201
        token = client.post(
            "/auth/signin", json={"email": "role@example.com", "password": PASSWORD}
        ).json()["access_token"]
        auth = {"Authorization": f"Bearer {token}"}
        slot_id = client.get("/slots", headers=auth).json()[0]["id"]
        assert client.post("/appointments", json={"slot_id": slot_id}, headers=auth).status_code == 201
        assert len(client.get("/appointments", headers=auth).json()) == 1
        assert client.get("/ready").status_code == 200
        assert client.post("/auth/signout", headers=auth).status_code == 204


def test_truncate_by_owner_raises_destructive_sql_warning(app_role_db):
    """The owner can still TRUNCATE, but it leaves a marker the log alarm matches (F-7)."""
    notices = []
    with get_connection() as conn:
        conn.add_notice_handler(lambda d: notices.append(d.message_primary))
        conn.execute("TRUNCATE appointments")
    assert any(m.startswith("DESTRUCTIVE_SQL: TRUNCATE on appointments") for m in notices)


@pytest.mark.parametrize("statement", [
    "DROP TABLE appointments CASCADE",
    "DrOp TaBlE appointments CASCADE",
    "drop\n   table\tappointments cascade",
    'DROP TABLE "appointments" CASCADE',
])
def test_any_spelling_of_drop_raises_destructive_sql_warning(app_role_db, statement):
    """The log filter is case-sensitive; the event trigger's marker is not (MB-007)."""
    notices = []
    with get_connection() as conn:
        conn.add_notice_handler(lambda d: notices.append(d.message_primary))
        conn.execute(statement)
    assert any(m.startswith("DESTRUCTIVE_SQL: DROP table public.appointments") for m in notices)
