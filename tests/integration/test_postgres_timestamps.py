"""Real-PostgreSQL timestamp compatibility (Phase 3.3).

Complements ``tests/test_timestamp_compat.py`` (which pins the normalization
contract with constructed values) by proving that the values the **installed
psycopg driver actually returns** for ``TIMESTAMPTZ`` flow through the
application's helpers to the same contract SQLite produces.

Opt-in; requires ``MEDIA_SERVER_TEST_POSTGRES_URL`` (see ``conftest.py``).
"""
from __future__ import annotations

import datetime as dt

import pytest

from app.db import run_postgres_migrations
from app.services.device_service import format_time_ago
from app.utils.formatting import format_db_timestamp, parse_db_timestamp

pytestmark = pytest.mark.integration

UTC = dt.timezone.utc

# A fixed instant written explicitly so assertions never depend on wall clock.
FIXED_ISO = "2026-10-10 01:58:09+00"
EXPECTED_SQLITE_FORM = "2026-10-10 01:58:09"


@pytest.fixture
def migrated(pg_session):
    """A throwaway schema with the real application schema applied."""
    run_postgres_migrations(pg_session)
    return pg_session


def test_timestamptz_columns_actually_return_datetime(pg_session, migrated):
    """Confirms the premise: psycopg hands the app ``datetime``, not a string."""
    pg_session.execute(
        "INSERT INTO devices (device_id, device_name, first_seen, last_seen) "
        "VALUES ('ts-dev', 'TS Device', %s, %s)",
        (FIXED_ISO, FIXED_ISO),
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT first_seen, last_seen FROM devices WHERE device_id = 'ts-dev'"
    ).fetchone()
    assert isinstance(row["last_seen"], dt.datetime)
    assert isinstance(row["first_seen"], dt.datetime)


def test_real_timestamptz_normalizes_to_the_sqlite_contract(pg_session, migrated):
    """A real TIMESTAMPTZ renders exactly like SQLite's CURRENT_TIMESTAMP string."""
    pg_session.execute(
        "INSERT INTO devices (device_id, device_name, first_seen, last_seen) "
        "VALUES ('ts-dev', 'TS Device', %s, %s)",
        (FIXED_ISO, FIXED_ISO),
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT last_seen FROM devices WHERE device_id = 'ts-dev'"
    ).fetchone()

    rendered = format_db_timestamp(row["last_seen"])
    assert rendered == EXPECTED_SQLITE_FORM
    assert isinstance(rendered, str)
    # templates/devices.html slices this value.
    assert rendered[:19] == EXPECTED_SQLITE_FORM
    # And it round-trips through the parser.
    assert parse_db_timestamp(rendered) == dt.datetime(2026, 10, 10, 1, 58, 9, tzinfo=UTC)


def test_real_timestamptz_produces_a_relative_string(pg_session, migrated):
    """format_time_ago must return text, never leak a raw datetime to JSON."""
    pg_session.execute(
        "INSERT INTO devices (device_id, device_name, first_seen, last_seen) "
        "VALUES ('ts-dev', 'TS Device', %s, %s)",
        (FIXED_ISO, FIXED_ISO),
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT last_seen FROM devices WHERE device_id = 'ts-dev'"
    ).fetchone()

    ago = format_time_ago(row["last_seen"])
    assert isinstance(ago, str)
    assert ago.endswith("ago") or ago == "Just now"


def test_real_watch_history_timestamps_flow_through(pg_session, migrated):
    """device_watch_history.last_watched reaches JSON as the canonical string."""
    pg_session.execute("INSERT INTO devices (device_id) VALUES ('ts-dev')")
    pg_session.execute(
        "INSERT INTO device_watch_history (device_id, filename, position, duration, last_watched) "
        "VALUES ('ts-dev', 'movie.mkv', 10.0, 100.0, %s)",
        (FIXED_ISO,),
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT last_watched FROM device_watch_history WHERE device_id = 'ts-dev'"
    ).fetchone()
    assert isinstance(row["last_watched"], dt.datetime)
    assert format_db_timestamp(row["last_watched"]) == EXPECTED_SQLITE_FORM


def test_real_progress_timestamp_flows_through(pg_session, migrated):
    """progress.updated_at reaches the movie payload as the canonical string."""
    pg_session.execute(
        "INSERT INTO progress (filename, position, duration, updated_at) "
        "VALUES ('movie.mkv', 10.0, 100.0, %s)",
        (FIXED_ISO,),
    )
    pg_session.commit()
    row = pg_session.execute(
        "SELECT updated_at FROM progress WHERE filename = 'movie.mkv'"
    ).fetchone()
    assert isinstance(row["updated_at"], dt.datetime)
    assert format_db_timestamp(row["updated_at"]) == EXPECTED_SQLITE_FORM


def test_real_timestamptz_ordering_is_stable(pg_session, migrated):
    """Continue-watching ordering behaves the same on PostgreSQL."""
    pg_session.execute(
        "INSERT INTO progress (filename, position, duration, updated_at) VALUES "
        "('a.mkv', 10.0, 100.0, '2026-10-09 01:58:09+00'), "
        "('b.mkv', 10.0, 100.0, '2026-10-11 01:58:09+00'), "
        "('c.mkv', 10.0, 100.0, '2026-10-10 01:58:09+00')"
    )
    pg_session.commit()
    rows = pg_session.execute(
        "SELECT filename, updated_at FROM progress"
    ).fetchall()

    # SQL ordering (server-side, on the real column type)...
    by_sql = [r["filename"] for r in sorted(rows, key=lambda r: r["updated_at"], reverse=True)]
    # ...must match ordering of the normalized strings the app actually sorts.
    by_app = [
        r["filename"]
        for r in sorted(rows, key=lambda r: format_db_timestamp(r["updated_at"]), reverse=True)
    ]
    assert by_sql == by_app == ["b.mkv", "c.mkv", "a.mkv"]