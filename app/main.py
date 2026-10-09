"""MediBook API routes."""
import logging
from contextlib import asynccontextmanager

import psycopg
from psycopg.errors import UniqueViolation

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app import audit, auth
from app.ratelimit import SigninLimiter
from app.db import get_connection
from app.models import (
    AppointmentResponse,
    BookingRequest,
    PatientResponse,
    SigninRequest,
    SignupRequest,
    SlotResponse,
    TokenResponse,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # No schema changes here: the API's database role cannot run DDL (finding F-8).
    # The schema is created by `python -m app.seed`, run as the database owner.
    app.state.signin_limiter = SigninLimiter()
    yield


app = FastAPI(title="MediBook", version="0.1.0", lifespan=lifespan)
bearer = HTTPBearer(auto_error=False)
logger = logging.getLogger("medibook.api")


@app.middleware("http")
async def request_context(request: Request, call_next):
    """Give every request an ID and record the caller's address for the audit log.

    The ID is always generated here; a client-supplied X-Request-ID is ignored so
    it cannot be used to forge or inject log entries.
    """
    rid = audit.new_request_id()
    rid_token = audit.request_id.set(rid)
    ip_token = audit.client_ip.set(request.client.host if request.client else None)
    try:
        response = await call_next(request)
    finally:
        audit.request_id.reset(rid_token)
        audit.client_ip.reset(ip_token)
    response.headers["X-Request-ID"] = rid
    response.headers.update(security_headers(request.url.path))
    return response


# Interactive API docs load Swagger UI scripts and styles from a CDN, so they get
# a CSP that allows them; every other response is JSON and gets the strictest one.
DOCS_PATHS = ("/docs", "/redoc")
DOCS_CSP = (
    "default-src 'none'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
    "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://fonts.googleapis.com; "
    "font-src https://fonts.gstatic.com; img-src 'self' data: https://fastapi.tiangolo.com https://cdn.redoc.ly; "
    "worker-src blob:; connect-src 'self'; frame-ancestors 'none'"
)


def security_headers(path: str) -> dict:
    """Response headers for a JSON API that returns patient data (OWASP REST Security)."""
    docs = path.startswith(DOCS_PATHS)
    return {
        # Never let a browser guess the content type of a response.
        "X-Content-Type-Options": "nosniff",
        # Responses may contain appointment data: never store them in any cache.
        "Cache-Control": "no-store",
        # Other sites cannot embed or read responses.
        "Content-Security-Policy": DOCS_CSP if docs else "default-src 'none'; frame-ancestors 'none'",
        "X-Frame-Options": "DENY",
        "Cross-Origin-Resource-Policy": "same-origin",
        "Referrer-Policy": "no-referrer",
    }


# ---------- Dependencies ----------

def current_patient_id(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> int:
    """Resolve the patient from the session token. This is the only source of identity."""
    patient_id = auth.get_patient_id_for_token(creds.credentials) if creds else None
    if patient_id is None:
        audit.event("auth.session", "failure", reason="missing_token" if creds is None else "invalid_token")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return patient_id


# ---------- Health ----------

# Liveness and readiness are separate (finding F-6). The load balancer and the
# container HEALTHCHECK use liveness, so a database outage does not make ECS
# replace API tasks that are not at fault.

@app.get("/health")
def health() -> dict:
    """Liveness: the process is up and serving requests. Never touches the database."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness: the API can reach the database. 503 without details when it cannot."""
    try:
        with get_connection() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error as exc:
        # Log the error class only: connection errors can include host names.
        logger.warning("readiness check failed: %s", type(exc).__name__)
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "unavailable"},
        )
    return {"status": "ok"}


# ---------- Auth ----------

@app.post("/auth/signup", status_code=status.HTTP_201_CREATED, response_model=PatientResponse)
def signup(body: SignupRequest):
    password_hash = auth.hash_password(body.password)
    try:
        with get_connection() as conn:
            patient_id = conn.execute(
                "INSERT INTO patients (full_name, email, password_hash) VALUES (%s, %s, %s) RETURNING id",
                (body.full_name, body.email.lower(), password_hash),
            ).fetchone()["id"]
    except UniqueViolation:
        audit.event("auth.signup", "failure", reason="email_taken")
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
    audit.event("auth.signup", "success", patient_id=patient_id)
    return PatientResponse(id=patient_id, full_name=body.full_name, email=body.email.lower())


@app.post("/auth/signin", response_model=TokenResponse)
def signin(body: SigninRequest, request: Request):
    # MB-002: refuse before checking the password, so a blocked caller cannot
    # keep guessing and does not cost an argon2 verification.
    limiter: SigninLimiter = request.app.state.signin_limiter
    client = audit.client_ip.get() or "unknown"
    wait = limiter.retry_after(body.email, client)
    if wait:
        audit.event("auth.signin", "denied", reason="rate_limited")
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Too many sign-in attempts. Try again later.",
            headers={"Retry-After": str(wait)},
        )

    with get_connection() as conn:
        row = conn.execute(
            "SELECT id, password_hash FROM patients WHERE email = %s", (body.email.lower(),)
        ).fetchone()
    # Same message for unknown email and wrong password: no account enumeration.
    # The log records which case it was; the client never learns.
    if row is None:
        limiter.record_failure(body.email, client)
        audit.event("auth.signin", "failure", reason="unknown_account")
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    if not auth.verify_password(row["password_hash"], body.password):
        limiter.record_failure(body.email, client)
        audit.event("auth.signin", "failure", reason="bad_password", patient_id=row["id"])
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    limiter.record_success(body.email)
    audit.event("auth.signin", "success", patient_id=row["id"])
    return TokenResponse(access_token=auth.create_session(row["id"]))


