"""Tests for sign-in throttling (MB-002)."""
import logging

from app.ratelimit import ACCOUNT_MAX_FAILURES, CLIENT_MAX_FAILURES, WINDOW_SECONDS, FailureLimiter
from test_api import PASSWORD, client, signup_and_signin  # noqa: F401  (client is a fixture)

WRONG = "wrong-password"


def signin(client, email, password):
    return client.post("/auth/signin", json={"email": email, "password": password})


def test_account_is_throttled_after_repeated_failures(client):
    signup_and_signin(client, "alex@example.com")
    for _ in range(ACCOUNT_MAX_FAILURES):
        assert signin(client, "alex@example.com", WRONG).status_code == 401

    # Even the correct password is refused while the account is throttled.
    response = signin(client, "alex@example.com", PASSWORD)
    assert response.status_code == 429
    assert int(response.headers["Retry-After"]) > 0


def test_unknown_account_is_throttled_the_same_way(client):
    for _ in range(ACCOUNT_MAX_FAILURES):
        assert signin(client, "nobody@example.com", WRONG).status_code == 401
    assert signin(client, "nobody@example.com", WRONG).status_code == 429


def test_successful_signin_resets_the_account_counter(client):
    signup_and_signin(client, "alex@example.com")
    for _ in range(ACCOUNT_MAX_FAILURES - 1):
        signin(client, "alex@example.com", WRONG)
    assert signin(client, "alex@example.com", PASSWORD).status_code == 200
    for _ in range(ACCOUNT_MAX_FAILURES - 1):
        assert signin(client, "alex@example.com", WRONG).status_code == 401


def test_throttling_one_account_does_not_block_another(client):
    signup_and_signin(client, "sam@example.com")
    for _ in range(ACCOUNT_MAX_FAILURES):
        signin(client, "alex@example.com", WRONG)
    assert signin(client, "sam@example.com", PASSWORD).status_code == 200


def test_client_is_throttled_across_many_accounts(client):
    # Credential stuffing: one client, one guess each against many accounts.
    for i in range(CLIENT_MAX_FAILURES):
        assert signin(client, f"user{i}@example.com", WRONG).status_code == 401
    assert signin(client, "another@example.com", WRONG).status_code == 429


def test_throttled_attempt_is_audited(client, caplog):
    caplog.set_level(logging.INFO, logger="medibook.audit")
    for _ in range(ACCOUNT_MAX_FAILURES + 1):
        signin(client, "alex@example.com", WRONG)
    denied = [r.audit for r in caplog.records
              if r.name == "medibook.audit" and r.audit["outcome"] == "denied"]
    assert [e["reason"] for e in denied] == ["rate_limited"]


def test_limit_expires_after_the_window():
    now = [0.0]
    limiter = FailureLimiter(max_failures=2, window_seconds=WINDOW_SECONDS, clock=lambda: now[0])
    limiter.record_failure("key")
    limiter.record_failure("key")
    assert limiter.retry_after("key") == WINDOW_SECONDS

    now[0] = WINDOW_SECONDS - 1
    assert limiter.retry_after("key") == 1

    now[0] = WINDOW_SECONDS
    assert limiter.retry_after("key") == 0