"""Opt-in PostgreSQL integration harness (Phase 3.2).

SAFETY MODEL
------------
These tests talk to a REAL PostgreSQL server, so the gate is deliberately
paranoid and fails closed:

1. **Explicit opt-in only.** The DSN is read from ``MEDIA_SERVER_TEST_POSTGRES_URL``
   and from nothing else. The application's own ``MEDIA_SERVER_DATABASE_URL`` /
   ``DATABASE_URL`` is never consulted, and a missing test URL *skips* rather than
   falling back. There is no code path here that can reach the application
   database.
2. **Name validation.** The target database name must contain ``test`` and must not
   be one of the reserved names (``media_dev``, ``postgres``, ``template*``, ...).
   A URL that names anything else raises instead of running.
3. **Per-test schema isolation.** Every test gets its own throwaway PostgreSQL
   *schema* (``pgi_<random>``) and the session's ``search_path`` points at it, so
   the migration runner's unqualified DDL lands there and nowhere else. Teardown
   issues ``DROP SCHEMA IF EXISTS "pgi_<random>" CASCADE`` against a name this
   process generated - it cannot address any pre-existing schema.
4. **No credential disclosure.** ``describe_target()`` reports host/port/dbname/
   user/sslmode only. The password is never logged, asserted or embedded in a
   skip reason.

Running the suite without the env var set is a clean skip of every test; it never
touches a database.
"""
from __future__ import annotations

import os
import uuid

import pytest

TEST_URL_ENV = "MEDIA_SERVER_TEST_POSTGRES_URL"

#: Application-owned / infrastructure databases that must never be a test target.
FORBIDDEN_DATABASES = frozenset(
    {
        "postgres",
        "template0",
        "template1",
        "media",
        "media_dev",
        "media_prod",
        "media_production",
        "production",
        "prod",
    }
)

#: The target database name must contain this substring.
REQUIRED_DB_SUBSTRING = "test"

#: Bounded wait when the pool cannot hand out a connection, so a stuck test fails
#: instead of hanging the run.
POOL_TIMEOUT_SECONDS = 10.0


def pytest_configure(config):
    """Register the marker locally, so no repo-wide pytest config file is needed."""
    config.addinivalue_line(
        "markers",
        "integration: requires a live, dedicated PostgreSQL test database",
    )


def test_url() -> str:
    """Return the explicit test DSN, or ``""`` when the suite must skip.

    Deliberately reads ONLY ``MEDIA_SERVER_TEST_POSTGRES_URL``. It never consults
    the application's own ``MEDIA_SERVER_DATABASE_URL`` / ``DATABASE_URL``: a
    missing test URL must skip, never silently retarget the application database.
    """
    return os.environ.get(TEST_URL_ENV, "").strip()


def skip_reason() -> str:
    """Human-readable reason the integration suite cannot run, or ``""``."""
    if not test_url():
        return (
            f"{TEST_URL_ENV} is not set; skipping PostgreSQL integration tests. "
            "This suite never falls back to the application's DATABASE_URL - set "
            f"{TEST_URL_ENV} to a dedicated, disposable test database to enable it."
        )
    return ""


def describe_target(info: dict) -> str:
    """Describe a connection target WITHOUT revealing the password."""
    return (
        f"host={info.get('host')} port={info.get('port', 5432)} "
        f"dbname={info.get('dbname')} user={info.get('user')} "
        f"sslmode={info.get('sslmode', 'prefer')}"
    )


def validate_test_target(raw_url: str) -> dict:
    """Parse and fail closed unless ``raw_url`` names a dedicated test database.

    Raises ``RuntimeError`` (never connects) when the target looks like an
    application or infrastructure database.
    """
    from psycopg.conninfo import conninfo_to_dict

    info = conninfo_to_dict(raw_url)
    dbname = (info.get("dbname") or "").strip()

    if not dbname:
        raise RuntimeError(
            f"{TEST_URL_ENV} does not name a database; refusing to guess one."
        )
    if dbname.lower() in FORBIDDEN_DATABASES:
        raise RuntimeError(
            f"Refusing to run integration tests against {dbname!r}: it is a reserved "
            "application/infrastructure database. Point the harness at a dedicated, "
            f"disposable test database. ({describe_target(info)})"
        )
    if REQUIRED_DB_SUBSTRING not in dbname.lower():
        raise RuntimeError(
            f"Refusing to run integration tests against database {dbname!r}: the name "
            f"must contain {REQUIRED_DB_SUBSTRING!r} so it is unmistakably disposable. "
            f"({describe_target(info)})"
        )
    return info


@pytest.fixture(scope="session")
def pg_target() -> dict:
    """Validated connection info for the dedicated test database.

    Skips (never falls back) when the environment is absent, and raises when the
    configured database is not unmistakably a test database.
    """
    reason = skip_reason()
    if reason:
        pytest.skip(reason)
    return validate_test_target(test_url())


@pytest.fixture(scope="session")
def pg_dsn(pg_target: dict) -> str:
    """The raw DSN, passed straight to the pool so nothing rewrites it."""
    return test_url()


def psycopg_connect(dsn: str):
    """Connect with the app's row factory so ``app.db.value()`` works on rows."""
    import psycopg
    from psycopg.rows import dict_row

    return psycopg.connect(dsn, row_factory=dict_row, connect_timeout=10)


@pytest.fixture(scope="session")
def pg_pool(pg_dsn: str):
    """A real psycopg pool, configured like the application's own pool."""
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool

    pool = ConnectionPool(
        conninfo=pg_dsn,
        min_size=1,
        max_size=8,
        timeout=POOL_TIMEOUT_SECONDS,
        kwargs={"row_factory": dict_row},
        check=ConnectionPool.check_connection,
        open=True,
    )
    try:
        yield pool
    finally:
        pool.close()


@pytest.fixture
def pg_schema(pg_dsn: str, pg_target: dict) -> str:
    """Create a unique throwaway schema for one test, and drop it afterwards."""
    schema = f"pgi_{uuid.uuid4().hex[:12]}"
    conn = psycopg_connect(pg_dsn)
    try:
        conn.execute(f'CREATE SCHEMA "{schema}"')
        conn.commit()
    finally:
        conn.close()
    try:
        yield schema
    finally:
        # Only ever drops the randomly generated name created above.
        cleanup = psycopg_connect(pg_dsn)
        try:
            cleanup.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
            cleanup.commit()
        finally:
            cleanup.close()


def psycopg_connect(dsn: str):
    """Connect with the app's row factory so ``app.db.value()`` works on rows."""
    import psycopg
    from psycopg.rows import dict_row

    return psycopg.connect(dsn, row_factory=dict_row, connect_timeout=10)


@pytest.fixture
def pg_session(pg_pool, pg_schema):
    """A real ``PostgresSession`` whose ``search_path`` is the throwaway schema."""
    from app.db import PostgresSession

    session = PostgresSession(pg_pool)
    try:
        session.execute(f'SET search_path TO "{pg_schema}"')
        session.commit()
        yield session
    finally:
        session.close()


@pytest.fixture
def admin_conn(pg_dsn: str):
    """A separate admin connection for out-of-band inspection/termination."""
    conn = psycopg_connect(pg_dsn)
    try:
        yield conn
    finally:
        try:
            conn.close()
        except Exception:
            pass