#!/usr/bin/env python3
"""Publication script for Anis' Home Media Server multi-channel Android client updates.

Enforces:
1. Global monotonic versionCode allocation across both production and developer channels.
2. Cryptographic SHA-256 checksum generation.
3. Atomic manifest and APK publication.
4. Fail-closed channel validation.
"""
import argparse
import hashlib
import json
import logging
import os
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_UPDATES_DIR = REPO_ROOT / "updates"
DEFAULT_REGISTRY_PATH = DEFAULT_UPDATES_DIR / "version_registry.json"
ALLOWED_CHANNELS = {"production", "developer"}
PACKAGE_ID = "in.anisparvez.media_server_client"


def calculate_sha256(file_path: Path) -> str:
    """Compute hex SHA-256 digest of a file in 64 KiB chunks."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().lower()


def load_registry(registry_path: Path) -> dict:
    """Load the version registry or initialize a fresh one."""
    if registry_path.is_file():
        try:
            return json.loads(registry_path.read_text(encoding="utf-8"))
        except Exception as e:
            raise ValueError(f"Failed to parse registry at {registry_path}: {e}")
    return {
        "lastVersionCode": 100,
        "channels": {
            "production": {"version": "1.0.0", "versionCode": 100, "publishedAt": ""},
            "developer": {"version": "1.0.0", "versionCode": 100, "publishedAt": ""},
        }
    }


def save_registry(registry_path: Path, registry: dict):
    """Atomically save the updated registry."""
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    temp_file = registry_path.with_suffix(".tmp")
    temp_file.write_text(json.dumps(registry, indent=2), encoding="utf-8")
    temp_file.replace(registry_path)


def publish_release(
    channel: str,
    version: str,
    apk_path: Path,
    notes: str = "",
    explicit_version_code: int = None,
    mandatory: bool = False,
    min_android_sdk: int = 26,
    target_android_sdk: int = 36,
    updates_dir: Path = None,
    registry_path: Path = None,
    git_commit: str = None,
) -> dict:
    """Publish an APK update atomically to a specified channel.

    Returns the published manifest dictionary.
    """
    channel = channel.strip().lower()
    if channel not in ALLOWED_CHANNELS:
        raise ValueError(f"Invalid channel '{channel}'. Allowed: {sorted(ALLOWED_CHANNELS)}")

    apk_path = Path(apk_path).resolve()
    if not apk_path.is_file():
        raise FileNotFoundError(f"APK file not found: {apk_path}")
    apk_size = apk_path.stat().st_size
    if apk_size <= 0:
        raise ValueError(f"APK file is empty (size 0): {apk_path}")

    updates_dir = Path(updates_dir or DEFAULT_UPDATES_DIR).resolve()
    registry_path = Path(registry_path or (updates_dir / "version_registry.json")).resolve()

    # 1. Allocate / Validate Monotonic VersionCode
    registry = load_registry(registry_path)
    last_code = int(registry.get("lastVersionCode", 100))

    if explicit_version_code is not None:
        if explicit_version_code <= last_code:
            raise ValueError(
                f"Requested versionCode {explicit_version_code} violates global monotonicity: "
                f"must be strictly greater than lastVersionCode {last_code}"
            )
        new_version_code = explicit_version_code
    else:
        new_version_code = last_code + 1

    # 2. Compute SHA-256
    sha256 = calculate_sha256(apk_path)

    # 3. Resolve Git Commit if available
    if not git_commit:
        try:
            import subprocess
            res = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                capture_output=True,
                text=True,
                cwd=REPO_ROOT,
            )
            if res.returncode == 0:
                git_commit = res.stdout.strip()
        except Exception:
            pass

    release_date = datetime.now(timezone.utc).isoformat()

    manifest = {
        "channel": channel,
        "version": version.strip(),
        "versionCode": new_version_code,
        "releaseDate": release_date,
        "minAndroidSdk": min_android_sdk,
        "targetAndroidSdk": target_android_sdk,
        "packageId": PACKAGE_ID,
        "apkUrl": f"/api/app/download?channel={channel}",
        "sha256": sha256,
        "fileSizeBytes": apk_size,
        "releaseNotes": notes.strip(),
        "mandatory": mandatory,
        "minSupportedVersionCode": 1,
    }
    if git_commit:
        manifest["gitCommit"] = git_commit

    # 4. Atomic Publication to updates/<channel>/
    channel_dir = updates_dir / channel
    channel_dir.mkdir(parents=True, exist_ok=True)

    dest_apk = channel_dir / "media-server-client.apk"
    temp_apk = channel_dir / f"media-server-client.{os.getpid()}.tmp"
    shutil.copy2(apk_path, temp_apk)
    temp_apk.replace(dest_apk)

    manifest_file = channel_dir / "manifest.json"
    temp_manifest = channel_dir / f"manifest.{os.getpid()}.tmp"
    temp_manifest.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    temp_manifest.replace(manifest_file)

    # 5. Atomically update registry
    registry["lastVersionCode"] = new_version_code
    registry.setdefault("channels", {})[channel] = {
        "version": version.strip(),
        "versionCode": new_version_code,
        "publishedAt": release_date,
        "sha256": sha256,
    }
    save_registry(registry_path, registry)

    return manifest


def main():
    parser = argparse.ArgumentParser(description="Publish Android APK to Media Server update feed.")
    parser.add_argument("--channel", required=True, choices=["production", "developer"], help="Target update channel")
    parser.add_argument("--version", required=True, help="Display version string (e.g. 1.1.0 or 1.1.0-dev.101)")
    parser.add_argument("--apk", required=True, help="Path to signed release APK file")
    parser.add_argument("--notes", default="", help="Release notes text")
    parser.add_argument("--version-code", type=int, help="Explicit versionCode (must be > lastVersionCode)")
    parser.add_argument("--mandatory", action="store_true", help="Mark this update as mandatory")
    parser.add_argument("--updates-dir", help="Custom updates directory")

    args = parser.parse_args()

    try:
        manifest = publish_release(
            channel=args.channel,
            version=args.version,
            apk_path=Path(args.apk),
            notes=args.notes,
            explicit_version_code=args.version_code,
            mandatory=args.mandatory,
            updates_dir=Path(args.updates_dir) if args.updates_dir else None,
        )
        print("=" * 60)
        print(f"Successfully published {manifest['channel'].upper()} update!")
        print(f"Version:      {manifest['version']} (versionCode: {manifest['versionCode']})")
        print(f"SHA-256:      {manifest['sha256']}")
        print(f"Size:         {manifest['fileSizeBytes']} bytes")
        print(f"APK URL:      {manifest['apkUrl']}")
        print("=" * 60)
    except Exception as e:
        print(f"ERROR: Publication failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
