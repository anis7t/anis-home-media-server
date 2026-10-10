"""Real-PostgreSQL integration tests for the Phase 3.1 migration runner.

These tests exercise ``app.db.run_postgres_migrations`` against a **live
PostgreSQL server** through the real psycopg driver and psycopg_pool. They are
opt-in and skip cleanly unless ``MEDIA_SERVER_TEST_POSTGRES_URL`` points at a
dedicated, disposable test database (see ``conftest.py`` for the safety model).

Each test runs inside its own throwaway PostgreSQL schema, so nothing here can
touch an application table.

SCOPE / LIMITS - what a pass here does NOT prove:
  * Mock-based tests in ``tests/test_db_adapter.py`` are not integration evidence.
  * Passing here says nothing about whether the Flask application's
    string-oriented timestamp handling works against ``TIMESTAMPTZ`` columns, nor
    about end-to-end ingestion or playback, nor about SQLite->PostgreSQL data
    migration. PostgreSQL is not production-ready.
"""
from __future__ import annotations

import threading
import uuid

import pytest

from app import db as app_db

pytestmark = pytest.mark.integration


# --------------------------------------------------------------------------- #
# Introspection helpers (all schema-qualified; nothing relies on search_path)
# --------------------------------------------------------------------------- #

EXPECTED_TABLES = {
    "schema_migrations",
    "movies",
    "progress",
    "devices",
    "device_watch_history",
    "ip_cache",
    "settings",
}

EXPECTED_INDEXES = {
    "idx_devices_last_seen",
    "idx_dwh_device",
    "idx_progress_updated",
    "idx_movies_tmdb",
}


def _tables(conn, schema):
    rows = conn.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = %s AND table_type = 'BASE TABLE'",
        (schema,),
    ).fetchall()
    return {r["table_name"] for r in rows}


def _indexes(conn, schema):
    rows = conn.execute(
        "SELECT indexname FROM pg_indexes WHERE schemaname = %s",
        (schema,),
    ).fetchall()
    return {r["indexname"] for r in rows}


def _column_type(conn, schema, table, column):
    row = conn.execute(
        "SELECT data_type FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s AND column_name = %s",
        (schema, table, column),
    ).fetchone()
    return None if row is None else row["data_type"]


def _identity(conn, schema, table, column):
    row = conn.execute(
        "SELECT a.attidentity FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = %s AND c.relname = %s AND a.attname = %s",
        (schema, table, column),
    ).fetchone()
    return None if row is None else row["attidentity"]


def _foreign_keys(conn, schema, table):
    """Return {column: (referenced_table, delete_action)} for a table's FKs."""
    rows = conn.execute(
        "SELECT a.attname AS col, c2.relname AS reftable, con.confdeltype "
        "FROM pg_constraint con "
        "JOIN pg_class c1 ON c1.oid = con.conrelid "
        "JOIN pg_namespace n ON n.oid = c1.relnamespace "
        "JOIN pg_class c2 ON c2.oid = con.confrelid "
        "JOIN pg_attribute a ON a.attrelid = c1.oid AND a.attnum = con.conkey[1] "
        "WHERE n.nspname = %s AND c1.relname = %s AND con.contype = 'f'",
        (schema, table),
    ).fetchall()
    # 'c' = CASCADE, 'a' = NO ACTION, 'r' = RESTRICT
    actions = {"c": "CASCADE", "a": "NO ACTION", "r": "RESTRICT"}
    return {r["col"]: (r["reftable"], actions.get(r["confdeltype"], r["confdeltype"])) for r in rows}


def _unique_constraints(conn, schema, table):
    rows = conn.execute(
        "SELECT conname, pg_get_constraintdef(con.oid) AS def "
        "FROM pg_constraint con "
        "JOIN pg_class c ON c.oid = con.conrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = %s AND c.relname = %s AND con.contype = 'u'",
        (schema, table),
    ).fetchall()
    return {r["conname"]: r["def"] for r in rows}


def _applied_versions(conn, schema):
    rows = conn.execute(
        f'SELECT version FROM "{schema}".schema_migrations ORDER BY version'
    ).fetchall()
    return [r["version"] for r in rows]


# --------------------------------------------------------------------------- #
# C1. Fresh schema creation
# --------------------------------------------------------------------------- #


def test_fresh_migration_creates_all_tables_and_indexes(pg_session, pg_schema, admin_conn):
    """A fresh schema receives all 7 tables and all 4 indexes."""
    app_db.run_postgres_migrations(pg_session)

    tables = _tables(admin_conn, pg_schema)
    assert EXPECTED_TABLES <= tables, f"missing tables: {EXPECTED_TABLES - tables}"

    indexes = _indexes(admin_conn, pg_schema)
    missing_idx = {i for i in EXPECTED_INDEXES if i not in indexes}
    # idx_movies_tmdb is a PARTIAL index; still must exist.
    assert not missing_idx, f"missing indexes: {missing_idx}"


