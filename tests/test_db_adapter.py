"""Unit and integration tests for DatabaseAdapter (Stage 1 of SQLite-to-PostgreSQL migration)."""
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

from app import config
from app.db import (
    PostgresSession,
    close_db_pool,
    get_backend,
    get_db,
    normalize_sql,
    value,
)


class TestDatabaseAdapterSQLiteDefault(unittest.TestCase):
    """Verify that SQLite remains the default backend and existing behavior is 100% preserved."""

    def test_default_backend_is_sqlite(self):
        """Default backend must be 'sqlite' when no environment override is set."""
        with patch.object(config, "DATABASE_BACKEND", "sqlite"):
            self.assertEqual(get_backend(), "sqlite")

    def test_get_db_returns_sqlite_connection_by_default(self):
        """get_db() must return a sqlite3.Connection with Row factory when backend is sqlite."""
        with patch.object(config, "DATABASE_BACKEND", "sqlite"):
            db = get_db()
            try:
                self.assertIsInstance(db, sqlite3.Connection)
                self.assertEqual(db.row_factory, sqlite3.Row)
                # Verify basic execution and row factory behavior
                row = db.execute("SELECT 1 AS num, 'test' AS text").fetchone()
                self.assertEqual(row["num"], 1)
                self.assertEqual(row["text"], "test")
                self.assertEqual(value(row, "num"), 1)
                self.assertEqual(value(row, "missing", "default"), "default")
            finally:
                db.close()


class TestDatabaseAdapterConfigurationValidation(unittest.TestCase):
    """Verify backend selection validation and fail-closed policies."""

    def test_invalid_backend_raises_value_error(self):
        """Specifying an unknown backend must raise ValueError."""
        with patch.object(config, "DATABASE_BACKEND", "mysql"):
            with self.assertRaises(ValueError) as ctx:
                get_backend()
            self.assertIn("Unsupported database backend", str(ctx.exception))

    def test_postgres_backend_without_url_raises_value_error(self):
        """Selecting postgres without MEDIA_SERVER_DATABASE_URL must fail clearly with ValueError."""
        with patch.object(config, "DATABASE_BACKEND", "postgres"), patch.object(config, "DATABASE_URL", None):
            with self.assertRaises(ValueError) as ctx:
                get_db()
            self.assertIn("MEDIA_SERVER_DATABASE_URL is not configured", str(ctx.exception))

    def test_postgres_backend_without_psycopg_raises_runtime_error(self):
        """Selecting postgres when psycopg is unavailable must fail clearly with RuntimeError."""
        with patch.object(config, "DATABASE_BACKEND", "postgres"), \
             patch.object(config, "DATABASE_URL", "postgresql://user:pass@localhost:5432/db"), \
             patch("app.db.PSYCOPG_AVAILABLE", False):
            with self.assertRaises(RuntimeError) as ctx:
                get_db()
            self.assertIn("psycopg", str(ctx.exception).lower())

    def test_postgres_pool_init_failure_never_falls_back_to_sqlite(self):
        """A failure to connect to PostgreSQL must raise RuntimeError and NEVER silently fall back to SQLite."""
        mock_pool_cls = MagicMock(side_effect=Exception("Connection refused to postgresql://localhost:5432"))
        with patch.object(config, "DATABASE_BACKEND", "postgres"), \
             patch.object(config, "DATABASE_URL", "postgresql://user:pass@localhost:5432/db"), \
             patch("app.db.PSYCOPG_AVAILABLE", True), \
             patch("app.db.ConnectionPool", mock_pool_cls), \
             patch("app.db._PG_POOL", None):
            with self.assertRaises(RuntimeError) as ctx:
                get_db()
            self.assertIn("Failed to initialize PostgreSQL connection pool", str(ctx.exception))


class TestSQLPlaceholderNormalization(unittest.TestCase):
    """Verify safe SQL parameter placeholder normalization (? -> %s outside strings and comments)."""

    def test_sqlite_backend_leaves_sql_unchanged(self):
        """When targeting SQLite, SQL statements must remain completely untouched."""
        sql = "SELECT * FROM movies WHERE title = ? AND year = ?"
        self.assertEqual(normalize_sql(sql, backend="sqlite"), sql)

    def test_standard_query_placeholder_replacement(self):
        """Standard ? placeholders must be replaced with %s for PostgreSQL."""
        sql = "SELECT * FROM movies WHERE filename=?"
        expected = "SELECT * FROM movies WHERE filename=%s"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_multiple_placeholders(self):
        """Multiple comma-separated placeholders must all be converted to %s."""
        sql = "INSERT INTO progress(filename,position,duration) VALUES(?,?,?)"
        expected = "INSERT INTO progress(filename,position,duration) VALUES(%s,%s,%s)"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_preserves_question_mark_inside_single_quoted_string(self):
        """Literal question marks inside single-quoted strings must NOT be modified."""
        sql = "SELECT * FROM movies WHERE title = 'Who Framed Roger Rabbit?' AND year = ?"
        expected = "SELECT * FROM movies WHERE title = 'Who Framed Roger Rabbit?' AND year = %s"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_preserves_question_mark_inside_escaped_single_quotes(self):
        """Literal question marks inside single-quoted strings with escaped quotes ('') must NOT be modified."""
        sql = "SELECT * FROM movies WHERE title = 'Is it ''real''?' AND year = ?"
        expected = "SELECT * FROM movies WHERE title = 'Is it ''real''?' AND year = %s"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_preserves_question_mark_inside_double_quoted_identifiers(self):
        """Question marks inside double-quoted identifiers must NOT be modified."""
        sql = 'SELECT "col?name" FROM t WHERE a=? AND b=?'
        expected = 'SELECT "col?name" FROM t WHERE a=%s AND b=%s'
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_preserves_question_mark_in_line_comments(self):
        """Question marks in line comments (-- ...) must NOT be modified."""
        sql = "SELECT * FROM movies WHERE id = ? -- Is this correct? Yes"
        expected = "SELECT * FROM movies WHERE id = %s -- Is this correct? Yes"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_preserves_question_mark_in_block_comments(self):
        """Question marks in block comments (/* ... */) must NOT be modified."""
        sql = "/* Check condition? */ SELECT * FROM movies WHERE id = ?"
        expected = "/* Check condition? */ SELECT * FROM movies WHERE id = %s"
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)

    def test_on_conflict_upsert_query_placeholder_replacement(self):
        """ON CONFLICT queries with multiple placeholders must convert all placeholders to %s."""
        sql = (
            "INSERT INTO movies (filename, title, year, updated_at) "
            "VALUES (?, ?, ?, ?) ON CONFLICT (filename) DO NOTHING"
        )
        expected = (
            "INSERT INTO movies (filename, title, year, updated_at) "
            "VALUES (%s, %s, %s, %s) ON CONFLICT (filename) DO NOTHING"
        )
        self.assertEqual(normalize_sql(sql, backend="postgres"), expected)


