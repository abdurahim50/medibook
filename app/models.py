"""Request and response models. Pydantic validates every request before route code runs."""
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, StrictInt

# Reject unknown fields: a client cannot sneak in extra data such as patient_id.
_strict = ConfigDict(extra="forbid")

EMAIL_PATTERN = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


# ---------- Requests ----------

class SignupRequest(BaseModel):
    model_config = _strict

    full_name: str = Field(min_length=1, max_length=100)
    email: str = Field(max_length=254, pattern=EMAIL_PATTERN)
    password: str = Field(min_length=12, max_length=128)


class SigninRequest(BaseModel):
    model_config = _strict

    email: str = Field(max_length=254, pattern=EMAIL_PATTERN)
    password: str = Field(min_length=1, max_length=128)


class BookingRequest(BaseModel):
    """Only the slot is supplied. Patient identity comes from the session, never the body."""
    model_config = _strict

    slot_id: StrictInt = Field(gt=0)


# ---------- Responses ----------

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class PatientResponse(BaseModel):
    id: int
    full_name: str
    email: str


class SlotResponse(BaseModel):
    id: int
    clinic_name: str
    starts_at: datetime


class AppointmentResponse(BaseModel):
    id: int
    slot_id: int
    clinic_name: str
    starts_at: datetime
    status: str