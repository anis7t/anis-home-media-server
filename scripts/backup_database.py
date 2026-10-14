#!/usr/bin/env python3
"""CLI utility to create an online, verified backup of the Media Server SQLite database.

Usage:
    python scripts/backup_database.py [--label LABEL] [--dest DIR] [--keep N] [--json]

Examples:
    python scripts/backup_database.py --label pre-migration
    python scripts/backup_database.py --keep 14
    python scripts/backup_database.py --label daily-cron --keep 7
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from app import config
from app.services import backup_service


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a crash-safe, online snapshot of the Media Server SQLite database."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=config.DATABASE,
        help=f"Source database path (default: {config.DATABASE})",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups"),
        help="Destination directory for backups (default: E:\\MediaServer\\backups)",
    )
    parser.add_argument(
        "--label",
        type=str,
        default="manual",
        help="Short label for backup filename (default: manual)",
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=7,
        help="Number of newest backups to retain (default: 7, 0 to disable pruning)",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="Skip post-backup SQLite integrity verification",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Emit JSON output for script integration",
    )

    args = parser.parse_args()

    try:
        manifest = backup_service.create_backup(
            source_db_path=args.source,
            backup_dir=args.dest,
            label=args.label,
            verify_after=not args.no_verify,
        )

        pruned = []
        if args.keep > 0:
            pruned = backup_service.prune_backups(backup_dir=args.dest, keep=args.keep)
            manifest["pruned_count"] = len(pruned)
            manifest["pruned_files"] = [p.name for p in pruned]

        if args.json_output:
            print(json.dumps(manifest, indent=2))
        else:
            print("==================================================")
            print("  DATABASE BACKUP COMPLETED SUCCESSFULLY")
            print("==================================================")
            print(f"  Backup File : {manifest['backup_file']}")
            print(f"  Destination : {manifest['backup_path']}")
            print(f"  Size        : {manifest['size_bytes']:,} bytes")
            print(f"  SHA-256     : {manifest['sha256']}")
            print(f"  Integrity   : {manifest['integrity'].upper()}")
            print(f"  Total Rows  : {manifest['total_rows']:,}")
            print(f"  Schema Ver  : {manifest['schema_version']}")
            if pruned:
                print(f"  Pruned Old  : {len(pruned)} files pruned (retaining {args.keep} newest)")
            print("==================================================")
        return 0

    except Exception as e:
        if args.json_output:
            print(json.dumps({"error": str(e)}, indent=2), file=sys.stderr)
        else:
            print(f"\n[ERROR] Database backup failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