class TestPostgresSessionLifecycle(unittest.TestCase):
    """Verify PostgresSession checkout, execution, transaction management, and pool return semantics."""

    def setUp(self):
        self.mock_pool = MagicMock()
        self.mock_conn = MagicMock()
        self.mock_conn.info.transaction_status = 0  # Clean/IDLE by default
        self.mock_cursor = MagicMock()
        self.mock_conn.cursor.return_value = self.mock_cursor
        self.mock_pool.getconn.return_value = self.mock_conn

    def test_execute_normalizes_and_runs_query(self):
        """execute() must normalize SQL placeholders and execute on cursor."""
        session = PostgresSession(self.mock_pool)
        session.execute("SELECT * FROM movies WHERE filename=?", ("test.mkv",))
        self.mock_cursor.execute.assert_called_once_with("SELECT * FROM movies WHERE filename=%s", ("test.mkv",))

    def test_executemany_normalizes_and_runs_batch(self):
        """executemany() must normalize SQL placeholders and executemany on cursor."""
        session = PostgresSession(self.mock_pool)
        params = [("test1.mkv",), ("test2.mkv",)]
        session.executemany("DELETE FROM progress WHERE filename=?", params)
        self.mock_cursor.executemany.assert_called_once_with("DELETE FROM progress WHERE filename=%s", params)

    def test_commit_and_rollback_delegation(self):
        """commit() and rollback() must delegate directly to connection."""
        session = PostgresSession(self.mock_pool)
        session.commit()
        self.mock_conn.commit.assert_called_once()
        session.rollback()
        self.mock_conn.rollback.assert_called_once()

    def test_close_returns_connection_to_pool(self):
        """close() must return connection to pool exactly once."""
        session = PostgresSession(self.mock_pool)
        session.close()
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)
        # Calling close again must be a no-op
        session.close()
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_close_rolls_back_active_transaction_before_returning_to_pool(self):
        """close() must issue a rollback if transaction status is active/dirty."""
        self.mock_conn.info.transaction_status = 2  # Non-idle transaction (2 != 0)
        mock_psycopg = MagicMock()
        mock_psycopg.pq.TransactionStatus.IDLE = 0
        with patch("app.db.psycopg", mock_psycopg):
            session = PostgresSession(self.mock_pool)
            session.close()
            self.mock_conn.rollback.assert_called_once()
            self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_context_manager_commits_on_clean_exit(self):
        """Context manager must commit and close on clean block exit."""
        with PostgresSession(self.mock_pool) as session:
            pass
        self.mock_conn.commit.assert_called_once()
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_context_manager_rolls_back_on_exception(self):
        """Context manager must rollback and close on exception within block."""
        with self.assertRaises(ZeroDivisionError):
            with PostgresSession(self.mock_pool) as session:
                _ = 1 / 0
        self.mock_conn.rollback.assert_called_once()
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_context_manager_commit_failure_still_invokes_close_and_reraises(self):
        """Context manager must close and return connection to pool even if commit() raises."""
        self.mock_conn.commit.side_effect = RuntimeError("Commit failed")
        with self.assertRaises(RuntimeError) as ctx:
            with PostgresSession(self.mock_pool) as session:
                pass
        self.assertIn("Commit failed", str(ctx.exception))
        self.mock_conn.commit.assert_called_once()
        self.assertTrue(session._closed)
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_context_manager_rollback_failure_still_invokes_close_and_reraises(self):
        """Context manager must close and return connection to pool even if rollback() raises."""
        self.mock_conn.rollback.side_effect = RuntimeError("Rollback failed")
        with self.assertRaises(RuntimeError) as ctx:
            with PostgresSession(self.mock_pool) as session:
                raise ValueError("Original block failure")
        self.assertIn("Rollback failed", str(ctx.exception))
        self.mock_conn.rollback.assert_called_once()
        self.assertTrue(session._closed)
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_del_automatically_releases_unclosed_session(self):
        """Dropping an unclosed PostgresSession (e.g. on unhandled exception) must release connection back to pool."""
        session = PostgresSession(self.mock_pool)
        self.assertFalse(session._closed)
        session.__del__()
        self.assertTrue(session._closed)
        self.mock_pool.putconn.assert_called_once_with(self.mock_conn)

    def test_del_idempotent_after_explicit_close(self):
        """__del__() on an already closed PostgresSession must be a no-op."""
        session = PostgresSession(self.mock_pool)
        session.close()
        self.assertEqual(self.mock_pool.putconn.call_count, 1)
        session.__del__()
        self.assertEqual(self.mock_pool.putconn.call_count, 1)


