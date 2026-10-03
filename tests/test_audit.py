"""Tests for the audit log (MB-003).

Checks that security-relevant events are recorded, that cross-patient attempts
are flagged, and that no personal data or secrets reach the log.
"""
import logging

import pytest

from app import audit
from test_api import PASSWORD, client, signup_and_signin  # noqa: F401  (client is a fixture)


@pytest.fixture
def audit_log(caplog):
    caplog.set_level(logging.INFO, logger="medibook.audit")
    return caplog


def events(caplog) -> list[dict]:
    return [r.audit for r in caplog.records if r.name == "medibook.audit"]


def find(caplog, name: str, outcome: str) -> list[dict]:
    return [e for e in events(caplog) if e["event"] == name and e["outcome"] == outcome]


def test_successful_signin_is_logged_with_patient_id(client, audit_log):
    signup_and_signin(client, "alex@example.com")
    [entry] = find(audit_log, "auth.signin", "success")
    assert isinstance(entry["patient_id"], int)
    assert entry["request_id"] and entry["client_ip"]


def test_failed_signins_are_logged_with_reason(client, audit_log):
    signup_and_signin(client, "alex@example.com")
    client.post("/auth/signin", json={"email": "alex@example.com", "password": "wrong-password"})
    client.post("/auth/signin", json={"email": "nobody@example.com", "password": "wrong-password"})
    reasons = {e["reason"] for e in find(audit_log, "auth.signin", "failure")}
    assert reasons == {"bad_password", "unknown_account"}


def test_cross_patient_read_is_logged_as_denied(client, audit_log):
    alex = signup_and_signin(client, "alex@example.com")
    sam = signup_and_signin(client, "sam@example.com")
    appointment_id = client.post("/appointments", json={"slot_id": 1}, headers=alex).json()["id"]

    response = client.get(f"/appointments/{appointment_id}", headers=sam)

    assert response.status_code == 404  # the client still cannot tell the record exists
    [entry] = find(audit_log, "appointment.read", "denied")
    assert entry["reason"] == "not_owner"
    assert entry["appointment_id"] == appointment_id


def test_missing_appointment_is_not_flagged_as_denied(client, audit_log):
    alex = signup_and_signin(client, "alex@example.com")
    client.get("/appointments/999", headers=alex)
    assert find(audit_log, "appointment.read", "denied") == []
    [entry] = find(audit_log, "appointment.read", "failure")
    assert entry["reason"] == "not_found"


def test_invalid_token_is_logged(client, audit_log):
    client.get("/appointments", headers={"Authorization": "Bearer not-a-real-token"})
    [entry] = find(audit_log, "auth.session", "failure")
    assert entry["reason"] == "invalid_token"


def test_booking_is_logged(client, audit_log):
    alex = signup_and_signin(client, "alex@example.com")
    client.post("/appointments", json={"slot_id": 1}, headers=alex)
    [entry] = find(audit_log, "appointment.book", "success")
    assert entry["slot_id"] == 1


def test_log_contains_no_personal_data_or_secrets(client, audit_log):
    headers = signup_and_signin(client, "alex@example.com")
    token = headers["Authorization"].removeprefix("Bearer ")
    client.post("/appointments", json={"slot_id": 1}, headers=headers)
    client.post("/auth/signin", json={"email": "alex@example.com", "password": "wrong-password"})

    log_text = "\n".join(audit_log.messages + [str(e) for e in events(audit_log)])
    for secret in ("alex@example.com", "Test Patient", PASSWORD, "wrong-password", token):
        assert secret not in log_text


def test_response_carries_request_id(client):
    response = client.get("/health", headers={"X-Request-ID": "forged-id"})
    assert len(response.headers["X-Request-ID"]) == 32
    assert response.headers["X-Request-ID"] != "forged-id"


def test_audit_rejects_fields_outside_the_allow_list():
    with pytest.raises(ValueError):
        audit.event("auth.signin", "success", email="alex@example.com")