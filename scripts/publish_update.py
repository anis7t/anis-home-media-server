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
import subprocess
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
AAPT2_ENV_VAR = "MEDIA_SERVER_AAPT2"


class ApkIdentityError(RuntimeError):
    """The APK's own metadata is unreadable, or contradicts the manifest about to be published."""


def find_aapt2() -> Path | None:
    """Locate aapt2: explicit env override, then the Android SDK build-tools (newest), then PATH."""
    override = os.environ.get(AAPT2_ENV_VAR)
    if override:
        candidate = Path(override)
        return candidate if candidate.is_file() else None

    sdk_root = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk_root:
        build_tools = Path(sdk_root) / "build-tools"
        if build_tools.is_dir():
            versions = sorted((d for d in build_tools.iterdir() if d.is_dir()),
                              key=lambda d: d.name, reverse=True)
            for version_dir in versions:
                for binary in ("aapt2.exe", "aapt2"):
                    candidate = version_dir / binary
                    if candidate.is_file():
                        return candidate

    found = shutil.which("aapt2")
    return Path(found) if found else None


def parse_badging(text: str) -> dict:
    """Parse `aapt2 dump badging` output into the fields the manifest must agree with."""
    identity = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("package:"):
            for key, target in (("name", "packageId"), ("versionCode", "versionCode"),
                                ("versionName", "versionName")):
                marker = f"{key}='"
                start = line.find(marker)
                if start == -1:
                    continue
                start += len(marker)
                end = line.find("'", start)
                if end > start:
                    identity[target] = line[start:end]
        elif line.startswith("minSdkVersion:") or line.startswith("sdkVersion:"):
            # aapt2 (build-tools 30+) prints `minSdkVersion:`; the legacy aapt printed `sdkVersion:`.
            identity["minSdk"] = line.split(":", 1)[1].strip().strip("'")
        elif line.startswith("targetSdkVersion:"):
            identity["targetSdk"] = line.split(":", 1)[1].strip().strip("'")
    return identity


def read_apk_identity(apk_path: Path) -> dict:
    """Read the APK's OWN identity: packageId, versionCode, versionName, minSdk, targetSdk.

    This is the anti-drift gate. The published manifest must describe the APK that was really
    built, so the APK - not the operator's command line - is the source of truth.
    """
    aapt2 = find_aapt2()
    if aapt2 is None:
        raise ApkIdentityError(
            "aapt2 not found - point "
            f"{AAPT2_ENV_VAR} at it, or set ANDROID_HOME so its build-tools can be searched"
        )

    result = subprocess.run(
        [str(aapt2), "dump", "badging", str(apk_path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ApkIdentityError(
            f"aapt2 could not read {apk_path.name}: {(result.stderr or result.stdout).strip()[:200]}"
        )

    identity = parse_badging(result.stdout)
    missing = sorted({"packageId", "versionCode", "versionName", "minSdk", "targetSdk"} - set(identity))
    if missing:
        raise ApkIdentityError(f"aapt2 output for {apk_path.name} is missing {missing}")
    return identity


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
    explicit_version_code: int | None = None,
    mandatory: bool = False,
    min_android_sdk: int | None = None,
    target_android_sdk: int | None = None,
    min_supported_version_code: int = 1,
    updates_dir: Path | None = None,
    registry_path: Path | None = None,
    git_commit: str | None = None,
) -> dict:
    """Publish an APK update atomically to a specified channel.

    The APK is the source of truth: its own packageId, versionCode, versionName, minSdk and
    targetSdk are read back from the built artifact and must agree with the manifest being
    written. Anything that disagrees is refused - never published with corrected metadata.

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

    # 2. Read the APK's own identity - the manifest must describe THIS artifact
    identity = read_apk_identity(apk_path)

    if identity["packageId"] != PACKAGE_ID:
        raise ApkIdentityError(
            f"APK packageId '{identity['packageId']}' does not match the expected '{PACKAGE_ID}'"
        )

    apk_version_code = int(identity["versionCode"])
    if apk_version_code != new_version_code:
        raise ApkIdentityError(
            f"APK versionCode {apk_version_code} != allocated versionCode {new_version_code}. "
            "Rebuild with --build-number set to the allocated code "
            "(scripts/release_android.py does the allocation, build and publish in one step)."
        )

    apk_version_name = identity["versionName"]
    if apk_version_name != version.strip():
        raise ApkIdentityError(
            f"APK versionName '{apk_version_name}' != --version '{version.strip()}'. "
            "Rebuild with --build-name set to the same value."
        )

    apk_min_sdk = int(identity["minSdk"])
    apk_target_sdk = int(identity["targetSdk"])
    for label, requested, actual in (
        ("min_android_sdk", min_android_sdk, apk_min_sdk),
        ("target_android_sdk", target_android_sdk, apk_target_sdk),
    ):
        if requested is not None and int(requested) != actual:
            raise ApkIdentityError(f"{label}={requested} contradicts the APK's own value {actual}")
    min_android_sdk, target_android_sdk = apk_min_sdk, apk_target_sdk

    # 3. Compute SHA-256
    sha256 = calculate_sha256(apk_path)

    # 4. Resolve Git Commit if available
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
        "minSupportedVersionCode": int(min_supported_version_code),
    }
    if git_commit:
        manifest["gitCommit"] = git_commit

    # 5. Atomic Publication to updates/<channel>/
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

    # 6. Atomically update registry
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
    parser.add_argument("--min-supported-code", type=int, default=1,
                        help="versionCode below which the installed client must stop working (default 1 = no floor)")
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
            min_supported_version_code=args.min_supported_code,
            updates_dir=Path(args.updates_dir) if args.updates_dir else None,
        )
        print("=" * 60)
        print(f"Successfully published {manifest['channel'].upper()} update!")
        print(f"Version:      {manifest['version']} (versionCode: {manifest['versionCode']})")
        print(f"Min/Target SDK: {manifest['minAndroidSdk']} / {manifest['targetAndroidSdk']} (read from the APK)")
        print(f"Min supported code: {manifest['minSupportedVersionCode']}")
        print(f"SHA-256:      {manifest['sha256']}")
        print(f"Size:         {manifest['fileSizeBytes']} bytes")
        print(f"APK URL:      {manifest['apkUrl']}")
        print("=" * 60)
    except Exception as e:
        print(f"ERROR: Publication failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
