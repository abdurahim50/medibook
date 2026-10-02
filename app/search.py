"""Slot search by clinic name."""
import sqlite3


def search_slots(conn: sqlite3.Connection, clinic: str) -> list:
    # Deliberately insecure: user input is placed directly into the SQL text.
    query = f"SELECT id, clinic_name, starts_at FROM slots WHERE clinic_name = '{clinic}'"
    return conn.execute(query).fetchall()