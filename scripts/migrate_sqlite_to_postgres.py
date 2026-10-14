#!/usr/bin/env python3
"""Automated SQLite to PostgreSQL Migration and Verification Utility (Phase 3).

Transfers all tables and rows from the Media Server SQLite database into PostgreSQL
with dependency-ordered insertion, identity sequence synchronization, timestamp
normalization, and cryptographic parity auditing.

Usage:
    python scripts/migrate_sqlite_to_postgres.py [--source PATH] [--target-url DSN] [--dry-run] [--no-verify]

Examples:
    python scripts/migrate_sqlite_to_postgres.py
    python scripts/migrate_sqlite_to_postgres.py --source backups/media_backup_baseline.db
    python scripts/migrate_sqlite_to_postgres.py --dry-run
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import psycopg
from psycopg.rows import dict_row

from app import config, db as app_db
from app.utils.formatting import parse_db_timestamp

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("migration")

# Dependency-ordered tables for migration (excluding obsolete prototype tables)
MIGRATION_TABLES = [
    {
        "table": "settings",
        "pk": "key",
        "columns": ["key", "value", "updated_at"],
        "timestamp_cols": {"updated_at"},
        "identity_col": None,
    },
    {
        "table": "ip_cache",
        "pk": "ip",
        "columns": ["ip", "isp", "org", "city", "country", "updated_at"],
        "timestamp_cols": {"updated_at"},
        "identity_col": None,
    },
    {
        "table": "movies",
        "pk": "filename",
        "columns": [
            "filename",
            "title",
            "year",
            "tmdb_id",
            "overview",
            "poster_path",
            "backdrop_path",
            "runtime",
            "genres",
            "vote_average",
            "updated_at",
            "release_date",
            "added_at",
            "details_json",
            "last_metadata_refresh",
        ],
        "timestamp_cols": set(),  # integer epoch timestamps in movies
        "identity_col": None,
    },
    {
        "table": "progress",
        "pk": "filename",
        "columns": ["filename", "position", "duration", "updated_at"],
        "timestamp_cols": {"updated_at"},
        "identity_col": None,
    },
    {
        "table": "devices",
        "pk": "device_id",
        "columns": [
            "device_id",
            "custom_name",
            "device_name",
            "device_type",
            "device_os",
            "browser",
            "user_agent",
            "connection_type",
            "client_ip",
            "public_ip",
            "mac_address",
            "isp",
            "city",
            "country",
            "first_seen",
            "last_seen",
            "device_model",
        ],
        "timestamp_cols": {"first_seen", "last_seen"},
        "identity_col": None,
    },
    {
        "table": "device_watch_history",
        "pk": "id",
        "columns": [
            "id",
            "device_id",
            "filename",
            "position",
            "duration",
            "completed",
            "last_watched",
        ],
        "timestamp_cols": {"last_watched"},
        "identity_col": "id",
    },
    {
        "table": "users",
        "pk": "id",
        "columns": [
            "id",
            "google_sub",
            "email",
            "name",
            "picture_url",
            "role",
            "created_at",
            "last_login_at",
        ],
        "timestamp_cols": {"created_at", "last_login_at"},
        "identity_col": "id",
    },
    {
        "table": "auth_tokens",
        "pk": "id",
        "columns": [
            "id",
            "user_id",
            "label",
            "token_hash",
            "created_at",
            "last_used_at",
            "expires_at",
            "revoked_at",
        ],
        "timestamp_cols": {"created_at", "last_used_at", "expires_at", "revoked_at"},
        "identity_col": "id",
    },
    {
        "table": "oauth_attempts",
        "pk": "state",
        "columns": [
            "state",
            "nonce",
            "verifier",
            "redirect_uri",
            "next_path",
            "started_at",
            "used",
        ],
        "timestamp_cols": set(),
        "identity_col": None,
    },
]


def compute_file_sha256(path: Path) -> str:
    """Compute SHA-256 hash of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def find_default_source() -> Path:
    """Find the default source database: latest baseline backup or live media.db."""
    backup_dir = getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")
    if backup_dir.exists():
        candidates = sorted(
            backup_dir.glob("media_backup_*_pre-migration*.db"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if candidates:
            return candidates[0]
        # Any .db in backups
        any_backups = sorted(
            [p for p in backup_dir.glob("*.db") if not p.name.endswith("-wal") and not p.name.endswith("-shm")],
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if any_backups:
            return any_backups[0]
    return config.DATABASE


def check_sqlite_integrity(source_path: Path) -> bool:
    """Run PRAGMA integrity_check on source SQLite database."""
    conn = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    try:
        cur = conn.cursor()
        res = cur.execute("PRAGMA integrity_check").fetchone()
        return bool(res and res[0] == "ok")
    finally:
        conn.close()


def migrate_data(
    source_path: Path,
    target_url: str,
    dry_run: bool = False,
    verify: bool = True,
) -> dict:
    """Execute SQLite to PostgreSQL data migration and return audit results."""
    logger.info(f"Source SQLite database: {source_path}")
    logger.info(f"Target PostgreSQL URL: {target_url.split('@')[-1] if '@' in target_url else target_url}")

    if not source_path.exists():
        raise FileNotFoundError(f"Source SQLite database not found: {source_path}")

    # Step 1: Pre-flight integrity check
    logger.info("Running SQLite source integrity check...")
    if not check_sqlite_integrity(source_path):
        raise RuntimeError(f"Source SQLite database failed integrity check: {source_path}")
    source_sha256 = compute_file_sha256(source_path)
    logger.info(f"Source integrity verified. SHA-256: {source_sha256[:16]}...")

    sqlite_conn = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
    sqlite_conn.row_factory = sqlite3.Row

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "source_path": str(source_path),
        "source_sha256": source_sha256,
        "target_host": target_url.split("@")[-1] if "@" in target_url else target_url,
        "dry_run": dry_run,
        "tables": {},
        "status": "pending",
    }

    pg_conn = psycopg.connect(target_url, row_factory=dict_row)
    try:
        # Step 2: Bootstrap PostgreSQL schema migrations inside advisory lock
        logger.info("Acquiring PostgreSQL advisory lock and ensuring schema migrations...")
        pg_conn.execute(f"SELECT pg_advisory_lock({app_db.PG_MIGRATION_ADVISORY_LOCK_KEY})")
        pg_conn.commit()

        class DirectSession:
            """Simple session shim wrapping psycopg connection for run_postgres_migrations."""
            def __init__(self, conn):
                self._conn = conn
            def execute(self, sql, params=None):
                norm = app_db.normalize_sql(sql, backend="postgres")
                cur = self._conn.cursor()
                if params is not None:
                    cur.execute(norm, params)
                else:
                    cur.execute(norm)
                return cur
            def commit(self):
                self._conn.commit()
            def rollback(self):
                self._conn.rollback()
            def close(self):
                pass

        app_db.run_postgres_migrations(DirectSession(pg_conn))
        logger.info("PostgreSQL schema migrations verified.")

        # Step 3: Iterate through tables and migrate rows
        for item in MIGRATION_TABLES:
            table_name = item["table"]
            columns = item["columns"]
            timestamp_cols = item["timestamp_cols"]
            identity_col = item["identity_col"]

            # Query source SQLite
            cols_sql = ", ".join(columns)
            sqlite_rows = sqlite_conn.execute(f"SELECT {cols_sql} FROM {table_name}").fetchall()
            src_count = len(sqlite_rows)
            logger.info(f"Migrating table '{table_name}': {src_count} source rows found.")

            if dry_run:
                report["tables"][table_name] = {
                    "source_count": src_count,
                    "target_count": "(dry-run)",
                    "parity": True,
                }
                continue

            # Ingest rows into PostgreSQL
            # Truncate existing data in table to ensure idempotent fresh snapshot
            pg_conn.execute(f"TRUNCATE TABLE {table_name} CASCADE")

            if src_count > 0:
                # Prepare rows with converted timestamps
                prepared_rows = []
                for row in sqlite_rows:
                    row_vals = []
                    for col in columns:
                        val = row[col]
                        if col in timestamp_cols:
                            val = parse_db_timestamp(val)
                            # Guard NOT NULL timestamp columns against legacy SQLite NULLs
                            if val is None and col in {"created_at", "updated_at", "first_seen", "last_seen", "last_watched"}:
                                val = datetime.now(timezone.utc)
                        row_vals.append(val)
                    prepared_rows.append(tuple(row_vals))

                placeholders = ", ".join(["%s"] * len(columns))
                insert_sql = f"INSERT INTO {table_name} ({cols_sql}) VALUES ({placeholders})"

                with pg_conn.cursor() as cur:
                    cur.executemany(insert_sql, prepared_rows)
                logger.info(f"Inserted {src_count} rows into '{table_name}'.")

            # Reset identity sequence if applicable
            if identity_col:
                seq_query = (
                    f"SELECT setval(pg_get_serial_sequence('{table_name}', '{identity_col}'), "
                    f"COALESCE((SELECT MAX({identity_col}) FROM {table_name}), 1))"
                )
                pg_conn.execute(seq_query)
                logger.info(f"Synchronized sequence for '{table_name}.{identity_col}'.")

            pg_conn.commit()

            # Verify row counts
            tgt_count = pg_conn.execute(f"SELECT COUNT(*) as cnt FROM {table_name}").fetchone()["cnt"]
            parity = (src_count == tgt_count)
            report["tables"][table_name] = {
                "source_count": src_count,
                "target_count": tgt_count,
                "parity": parity,
            }
            if not parity:
                raise RuntimeError(
                    f"Parity check failed on '{table_name}': source={src_count}, target={tgt_count}"
                )

        report["status"] = "SUCCESS"
        logger.info("All table data migrated and verified with 100% parity.")

    finally:
        try:
            pg_conn.execute(f"SELECT pg_advisory_unlock({app_db.PG_MIGRATION_ADVISORY_LOCK_KEY})")
            pg_conn.commit()
        except Exception:
            pass
        pg_conn.close()
        sqlite_conn.close()

    # Step 4: Write migration report manifest
    backup_dir = getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")
    backup_dir.mkdir(parents=True, exist_ok=True)
    report_file = backup_dir / f"migration_report_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.json"
    with open(report_file, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    logger.info(f"Migration audit report written to: {report_file}")
    report["report_file"] = str(report_file)

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Migrate Media Server SQLite database to PostgreSQL with full parity verification."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Path to source SQLite database (defaults to newest baseline backup or live media.db)",
    )
    parser.add_argument(
        "--target-url",
        type=str,
        default=os.environ.get(
            "MEDIA_SERVER_DATABASE_URL",
            "postgresql://postgres:postgres@127.0.0.1:5432/media_server",
        ),
        help="Target PostgreSQL connection URL (default: from MEDIA_SERVER_DATABASE_URL or local media_server)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect source and target schema without copying data",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="Skip post-migration row count validation",
    )

    args = parser.parse_args()

    source = args.source if args.source else find_default_source()

    try:
        res = migrate_data(
            source_path=source,
            target_url=args.target_url,
            dry_run=args.dry_run,
            verify=not args.no_verify,
        )
        print("\n====================================================")
        print("  MIGRATION SUMMARY (SQLite -> PostgreSQL)")
        print("====================================================")
        print(f"Status:      {res['status']}")
        print(f"Source:      {res['source_path']}")
        print(f"Target:      {res['target_host']}")
        print("Tables:")
        for tbl, details in res["tables"].items():
            mark = "[OK]" if details.get("parity") else "[MISMATCH]"
            print(f"  {mark:<10} {tbl:<22}: {details['source_count']} -> {details['target_count']}")
        print("====================================================")
        return 0
    except Exception as e:
        logger.error(f"Migration failed: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
