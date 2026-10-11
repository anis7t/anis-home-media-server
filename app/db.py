"""Database connection and initialization module supporting SQLite and PostgreSQL backends."""
import atexit
import logging
import re
import sqlite3
import threading
from app import config

logger = logging.getLogger(__name__)

# Conditional import of psycopg 3 and psycopg-pool for PostgreSQL backend
try:
    import psycopg
    from psycopg.rows import dict_row
    from psycopg_pool import ConnectionPool
    PSYCOPG_AVAILABLE = True
except ImportError:
    psycopg = None
    dict_row = None
    ConnectionPool = None
    PSYCOPG_AVAILABLE = False

# Global PostgreSQL connection pool singleton & thread lock
_PG_POOL = None
_PG_POOL_LOCK = threading.Lock()

# SQL Tokenizer for safe parameter translation (? -> %s outside of literals and comments)
_SQL_TOKEN_RE = re.compile(
    r"""
    (
        --[^\r\n]*                  # Line comment
      | /\*[\s\S]*?\*/              # Block comment
      | '(?:''|[^'])*'              # Single-quoted string literal
      | "(?:""|[^"])*"              # Double-quoted identifier
      | \?                          # Parameter placeholder
      | [^'"/?\-]+                  # Plain non-special characters
      | [-/]                        # Stray hyphens or slashes not starting comments
    )
    """,
    re.VERBOSE,
)


def normalize_sql(sql: str, backend: str = None) -> str:
    """Normalize SQL parameter placeholders (? to %s) outside string literals and comments for PostgreSQL."""
    if backend is None:
        backend = get_backend()
    if backend == "sqlite":
        return sql
    tokens = _SQL_TOKEN_RE.findall(sql)
    return "".join("%s" if t == "?" else t for t in tokens)


def get_backend() -> str:
    """Return normalized database backend ('sqlite' or 'postgres')."""
    backend = getattr(config, "DATABASE_BACKEND", "sqlite").lower().strip()
    if backend == "postgresql":
        backend = "postgres"
    allowed = getattr(config, "ALLOWED_DATABASE_BACKENDS", frozenset({"sqlite", "postgres", "postgresql"}))
    if backend not in allowed and backend != "postgres":
        raise ValueError(
            f"Unsupported database backend '{backend}'. Allowed backends: {', '.join(sorted(allowed))}"
        )
    return backend


def get_postgres_pool():
    """Retrieve or initialize the thread-safe PostgreSQL connection pool."""
    global _PG_POOL
    url = getattr(config, "DATABASE_URL", None)
    if not url:
        raise ValueError(
            "PostgreSQL backend is selected ('postgres'), but MEDIA_SERVER_DATABASE_URL is not configured."
        )
    if not PSYCOPG_AVAILABLE:
        raise RuntimeError(
            "PostgreSQL backend is selected ('postgres'), but 'psycopg' or 'psycopg-pool' "
            "is not installed. Please install 'psycopg[binary]' and 'psycopg-pool'."
        )

    if _PG_POOL is None:
        with _PG_POOL_LOCK:
            if _PG_POOL is None:
                try:
                    pool = ConnectionPool(
                        conninfo=url,
                        min_size=2,
                        max_size=16,
                        timeout=10.0,
                        max_idle=300.0,
                        kwargs={"row_factory": dict_row},
                        check=ConnectionPool.check_connection,
                    )
                    pool.open()
                    _PG_POOL = pool
                    logger.info("PostgreSQL connection pool initialized successfully.")
                except Exception as e:
                    logger.error(f"Failed to initialize PostgreSQL connection pool: {e}")
                    raise RuntimeError(f"Failed to initialize PostgreSQL connection pool: {e}") from e
    return _PG_POOL


def close_db_pool():
    """Gracefully close the PostgreSQL connection pool if active."""
    global _PG_POOL
    with _PG_POOL_LOCK:
        if _PG_POOL is not None:
            try:
                _PG_POOL.close()
                logger.info("PostgreSQL connection pool closed.")
            except Exception as e:
                logger.warning(f"Error during PostgreSQL connection pool shutdown: {e}")
            finally:
                _PG_POOL = None


atexit.register(close_db_pool)


