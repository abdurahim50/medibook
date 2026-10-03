"""Structured audit log for security-relevant events.

Each event is written as one JSON object per line to standard output, where the
container platform collects it. Only identifiers are logged: never names, emails,
passwords or session tokens. The allowed fields are fixed in code, so personal
data cannot be added to the log by accident.
"""
import json
import logging
import sys
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone

# Set per request by the middleware in app.main.
request_id: ContextVar[str | None] = ContextVar("request_id", default=None)
client_ip: ContextVar[str | None] = ContextVar("client_ip", default=None)

ALLOWED_FIELDS = frozenset({"patient_id", "appointment_id", "slot_id", "reason"})
OUTCOMES = frozenset({"success", "failure", "denied"})

logger = logging.getLogger("medibook.audit")


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps(record.audit, separators=(",", ":"))


def _configure() -> None:
    if logger.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(_JsonFormatter())
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)


_configure()


def new_request_id() -> str:
    return uuid.uuid4().hex


def event(name: str, outcome: str, **fields) -> None:
    """Record one audit event. Rejects any field that is not on the allow-list."""
    if outcome not in OUTCOMES:
        raise ValueError(f"unknown outcome: {outcome}")
    unknown = set(fields) - ALLOWED_FIELDS
    if unknown:
        raise ValueError(f"field(s) not allowed in audit log: {sorted(unknown)}")
    record = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "type": "audit",
        "event": name,
        "outcome": outcome,
        "request_id": request_id.get(),
        "client_ip": client_ip.get(),
        **fields,
    }
    level = logging.INFO if outcome == "success" else logging.WARNING
    logger.log(level, name, extra={"audit": record})