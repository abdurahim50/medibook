"""Bootstrap deadlines and controlled errors without a database connection."""
import logging
from datetime import datetime, timedelta, timezone

import psycopg
import pytest
from fastapi.testclient import TestClient

from app import auth, main


@pytest.fixture(autouse=True)
def normal_startup(monkeypatch):
    monkeypatch.delenv("MEDIBOOK_READINESS_GRACE_UNTIL", raising=False)
    monkeypatch.delenv("MEDIBOOK_READINESS_GRACE_SECONDS", raising=False)
    monkeypatch.setenv("MEDIBOOK_READINESS_PROBE_SECONDS", "0")


def test_default_startup_has_no_quiet_period():
    assert main.startup_grace_seconds() == 0


def test_fixed_deadline_does_not_restart_the_grace_window(monkeypatch):
    clock = [datetime(2026, 10, 14, 18, tzinfo=timezone.utc)]

    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return clock[0]

    monkeypatch.setattr(main, "datetime", Clock)
    monkeypatch.setenv("MEDIBOOK_READINESS_GRACE_UNTIL", "2026-10-14T18:15:00Z")
    assert main.startup_grace_seconds() == 900
    clock[0] += timedelta(minutes=14)
    assert main.startup_grace_seconds() == 60
    clock[0] += timedelta(minutes=1)
    assert main.startup_grace_seconds() == 0


@pytest.mark.parametrize("deadline", [
    "not-a-date", "2026-10-14T18:15:00", "2026-10-14T18:15:00+01:00",
])
def test_invalid_bootstrap_deadline_is_rejected(monkeypatch, deadline):
    monkeypatch.setenv("MEDIBOOK_READINESS_GRACE_UNTIL", deadline)
    with pytest.raises(ValueError):
        main.startup_grace_seconds()


def test_deadline_more_than_fifteen_minutes_ahead_is_rejected(monkeypatch):
    monkeypatch.setenv("MEDIBOOK_READINESS_GRACE_UNTIL",
                       (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat())
    with pytest.raises(ValueError, match="at most 15 minutes"):
        main.startup_grace_seconds()


def test_relative_grace_cannot_silently_renew_on_restart(monkeypatch):
    monkeypatch.setenv("MEDIBOOK_READINESS_GRACE_SECONDS", "900")
    with pytest.raises(ValueError, match="instead of a relative"):
        main.startup_grace_seconds()


@pytest.mark.parametrize("error_type", [psycopg.OperationalError, psycopg.InterfaceError])
@pytest.mark.parametrize("method, path, body", [
    ("POST", "/auth/signup", {"full_name": "Synthetic Patient", "email": "test@example.com",
                              "password": "Synthetic-Test-Only"}),
    ("POST", "/auth/signin", {"email": "test@example.com", "password": "Synthetic-Test-Only"}),
    ("POST", "/auth/signout", None),
    ("GET", "/slots", None),
    ("GET", "/appointments", None),
    ("GET", "/appointments/1", None),
    ("POST", "/appointments", {"slot_id": 1}),
])
@pytest.mark.parametrize("phase", ["normal", "bootstrap", "after_success"])
def test_database_errors_are_controlled_and_use_the_probe_signal(
    monkeypatch, caplog, error_type, method, path, body, phase,
):
    if phase != "normal":
        monkeypatch.setenv("MEDIBOOK_READINESS_GRACE_UNTIL",
                           (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat())

    def unavailable():
        raise error_type("synthetic-db.internal: synthetic connection failure")

    monkeypatch.setattr(main, "get_connection", unavailable)
    monkeypatch.setattr(auth, "get_connection", unavailable)
    with TestClient(main.app) as client:
        if phase == "after_success":
            main.readiness.succeeded()
        with caplog.at_level(logging.INFO, logger="medibook.api"):
            response = client.request(method, path, json=body,
                                      headers={"Authorization": "Bearer synthetic-token"})
    assert response.status_code == 503
    assert response.json() == {"detail": "Service temporarily unavailable"}
    assert response.headers["Retry-After"] == "60"
    assert response.headers["Cache-Control"] == "no-store"
    assert "synthetic-db.internal" not in response.text
    records = [r for r in caplog.records if r.name == "medibook.api"]
    assert len(records) == 1
    expected = "database not ready yet" if phase == "bootstrap" else "readiness check failed"
    assert records[0].getMessage() == f"{expected}: {error_type.__name__}"
    assert records[0].exc_info is None


def test_unexpected_programming_error_is_not_converted_to_database_unavailable(monkeypatch):
    def bug():
        raise RuntimeError("synthetic implementation bug")

    monkeypatch.setattr(main, "get_connection", bug)
    with TestClient(main.app) as client, pytest.raises(RuntimeError):
        client.post("/auth/signin", json={"email": "test@example.com", "password": "Synthetic-Test-Only"})
