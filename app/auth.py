"""Password hashing and server-side session management for MediBook."""
import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from app.db import get_connection

SESSION_TTL = timedelta(hours=8)

_hasher = PasswordHasher()


# ---------- Passwords ----------

def hash_password(password: str) -> str:
    """Return an argon2id hash. The plaintext password is never stored."""
    return _hasher.hash(password)


# Verified against for unknown accounts, so sign-in costs the same argon2 work
# whether or not the email exists (MB-008: no timing signal for enumeration).
_DUMMY_HASH = _hasher.hash(secrets.token_urlsafe(32))


def burn_verification(password: str) -> None:
    """Do a full argon2 verification that always fails, to match the timing of a real one."""
    verify_password(_DUMMY_HASH, password)


def verify_password(password_hash: str, password: str) -> bool:
    """Return True only if the password matches the stored hash."""
    try:
        return _hasher.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


# ---------- Sessions ----------

def _now() -> datetime:
    return datetime.now(timezone.utc)


def _token_digest(token: str) -> str:
    """Store only a SHA-256 digest, so a leaked database holds no usable tokens."""
    return hashlib.sha256(token.encode()).hexdigest()


def create_session(patient_id: int) -> str:
    """Create a session and return the raw token. Only its digest is stored."""
    token = secrets.token_urlsafe(32)
    with get_connection() as conn:
        conn.execute(
            "INSERT INTO sessions (token, patient_id, expires_at) VALUES (%s, %s, %s)",
            (_token_digest(token), patient_id, _now() + SESSION_TTL),
        )
    return token


def get_patient_id_for_token(token: str) -> int | None:
    """Return the patient ID for a valid, unexpired token, otherwise None."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT patient_id, expires_at FROM sessions WHERE token = %s",
            (_token_digest(token),),
        ).fetchone()
        if row is None:
            return None
        if row["expires_at"] <= _now():
            conn.execute("DELETE FROM sessions WHERE token = %s", (_token_digest(token),))
            return None
        return row["patient_id"]


def delete_session(token: str) -> None:
    """Sign out: remove the session so the token stops working immediately."""
    with get_connection() as conn:
        conn.execute("DELETE FROM sessions WHERE token = %s", (_token_digest(token),))