class TestThreadSafePoolCheckout(unittest.TestCase):
    """Verify thread-safety of connection pool checkout and return."""

    def test_concurrent_pool_checkouts_under_load(self):
        """Multiple concurrent threads must check out and return connections cleanly."""
        mock_pool = MagicMock()
        connections = [MagicMock() for _ in range(5)]
        # Return different connection objects per call
        mock_pool.getconn.side_effect = connections

        checked_out = []
        errors = []

        def worker():
            try:
                session = PostgresSession(mock_pool)
                checked_out.append(session._conn)
                session.close()
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=worker) for _ in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0)
        self.assertEqual(len(checked_out), 5)
        self.assertEqual(mock_pool.putconn.call_count, 5)


class TestPoolShutdown(unittest.TestCase):
    """Verify clean pool closure."""

    def test_close_db_pool_shuts_down_open_pool(self):
        """close_db_pool() must close the pool and reset singleton to None."""
        mock_pool = MagicMock()
        with patch("app.db._PG_POOL", mock_pool):
            close_db_pool()
            mock_pool.close.assert_called_once()


class TestQueryPortabilityAndHarmonization(unittest.TestCase):
    """Verify ANSI/PostgreSQL/SQLite portable query execution and caller harmonization."""

    def test_on_conflict_do_nothing_sqlite_execution(self):
        """ON CONFLICT DO NOTHING must execute cleanly on SQLite."""
        conn = sqlite3.connect(":memory:")
        conn.execute("CREATE TABLE movies (filename TEXT PRIMARY KEY, title TEXT, year INTEGER, updated_at INTEGER)")
        conn.execute("INSERT INTO movies VALUES ('test.mp4', 'Original', 2020, 100)")
        conn.commit()

        # Insert conflicting row
        conn.execute(
            "INSERT INTO movies (filename, title, year, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT (filename) DO NOTHING",
            ('test.mp4', 'Ignored', 2026, 200)
        )
        conn.commit()

        row = conn.execute("SELECT title, year, updated_at FROM movies WHERE filename='test.mp4'").fetchone()
        self.assertEqual(row[0], 'Original')
        self.assertEqual(row[1], 2020)
        conn.close()

    def test_on_conflict_do_update_sqlite_execution(self):
        """ON CONFLICT DO UPDATE SET ... must execute cleanly on SQLite and update target values."""
        conn = sqlite3.connect(":memory:")
        conn.execute("CREATE TABLE movies (filename TEXT PRIMARY KEY, title TEXT, year INTEGER, updated_at INTEGER)")
        conn.execute("INSERT INTO movies VALUES ('test.mp4', 'Original', 2020, 100)")
        conn.commit()

        conn.execute(
            """
            INSERT INTO movies (filename, title, year, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (filename) DO UPDATE SET
                title=excluded.title,
                year=excluded.year,
                updated_at=excluded.updated_at
            """,
            ('test.mp4', 'Updated Title', 2026, 300)
        )
        conn.commit()

        row = conn.execute("SELECT title, year, updated_at FROM movies WHERE filename='test.mp4'").fetchone()
        self.assertEqual(row[0], 'Updated Title')
        self.assertEqual(row[1], 2026)
        self.assertEqual(row[2], 300)
        conn.close()

    def test_scanner_scan_unindexed_uses_get_db(self):
        """scanner.scan_unindexed() must obtain connection from app.db.get_db and close it."""
        import scanner
        mock_conn = MagicMock()
        mock_conn.execute.return_value.fetchall.return_value = []
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as empty_dir:
            with patch("scanner.load_token", return_value="fake_token"), \
                 patch("scanner.get_db", return_value=mock_conn) as mock_get_db:
                res = scanner.scan_unindexed(media_root=empty_dir)
                mock_get_db.assert_called_once()
                mock_conn.close.assert_called_once()
                self.assertEqual(res, [])

    def test_posters_main_uses_get_db(self):
        """posters.main() must obtain connection from app.db.get_db and close it."""
        import posters
        mock_conn = MagicMock()
        mock_conn.execute.return_value.fetchall.return_value = []
        with patch("app.db.get_db", return_value=mock_conn) as mock_get_db:
            posters.main()
            mock_get_db.assert_called_once()
            mock_conn.close.assert_called_once()

    def test_scanner_scan_single_file_postgres_failure_does_not_open_sqlite(self):
        """scan_single_file must propagate PostgreSQL errors and never open SQLite."""
        import scanner
        with patch("scanner.load_token", return_value="fake_token"), \
             patch("app.db.get_db", side_effect=RuntimeError("PostgreSQL pool unreachable")), \
             patch("sqlite3.connect") as mock_sqlite:
            with self.assertRaises(RuntimeError) as ctx:
                scanner.scan_single_file("movie.mkv")
            self.assertIn("PostgreSQL pool unreachable", str(ctx.exception))
            mock_sqlite.assert_not_called()

    def test_scanner_scan_unindexed_postgres_failure_does_not_open_sqlite(self):
        """scan_unindexed must propagate PostgreSQL errors and never open SQLite."""
        import scanner
        with patch("scanner.load_token", return_value="fake_token"), \
             patch("scanner.get_db", side_effect=RuntimeError("PostgreSQL pool unreachable")), \
             patch("sqlite3.connect") as mock_sqlite:
            with self.assertRaises(RuntimeError) as ctx:
                scanner.scan_unindexed()
            self.assertIn("PostgreSQL pool unreachable", str(ctx.exception))
            mock_sqlite.assert_not_called()

    def test_posters_main_postgres_failure_does_not_open_sqlite(self):
        """posters.main must propagate PostgreSQL errors and never open SQLite."""
        import posters
        with patch("app.db.get_db", side_effect=RuntimeError("PostgreSQL pool unreachable")), \
             patch("sqlite3.connect") as mock_sqlite:
            with self.assertRaises(RuntimeError) as ctx:
                posters.main()
            self.assertIn("PostgreSQL pool unreachable", str(ctx.exception))
            mock_sqlite.assert_not_called()

    def test_scanner_custom_db_path_workflow_preserved(self):
        """Explicit offline/custom db_path must still open custom SQLite database."""
        import scanner
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp_dir:
            custom_db = Path(tmp_dir) / "custom.db"
            conn = sqlite3.connect(custom_db)
            conn.execute("CREATE TABLE movies (filename TEXT PRIMARY KEY, title TEXT)")
            conn.commit()
            conn.close()

            with patch("scanner.load_token", return_value="fake_token"), \
                 patch("scanner.get_db") as mock_get_db:
                res = scanner.scan_unindexed(media_root=tmp_dir, db_path=custom_db)
                mock_get_db.assert_not_called()
                self.assertEqual(res, [])

    def test_scanner_scan_single_file_closes_conn_on_completion_and_error(self):
        """scan_single_file must close conn when acquired, but preserve externally passed conn."""
        import scanner
        mock_conn = MagicMock()
        mock_conn.execute.return_value = None

        with patch("scanner.load_token", return_value="fake_token"), \
             patch("app.db.get_db", return_value=mock_conn), \
             patch("scanner.parse_filename", return_value=("Test Movie", 2026)), \
             patch("app.services.media_resolver.is_anonymous_name", return_value=False), \
             patch("scanner.find_movie", return_value=None):
            # 1. Internally acquired conn must be closed
            scanner.scan_single_file("Test Movie 2026.mkv")
            mock_conn.close.assert_called_once()

        # 2. Externally passed conn must NOT be closed by scan_single_file
        external_conn = MagicMock()
        with patch("scanner.load_token", return_value="fake_token"), \
             patch("scanner.parse_filename", return_value=("Test Movie", 2026)), \
             patch("app.services.media_resolver.is_anonymous_name", return_value=False), \
             patch("scanner.find_movie", return_value=None):
            scanner.scan_single_file("Test Movie 2026.mkv", conn=external_conn)
            external_conn.close.assert_not_called()


