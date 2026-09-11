"""Database connection and initialization module."""
import sqlite3
from app import config


def get_db():
    """Return a new SQLite database connection configured with Row factory."""
    config.DATABASE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(config.DATABASE)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    """Initialize SQLite database tables, perform schema migrations, and create indexes."""
    db = get_db()
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
    for name, spec in (("release_date", "TEXT"), ("added_at", "INTEGER"), ("details_json", "TEXT")):
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
    db.execute("CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen DESC)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_dwh_device ON device_watch_history(device_id, last_watched DESC)")
    db.execute("CREATE INDEX IF NOT EXISTS idx_progress_updated ON progress(updated_at DESC)")
    db.execute("INSERT OR IGNORE INTO schema_migrations VALUES(1)")
    db.commit()
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

