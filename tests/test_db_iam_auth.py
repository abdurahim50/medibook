"""RDS IAM authentication: the API's role signs in with a short-lived token (F-8).

No database or AWS call is made: the token is signed locally with fake
credentials, and the connection attempt is intercepted.
"""
from urllib.parse import parse_qs, urlsplit

import app.db as db


def test_iam_token_is_a_signed_connect_request_for_pguser(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test-only-not-a-real-secret")
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("PGHOST", "medibook-dev.example.us-east-1.rds.amazonaws.com")
    monkeypatch.setenv("PGPORT", "5432")
    monkeypatch.setenv("PGUSER", "medibook_app")
    db._rds_client.cache_clear()

    token = db.iam_auth_token()
    query = parse_qs(urlsplit("https://" + token).query)

    assert token.startswith("medibook-dev.example.us-east-1.rds.amazonaws.com:5432/?")
    assert query["Action"] == ["connect"]
    assert query["DBUser"] == ["medibook_app"]
    assert query["X-Amz-Expires"] == ["900"]
    assert "X-Amz-Signature" in query
    db._rds_client.cache_clear()


def test_connection_uses_iam_token_as_password_when_enabled(monkeypatch):
    captured = {}
    monkeypatch.setenv("MEDIBOOK_DB_IAM_AUTH", "1")
    monkeypatch.setattr(db, "iam_auth_token", lambda: "signed-token")
    monkeypatch.setattr(db.psycopg, "connect", lambda **kwargs: captured.update(kwargs))

    db.get_connection()

    assert captured["password"] == "signed-token"


def test_connection_leaves_password_to_libpq_when_disabled(monkeypatch):
    captured = {}
    monkeypatch.delenv("MEDIBOOK_DB_IAM_AUTH", raising=False)
    monkeypatch.setattr(db.psycopg, "connect", lambda **kwargs: captured.update(kwargs))

    db.get_connection()

    assert "password" not in captured