def test_details_json_stays_text(pg_session, pg_schema, admin_conn):
    """movies.details_json is TEXT, not JSON/JSONB (callers rely on str)."""
    app_db.run_postgres_migrations(pg_session)
    assert _column_type(admin_conn, pg_schema, "movies", "details_json") == "text"


def test_device_watch_history_id_is_by_default_identity(pg_session, pg_schema, admin_conn):
    """id uses GENERATED BY DEFAULT (attidentity='d'), not ALWAYS ('a')."""
    app_db.run_postgres_migrations(pg_session)
    assert _identity(admin_conn, pg_schema, "device_watch_history", "id") == "d"


def test_device_watch_history_id_accepts_explicit_value(pg_session, admin_conn):
    """Behavioral proof of BY DEFAULT: an explicit id inserts successfully."""
    app_db.run_postgres_migrations(pg_session)
    pg_session.execute("INSERT INTO devices (device_id) VALUES ('dev-explicit')")
    pg_session.execute(
        "INSERT INTO device_watch_history (id, device_id, filename, position, duration) "
        "VALUES (4242, 'dev-explicit', 'movie.mkv', 1.0, 100.0)"
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT id FROM device_watch_history WHERE device_id = 'dev-explicit'"
    ).fetchone()
    assert row["id"] == 4242


def test_device_watch_history_fk_and_cascade(pg_session, pg_schema, admin_conn):
    """device_id FK targets devices with ON DELETE CASCADE, verified behaviorally."""
    app_db.run_postgres_migrations(pg_session)
    fks = _foreign_keys(admin_conn, pg_schema, "device_watch_history")
    assert fks.get("device_id") == ("devices", "CASCADE")

    pg_session.execute("INSERT INTO devices (device_id) VALUES ('dev-cascade')")
    pg_session.execute(
        "INSERT INTO device_watch_history (device_id, filename) VALUES ('dev-cascade', 'm.mkv')"
    )
    pg_session.commit()
    pg_session.execute("DELETE FROM devices WHERE device_id = 'dev-cascade'")
    pg_session.commit()
    remaining = pg_session.execute(
        "SELECT count(*) AS n FROM device_watch_history WHERE device_id = 'dev-cascade'"
    ).fetchone()
    assert remaining["n"] == 0


def test_device_watch_history_filename_has_no_fk_to_movies(pg_session, pg_schema, admin_conn):
    """filename must NOT have a foreign key to movies (by design)."""
    app_db.run_postgres_migrations(pg_session)
    fks = _foreign_keys(admin_conn, pg_schema, "device_watch_history")
    assert "filename" not in fks, f"unexpected FK on filename: {fks}"


def test_device_watch_history_unique_device_filename(pg_session, pg_schema, admin_conn):
    """UNIQUE (device_id, filename) exists and is enforced."""
    app_db.run_postgres_migrations(pg_session)
    defs = _unique_constraints(admin_conn, pg_schema, "device_watch_history")
    assert "uq_device_watch_history" in defs, defs
    assert any("UNIQUE (device_id, filename)" in d for d in defs.values()), defs

    pg_session.execute("INSERT INTO devices (device_id) VALUES ('dev-u')")
    pg_session.execute(
        "INSERT INTO device_watch_history (device_id, filename) VALUES ('dev-u', 'a.mkv')"
    )
    pg_session.commit()
    with pytest.raises(Exception):
        pg_session.execute(
            "INSERT INTO device_watch_history (device_id, filename) VALUES ('dev-u', 'a.mkv')"
        )
    pg_session.rollback()


# --------------------------------------------------------------------------- #
# C2. Migration idempotency
# --------------------------------------------------------------------------- #


def test_migration_is_idempotent_and_preserves_data(pg_session, pg_schema, admin_conn):
    """A second run succeeds, does not duplicate, and preserves existing data."""
    app_db.run_postgres_migrations(pg_session)

    pg_session.execute(
        "INSERT INTO movies (filename, title, year, updated_at) "
        "VALUES ('keep.mkv', 'Keep Me', 2026, 1)"
    )
    pg_session.commit()
    before_indexes = _indexes(admin_conn, pg_schema)
    before_tables = _tables(admin_conn, pg_schema)

    app_db.run_postgres_migrations(pg_session)  # second run

    assert _tables(admin_conn, pg_schema) == before_tables
    assert _indexes(admin_conn, pg_schema) == before_indexes
    versions = _applied_versions(admin_conn, pg_schema)
    assert versions == sorted(set(versions)), "duplicate version rows"
    assert versions == [1]
    row = pg_session.execute("SELECT title FROM movies WHERE filename = 'keep.mkv'").fetchone()
    assert row["title"] == "Keep Me"