class TestPostgresMigrationsRunner(unittest.TestCase):
    """Unit and integration tests for PostgreSQL schema migration runner (Phase 3.1)."""

    def setUp(self):
        self.mock_db = MagicMock()
        self.mock_cursor = MagicMock()
        self.mock_db.execute.return_value = self.mock_cursor
        # Default: empty schema_migrations (no migrations previously applied)
        self.mock_cursor.fetchall.return_value = []

    def test_migration_runner_acquires_and_releases_advisory_lock(self):
        """run_postgres_migrations must acquire advisory lock at entry and release it in finally."""
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations

        run_postgres_migrations(self.mock_db)

        # First query should be pg_advisory_lock
        first_call = self.mock_db.execute.call_args_list[0]
        self.assertIn(f"pg_advisory_lock({PG_MIGRATION_ADVISORY_LOCK_KEY})", first_call[0][0])

        # Last query should be pg_advisory_unlock
        last_call = self.mock_db.execute.call_args_list[-1]
        self.assertIn(f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})", last_call[0][0])

    def test_migration_runner_releases_advisory_lock_even_on_exception(self):
        """run_postgres_migrations must ensure pg_advisory_unlock is invoked when a statement fails."""
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, POSTGRES_MIGRATIONS, run_postgres_migrations

        # Make a migration execution fail
        def fail_on_movies_create(sql, *args, **kwargs):
            if "CREATE TABLE IF NOT EXISTS movies" in sql:
                raise RuntimeError("Postgres DDL syntax error")
            return self.mock_cursor

        self.mock_db.execute.side_effect = fail_on_movies_create

        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(self.mock_db)
        self.assertIn("Postgres DDL syntax error", str(ctx.exception))

        # Advisory unlock must still have been called
        unlock_calls = [
            call for call in self.mock_db.execute.call_args_list
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in call[0][0]
        ]
        self.assertTrue(len(unlock_calls) >= 1)
        self.mock_db.rollback.assert_called()

    def test_migration_runner_applies_all_statements_and_records_version(self):
        """run_postgres_migrations must execute each migration statement and record the version."""
        from app.db import POSTGRES_MIGRATIONS, run_postgres_migrations

        run_postgres_migrations(self.mock_db)

        executed_sqls = [call[0][0] for call in self.mock_db.execute.call_args_list]

        # Verify key tables in Migration 1 are created
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS movies" in s for s in executed_sqls))
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS progress" in s for s in executed_sqls))
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS devices" in s for s in executed_sqls))
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS device_watch_history" in s for s in executed_sqls))
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS ip_cache" in s for s in executed_sqls))
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS settings" in s for s in executed_sqls))

        # Verify indexes are created
        self.assertTrue(any("CREATE INDEX IF NOT EXISTS idx_devices_last_seen" in s for s in executed_sqls))
        self.assertTrue(any("CREATE INDEX IF NOT EXISTS idx_dwh_device" in s for s in executed_sqls))
        self.assertTrue(any("CREATE INDEX IF NOT EXISTS idx_progress_updated" in s for s in executed_sqls))
        self.assertTrue(any("CREATE INDEX IF NOT EXISTS idx_movies_tmdb" in s for s in executed_sqls))

        # Verify version recording
        version_record_calls = [
            call for call in self.mock_db.execute.call_args_list
            if "INSERT INTO schema_migrations" in call[0][0]
        ]
        self.assertEqual(len(version_record_calls), len(POSTGRES_MIGRATIONS))
        self.assertEqual(version_record_calls[0][0][1], (1,))

    def test_migration_runner_skips_already_applied_migrations(self):
        """run_postgres_migrations must be idempotent and skip already-recorded versions."""
        from app.db import run_postgres_migrations

        # Simulate version 1 already present in schema_migrations
        self.mock_cursor.fetchall.return_value = [{"version": 1}]

        run_postgres_migrations(self.mock_db)

        executed_sqls = [call[0][0] for call in self.mock_db.execute.call_args_list]

        # No CREATE TABLE movies or INSERT INTO schema_migrations should be run
        self.assertFalse(any("CREATE TABLE IF NOT EXISTS movies" in s for s in executed_sqls))
        self.assertFalse(any("INSERT INTO schema_migrations" in s for s in executed_sqls))

    def test_migration_runner_rolls_back_and_does_not_record_version_on_failure(self):
        """If a migration fails midway, rollback must be called and the version must not be recorded."""
        from app.db import run_postgres_migrations

        def fail_on_settings(sql, *args, **kwargs):
            if "CREATE TABLE IF NOT EXISTS settings" in sql:
                raise RuntimeError("Disk full / permission denied")
            return self.mock_cursor

        self.mock_db.execute.side_effect = fail_on_settings

        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(self.mock_db)
        self.assertIn("Disk full / permission denied", str(ctx.exception))

        self.mock_db.rollback.assert_called()
        executed_sqls = [call[0][0] for call in self.mock_db.execute.call_args_list]
        self.assertFalse(any("INSERT INTO schema_migrations" in s for s in executed_sqls))

    def test_init_db_dispatches_to_run_postgres_migrations(self):
        """init_db must invoke run_postgres_migrations when backend is postgres."""
        from app.db import init_db

        with patch("app.db.get_backend", return_value="postgres"), \
             patch("app.db.get_db", return_value=self.mock_db), \
             patch("app.db.run_postgres_migrations") as mock_runner:
            init_db()
            mock_runner.assert_called_once_with(self.mock_db)
            self.mock_db.close.assert_called_once()

    def test_live_postgres_integration_gated(self):
        """Optional integration test executed ONLY when MEDIA_SERVER_TEST_POSTGRES_URL is provided."""
        test_url = os.environ.get("MEDIA_SERVER_TEST_POSTGRES_URL")
        if not test_url:
            self.skipTest("Live PostgreSQL test skipped: MEDIA_SERVER_TEST_POSTGRES_URL not set in environment.")

        from app.db import PostgresSession, get_postgres_pool, run_postgres_migrations
        with patch.object(config, "DATABASE_BACKEND", "postgres"), \
             patch.object(config, "DATABASE_URL", test_url):
            pool = get_postgres_pool()
            session = PostgresSession(pool)
            try:
                run_postgres_migrations(session)
                # Verify schema_migrations has version 1
                cur = session.execute("SELECT version FROM schema_migrations WHERE version=1")
                self.assertIsNotNone(cur.fetchone())
            finally:
                session.close()


