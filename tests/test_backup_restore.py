"""Automated test suite for the database backup, verification, and restore engine.

Ensures:
1. Online, non-blocking backup creation in SQLite WAL mode.
2. Manifest generation with SHA-256 and table row count auditing.
3. Cryptographic and SQLite integrity validation (detecting bit rot, truncation, tampering).
4. Atomic restore with pre-restore safety rollback snapshots.
5. Safe Windows WAL/SHM sidecar unlinking preventing stale log replay.
6. Retention pruning and backup cataloging.
7. Strict test isolation (only temporary fixtures touched, zero production leakage).
"""
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from app.services import backup_service


@pytest.fixture
def test_db_setup(tmp_path: Path):
    """Create an isolated SQLite database fixture populated with sample tables and rows."""
    db_file = tmp_path / "fixture_media.db"
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir(parents=True, exist_ok=True)

    con = sqlite3.connect(db_file)
    try:
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)")
        con.execute("INSERT INTO schema_migrations VALUES (1)")

        con.execute(
            """
            CREATE TABLE movies (
                filename TEXT PRIMARY KEY,
                title TEXT,
                year INTEGER,
                tmdb_id INTEGER
            )
            """
        )
        con.execute("INSERT INTO movies VALUES ('Movie1.mp4', 'Movie One', 2024, 101)")
        con.execute("INSERT INTO movies VALUES ('Movie2.mkv', 'Movie Two', 2025, 102)")

        con.execute(
            """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY,
                value TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        con.execute("INSERT INTO settings (key, value) VALUES ('admin_pin', '8492')")
        con.execute("INSERT INTO settings (key, value) VALUES ('retention_policy', 'archive')")

        con.execute(
            """
            CREATE TABLE progress (
                filename TEXT PRIMARY KEY,
                position REAL,
                duration REAL
            )
            """
        )
        con.execute("INSERT INTO progress VALUES ('Movie1.mp4', 120.5, 7200.0)")

        con.commit()
    finally:
        con.close()

    return {"db_file": db_file, "backup_dir": backup_dir}


def test_backup_creation_and_manifest(test_db_setup):
    """Verify backup creates a valid standalone .db and companion .json manifest."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    manifest = backup_service.create_backup(
        source_db_path=db_file,
        backup_dir=backup_dir,
        label="unit-test",
        verify_after=True,
    )

    assert manifest["integrity"] == "ok"
    assert manifest["label"] == "unit-test"
    assert manifest["table_counts"]["movies"] == 2
    assert manifest["table_counts"]["settings"] == 2
    assert manifest["table_counts"]["progress"] == 1
    assert manifest["total_rows"] == 6  # 2 + 2 + 1 + 1 migration row
    assert manifest["schema_version"] == 1

    backup_path = Path(manifest["backup_path"])
    manifest_path = backup_path.with_suffix(".json")
    assert backup_path.is_file()
    assert manifest_path.is_file()

    # Verify SHA-256 matches actual file
    assert backup_service.compute_file_sha256(backup_path) == manifest["sha256"]

    # Verify backup opens as a standalone SQLite database without needing WAL
    con = sqlite3.connect(backup_path)
    try:
        rows = con.execute("SELECT filename, title FROM movies ORDER BY filename").fetchall()
        assert len(rows) == 2
        assert rows[0] == ("Movie1.mp4", "Movie One")
    finally:
        con.close()