# --------------------------------------------------------------------------- #
# C3. Version tracking, upgrades, future versions
# --------------------------------------------------------------------------- #


def test_migration_version_recorded_once(pg_session, pg_schema, admin_conn):
    """The applied version is persisted in PostgreSQL."""
    app_db.run_postgres_migrations(pg_session)
    assert _applied_versions(admin_conn, pg_schema) == [1]


def test_future_version_is_rejected(pg_session, pg_schema, admin_conn):
    """A recorded version newer than supported is rejected, no silent success."""
    app_db.run_postgres_migrations(pg_session)
    admin_conn.execute(f'INSERT INTO "{pg_schema}".schema_migrations (version) VALUES (999)')
    admin_conn.commit()

    with pytest.raises(RuntimeError, match="unsupported"):
        app_db.run_postgres_migrations(pg_session)


def test_empty_history_applies_migration(pg_session, pg_schema, admin_conn):
    """Empty schema_migrations leads to a full apply."""
    assert _tables(admin_conn, pg_schema) == set()
    app_db.run_postgres_migrations(pg_session)
    assert _applied_versions(admin_conn, pg_schema) == [1]


def test_invalid_definitions_fail_before_ddl(pg_session, pg_schema, admin_conn, monkeypatch):
    """Definition validation raises before any table is created."""
    monkeypatch.setattr(app_db, "POSTGRES_MIGRATIONS", [(0, "bad", ["SELECT 1"])])
    with pytest.raises(ValueError):
        app_db.run_postgres_migrations(pg_session)
    assert _tables(admin_conn, pg_schema) == set()


def test_out_of_order_definitions_apply_in_version_order(pg_session, pg_schema, admin_conn, monkeypatch):
    """Valid definitions supplied out of order run in ascending version order."""
    monkeypatch.setattr(
        app_db,
        "POSTGRES_MIGRATIONS",
        [(2, "second", ["CREATE TABLE IF NOT EXISTS it_b (x int)"]),
         (1, "first", ["CREATE TABLE IF NOT EXISTS it_a (x int)"])],
    )
    app_db.run_postgres_migrations(pg_session)
    versions = _applied_versions(admin_conn, pg_schema)
    assert versions == [1, 2]
    tables = _tables(admin_conn, pg_schema)
    assert {"it_a", "it_b"} <= tables


# --------------------------------------------------------------------------- #
# C4. Transaction rollback
# --------------------------------------------------------------------------- #


def test_failed_migration_rolls_back_ddl_and_version(pg_session, pg_schema, admin_conn, monkeypatch):
    """A mid-migration failure leaves no partial DDL or version row committed."""
    monkeypatch.setattr(
        app_db,
        "POSTGRES_MIGRATIONS",
        [
            (1, "good", ["CREATE TABLE IF NOT EXISTS rb_ok (x int)"]),
            (2, "bad", [
                "CREATE TABLE IF NOT EXISTS rb_partial (x int)",
                "SELECT 1 FROM table_that_does_not_exist_xyz",  # fails here
            ]),
        ],
    )
    with pytest.raises(Exception):
        app_db.run_postgres_migrations(pg_session)

    tables = _tables(admin_conn, pg_schema)
    assert "rb_ok" in tables, "committed migration before the failure must persist"
    assert "rb_partial" not in tables, "failed migration DDL must be rolled back"
    versions = _applied_versions(admin_conn, pg_schema)
    assert versions == [1], "failed version must not be recorded"


def test_lock_released_after_failed_migration(pg_pool, pg_schema, admin_conn, monkeypatch):
    """After a failure the advisory lock is released (no lingering lock row)."""
    monkeypatch.setattr(
        app_db, "POSTGRES_MIGRATIONS", [(1, "bad", ["SELECT 1 FROM nonexistent_table_abc"])]
    )
    from app.db import PostgresSession

    session = PostgresSession(pg_pool)
    try:
        session.execute(f'SET search_path TO "{pg_schema}"')
        session.commit()
        with pytest.raises(Exception):
            app_db.run_postgres_migrations(session)
    finally:
        session.close()

    lock_rows = admin_conn.execute(
        "SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory'"
    ).fetchone()
    assert lock_rows["n"] == 0, "advisory lock still held after failure"


# --------------------------------------------------------------------------- #
# C5. Concurrent migration runners
# --------------------------------------------------------------------------- #