class TestPostgresMigrationDefinitionsHardening(unittest.TestCase):
    """Regression tests for Phase 3.1 objectives A1, A2 and A4 (DDL semantics + validation)."""

    def _movies_ddl(self):
        from app.db import POSTGRES_MIGRATIONS
        for _version, _desc, statements in POSTGRES_MIGRATIONS:
            for stmt in statements:
                if "CREATE TABLE IF NOT EXISTS movies" in stmt:
                    return stmt
        self.fail("movies DDL not found in POSTGRES_MIGRATIONS")

    def _watch_history_ddl(self):
        from app.db import POSTGRES_MIGRATIONS
        for _version, _desc, statements in POSTGRES_MIGRATIONS:
            for stmt in statements:
                if "CREATE TABLE IF NOT EXISTS device_watch_history" in stmt:
                    return stmt
        self.fail("device_watch_history DDL not found in POSTGRES_MIGRATIONS")

    def test_device_watch_history_uses_by_default_identity(self):
        """device_watch_history.id must allow explicit values for future data import."""
        ddl = self._watch_history_ddl()
        self.assertIn("GENERATED BY DEFAULT AS IDENTITY", ddl)
        self.assertNotIn("GENERATED ALWAYS AS IDENTITY", ddl)

    def test_movies_details_json_remains_text(self):
        """movies.details_json must stay TEXT so callers keep receiving JSON strings."""
        ddl = self._movies_ddl()
        self.assertIn("details_json TEXT", ddl)
        self.assertNotIn("details_json JSONB", ddl)
        self.assertNotIn("details_json JSON", ddl.replace("details_json TEXT", ""))

    def test_validate_rejects_non_integer_version(self):
        from app.db import _validate_postgres_migrations
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([( "1", "bad", ["SELECT 1"])])

    def test_validate_rejects_bool_version(self):
        from app.db import _validate_postgres_migrations
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(True, "bool version", ["SELECT 1"])])

    def test_validate_rejects_zero_and_negative_versions(self):
        from app.db import _validate_postgres_migrations
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(0, "zero", ["SELECT 1"])])
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(-2, "negative", ["SELECT 1"])])

    def test_validate_rejects_duplicate_versions(self):
        from app.db import _validate_postgres_migrations
        dupes = [(1, "one", ["SELECT 1"]), (1, "one again", ["SELECT 2"])]
        with self.assertRaises(ValueError) as ctx:
            _validate_postgres_migrations(dupes)
        self.assertIn("Duplicate", str(ctx.exception))

    def test_validate_rejects_malformed_entries(self):
        from app.db import _validate_postgres_migrations
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(1, "missing statements")])
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(1, "", ["SELECT 1"])])
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(1, "empty statements", [])])
        with self.assertRaises(ValueError):
            _validate_postgres_migrations("not-a-list")

    def test_validate_rejects_invalid_sql_definitions(self):
        from app.db import _validate_postgres_migrations
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(1, "non-string stmt", [123])])
        with self.assertRaises(ValueError):
            _validate_postgres_migrations([(1, "empty stmt", ["   "])])

    def test_validate_sorts_out_of_order_definitions(self):
        from app.db import _validate_postgres_migrations
        out_of_order = [
            (2, "second", ["SELECT 2"]),
            (1, "first", ["SELECT 1"]),
        ]
        sorted_migrations = _validate_postgres_migrations(out_of_order)
        self.assertEqual([m[0] for m in sorted_migrations], [1, 2])

    def test_runner_rejects_invalid_definitions_before_ddl(self):
        """Validation must fail fast: no lock acquisition and no DDL on bad definitions."""
        from app.db import run_postgres_migrations
        mock_db = MagicMock()
        with patch("app.db.POSTGRES_MIGRATIONS", [(0, "bad", ["SELECT 1"])]):
            with self.assertRaises(ValueError):
                run_postgres_migrations(mock_db)
        mock_db.execute.assert_not_called()

    def test_runner_applies_out_of_order_definitions_in_version_order(self):
        from app.db import run_postgres_migrations
        mock_db = MagicMock()
        mock_cursor = MagicMock()
        mock_db.execute.return_value = mock_cursor
        mock_cursor.fetchall.return_value = []
        out_of_order = [
            (2, "second", ["SELECT 2"]),
            (1, "first", ["SELECT 1"]),
        ]
        with patch("app.db.POSTGRES_MIGRATIONS", out_of_order):
            run_postgres_migrations(mock_db)
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertIn("SELECT 1", sqls)
        self.assertIn("SELECT 2", sqls)
        self.assertLess(sqls.index("SELECT 1"), sqls.index("SELECT 2"))


