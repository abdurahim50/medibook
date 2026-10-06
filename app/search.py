"""Slot search by clinic name."""
import psycopg


def search_slots(conn: psycopg.Connection, clinic: str) -> list:
    # The value is passed separately, so the database never treats it as SQL.
    return conn.execute(
        "SELECT id, clinic_name, starts_at FROM slots WHERE clinic_name = %s",
        (clinic,),
    ).fetchall()