def test_concurrent_runners_serialize_and_record_once(pg_pool, pg_schema, admin_conn):
    """Two synchronized runners on one schema both finish; version recorded once."""
    from app.db import PostgresSession

    barrier = threading.Barrier(2)
    errors = []

    def runner():
        session = PostgresSession(pg_pool)
        try:
            session.execute(f'SET search_path TO "{pg_schema}"')
            session.commit()
            barrier.wait(timeout=30)  # deterministic start
            app_db.run_postgres_migrations(session)
        except Exception as e:  # noqa: BLE001
            errors.append(e)
        finally:
            session.close()

    threads = [threading.Thread(target=runner) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=60)
        assert not t.is_alive(), "runner did not finish within timeout"

    assert not errors, f"runner errors: {errors}"
    versions = _applied_versions(admin_conn, pg_schema)
    assert versions == [1], f"version recorded more than once: {versions}"


# --------------------------------------------------------------------------- #
# D1 / D2. Pool and advisory-lock lifecycle against the real server
# --------------------------------------------------------------------------- #


def test_pool_checkout_and_return(pg_pool):
    """A normal connection checks out, runs, and returns to the pool."""
    conn = pg_pool.getconn(timeout=10)
    try:
        assert conn.execute("SELECT 1 AS n").fetchone()["n"] == 1
    finally:
        pg_pool.putconn(conn)
    # A replacement/available connection is still servable.
    conn2 = pg_pool.getconn(timeout=10)
    try:
        assert conn2.execute("SELECT 2 AS n").fetchone()["n"] == 2
    finally:
        pg_pool.putconn(conn2)


def test_closed_connection_is_discarded_not_reused(pg_pool):
    """A physically closed connection is discarded and replaced, never served."""
    conn = pg_pool.getconn(timeout=10)
    backend_pid = conn.execute("SELECT pg_backend_pid() AS pid").fetchone()["pid"]
    conn.close()  # physical close -> transaction_status UNKNOWN
    pg_pool.putconn(conn)  # pool should discard + spawn a replacement

    conn2 = pg_pool.getconn(timeout=10)
    try:
        new_pid = conn2.execute("SELECT pg_backend_pid() AS pid").fetchone()["pid"]
        assert conn2.execute("SELECT 1 AS n").fetchone()["n"] == 1
        # The closed connection is not handed back as a usable one.
        assert new_pid != backend_pid or conn2.pgconn.transaction_status.name != "UNKNOWN"
    finally:
        pg_pool.putconn(conn2)


def test_advisory_lock_blocks_second_session_until_first_terminated(pg_pool, admin_conn):
    """Session B cannot take the lock until session A's server session ends."""
    lock_key = 0x7067_0000_0000_0001  # unique test-only key (not the app's)
    conn_a = pg_pool.getconn(timeout=10)
    conn_b = pg_pool.getconn(timeout=10)
    try:
        conn_a.execute("SELECT pg_advisory_lock(%s)", (lock_key,)).fetchone()
        pid_a = conn_a.execute("SELECT pg_backend_pid() AS pid").fetchone()["pid"]

        # B cannot acquire the same session-level lock.
        got_b = conn_b.execute("SELECT pg_try_advisory_lock(%s) AS g", (lock_key,)).fetchone()["g"]
        assert got_b is False, "second session acquired a held advisory lock"

        # Terminate A's server session (controlled, this is our own test backend).
        admin_conn.execute("SELECT pg_terminate_backend(%s)", (pid_a,)).fetchone()

        # After A's session ends the lock is released; poll briefly for release.
        acquired = False
        for _ in range(50):
            got_b = conn_b.execute("SELECT pg_try_advisory_lock(%s) AS g", (lock_key,)).fetchone()["g"]
            if got_b:
                acquired = True
                break
            threading.Event().wait(0.1)
        assert acquired, "B never acquired the lock after A was terminated"

        conn_b.execute("SELECT pg_advisory_unlock(%s)", (lock_key,)).fetchone()
    finally:
        for c in (conn_a, conn_b):
            try:
                pg_pool.putconn(c)
            except Exception:
                pass


# --------------------------------------------------------------------------- #
# E. PostgresSession.close() fallback audit
# --------------------------------------------------------------------------- #


def test_close_after_error_returns_or_discards_safely(pg_pool, pg_schema):
    """PostgresSession.close() after an error still yields a healthy pool.

    The Phase 3.1 review flagged close()'s fallback that putconn()s after an
    exception. Against a real server this shows the connection is either cleanly
    returned or discarded, never left in a broken state that serves traffic.
    """
    from app.db import PostgresSession

    session = PostgresSession(pg_pool)
    session.execute(f'SET search_path TO "{pg_schema}"')
    session.commit()
    with pytest.raises(Exception):
        session.execute("SELECT * FROM table_that_does_not_exist_xyz")
    session.close()  # exception path inside close() is exercised by the failed txn

    # The pool still serves healthy connections afterward.
    conn = pg_pool.getconn(timeout=10)
    try:
        assert conn.execute("SELECT 1 AS n").fetchone()["n"] == 1
    finally:
        pg_pool.putconn(conn)