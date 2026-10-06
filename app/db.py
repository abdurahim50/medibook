"""PostgreSQL connection and schema for MediBook.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, PGSSLMODE, PGSSLROOTCERT),
so the same code runs locally, in CI and against Amazon RDS without a
connection string in the code or in configuration files.
"""
import psycopg
from psycopg.rows import dict_row

SCHEMA = """
CREATE TABLE IF NOT EXISTS patients (
    id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     TEXT        NOT NULL,
    email         TEXT        NOT NULL UNIQUE,
    password_hash TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sessions (
    token       TEXT        PRIMARY KEY,
    patient_id  INTEGER     NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS slots (
    id           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clinic_name  TEXT        NOT NULL,
    starts_at    TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS appointments (
    id          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id  INTEGER     NOT NULL REFERENCES patients(id),
    slot_id     INTEGER     NOT NULL UNIQUE REFERENCES slots(id),
    status      TEXT        NOT NULL DEFAULT 'booked' CHECK (status IN ('booked')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sessions_patient     ON sessions(patient_id);
CREATE INDEX IF NOT EXISTS idx_appointments_patient ON appointments(patient_id);
"""


def get_connection() -> psycopg.Connection:
    """Open a connection that returns rows as dictionaries.

    Use it as a context manager: the transaction commits when the block ends
    normally and rolls back on an exception, then the connection closes.
    The connect timeout keeps a request from hanging if the database is
    unreachable; the application name identifies these sessions in the
    database's activity view and logs.
    """
    return psycopg.connect(
        row_factory=dict_row,
        connect_timeout=5,
        application_name="medibook-api",
        options="-c timezone=UTC",  # timestamps leave the API in UTC, whatever the server's zone
    )


def init_db() -> None:
    """Create all tables and indexes if they do not already exist."""
    with get_connection() as conn:
        conn.execute(SCHEMA)


def drop_all() -> None:
    """Remove all MediBook tables and their data. Used by `seed --reset` and tests."""
    with get_connection() as conn:
        conn.execute("DROP TABLE IF EXISTS appointments, sessions, slots, patients CASCADE")
