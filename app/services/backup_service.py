"""Database backup, verification, restoration, and retention service.

Provides crash-safe, online snapshots of SQLite databases (handling WAL mode
without locking or tearing pages), cryptographic integrity verification,
atomic restoration with pre-restore safety rollback points, and retention rotation.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app import config

logger = logging.getLogger(__name__)


class BackupError(Exception):
    """Base exception for database backup and recovery operations."""


class BackupVerificationError(BackupError):
    """Raised when a database backup fails cryptographic or SQLite integrity checks."""


class RestoreError(BackupError):
    """Raised when database restoration fails or safety pre-conditions are unmet."""


def compute_file_sha256(file_path: Path | str, chunk_size: int = 65536) -> str:
    """Compute the SHA-256 hex digest of a file in streaming chunks."""
    path = Path(file_path)
    if not path.is_file():
        raise FileNotFoundError(f"File not found for checksum: {path}")
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(chunk_size):
            h.update(chunk)
    return h.hexdigest()


def audit_sqlite_database(db_path: Path | str) -> dict[str, Any]:
    """Inspect an SQLite database for integrity, foreign key consistency, and table row counts.

    Opens the database in read-only mode to prevent side-effect writes.
    """
    path = Path(db_path).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"SQLite database file not found: {path}")

    uri = f"file:{path.as_posix()}?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=10.0)
    except sqlite3.DatabaseError as e:
        raise BackupVerificationError(f"Failed to open SQLite database {path.name}: {e}") from e

    try:
        # 1. PRAGMA integrity_check
        try:
            integrity_rows = [r[0] for r in con.execute("PRAGMA integrity_check").fetchall()]
        except sqlite3.DatabaseError as e:
            raise BackupVerificationError(f"SQLite integrity check failed on {path.name}: {e}") from e

        is_ok = len(integrity_rows) == 1 and integrity_rows[0] == "ok"
        if not is_ok:
            raise BackupVerificationError(f"SQLite integrity check failed on {path}: {integrity_rows}")

        # 2. PRAGMA foreign_key_check
        fk_violations = con.execute("PRAGMA foreign_key_check").fetchall()
        if fk_violations:
            logger.warning("Foreign key check violations found in %s: %s", path, fk_violations)

        # 3. Discovered tables and row counts
        tables_res = con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).fetchall()
        table_names = [r[0] for r in tables_res]

        table_counts: dict[str, int] = {}
        total_rows = 0
        for table in table_names:
            try:
                # Table names from sqlite_master are safe identifiers
                cnt = con.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
                table_counts[table] = cnt
                total_rows += cnt
            except Exception as e:
                logger.warning("Could not count rows in table %s: %e", table, e)
                table_counts[table] = -1

        # 4. Schema version
        schema_version: int | None = None
        if "schema_migrations" in table_names:
            try:
                ver_row = con.execute("SELECT MAX(version) FROM schema_migrations").fetchone()
                if ver_row and ver_row[0] is not None:
                    schema_version = int(ver_row[0])
            except Exception:
                pass

        return {
            "integrity": "ok",
            "foreign_key_violations": len(fk_violations),
            "tables": table_counts,
            "total_rows": total_rows,
            "schema_version": schema_version,
            "file_size_bytes": path.stat().st_size,
        }
    finally:
        con.close()


def create_backup(
    source_db_path: Path | str | None = None,
    backup_dir: Path | str | None = None,
    label: str = "manual",
    verify_after: bool = True,
) -> dict[str, Any]:
    """Create a crash-safe, verified online backup of an SQLite database.

    Uses SQLite's native Online Backup API (`source.backup(dest)`) which:
    - Atomically captures all committed transactions including active WAL pages.
    - Never interrupts concurrent readers or blocks writers during long-running copies.
    - Yields a standalone, defragmented single-file database that requires no WAL sidecars.
    - Emits a cryptographic manifest (.json) alongside the .db backup.
    """
    src = Path(source_db_path or config.DATABASE).resolve()
    if not src.is_file():
        raise FileNotFoundError(f"Source database file does not exist: {src}")

    dst_dir = Path(backup_dir or getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")).resolve()
    dst_dir.mkdir(parents=True, exist_ok=True)

    timestamp_str = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    clean_label = "".join(c for c in label if c.isalnum() or c in ("-", "_")).strip("-_")
    file_stem = f"media_backup_{timestamp_str}_{clean_label}" if clean_label else f"media_backup_{timestamp_str}"

    backup_file = dst_dir / f"{file_stem}.db"
    manifest_file = dst_dir / f"{file_stem}.json"
    temp_stage = dst_dir / f"{file_stem}.tmp"

    if temp_stage.exists():
        temp_stage.unlink(missing_ok=True)

    logger.info("Starting online backup of %s to %s", src, backup_file)

    try:
        # Use SQLite Online Backup API via Python standard library
        src_conn = sqlite3.connect(src, timeout=30.0)
        dst_conn = sqlite3.connect(temp_stage)
        try:
            # Transfer pages incrementally in chunks of 100 pages
            src_conn.backup(dst_conn, pages=100)
        finally:
            dst_conn.close()
            src_conn.close()

        # Atomic promotion of the stage file
        if backup_file.exists():
            backup_file.unlink()
        temp_stage.replace(backup_file)

        # Audit and verify the backup
        audit_info = audit_sqlite_database(backup_file) if verify_after else {}
        file_sha256 = compute_file_sha256(backup_file)

        manifest: dict[str, Any] = {
            "version": 1,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "source_db": str(src),
            "backup_file": backup_file.name,
            "backup_path": str(backup_file),
            "label": label,
            "sha256": file_sha256,
            "size_bytes": backup_file.stat().st_size,
            "schema_version": audit_info.get("schema_version"),
            "table_counts": audit_info.get("tables", {}),
            "total_rows": audit_info.get("total_rows", 0),
            "integrity": audit_info.get("integrity", "unverified"),
        }

        # Write manifest atomically
        manifest_tmp = manifest_file.with_suffix(".json.tmp")
        manifest_tmp.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        manifest_tmp.replace(manifest_file)

        logger.info(
            "Backup successfully created: %s (%d bytes, sha256=%s, rows=%d)",
            backup_file.name,
            manifest["size_bytes"],
            file_sha256[:12],
            manifest["total_rows"],
        )
        return manifest

    except Exception as e:
        logger.error("Failed to complete database backup: %s", e)
        if temp_stage.exists():
            temp_stage.unlink(missing_ok=True)
        if backup_file.exists():
            backup_file.unlink(missing_ok=True)
        if manifest_file.exists():
            manifest_file.unlink(missing_ok=True)
        raise BackupError(f"Backup failed: {e}") from e


def verify_backup(backup_file: Path | str, expected_sha256: str | None = None) -> dict[str, Any]:
    """Verify an existing backup against cryptographic hashes and SQLite integrity checks.

    Validates:
    1. File existence and non-zero length.
    2. Computed SHA-256 against expected hash and/or companion manifest (.json).
    3. SQLite PRAGMA integrity_check.
    4. Table row count parity against the manifest if available.
    """
    path = Path(backup_file).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"Backup file not found: {path}")

    actual_sha256 = compute_file_sha256(path)
    if expected_sha256 and actual_sha256.lower() != expected_sha256.lower():
        raise BackupVerificationError(
            f"Checksum mismatch for {path.name}: expected {expected_sha256}, got {actual_sha256}"
        )

    # Check companion manifest if present
    manifest_file = path.with_suffix(".json")
    manifest_data: dict[str, Any] | None = None
    if manifest_file.is_file():
        try:
            manifest_data = json.loads(manifest_file.read_text(encoding="utf-8"))
            recorded_sha = manifest_data.get("sha256")
            if recorded_sha and recorded_sha.lower() != actual_sha256.lower():
                raise BackupVerificationError(
                    f"Manifest checksum mismatch for {path.name}: recorded {recorded_sha}, actual {actual_sha256}"
                )
        except json.JSONDecodeError as jde:
            logger.warning("Manifest for %s is corrupted: %s", path.name, jde)

    # Run full SQLite integrity and schema audit
    audit_data = audit_sqlite_database(path)

    # Reconcile with manifest table counts if available
    if manifest_data and "table_counts" in manifest_data:
        expected_counts = manifest_data["table_counts"]
        actual_counts = audit_data["tables"]
        for table, expected_cnt in expected_counts.items():
            actual_cnt = actual_counts.get(table)
            if actual_cnt != expected_cnt:
                raise BackupVerificationError(
                    f"Table row count mismatch in {table}: expected {expected_cnt}, found {actual_cnt}"
                )

    return {
        "valid": True,
        "backup_file": path.name,
        "path": str(path),
        "sha256": actual_sha256,
        "audit": audit_data,
        "manifest_verified": manifest_data is not None,
    }


def restore_database(
    backup_file: Path | str,
    target_db_path: Path | str | None = None,
    create_rollback_point: bool = True,
    backup_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Safely restore a database from an approved backup file.

    Guarantees:
    1. Pre-validates the backup file using `verify_backup()` before touching the target.
    2. Takes an automatic pre-restore rollback snapshot of the existing database.
    3. Handles SQLite WAL mode on Windows: purges stale -wal and -shm files prior to swap,
       preventing database disk image corruption from stale write-ahead log replay.
    4. Post-validates the target database with `PRAGMA integrity_check` and reinstates WAL mode.
    """
    src_backup = Path(backup_file).resolve()
    target = Path(target_db_path or config.DATABASE).resolve()

    # 1. Pre-validation of backup
    logger.info("Validating backup %s before restoration...", src_backup.name)
    verification = verify_backup(src_backup)
    if not verification.get("valid"):
        raise RestoreError(f"Refusing to restore from unverified backup: {src_backup}")

    # 2. Safety rollback snapshot of existing database if present
    rollback_manifest: dict[str, Any] | None = None
    if target.is_file() and target.stat().st_size > 0 and create_rollback_point:
        rollback_dir = Path(backup_dir or getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")).resolve()
        logger.info("Creating safety rollback point of active database %s...", target)
        rollback_manifest = create_backup(
            source_db_path=target,
            backup_dir=rollback_dir,
            label="pre_restore_safety_rollback",
            verify_after=True,
        )

    # 3. Perform restoration via atomic staging
    target.parent.mkdir(parents=True, exist_ok=True)
    stage_path = target.with_suffix(".restore_stage")

    try:
        # Copy verified backup to stage file
        if stage_path.exists():
            stage_path.unlink(missing_ok=True)
        shutil.copy2(src_backup, stage_path)

        # 4. Clean up SQLite WAL and SHM sidecars on the target database
        # This is vital on Windows: leaving stale -wal / -shm will cause SQLite to replay
        # mismatched WAL pages over the new database, creating corrupt disk image errors.
        wal_path = target.parent / f"{target.name}-wal"
        shm_path = target.parent / f"{target.name}-shm"
        for sidecar in (wal_path, shm_path):
            if sidecar.exists():
                try:
                    sidecar.unlink()
                except OSError as e:
                    logger.warning("Could not unlink sidecar %s: %s", sidecar, e)

        # 5. Atomic promotion of restored database
        if target.exists():
            target.unlink(missing_ok=True)
        stage_path.replace(target)

        # 6. Post-restore verification and WAL mode reinstatement
        post_conn = sqlite3.connect(target, timeout=15.0)
        try:
            # Re-ensure WAL journal mode
            post_conn.execute("PRAGMA journal_mode=WAL")
            check_res = post_conn.execute("PRAGMA integrity_check").fetchone()
            if not check_res or check_res[0] != "ok":
                raise RestoreError(f"Post-restore integrity check failed on {target}: {check_res}")
        finally:
            post_conn.close()

        logger.info("Database successfully restored to %s from %s", target, src_backup.name)
        return {
            "restored": True,
            "target": str(target),
            "backup_used": str(src_backup),
            "sha256": verification["sha256"],
            "rollback_created": rollback_manifest is not None,
            "rollback_file": rollback_manifest["backup_file"] if rollback_manifest else None,
        }

    except Exception as e:
        logger.error("Failed to restore database to %s: %s", target, e)
        if stage_path.exists():
            stage_path.unlink(missing_ok=True)
        raise RestoreError(f"Database restoration failed: {e}") from e


def prune_backups(backup_dir: Path | str | None = None, keep: int = 7) -> list[Path]:
    """Retain the newest `keep` backups and remove older snapshots and manifests."""
    if keep < 1:
        raise ValueError(f"keep parameter must be >= 1, got {keep}")

    b_dir = Path(backup_dir or getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")).resolve()
    if not b_dir.is_dir():
        return []

    # Identify all backup database files matching canonical naming
    backup_files = [f for f in b_dir.glob("media_backup_*.db") if f.is_file()]
    # Sort by modification time descending (newest first)
    backup_files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    retained = backup_files[:keep]
    to_prune = backup_files[keep:]

    pruned: list[Path] = []
    for old_file in to_prune:
        try:
            old_file.unlink(missing_ok=True)
            pruned.append(old_file)
            manifest = old_file.with_suffix(".json")
            if manifest.exists():
                manifest.unlink(missing_ok=True)
                pruned.append(manifest)
            logger.info("Pruned old backup: %s", old_file.name)
        except OSError as e:
            logger.warning("Could not prune backup file %s: %s", old_file, e)

    return pruned


def list_backups(backup_dir: Path | str | None = None) -> list[dict[str, Any]]:
    """Return an ordered summary list of all available backups in the backup directory."""
    b_dir = Path(backup_dir or getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")).resolve()
    if not b_dir.is_dir():
        return []

    backup_files = [f for f in b_dir.glob("media_backup_*.db") if f.is_file()]
    backup_files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    results: list[dict[str, Any]] = []
    for bf in backup_files:
        st = bf.stat()
        manifest_path = bf.with_suffix(".json")
        info: dict[str, Any] = {
            "filename": bf.name,
            "path": str(bf),
            "size_bytes": st.st_size,
            "modified_at": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat(),
            "has_manifest": manifest_path.is_file(),
            "label": "unknown",
            "schema_version": None,
            "total_rows": None,
            "sha256": None,
        }
        if manifest_path.is_file():
            try:
                m_data = json.loads(manifest_path.read_text(encoding="utf-8"))
                info["label"] = m_data.get("label", "unknown")
                info["schema_version"] = m_data.get("schema_version")
                info["total_rows"] = m_data.get("total_rows")
                info["sha256"] = m_data.get("sha256")
                info["timestamp"] = m_data.get("timestamp")
            except Exception:
                pass
        results.append(info)

    return results