@app.post("/auth/signout", status_code=status.HTTP_204_NO_CONTENT)
def signout(
    patient_id: int = Depends(current_patient_id),
    creds: HTTPAuthorizationCredentials = Depends(bearer),
):
    auth.delete_session(creds.credentials)
    audit.event("auth.signout", "success", patient_id=patient_id)


# ---------- Slots ----------

@app.get("/slots", response_model=list[SlotResponse])
def list_available_slots(_: int = Depends(current_patient_id)):
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT s.id, s.clinic_name, s.starts_at
            FROM slots s
            LEFT JOIN appointments a ON a.slot_id = s.id
            WHERE a.id IS NULL AND s.starts_at > now()
            ORDER BY s.starts_at
            """
        ).fetchall()
    return [SlotResponse(**r) for r in rows]


# ---------- Appointments ----------

_APPOINTMENT_SELECT = """
    SELECT a.id, a.slot_id, s.clinic_name, s.starts_at, a.status
    FROM appointments a
    JOIN slots s ON s.id = a.slot_id
"""


@app.post("/appointments", status_code=status.HTTP_201_CREATED, response_model=AppointmentResponse)
def book_appointment(body: BookingRequest, patient_id: int = Depends(current_patient_id)):
    try:
        with get_connection() as conn:
            slot = conn.execute(
                "SELECT starts_at > now() AS upcoming FROM slots WHERE id = %s", (body.slot_id,)
            ).fetchone()
            if slot is None:
                audit.event("appointment.book", "failure", reason="slot_not_found",
                            patient_id=patient_id, slot_id=body.slot_id)
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Slot not found")
            if not slot["upcoming"]:
                # A slot whose time has passed cannot be booked (MB-005).
                audit.event("appointment.book", "failure", reason="slot_in_past",
                            patient_id=patient_id, slot_id=body.slot_id)
                raise HTTPException(status.HTTP_409_CONFLICT, "Slot is no longer available")
            appointment_id = conn.execute(
                "INSERT INTO appointments (patient_id, slot_id) VALUES (%s, %s) RETURNING id",
                (patient_id, body.slot_id),
            ).fetchone()["id"]
            row = conn.execute(_APPOINTMENT_SELECT + " WHERE a.id = %s", (appointment_id,)).fetchone()
    except UniqueViolation:
        # UNIQUE(slot_id) rejects double booking, even under concurrent requests:
        # the second transaction waits for the first and then fails here.
        audit.event("appointment.book", "failure", reason="slot_taken",
                    patient_id=patient_id, slot_id=body.slot_id)
        raise HTTPException(status.HTTP_409_CONFLICT, "Slot already booked")
    audit.event("appointment.book", "success", patient_id=patient_id,
                appointment_id=row["id"], slot_id=row["slot_id"])
    return AppointmentResponse(**row)


@app.get("/appointments", response_model=list[AppointmentResponse])
def list_my_appointments(patient_id: int = Depends(current_patient_id)):
    with get_connection() as conn:
        rows = conn.execute(
            _APPOINTMENT_SELECT + " WHERE a.patient_id = %s ORDER BY s.starts_at", (patient_id,)
        ).fetchall()
    audit.event("appointment.list", "success", patient_id=patient_id)
    return [AppointmentResponse(**r) for r in rows]


@app.get("/appointments/{appointment_id}", response_model=AppointmentResponse)
def get_appointment(appointment_id: int, patient_id: int = Depends(current_patient_id)):
    # Ownership is enforced in the query itself (MB-001): a patient can only
    # match their own appointments. Someone else's ID returns 404, the same as
    # a missing record, so the response never confirms that the ID exists.
    with get_connection() as conn:
        row = conn.execute(
            _APPOINTMENT_SELECT + " WHERE a.id = %s AND a.patient_id = %s",
            (appointment_id, patient_id),
        ).fetchone()
        # For the audit log only: distinguish a cross-patient attempt from a missing ID.
        exists = row is not None or conn.execute(
            "SELECT 1 FROM appointments WHERE id = %s", (appointment_id,)
        ).fetchone() is not None
    if row is None:
        if exists:
            audit.event("appointment.read", "denied", reason="not_owner",
                        patient_id=patient_id, appointment_id=appointment_id)
        else:
            audit.event("appointment.read", "failure", reason="not_found",
                        patient_id=patient_id, appointment_id=appointment_id)
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Appointment not found")
    audit.event("appointment.read", "success", patient_id=patient_id, appointment_id=appointment_id)
    return AppointmentResponse(**row)