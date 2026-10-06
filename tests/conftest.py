"""Test database safety check.

Every test drops and recreates the MediBook tables, so the suite refuses to run
unless PGDATABASE names a dedicated test database (ending in "_test"). This
prevents an accidental run against a development or production database.
"""
import os

import pytest


def pytest_configure(config):
    database = os.environ.get("PGDATABASE", "")
    if not database.endswith("_test"):
        raise pytest.UsageError(
            f"Refusing to run: PGDATABASE={database!r}. Tests drop all tables, so point "
            "PGDATABASE at a test database whose name ends in _test (see README, Testing)."
        )
