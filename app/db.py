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

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            self.rollback()
        else:
            self.commit()
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
            # PostgreSQL schema is created and managed through migration scripts;
            # verify connectivity and schema migrations table existence.
            db.execute("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())")
            db.commit()
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