def _dispose_postgres_connection(conn, pool, *, reason):
    """Close *conn* and, only after a confirmed close, return it to *pool*.

    Returns ``True`` only when **both** steps were confirmed:

    1. ``conn.close()`` returned normally. psycopg's ``Connection.close()``
       finishes the libpq connection, which ends the PostgreSQL server session
       and therefore releases any session-level advisory lock that session held.
    2. ``pool.putconn(conn)`` returned normally. ``psycopg_pool``'s
       ``_return_connection()`` sees ``TransactionStatus.UNKNOWN`` for a closed
       connection, logs ``discarding closed connection`` and schedules a
       replacement, so the pool slot is reclaimed rather than lost.

    ``putconn`` is deliberately **skipped** when ``close()`` raises:
    ``psycopg_pool`` resets and re-serves any connection it still considers
    usable, so handing back a connection that may still be open — and may
    therefore still hold the advisory lock — would pass that lock to the next
    client. Leaving the handle out of the pool costs at most one slot of
    ``max_size`` and is reported to the caller instead of being hidden.

    *reason* is a short human-readable trigger used in the log records.
    """
    try:
        conn.close()
    except Exception as close_e:
        logger.error(
            "Failed to close PostgreSQL connection (%s): %s. It is NOT being returned "
            "to the pool: it may still be open and may still hold the session-level "
            "advisory lock, which the pool would otherwise reset and serve to the "
            "next client.",
            reason,
            close_e,
        )
        return False
    try:
        pool.putconn(conn)
    except Exception as putconn_e:
        logger.error(
            "Closed PostgreSQL connection (%s) but failed to return it to the pool: %s. "
            "The server session was ended by close(), but the pool slot was not "
            "reclaimed; capacity shrinks by one until the pool grows again.",
            reason,
            putconn_e,
        )
        return False
    return True


class PostgresSession:
    """Thread-safe connection wrapper for PostgreSQL checked out from psycopg_pool."""

    def __init__(self, pool):
        self._pool = pool
        self._conn = pool.getconn(timeout=10.0)
        self._closed = False
        self._trans_clean = True

    def execute(self, sql: str, params=None):
        if self._closed:
            raise RuntimeError("Cannot execute query on a closed database connection.")
        self._trans_clean = False
        normalized = normalize_sql(sql, backend="postgres")
        cur = self._conn.cursor()
        if params is not None:
            cur.execute(normalized, params)
        else:
            cur.execute(normalized)
        return cur

    def executemany(self, sql: str, seq_of_params):
        if self._closed:
            raise RuntimeError("Cannot execute query on a closed database connection.")
        self._trans_clean = False
        normalized = normalize_sql(sql, backend="postgres")
        cur = self._conn.cursor()
        cur.executemany(normalized, seq_of_params)
        return cur

    def commit(self):
        if self._closed:
            raise RuntimeError("Cannot commit a closed database connection.")
        self._conn.commit()
        self._trans_clean = True

    def rollback(self):
        if self._closed:
            return
        self._conn.rollback()
        self._trans_clean = True

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            # Ensure connection does not retain an uncommitted or broken transaction
            if not self._trans_clean:
                self._conn.rollback()
                self._trans_clean = True
            elif hasattr(self._conn, "info") and hasattr(self._conn.info, "transaction_status"):
                idle_status = getattr(getattr(getattr(psycopg, "pq", None), "TransactionStatus", None), "IDLE", 0) if psycopg else 0
                if self._conn.info.transaction_status != idle_status:
                    self._conn.rollback()
            self._pool.putconn(self._conn)
        except Exception as e:
            logger.warning(f"Error cleaning up connection before returning to pool: {e}")
            try:
                self._pool.putconn(self._conn)
            except Exception:
                pass

    def discard(self):
        """Discard this session's connection instead of returning it for reuse.

        Closes the underlying connection (``Connection.close()`` finishes the
        libpq connection, ending the PostgreSQL server session and releasing any
        session-level advisory lock it held) and only then returns the *closed*
        connection via ``pool.putconn()``, which makes ``psycopg_pool`` discard
        it and spawn a replacement. ``putconn`` is intentionally skipped when the
        close fails, so a connection that may still be open and may still hold the
        lock is never recycled into the pool.

        Returns ``True`` when the connection was closed and handed back for
        replacement, ``False`` when safe disposal could not be established. A
        ``False`` result is a real residual limitation (the server session may
        still hold the advisory lock until the server ends it) and must be
        reported by the caller, never described as a successful discard.

        Use when session-level state is ambiguous (e.g. ``pg_advisory_unlock``
        failed) and the connection must not serve ordinary traffic.
        """
        if self._closed:
            return False
        self._closed = True
        pool = self._pool
        conn = self._conn
        if pool is None or conn is None:
            logger.error(
                "Cannot discard PostgreSQL connection: session has no pool/connection "
                "handle. The session-level advisory lock state is ambiguous and the "
                "connection is not safe for reuse."
            )
            return False
        return _dispose_postgres_connection(
            conn, pool, reason="advisory-lock discard on a migration session"
        )

    def __del__(self):
        if not getattr(self, "_closed", True):
            try:
                self.close()
            except Exception:
                pass

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if exc_type:
                self.rollback()
            else:
                self.commit()
        finally:
            self.close()



