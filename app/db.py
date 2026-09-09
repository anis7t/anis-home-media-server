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

