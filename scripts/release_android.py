#!/usr/bin/env python3
"""Build and publish an Android client release in ONE verified step.

WHY THIS EXISTS
---------------
The released APK and the update manifest had drifted apart: the build the device runs carried
versionCode 103 (published by `publish_update.py`) while a plain `flutter build apk --release`
stamped `pubspec.yaml`'s version instead - a different number entirely. Publishing such a pair
would hand every client an update that claims one version and installs another.

The rule now is that the APK is the source of truth: `publish_update.py` reads the built APK's
own packageId/versionCode/versionName/minSdk/targetSdk (via aapt2) and refuses to publish unless
they match the manifest it is about to write. For that gate to pass, the build and the
publication must be given the same versionCode - which is what this script does, so the two can
no longer be produced separately by hand:

  1. allocate the next global monotonic versionCode from updates/version_registry.json
     (or honour an explicit --version-code that is strictly greater)
  2. `flutter build apk --release --build-name=<version> --build-number=<code>`
  3. read the built APK's identity back and print it
  4. publish atomically (APK + manifest + registry) to the requested channel

Usage:
  python scripts/release_android.py --channel developer --version 1.0.4-dev.104 \
      --notes "phase 4.6 navigation shell"
  python scripts/release_android.py --channel developer --version 1.0.4-dev.104 --dry-run
  python scripts/release_android.py --channel developer --version 1.0.4-dev.104 \
      --apk build/app/outputs/flutter-apk/app-release.apk     # publish an existing build

The version string is the APK's versionName as well as the manifest's display version; keep the
`-dev.<code>` suffix on developer builds so the installed app and the feed agree.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FLUTTER_CLIENT_DIR = REPO_ROOT / "flutter_client"
APK_RELATIVE_PATH = Path("build/app/outputs/flutter-apk/app-release.apk")
FLUTTER_ENV_VAR = "MEDIA_SERVER_FLUTTER"
FLUTTER_FALLBACKS = (Path("D:/src/flutter/bin/flutter.bat"), Path("C:/src/flutter/bin/flutter.bat"))

if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.publish_update import (  # noqa: E402  (sys.path is extended just above)
    DEFAULT_REGISTRY_PATH,
    load_registry,
    publish_release,
    read_apk_identity,
)


def find_flutter(explicit: str | None = None) -> str:
    """Locate the Flutter launcher: --flutter, then MEDIA_SERVER_FLUTTER, then PATH, then common installs."""
    if explicit:
        return explicit
    from_env = os.environ.get(FLUTTER_ENV_VAR)
    if from_env:
        return from_env
    on_path = shutil.which("flutter")
    if on_path:
        return on_path
    for candidate in FLUTTER_FALLBACKS:
        if candidate.is_file():
            return str(candidate)
    raise SystemExit(f"flutter not found - pass --flutter, set {FLUTTER_ENV_VAR}, or put flutter on PATH")


def next_version_code(registry_path: Path, explicit: int | None) -> int:
    """Allocate the versionCode exactly as publish_release will, so build and manifest agree."""
    registry = load_registry(registry_path)
    last_code = int(registry.get("lastVersionCode", 100))
    if explicit is not None:
        if explicit <= last_code:
            raise SystemExit(
                f"--version-code {explicit} is not greater than the registry's lastVersionCode {last_code}"
            )
        return explicit
    return last_code + 1


def build_apk(flutter: str, version: str, version_code: int) -> Path:
    """Run the release build with the allocated build number and return the produced APK path."""
    command = [
        "build",
        "apk",
        "--release",
        f"--build-name={version}",
        f"--build-number={version_code}",
    ]
    # CreateProcess cannot launch a .bat/.cmd directly; route the Windows launcher through cmd.exe.
    if flutter.lower().endswith((".bat", ".cmd")):
        command = ["cmd.exe", "/c", flutter] + command
    else:
        command = [flutter] + command
    print(f"[release] building: {' '.join(command)}", flush=True)
    result = subprocess.run(command, cwd=str(FLUTTER_CLIENT_DIR))
    if result.returncode != 0:
        raise SystemExit(f"[release] flutter build failed with exit code {result.returncode}")
    apk_path = FLUTTER_CLIENT_DIR / APK_RELATIVE_PATH
    if not apk_path.is_file():
        raise SystemExit(f"[release] expected APK not found: {apk_path}")
    return apk_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and publish a verified Android release.")
    parser.add_argument("--channel", required=True, choices=["production", "developer"], help="Target update channel")
    parser.add_argument("--version", required=True, help="Display version AND APK versionName, e.g. 1.0.4-dev.104")
    parser.add_argument("--version-code", type=int, help="Explicit build number (must exceed the registry's lastVersionCode)")
    parser.add_argument("--notes", default="", help="Release notes shown in the client")
    parser.add_argument("--mandatory", action="store_true", help="Mark this update mandatory")
    parser.add_argument("--min-supported-code", type=int, default=1,
                        help="versionCode below which installed clients must stop working (default 1 = no floor)")
    parser.add_argument("--apk", help="Publish this APK instead of building one (still identity-verified)")
    parser.add_argument("--flutter", help=f"Path to the flutter launcher (default: {FLUTTER_ENV_VAR}, PATH, common installs)")
    parser.add_argument("--updates-dir", help="Custom updates directory (default: <repo>/updates)")
    parser.add_argument("--dry-run", action="store_true", help="Build and verify, publish nothing")
    args = parser.parse_args()

    updates_dir = Path(args.updates_dir).resolve() if args.updates_dir else None
    registry_path = (updates_dir / "version_registry.json") if updates_dir else DEFAULT_REGISTRY_PATH

    version_code = next_version_code(registry_path, args.version_code)
    print(f"[release] allocated versionCode {version_code} for version {args.version} ({args.channel})")

    if args.apk:
        apk_path = Path(args.apk)
        if not apk_path.is_absolute():
            apk_path = (REPO_ROOT / apk_path).resolve()
        if not apk_path.is_file():
            raise SystemExit(f"[release] APK not found: {apk_path}")
        print(f"[release] using existing APK: {apk_path}")
    else:
        apk_path = build_apk(find_flutter(args.flutter), args.version, version_code)

    identity = read_apk_identity(apk_path)
    print(
        "[release] APK identity: "
        f"package={identity['packageId']} versionCode={identity['versionCode']} "
        f"versionName={identity['versionName']} minSdk={identity['minSdk']} targetSdk={identity['targetSdk']}"
    )

    if args.dry_run:
        print(f"[release] dry run: verified build only, nothing published (code {version_code})")
        return 0

    manifest = publish_release(
        channel=args.channel,
        version=args.version,
        apk_path=apk_path,
        notes=args.notes,
        explicit_version_code=version_code,
        mandatory=args.mandatory,
        min_supported_version_code=args.min_supported_code,
        updates_dir=updates_dir,
    )
    print("=" * 60)
    print(f"[release] published {manifest['channel'].upper()} {manifest['version']} (versionCode {manifest['versionCode']})")
    print(f"[release] minSdk {manifest['minAndroidSdk']} / targetSdk {manifest['targetAndroidSdk']} (read from the APK)")
    print(f"[release] sha256 {manifest['sha256']}")
    print(f"[release] apk {apk_path}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())