"""Slot search by clinic name."""
import sqlite3


def search_slots(conn: sqlite3.Connection, clinic: str) -> list:
    # The value is passed separately, so the database never treats it as SQL.
    return conn.execute(
        "SELECT id, clinic_name, starts_at FROM slots WHERE clinic_name = ?",
        (clinic,),
    ).fetchall()