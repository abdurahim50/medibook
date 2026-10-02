"""MediBook API routes."""
import sqlite3
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app import audit, auth
from app.db import get_connection, init_db
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
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(title="MediBook", version="0.1.0", lifespan=lifespan)
bearer = HTTPBearer(auto_error=False)


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
    return response


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

@app.get("/health")
def health() -> dict:
    conn = get_connection()
    try:
        conn.execute("SELECT 1")
    finally:
        conn.close()
    return {"status": "ok"}


# ---------- Auth ----------

@app.post("/auth/signup", status_code=status.HTTP_201_CREATED, response_model=PatientResponse)
def signup(body: SignupRequest):
    conn = get_connection()
    try:
        cur = conn.execute(
            "INSERT INTO patients (full_name, email, password_hash) VALUES (?, ?, ?)",
            (body.full_name, body.email.lower(), auth.hash_password(body.password)),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        audit.event("auth.signup", "failure", reason="email_taken")
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
    finally:
        conn.close()
    audit.event("auth.signup", "success", patient_id=cur.lastrowid)
    return PatientResponse(id=cur.lastrowid, full_name=body.full_name, email=body.email.lower())


@app.post("/auth/signin", response_model=TokenResponse)
def signin(body: SigninRequest):
    conn = get_connection()
    try:
        row = conn.execute(
            "SELECT id, password_hash FROM patients WHERE email = ?", (body.email.lower(),)
        ).fetchone()
    finally:
        conn.close()
    # Same message for unknown email and wrong password: no account enumeration.
    # The log records which case it was; the client never learns.
    if row is None:
        audit.event("auth.signin", "failure", reason="unknown_account")
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    if not auth.verify_password(row["password_hash"], body.password):
        audit.event("auth.signin", "failure", reason="bad_password", patient_id=row["id"])
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
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
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT s.id, s.clinic_name, s.starts_at
            FROM slots s
            LEFT JOIN appointments a ON a.slot_id = s.id
            WHERE a.id IS NULL
            ORDER BY s.starts_at
            """
        ).fetchall()
    finally:
        conn.close()
    return [SlotResponse(**dict(r)) for r in rows]


# ---------- Appointments ----------

_APPOINTMENT_SELECT = """
    SELECT a.id, a.slot_id, s.clinic_name, s.starts_at, a.status
    FROM appointments a
    JOIN slots s ON s.id = a.slot_id
"""


@app.post("/appointments", status_code=status.HTTP_201_CREATED, response_model=AppointmentResponse)
def book_appointment(body: BookingRequest, patient_id: int = Depends(current_patient_id)):
    conn = get_connection()
    try:
        if conn.execute("SELECT 1 FROM slots WHERE id = ?", (body.slot_id,)).fetchone() is None:
            audit.event("appointment.book", "failure", reason="slot_not_found",
                        patient_id=patient_id, slot_id=body.slot_id)
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Slot not found")
        try:
            cur = conn.execute(
                "INSERT INTO appointments (patient_id, slot_id) VALUES (?, ?)",
                (patient_id, body.slot_id),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            # UNIQUE(slot_id) rejects double booking, even under concurrent requests.
            audit.event("appointment.book", "failure", reason="slot_taken",
                        patient_id=patient_id, slot_id=body.slot_id)
            raise HTTPException(status.HTTP_409_CONFLICT, "Slot already booked")
        row = conn.execute(_APPOINTMENT_SELECT + " WHERE a.id = ?", (cur.lastrowid,)).fetchone()
    finally:
        conn.close()
    audit.event("appointment.book", "success", patient_id=patient_id,
                appointment_id=row["id"], slot_id=row["slot_id"])
    return AppointmentResponse(**dict(row))


@app.get("/appointments", response_model=list[AppointmentResponse])
def list_my_appointments(patient_id: int = Depends(current_patient_id)):
    conn = get_connection()
    try:
        rows = conn.execute(
            _APPOINTMENT_SELECT + " WHERE a.patient_id = ? ORDER BY s.starts_at", (patient_id,)
        ).fetchall()
    finally:
        conn.close()
    audit.event("appointment.list", "success", patient_id=patient_id)
    return [AppointmentResponse(**dict(r)) for r in rows]


@app.get("/appointments/{appointment_id}", response_model=AppointmentResponse)
def get_appointment(appointment_id: int, patient_id: int = Depends(current_patient_id)):
    # Ownership is enforced in the query itself (MB-001): a patient can only
    # match their own appointments. Someone else's ID returns 404, the same as
    # a missing record, so the response never confirms that the ID exists.
    conn = get_connection()
    try:
        row = conn.execute(
            _APPOINTMENT_SELECT + " WHERE a.id = ? AND a.patient_id = ?",
            (appointment_id, patient_id),
        ).fetchone()
        # For the audit log only: distinguish a cross-patient attempt from a missing ID.
        exists = row is not None or conn.execute(
            "SELECT 1 FROM appointments WHERE id = ?", (appointment_id,)
        ).fetchone() is not None
    finally:
        conn.close()
    if row is None:
        if exists:
            audit.event("appointment.read", "denied", reason="not_owner",
                        patient_id=patient_id, appointment_id=appointment_id)
        else:
            audit.event("appointment.read", "failure", reason="not_found",
                        patient_id=patient_id, appointment_id=appointment_id)
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Appointment not found")
    audit.event("appointment.read", "success", patient_id=patient_id, appointment_id=appointment_id)
    return AppointmentResponse(**dict(row))