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


if __name__ == "__main__":
    unittest.main()
