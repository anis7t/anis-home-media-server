#!/usr/bin/env python3
"""CLI utility to restore the Media Server SQLite database from an approved backup.

Usage:
    python scripts/restore_database.py --backup PATH_OR_LATEST [--target PATH] [--force] [--json]

Examples:
    python scripts/restore_database.py --backup latest
    python scripts/restore_database.py --backup E:\\MediaServer\\backups\\media_backup_20261014_212000.db
    python scripts/restore_database.py --backup latest --force
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Add project root to sys.path
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from app import config
from app.services import backup_service


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Safely restore the Media Server SQLite database from a verified backup."
    )
    parser.add_argument(
        "--backup",
        type=str,
        required=True,
        help="Path to the .db backup file, or 'latest' to automatically select the newest backup.",
    )
    parser.add_argument(
        "--target",
        type=Path,
        default=config.DATABASE,
        help=f"Target database path to overwrite (default: {config.DATABASE})",
    )
    parser.add_argument(
        "--no-rollback",
        action="store_true",
        help="Skip creating a pre-restore safety rollback snapshot of the target database.",
    )
    parser.add_argument(
        "--force",
        "-f",
        action="store_true",
        help="Skip interactive confirmation prompt.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Emit JSON output for automated scripting.",
    )

    args = parser.parse_args()

    # 1. Resolve backup file
    backup_file: Path
    if args.backup.lower() == "latest":
        backup_dir = getattr(config, "BACKUP_DIR", config.BASE_DIR / "backups")
        backups = backup_service.list_backups(backup_dir=backup_dir)
        if not backups:
            print(f"[ERROR] No backups found in {backup_dir}", file=sys.stderr)
            return 1
        backup_file = Path(backups[0]["path"])
        if not args.json_output:
            print(f"Selected latest backup: {backup_file.name}")
    else:
        backup_file = Path(args.backup).resolve()
        if not backup_file.is_file():
            print(f"[ERROR] Specified backup file does not exist: {backup_file}", file=sys.stderr)
            return 1

    # 2. Interactive confirmation prompt
    if not args.force and sys.stdin.isatty():
        print("----------------------------------------------------------------------")
        print("WARNING: You are about to restore the database.")
        print(f"  Backup Source : {backup_file}")
        print(f"  Target File   : {args.target}")
        if not args.no_rollback:
            print("  Safety Action : An automatic rollback snapshot will be created first.")
        print("----------------------------------------------------------------------")
        try:
            confirm = input("Type 'RESTORE' to proceed: ").strip()
            if confirm != "RESTORE":
                print("Restoration cancelled by user.")
                return 2
        except EOFError:
            print("[ERROR] Non-interactive execution requires --force.", file=sys.stderr)
            return 1

    # 3. Perform restoration
    try:
        result = backup_service.restore_database(
            backup_file=backup_file,
            target_db_path=args.target,
            create_rollback_point=not args.no_rollback,
        )

        if args.json_output:
            print(json.dumps(result, indent=2))
        else:
            print("==================================================")
            print("  DATABASE RESTORE COMPLETED SUCCESSFULLY")
            print("==================================================")
            print(f"  Target Restored : {result['target']}")
            print(f"  Source Backup   : {Path(result['backup_used']).name}")
            print(f"  SHA-256 Checksum: {result['sha256']}")
            if result.get("rollback_created"):
                print(f"  Rollback Point  : {result.get('rollback_file')} (retained)")
            print("==================================================")
            print("NOTE: If the MediaServer Windows Service is running, restart it:")
            print("  e:\\MediaServer\\scripts\\restart_service.bat")
            print("==================================================")
        return 0

    except Exception as e:
        if args.json_output:
            print(json.dumps({"error": str(e)}, indent=2), file=sys.stderr)
        else:
            print(f"\n[ERROR] Database restoration failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