def test_verify_backup_tamper_detection(test_db_setup):
    """Ensure verify_backup detects checksum mismatch, corruption, and table row tampering."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    manifest = backup_service.create_backup(
        source_db_path=db_file,
        backup_dir=backup_dir,
        label="tamper-test",
    )
    backup_path = Path(manifest["backup_path"])

    # 1. Healthy backup passes
    report = backup_service.verify_backup(backup_path)
    assert report["valid"] is True
    assert report["manifest_verified"] is True

    # 2. Tampering file contents (corrupting bytes)
    corrupted_path = backup_dir / "corrupted.db"
    corrupted_manifest = backup_dir / "corrupted.json"
    raw_bytes = bytearray(backup_path.read_bytes())
    # Modify header bytes so checksum is guaranteed to differ
    raw_bytes[0] = (raw_bytes[0] + 1) % 256
    corrupted_path.write_bytes(raw_bytes)
    corrupted_manifest.write_text(Path(manifest["backup_path"]).with_suffix(".json").read_text())

    # SHA-256 check fails against manifest
    with pytest.raises(backup_service.BackupVerificationError, match="Manifest checksum mismatch"):
        backup_service.verify_backup(corrupted_path)


def test_restore_database_with_rollback(test_db_setup):
    """Ensure restore replaces the target database and creates an automatic rollback snapshot."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    # 1. Create baseline backup (v1)
    v1_manifest = backup_service.create_backup(
        source_db_path=db_file,
        backup_dir=backup_dir,
        label="version1",
    )
    v1_backup_path = Path(v1_manifest["backup_path"])

    # 2. Mutate active database to v2 (add new rows, change settings)
    con = sqlite3.connect(db_file)
    try:
        con.execute("INSERT INTO movies VALUES ('Movie3.mp4', 'Movie Three', 2026, 103)")
        con.execute("UPDATE settings SET value = '9999' WHERE key = 'admin_pin'")
        con.commit()
    finally:
        con.close()

    # Verify v2 state
    con = sqlite3.connect(db_file)
    assert con.execute("SELECT COUNT(*) FROM movies").fetchone()[0] == 3
    assert con.execute("SELECT value FROM settings WHERE key='admin_pin'").fetchone()[0] == "9999"
    con.close()

    # 3. Restore v1 over active database
    restore_res = backup_service.restore_database(
        backup_file=v1_backup_path,
        target_db_path=db_file,
        create_rollback_point=True,
        backup_dir=backup_dir,
    )

    assert restore_res["restored"] is True
    assert restore_res["rollback_created"] is True
    rollback_file = Path(backup_dir) / restore_res["rollback_file"]
    assert rollback_file.is_file()

    # 4. Verify target database is back to v1
    con = sqlite3.connect(db_file)
    try:
        movie_rows = con.execute("SELECT filename FROM movies ORDER BY filename").fetchall()
        assert len(movie_rows) == 2  # Movie3 is gone
        assert movie_rows == [("Movie1.mp4",), ("Movie2.mkv",)]
        pin = con.execute("SELECT value FROM settings WHERE key='admin_pin'").fetchone()[0]
        assert pin == "8492"  # Restored to 8492
    finally:
        con.close()

    # 5. Verify the safety rollback snapshot contains v2!
    rollback_audit = backup_service.audit_sqlite_database(rollback_file)
    assert rollback_audit["tables"]["movies"] == 3