class TestPostgresFutureSchemaVersions(unittest.TestCase):
    """Regression tests for Phase 3.1 objective A3 (future-version guard + empty handling)."""

    def _mock_db(self, applied):
        mock_db = MagicMock()
        mock_cursor = MagicMock()
        mock_db.execute.return_value = mock_cursor
        mock_cursor.fetchall.return_value = [{"version": v} for v in applied]
        return mock_db

    def test_future_applied_version_is_rejected(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db = self._mock_db([99])
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)
        msg = str(ctx.exception)
        self.assertIn("99", msg)
        self.assertIn("unsupported", msg.lower())
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertFalse(any("CREATE TABLE IF NOT EXISTS movies" in s for s in sqls))
        self.assertFalse(any("INSERT INTO schema_migrations" in s for s in sqls))
        self.assertTrue(any(f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in s for s in sqls))

    def test_empty_history_applies_supported_migrations(self):
        from app.db import run_postgres_migrations
        mock_db = self._mock_db([])
        run_postgres_migrations(mock_db)
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertTrue(any("CREATE TABLE IF NOT EXISTS movies" in s for s in sqls))
        self.assertTrue(any("INSERT INTO schema_migrations" in s for s in sqls))

    def test_normal_upgrade_from_earlier_version(self):
        from app.db import run_postgres_migrations
        mock_db = self._mock_db([1])
        migrations = [
            (1, "first", ["SELECT 1"]),
            (2, "second", ["SELECT 2"]),
        ]
        with patch("app.db.POSTGRES_MIGRATIONS", migrations):
            run_postgres_migrations(mock_db)
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertFalse(any(s.strip() == "SELECT 1" for s in sqls))
        self.assertTrue(any(s.strip() == "SELECT 2" for s in sqls))

    def test_empty_definitions_with_empty_history_is_noop(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db = self._mock_db([])
        with patch("app.db.POSTGRES_MIGRATIONS", []):
            run_postgres_migrations(mock_db)
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertTrue(any(f"pg_advisory_lock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in s for s in sqls))
        self.assertTrue(any(f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in s for s in sqls))
        self.assertFalse(any("INSERT INTO schema_migrations" in s for s in sqls))

    def test_empty_definitions_with_applied_versions_is_rejected(self):
        from app.db import run_postgres_migrations
        mock_db = self._mock_db([1])
        with patch("app.db.POSTGRES_MIGRATIONS", []):
            with self.assertRaises(RuntimeError) as ctx:
                run_postgres_migrations(mock_db)
        self.assertIn("1", str(ctx.exception))


class TestPostgresMigrationLockCleanupHardening(unittest.TestCase):
    """Regression tests for Phase 3.1 objectives B1-B4 (lock release + unsafe-connection discard)."""

    def _mock_db(self):
        mock_db = MagicMock()
        mock_cursor = MagicMock()
        mock_db.execute.return_value = mock_cursor
        mock_cursor.fetchall.return_value = []
        mock_db._pool = MagicMock()
        mock_db._conn = MagicMock()
        mock_db._closed = False
        return mock_db, mock_cursor

    def test_bootstrap_failure_propagates_and_attempts_unlock(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, _cursor = self._mock_db()

        def fail_on_bootstrap(sql, *args, **kwargs):
            if "CREATE TABLE IF NOT EXISTS schema_migrations" in sql:
                raise RuntimeError("bootstrap disk error")
            return _cursor

        mock_db.execute.side_effect = fail_on_bootstrap
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)
        self.assertIn("bootstrap disk error", str(ctx.exception))
        unlock_calls = [
            call for call in mock_db.execute.call_args_list
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in call[0][0]
        ]
        self.assertTrue(len(unlock_calls) >= 1)
        sqls = [call[0][0] for call in mock_db.execute.call_args_list]
        self.assertFalse(any("INSERT INTO schema_migrations" in s for s in sqls))

    def test_unlock_failure_after_success_is_reported_and_discards(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_on_unlock(sql, *args, **kwargs):
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("unlock connection reset")
            return mock_cursor

        mock_db.execute.side_effect = fail_on_unlock
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)
        self.assertIn("advisory lock", str(ctx.exception).lower())
        self.assertIsNotNone(ctx.exception.__cause__)
        self.assertIn("unlock connection reset", str(ctx.exception.__cause__))
        mock_db._conn.close.assert_called_once()
        mock_db._pool.putconn.assert_called_once_with(mock_db._conn)
        self.assertTrue(mock_db._closed)

    def test_unlock_failure_after_migration_failure_preserves_original(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_both(sql, *args, **kwargs):
            if "CREATE TABLE IF NOT EXISTS movies" in sql:
                raise RuntimeError("original DDL failure")
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("unlock failed during cleanup")
            return mock_cursor

        mock_db.execute.side_effect = fail_both
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)
        self.assertIn("original DDL failure", str(ctx.exception))
        self.assertNotIn("unlock failed during cleanup", str(ctx.exception))
        self.assertIsNotNone(ctx.exception.__cause__)
        self.assertIn("unlock failed during cleanup", str(ctx.exception.__cause__))
        mock_db._conn.close.assert_called_once()
        mock_db._pool.putconn.assert_called_once_with(mock_db._conn)

    def test_lock_acquire_failure_raises_without_unlock(self):
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_on_lock(sql, *args, **kwargs):
            if f"pg_advisory_lock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("lock timeout")
            return mock_cursor

        mock_db.execute.side_effect = fail_on_lock
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)
        self.assertIn("acquire", str(ctx.exception).lower())
        unlock_calls = [
            call for call in mock_db.execute.call_args_list
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in call[0][0]
        ]
        self.assertEqual(len(unlock_calls), 0)

    def test_postgres_session_discard_closes_and_replaces(self):
        """PostgresSession.discard() must close the session and putconn the closed conn."""
        from app.db import PostgresSession
        mock_pool = MagicMock()
        mock_conn = MagicMock()
        mock_pool.getconn.return_value = mock_conn
        session = PostgresSession(mock_pool)
        self.assertTrue(session.discard())
        mock_conn.close.assert_called_once()
        mock_pool.putconn.assert_called_once_with(mock_conn)
        self.assertTrue(session._closed)
        session.close()
        self.assertEqual(mock_pool.putconn.call_count, 1)


class TestPostgresConnectionDisposalSafety(unittest.TestCase):
    """Connection-disposal safety rules.

    Scope and limits of these tests: every pool/connection here is a
    ``unittest.mock`` double, so these tests prove only the *ordering and
    reporting contract* of our own code. They cannot prove that a real
    PostgreSQL server session is actually terminated by ``Connection.close()``,
    that the session-level advisory lock is released server-side, or that
    ``psycopg_pool`` discards and replaces a connection handed back to it. That
    still requires a live PostgreSQL verification run.
    """

    def _session(self, conn=None, pool=None):
        from app.db import PostgresSession
        mock_pool = pool or MagicMock()
        mock_conn = conn or MagicMock()
        mock_pool.getconn.return_value = mock_conn
        session = PostgresSession(mock_pool)
        return session, mock_pool, mock_conn

    def test_discard_does_not_return_connection_to_pool_when_close_fails(self):
        """A close() failure must NOT putconn a possibly-still-open connection.

        psycopg_pool resets and re-serves any connection it considers usable, so
        returning a connection that may still be open could hand a still-locked
        server session to the next client.
        """
        session, mock_pool, mock_conn = self._session()
        mock_conn.close.side_effect = RuntimeError("close failed: broken pipe")

        with self.assertLogs("app.db", level="ERROR") as logs:
            discarded = session.discard()

        self.assertFalse(discarded)
        mock_conn.close.assert_called_once()
        mock_pool.putconn.assert_not_called()
        self.assertTrue(session._closed)
        self.assertTrue(any("NOT being returned to the pool" in m for m in logs.output))

    def test_discard_reports_failure_when_putconn_raises_after_successful_close(self):
        """A putconn() failure after a good close must not be reported as success."""
        session, mock_pool, mock_conn = self._session()
        mock_pool.putconn.side_effect = ValueError(
            "can't return connection to pool 'x': it doesn't come from any pool"
        )

        with self.assertLogs("app.db", level="ERROR") as logs:
            discarded = session.discard()

        self.assertFalse(discarded)
        mock_conn.close.assert_called_once()
        mock_pool.putconn.assert_called_once_with(mock_conn)
        self.assertTrue(
            any("failed to return it to the pool" in m for m in logs.output),
            logs.output,
        )

    def test_discard_without_handles_reports_limitation(self):
        """Missing pool/connection handles must be reported, not treated as safe."""
        from app.db import _discard_postgres_migration_connection
        bare = object()

        with self.assertLogs("app.db", level="ERROR") as logs:
            self.assertFalse(_discard_postgres_migration_connection(bare))
        self.assertTrue(any("no pool/connection handle" in m for m in logs.output))

    def test_dispose_helper_confirms_success_only_when_both_steps_succeed(self):
        """_dispose_postgres_connection() returns True only on close + putconn."""
        from app.db import _dispose_postgres_connection
        pool = MagicMock()
        conn = MagicMock()
        self.assertTrue(_dispose_postgres_connection(conn, pool, reason="unit test"))

    def _mock_db(self):
        mock_db = MagicMock()
        mock_cursor = MagicMock()
        mock_db.execute.return_value = mock_cursor
        mock_cursor.fetchall.return_value = []
        mock_db._pool = MagicMock()
        mock_db._conn = MagicMock()
        mock_db._closed = False
        return mock_db, mock_cursor

    def test_migration_failure_with_unlock_and_disposal_failure_keeps_original_primary(self):
        """Migration failure + unlock failure + disposal failure: original stays primary."""
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_both(sql, *args, **kwargs):
            if "CREATE TABLE IF NOT EXISTS movies" in sql:
                raise RuntimeError("original DDL failure")
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("unlock failed during cleanup")
            return mock_cursor

        mock_db.execute.side_effect = fail_both
        mock_db._conn.close.side_effect = RuntimeError("close failed during disposal")

        with self.assertLogs("app.db", level="ERROR") as logs:
            with self.assertRaises(RuntimeError) as ctx:
                run_postgres_migrations(mock_db)

        # Original migration failure remains the primary exception...
        self.assertIn("original DDL failure", str(ctx.exception))
        self.assertNotIn("unlock failed during cleanup", str(ctx.exception))
        # ...with the unlock failure chained as __cause__.
        self.assertIsNotNone(ctx.exception.__cause__)
        self.assertIn("unlock failed during cleanup", str(ctx.exception.__cause__))
        # Disposal failure is observable in the logs, and the open connection is
        # NOT recycled into the pool.
        self.assertTrue(any("NOT being returned to the pool" in m for m in logs.output))
        self.assertTrue(any("Migration cleanup INCOMPLETE" in m for m in logs.output))
        mock_db._pool.putconn.assert_not_called()

    def test_successful_migration_with_unlock_and_disposal_failure_reports_unconfirmed(self):
        """Unlock failure + disposal failure after success must not claim disposal."""
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_on_unlock(sql, *args, **kwargs):
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("unlock connection reset")
            return mock_cursor

        mock_db.execute.side_effect = fail_on_unlock
        mock_db._pool.putconn.side_effect = ValueError("connection not from this pool")

        with self.assertLogs("app.db", level="ERROR") as logs:
            with self.assertRaises(RuntimeError) as ctx:
                run_postgres_migrations(mock_db)

        message = str(ctx.exception)
        self.assertIn("COULD NOT BE CONFIRMED", message)
        self.assertIn("unlock connection reset", message)
        self.assertNotIn("The connection was discarded and must not be reused.", message)
        self.assertIsNotNone(ctx.exception.__cause__)
        self.assertTrue(any("failed to return it to the pool" in m for m in logs.output))

    def test_successful_migration_with_unlock_failure_and_confirmed_disposal(self):
        """Existing successful-disposal behavior stays covered and truthfully worded."""
        from app.db import PG_MIGRATION_ADVISORY_LOCK_KEY, run_postgres_migrations
        mock_db, mock_cursor = self._mock_db()

        def fail_on_unlock(sql, *args, **kwargs):
            if f"pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})" in sql:
                raise RuntimeError("unlock connection reset")
            return mock_cursor

        mock_db.execute.side_effect = fail_on_unlock
        with self.assertRaises(RuntimeError) as ctx:
            run_postgres_migrations(mock_db)

        message = str(ctx.exception)
        self.assertIn("closed and returned to the pool for replacement", message)
        self.assertNotIn("COULD NOT BE CONFIRMED", message)
        mock_db._conn.close.assert_called_once()
        mock_db._pool.putconn.assert_called_once_with(mock_db._conn)
        self.assertTrue(mock_db._closed)


if __name__ == "__main__":
    unittest.main()
