"""PostgreSQL connection and schema for MediBook.

Connection settings come from the standard libpq environment variables
(PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, PGSSLMODE, PGSSLROOTCERT),
so the same code runs locally, in CI and against Amazon RDS without a
connection string in the code or in configuration files.

Two database roles (finding F-8):
  - The owner (admin) runs `migrate()` from a one-off task: tables, grants,
    triggers. The API never holds its credentials.
  - The API's role (MEDIBOOK_APP_DB_USER) gets row access only, per table, for
    exactly the statements the code runs: no DDL, no TRUNCATE, not the owner.
    In AWS it signs in with a 15-minute IAM token instead of a password
    (MEDIBOOK_DB_IAM_AUTH=1).
"""
import functools
import os

import psycopg
from psycopg import sql
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

-- TRUNCATE is not logged by log_statement = 'ddl', so every table raises a
-- warning that the database log alarm matches (finding F-7). The marker is built
-- with upper() so this function's own source, logged when it is created, does
-- not match the alarm's case-sensitive pattern.
CREATE OR REPLACE FUNCTION medibook_warn_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE WARNING '%: TRUNCATE on % by %', upper('destructive_sql'), TG_TABLE_NAME, session_user;
    RETURN NULL;
END
$$;
"""

TABLES = ("patients", "sessions", "slots", "appointments")

# Row privileges for the API's role: exactly what the application code does.
APP_GRANTS = {
    "patients": "SELECT, INSERT",
    "sessions": "SELECT, INSERT, DELETE",
    "slots": "SELECT",
    "appointments": "SELECT, INSERT",
}


def get_connection() -> psycopg.Connection:
    """Open a connection that returns rows as dictionaries.

    Use it as a context manager: the transaction commits when the block ends
    normally and rolls back on an exception, then the connection closes.
    The connect timeout keeps a request from hanging if the database is
    unreachable; the application name identifies these sessions in the
    database's activity view and logs.
    """
    extra = {}
    if os.environ.get("MEDIBOOK_DB_IAM_AUTH") == "1":
        extra["password"] = iam_auth_token()
    return psycopg.connect(
        row_factory=dict_row,
        connect_timeout=5,
        application_name="medibook-api",
        options="-c timezone=UTC",  # timestamps leave the API in UTC, whatever the server's zone
        **extra,
    )


@functools.cache
def _rds_client():
    import boto3  # imported only when IAM authentication is used

    return boto3.client("rds", region_name=os.environ["AWS_REGION"])


def iam_auth_token() -> str:
    """A short-lived (15-minute) RDS IAM authentication token for PGUSER.

    Signed locally with the task role's temporary credentials: no network call,
    and no long-lived database password exists for this role.
    """
    return _rds_client().generate_db_auth_token(
        DBHostname=os.environ["PGHOST"],
        Port=int(os.environ.get("PGPORT", "5432")),
        DBUsername=os.environ["PGUSER"],
    )


def init_db() -> None:
    """Create all tables, indexes and the TRUNCATE warning triggers if missing."""
    with get_connection() as conn:
        conn.execute(SCHEMA)
        for table in TABLES:
            conn.execute(
                sql.SQL(
                    "CREATE OR REPLACE TRIGGER warn_truncate BEFORE TRUNCATE ON {} "
                    "FOR EACH STATEMENT EXECUTE FUNCTION medibook_warn_truncate()"
                ).format(sql.Identifier(table))
            )


def grant_app_access(role: str) -> None:
    """Create the API's role if needed and grant it row access only.

    Idempotent: every run revokes and re-grants, so the privileges always match
    APP_GRANTS. On RDS the role is added to rds_iam, so it can sign in only with
    an IAM token; it has no password.
    """
    ident = sql.Identifier(role)
    with get_connection() as conn:
        if conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone() is None:
            conn.execute(sql.SQL("CREATE ROLE {} LOGIN").format(ident))
        if conn.execute("SELECT 1 FROM pg_roles WHERE rolname = 'rds_iam'").fetchone():
            conn.execute(sql.SQL("GRANT rds_iam TO {}").format(ident))
        conn.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        conn.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(conn.info.dbname), ident))
        conn.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(ident))
        conn.execute(sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM {}").format(ident))
        for table, privileges in APP_GRANTS.items():
            conn.execute(sql.SQL("GRANT {} ON {} TO {}").format(
                sql.SQL(privileges), sql.Identifier(table), ident))


def migrate() -> None:
    """Schema, then grants for MEDIBOOK_APP_DB_USER when it is set. Runs as the owner."""
    init_db()
    app_role = os.environ.get("MEDIBOOK_APP_DB_USER")
    if app_role:
        grant_app_access(app_role)


def drop_all() -> None:
    """Remove all MediBook tables and their data. Used by `seed --reset` and tests."""
    with get_connection() as conn:
        conn.execute("DROP TABLE IF EXISTS appointments, sessions, slots, patients CASCADE")