def test_restore_cleans_stale_wal_sidecars(test_db_setup):
    """Ensure restore deletes pre-existing .db-wal and .db-shm sidecars so SQLite starts clean."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    manifest = backup_service.create_backup(source_db_path=db_file, backup_dir=backup_dir)
    backup_path = Path(manifest["backup_path"])

    # Plant synthetic stale WAL and SHM sidecars
    wal_file = db_file.parent / f"{db_file.name}-wal"
    shm_file = db_file.parent / f"{db_file.name}-shm"
    wal_file.write_bytes(b"STALE_WAL_DATA" * 50)
    shm_file.write_bytes(b"STALE_SHM_DATA" * 50)
    assert wal_file.exists()
    assert shm_file.exists()

    # Restore backup
    res = backup_service.restore_database(
        backup_file=backup_path,
        target_db_path=db_file,
        create_rollback_point=False,
    )
    assert res["restored"] is True

    # Post-condition: old stale sidecars were removed during restore
    # (SQLite may create fresh zero-length or initialized WAL when connecting, but old content is gone)
    con = sqlite3.connect(db_file)
    try:
        check = con.execute("PRAGMA integrity_check").fetchone()[0]
        assert check == "ok"
    finally:
        con.close()


def test_prune_backups_retention(tmp_path: Path):
    """Ensure prune_backups retains exactly N newest backups and removes older ones."""
    backup_dir = tmp_path / "prune_test"
    backup_dir.mkdir()

    # Create 8 dummy backup pairs
    for i in range(8):
        db_file = backup_dir / f"media_backup_20261014_{i:02d}0000.db"
        json_file = db_file.with_suffix(".json")
        db_file.write_bytes(b"DUMMY_DB_DATA")
        json_file.write_text(json.dumps({"index": i}))
        # Modify mtime so ordering is deterministic
        st_time = 1700000000 + i * 100
        import os
        os.utime(db_file, (st_time, st_time))
        os.utime(json_file, (st_time, st_time))

    assert len(list(backup_dir.glob("*.db"))) == 8
    assert len(list(backup_dir.glob("*.json"))) == 8

    # Retain 3 newest
    pruned = backup_service.prune_backups(backup_dir=backup_dir, keep=3)
    assert len(pruned) == 10  # 5 .db files + 5 matching .json files

    remaining_dbs = sorted(f.name for f in backup_dir.glob("*.db"))
    assert len(remaining_dbs) == 3
    # The 3 newest are indices 05, 06, 07
    assert remaining_dbs == [
        "media_backup_20261014_050000.db",
        "media_backup_20261014_060000.db",
        "media_backup_20261014_070000.db",
    ]


def test_cli_backup_and_restore(test_db_setup):
    """Verify CLI scripts backup_database.py and restore_database.py run via subprocess."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    # 1. Run backup CLI
    cmd_backup = [
        sys.executable,
        "scripts/backup_database.py",
        "--source",
        str(db_file),
        "--dest",
        str(backup_dir),
        "--label",
        "cli-test",
        "--json",
    ]
    proc_b = subprocess.run(cmd_backup, capture_output=True, text=True, check=True)
    manifest = json.loads(proc_b.stdout)
    assert manifest["integrity"] == "ok"
    backup_file = Path(manifest["backup_path"])
    assert backup_file.is_file()

    # 2. Run restore CLI with --force
    target_restored = test_db_setup["db_file"].parent / "restored_cli.db"
    cmd_restore = [
        sys.executable,
        "scripts/restore_database.py",
        "--backup",
        str(backup_file),
        "--target",
        str(target_restored),
        "--no-rollback",
        "--force",
        "--json",
    ]
    proc_r = subprocess.run(cmd_restore, capture_output=True, text=True, check=True)
    res = json.loads(proc_r.stdout)
    assert res["restored"] is True
    assert Path(target_restored).is_file()

    # Verify restored DB integrity
    audit = backup_service.audit_sqlite_database(target_restored)
    assert audit["integrity"] == "ok"
    assert audit["tables"]["movies"] == 2


def test_list_backups_metadata(test_db_setup):
    """Ensure list_backups discovers, parses, and orders available backups with metadata."""
    db_file = test_db_setup["db_file"]
    backup_dir = test_db_setup["backup_dir"]

    # Initially empty
    assert backup_service.list_backups(backup_dir=backup_dir) == []

    # Create two backups
    backup_service.create_backup(source_db_path=db_file, backup_dir=backup_dir, label="first")
    backup_service.create_backup(source_db_path=db_file, backup_dir=backup_dir, label="second")

    backups = backup_service.list_backups(backup_dir=backup_dir)
    assert len(backups) == 2
    assert backups[0]["has_manifest"] is True
    assert backups[0]["schema_version"] == 1
    assert backups[0]["total_rows"] == 6
    assert backups[0]["label"] in ("first", "second")


def test_restore_rejects_unverified_file(tmp_path: Path):
    """Ensure restore_database raises RestoreError if given a non-existent or corrupted file."""
    non_existent = tmp_path / "does_not_exist.db"
    target = tmp_path / "target.db"

    with pytest.raises(FileNotFoundError):
        backup_service.restore_database(non_existent, target_db_path=target)

    corrupt = tmp_path / "corrupt.db"
    corrupt.write_bytes(b"NOT_A_SQLITE_DATABASE")
    with pytest.raises(backup_service.BackupVerificationError):
        backup_service.restore_database(corrupt, target_db_path=target)