def get_db():
    """Return a database connection or session matching the configured backend."""
    backend = get_backend()
    if backend == "sqlite":
        config.DATABASE.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(config.DATABASE, timeout=10.0)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA busy_timeout=5000")
        except Exception:
            pass
        return db
    elif backend == "postgres":
        pool = get_postgres_pool()
        return PostgresSession(pool)
    else:
        raise ValueError(f"Unsupported database backend '{backend}'.")


# PostgreSQL migration definitions and runner
# Advisory lock key: 64-bit integer derived for media_server_schema_migrations
PG_MIGRATION_ADVISORY_LOCK_KEY = 8392174910283

POSTGRES_MIGRATIONS = [
    (
        1,
        "Initial schema: movies, progress, devices, device_watch_history, ip_cache, settings",
        [
            # 1. movies table
            """
            CREATE TABLE IF NOT EXISTS movies (
                filename TEXT PRIMARY KEY,
                title TEXT,
                year INTEGER,
                tmdb_id INTEGER,
                overview TEXT,
                poster_path TEXT,
                backdrop_path TEXT,
                runtime INTEGER,
                genres TEXT,
                vote_average REAL,
                updated_at BIGINT,
                release_date TEXT,
                added_at BIGINT,
                details_json TEXT,
                last_metadata_refresh BIGINT
            )
            """,
            # 2. progress table
            """
            CREATE TABLE IF NOT EXISTS progress (
                filename TEXT PRIMARY KEY,
                position REAL NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            # 3. devices table
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY,
                custom_name TEXT,
                device_name TEXT,
                device_type TEXT,
                device_os TEXT,
                browser TEXT,
                user_agent TEXT,
                connection_type TEXT,
                client_ip TEXT,
                public_ip TEXT,
                mac_address TEXT,
                isp TEXT,
                city TEXT,
                country TEXT,
                first_seen TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                last_seen TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                device_model TEXT
            )
            """,
            # 4. device_watch_history table
            """
            CREATE TABLE IF NOT EXISTS device_watch_history (
                id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
                device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                filename TEXT NOT NULL,
                position REAL NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                completed SMALLINT NOT NULL DEFAULT 0,
                last_watched TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                CONSTRAINT uq_device_watch_history UNIQUE (device_id, filename)
            )
            """,
            # 5. ip_cache table
            """
            CREATE TABLE IF NOT EXISTS ip_cache (
                ip TEXT PRIMARY KEY,
                isp TEXT,
                org TEXT,
                city TEXT,
                country TEXT,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            # 6. settings table
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            # 7. Indexes
            "CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen DESC)",
            "CREATE INDEX IF NOT EXISTS idx_dwh_device ON device_watch_history(device_id, last_watched DESC)",
            "CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_movies_tmdb ON movies(tmdb_id) WHERE tmdb_id IS NOT NULL",
        ],
    ),
]


def _validate_postgres_migrations(migrations=None):
    """Validate PostgreSQL migration definitions and return them sorted by version.

    Rejects (with ``ValueError``) non-integer versions (including ``bool``,
    which is a subclass of ``int``), zero/negative versions, duplicate
    versions, malformed entries, missing descriptions/statements, and
    non-string or empty SQL statements. Never coerces malformed values.
    Version gaps are allowed; only duplicates and invalid versions fail.
    """
    if migrations is None:
        migrations = POSTGRES_MIGRATIONS
    if not isinstance(migrations, (list, tuple)):
        raise ValueError(
            "Invalid PostgreSQL migration definitions: expected a list of "
            f"(version, description, statements) entries, got {type(migrations).__name__}."
        )
    if len(migrations) == 0:
        return []
    seen = set()
    validated = []
    for idx, entry in enumerate(migrations):
        if not isinstance(entry, (list, tuple)) or len(entry) != 3:
            raise ValueError(
                "Invalid PostgreSQL migration definition at index "
                f"{idx}: expected a (version, description, statements) tuple, got {entry!r}."
            )
        version, description, statements = entry
        if isinstance(version, bool) or not isinstance(version, int):
            raise ValueError(
                "Invalid PostgreSQL migration version at index "
                f"{idx}: {version!r} is not an integer. Versions must be positive integers."
            )
        if version <= 0:
            raise ValueError(
                f"Invalid PostgreSQL migration version {version}: versions must be positive integers."
            )
        if version in seen:
            raise ValueError(
                f"Duplicate PostgreSQL migration version {version}: each version must be unique."
            )
        seen.add(version)
        if not isinstance(description, str) or not description.strip():
            raise ValueError(
                f"Invalid PostgreSQL migration definition for version {version}: "
                "description must be a non-empty string."
            )
        if not isinstance(statements, (list, tuple)) or len(statements) == 0:
            raise ValueError(
                f"Invalid PostgreSQL migration definition for version {version}: "
                "statements must be a non-empty list of SQL strings."
            )
        for stmt_idx, stmt in enumerate(statements):
            if not isinstance(stmt, str) or not stmt.strip():
                raise ValueError(
                    f"Invalid SQL statement in PostgreSQL migration version {version} "
                    f"at statement index {stmt_idx}: each statement must be a non-empty string."
                )
        validated.append((version, description, statements))
    validated.sort(key=lambda m: m[0])
    return validated


def _discard_postgres_migration_connection(db):
    """Prevent ordinary reuse of a connection whose advisory-lock state is ambiguous.

    Uses only the real ``psycopg_pool`` API: close the underlying connection
    (ending the PostgreSQL session and releasing any session-level advisory lock
    server-side), and only on a *confirmed* close ``putconn`` the closed
    connection so the pool discards it and spawns a replacement.

    Returns ``True`` only when disposal was actually established. ``False``
    means the outcome is unknown or incomplete and the caller must say so
    explicitly — it must never be reported as "the connection was discarded".
    """
    if isinstance(db, PostgresSession):
        return db.discard()
    pool = getattr(db, "_pool", None)
    conn = getattr(db, "_conn", None)
    if pool is None or conn is None:
        logger.error(
            "Cannot safely dispose of the PostgreSQL migration connection: %s exposes "
            "no pool/connection handle, so the session-level advisory lock state is "
            "ambiguous and the connection must not be reused.",
            type(db).__name__,
        )
        return False
    try:
        db._closed = True
    except Exception as closed_e:
        logger.error(
            "Could not mark the migration connection closed (%s); the connection may "
            "still be usable by its owner: %s",
            type(db).__name__,
            closed_e,
        )
    return _dispose_postgres_connection(
        conn, pool, reason="advisory-lock cleanup after a migration failure"
    )


def run_postgres_migrations(db):
    """Run pending PostgreSQL schema migrations inside a concurrency-safe advisory lock.

    Guarantees:
    - Session-level advisory lock prevents concurrent runner execution across processes.
    - Each migration is executed inside a transaction and records its version on success.
    - If a migration statement fails, changes roll back and the version is not recorded.
    - Idempotent: already-applied migrations are safely skipped on repeated invocations.
    - Migration definitions are validated before any DDL runs; unsupported future
      schema versions in the database are rejected instead of silently accepted.
    - The advisory lock is released on success and on failure. If unlocking fails,
      the connection is discarded (closed, and only then returned closed so the
      pool replaces it) and never returned for ordinary reuse. The original
      migration/bootstrap exception always remains primary via explicit chaining.

    Residual limitation: if the process crashes between ``pg_advisory_lock`` and
    release without closing the session, the session-level lock is held until the
    server ends the session (disconnect/idle timeout). Discarding relies on
    ``Connection.close()`` finishing the libpq connection, which ends the server
    session and releases the lock server-side; that outcome is not exercised by
    the unit tests here, which are mock-based. If the close itself fails the
    connection is deliberately *not* returned to the pool (it may still hold the
    lock and the pool would reset and re-serve it), and the caller reports that
    safe disposal could not be confirmed.
    """
    sorted_migrations = _validate_postgres_migrations(POSTGRES_MIGRATIONS)
    latest_supported = sorted_migrations[-1][0] if sorted_migrations else None
    logger.info("Acquiring PostgreSQL migration advisory lock...")
    try:
        db.execute(f"SELECT pg_advisory_lock({PG_MIGRATION_ADVISORY_LOCK_KEY})")
    except Exception as e:
        raise RuntimeError(
            "Failed to acquire PostgreSQL migration advisory lock "
            f"({PG_MIGRATION_ADVISORY_LOCK_KEY}): {e}"
        ) from e
    try:
        # Ensure schema_migrations exists to track applied versions
        db.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            "version INTEGER PRIMARY KEY, "
            "applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP"
            ")"
        )
        db.commit()

        # Query currently applied migration versions
        cur = db.execute("SELECT version FROM schema_migrations ORDER BY version ASC")
        rows = cur.fetchall() if hasattr(cur, "fetchall") else []
        applied_versions = {value(r, "version") for r in rows if value(r, "version") is not None}

        if not sorted_migrations:
            if applied_versions:
                raise RuntimeError(
                    "Database contains applied schema migrations "
                    f"{sorted(applied_versions)} but this code supports no migrations. "
                    "Refusing to run: upgrade the application code to a version that "
                    "supports these schema versions."
                )
        else:
            unsupported = sorted(
                v for v in applied_versions
                if isinstance(v, int) and not isinstance(v, bool) and v > latest_supported
            )
            if unsupported:
                raise RuntimeError(
                    f"Database contains unsupported future schema migrations {unsupported}: "
                    f"latest supported version is {latest_supported}. Upgrade the application "
                    "code to a version that supports these schema versions; refusing to "
                    "report success against an unknown schema."
                )

        # Apply pending migrations in strict ascending version sequence
        for version, description, statements in sorted_migrations:
            if version in applied_versions:
                logger.debug(f"PostgreSQL migration {version} ('{description}') already applied. Skipping.")
                continue

            logger.info(f"Applying PostgreSQL migration {version}: '{description}'...")
            try:
                for stmt in statements:
                    stmt_clean = stmt.strip()
                    if stmt_clean:
                        db.execute(stmt_clean)
                db.execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, CURRENT_TIMESTAMP)",
                    (version,),
                )
                db.commit()
                applied_versions.add(version)
                logger.info(f"PostgreSQL migration {version} applied successfully.")
            except Exception as e:
                try:
                    db.rollback()
                except Exception as rb_e:
                    logger.warning(f"Rollback failed after migration {version} error: {rb_e}")
                logger.error(f"Failed to apply PostgreSQL migration {version} ('{description}'): {e}")
                raise
    except Exception as primary:
        try:
            try:
                db.rollback()
            except Exception:
                pass
            db.execute(f"SELECT pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})")
            db.commit()
        except Exception as unlock_e:
            logger.error(f"Failed to release PostgreSQL migration advisory lock after failure: {unlock_e}")
            discarded = _discard_postgres_migration_connection(db)
            if discarded:
                logger.error(
                    "Migration cleanup: connection closed and returned to the pool for "
                    "replacement; the session-level advisory lock was released by ending "
                    "the server session."
                )
            else:
                logger.error(
                    "Migration cleanup INCOMPLETE: the connection could not be confirmed "
                    "closed and removed from the pool (see the errors above). It is not "
                    "safe for reuse, and the session-level advisory lock (%s) may remain "
                    "held until the server ends the session. The original migration "
                    "exception remains the primary failure.",
                    PG_MIGRATION_ADVISORY_LOCK_KEY,
                )
            raise primary from unlock_e
        raise
    else:
        try:
            db.execute(f"SELECT pg_advisory_unlock({PG_MIGRATION_ADVISORY_LOCK_KEY})")
            db.commit()
        except Exception as unlock_e:
            logger.error(f"Failed to release PostgreSQL migration advisory lock: {unlock_e}")
            discarded = _discard_postgres_migration_connection(db)
            if discarded:
                raise RuntimeError(
                    "PostgreSQL migrations applied but failed to release the migration "
                    f"advisory lock ({PG_MIGRATION_ADVISORY_LOCK_KEY}): {unlock_e}. "
                    "The connection was closed and returned to the pool for replacement "
                    "(which ends the server session and releases the lock); it must not "
                    "be reused."
                ) from unlock_e
            raise RuntimeError(
                "PostgreSQL migrations applied but failed to release the migration "
                f"advisory lock ({PG_MIGRATION_ADVISORY_LOCK_KEY}): {unlock_e}. "
                "Safe disposal of the connection COULD NOT BE CONFIRMED (see the errors "
                "logged above): the connection is not safe for reuse, and the "
                "session-level advisory lock may remain held until the server ends the "
                "session. Inspect the PostgreSQL server before starting another migration "
                "run."
            ) from unlock_e


def init_db():
    """Initialize database tables, perform schema migrations, and create indexes."""
    backend = get_backend()
    if backend == "sqlite":
        db = get_db()
        try:
            db.execute("PRAGMA journal_mode=WAL")
        except Exception:
            pass
        db.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY)")
        db.execute(
            "CREATE TABLE IF NOT EXISTS progress("
            "filename TEXT PRIMARY KEY,"
            "position REAL NOT NULL DEFAULT 0,"
            "duration REAL NOT NULL DEFAULT 0,"
            "updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)"
        )
        db.execute(
            "CREATE TABLE IF NOT EXISTS movies("
            "filename TEXT PRIMARY KEY,"
            "title TEXT,"
            "year INTEGER,"
            "tmdb_id INTEGER,"
            "overview TEXT,"
            "poster_path TEXT,"
            "backdrop_path TEXT,"
            "runtime INTEGER,"
            "genres TEXT,"
            "vote_average REAL,"
            "updated_at INTEGER)"
        )
        columns = {r['name'] for r in db.execute("PRAGMA table_info(movies)")}
        for name, spec in (
            ("release_date", "TEXT"),
            ("added_at", "INTEGER"),
            ("details_json", "TEXT"),
            ("last_metadata_refresh", "INTEGER"),
        ):
            if name not in columns:
                db.execute(f"ALTER TABLE movies ADD COLUMN {name} {spec}")
        db.execute(
            "CREATE TABLE IF NOT EXISTS devices("
            "device_id TEXT PRIMARY KEY,"
            "custom_name TEXT,"
            "device_name TEXT,"
            "device_type TEXT,"
            "device_os TEXT,"
            "browser TEXT,"
            "user_agent TEXT,"
            "connection_type TEXT,"
            "client_ip TEXT,"
            "public_ip TEXT,"
            "mac_address TEXT,"
            "isp TEXT,"
            "city TEXT,"
            "country TEXT,"
            "first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,"
            "last_seen DATETIME DEFAULT CURRENT_TIMESTAMP)"
        )
        dev_cols = [c[1] for c in db.execute("PRAGMA table_info(devices)").fetchall()]
        if "device_model" not in dev_cols:
            try:
                db.execute("ALTER TABLE devices ADD COLUMN device_model TEXT")
            except Exception:
                pass
        db.execute(
            "CREATE TABLE IF NOT EXISTS device_watch_history("
            "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "device_id TEXT NOT NULL,"
            "filename TEXT NOT NULL,"
            "position REAL NOT NULL DEFAULT 0,"
            "duration REAL NOT NULL DEFAULT 0,"
            "completed INTEGER NOT NULL DEFAULT 0,"
            "last_watched DATETIME DEFAULT CURRENT_TIMESTAMP,"
            "UNIQUE(device_id, filename))"
        )
        db.execute(
            "CREATE TABLE IF NOT EXISTS ip_cache("
            "ip TEXT PRIMARY KEY,"
            "isp TEXT,"
            "org TEXT,"
            "city TEXT,"
            "country TEXT,"
            "updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)"
        )
        db.execute(
            "CREATE TABLE IF NOT EXISTS settings("
            "key TEXT PRIMARY KEY,"
            "value TEXT NOT NULL,"
            "updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)"
        )
        db.execute("CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_dwh_device ON device_watch_history(device_id, last_watched DESC)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at DESC)")
        db.execute("INSERT OR IGNORE INTO schema_migrations VALUES(1)")
        db.commit()
        db.close()
    elif backend == "postgres":
        db = get_db()
        try:
            run_postgres_migrations(db)
        finally:
            db.close()


def value(row, key, default=None):
    """Safely extract a value from a sqlite3.Row or dict, returning default if absent."""
    if row is None:
        return default
    if hasattr(row, 'keys'):
        return row[key] if key in row.keys() else default
    if isinstance(row, dict):
        return row.get(key, default)
    return default


def get_setting(key, default=None):
    """Retrieve an application setting value from the settings table."""
    db = get_db()
    try:
        row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return value(row, 'value', default)
    finally:
        db.close()


def set_setting(key, val):
    """Insert or update an application setting value in the settings table."""
    db = get_db()
    try:
        db.execute(
            "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, CURRENT_TIMESTAMP) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=CURRENT_TIMESTAMP",
            (key, str(val))
        )
        db.commit()
    finally:
        db.close()
