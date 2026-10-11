"""Pure production-path classification for the test isolation safeguards.

Split out of ``conftest.py`` so that ``tests/test_app.py`` can validate paths
during ``tearDownClass`` without importing ``conftest``: ``tests/integration/
conftest.py`` is registered under the same module name, so a bare
``import conftest`` resolves to whichever pytest loaded first.

This module holds NO state beyond the compiled path sets - it creates no
temporary directories and touches nothing on disk. Everything here is pure
string/path reasoning over values supplied by the caller.
"""
import os
from pathlib import Path

#: Deployed locations refused even when .env is missing or unreadable.
#:
#: Phase 3.4 derived the protected set only from .env. With no .env the set came
#: back empty, ``is_production_path("D:/Flicks")`` was False, and
#: ``_point_app_at_temp()`` (which only forces MEDIA_ROOT when the current value is
#: already production) left a production media root in place. ``app/config.py``
#: defaults MEDIA_ROOT to ``D:/Flicks`` on Windows, so that is exactly the value
#: that would leak. These are a conservative floor, UNIONed with .env - never
#: replaced by it.
KNOWN_PRODUCTION_DEFAULTS = (
    "D:/Flicks",
    "D:/Flicks/.archive",
    "D:/Flicks/.uploads",
    "E:/MediaServer/cache",
    "E:/MediaServer/media.db",
)

_ENV_PATH_KEYS = frozenset(
    {
        "MEDIA_SERVER_MEDIA_ROOT",
        "MEDIA_SERVER_DATABASE",
        "MEDIA_SERVER_UPLOAD_TARGET_DIR",
        "MEDIA_SERVER_UPLOAD_TMP",
        "MEDIA_SERVER_ARCHIVE_DIR",
        "MEDIA_SERVER_DELETED_DIR",
    }
)


def norm(path):
    """Case-insensitive, fully-resolved key for comparing Windows paths."""
    try:
        return os.path.normcase(os.path.realpath(str(path)))
    except (OSError, ValueError):
        return os.path.normcase(str(path)).lower()


def production_paths_from_env_text(raw, repo_root):
    """Extract deployed paths from ``.env`` text. Read-only; may return nothing."""
    found = set()
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().upper()
        value = value.strip().strip('"').strip("'")
        if not value:
            continue
        if key in _ENV_PATH_KEYS:
            try:
                found.add(Path(value).resolve())
            except (OSError, ValueError):
                continue
    return found


def production_paths_from_env_file(repo_root):
    """Read deployed paths from ``<repo_root>/.env``. Missing/unreadable -> empty."""
    try:
        raw = Path(repo_root).joinpath(".env").read_text(encoding="utf-8")
    except OSError:
        return set()
    return production_paths_from_env_text(raw, repo_root)


def build_production_paths(repo_root, extra=()):
    """Union of the hardcoded floor, the .env values, and *extra* checkout paths."""
    paths = set()
    for raw in KNOWN_PRODUCTION_DEFAULTS:
        try:
            paths.add(Path(raw).resolve())
        except (OSError, ValueError):
            paths.add(Path(raw))
    paths |= production_paths_from_env_file(repo_root)
    for raw in extra:
        try:
            paths.add(Path(raw).resolve())
        except (OSError, ValueError):
            paths.add(Path(raw))
    return paths


def is_production_path(path, production_paths):
    """True when *path* is, or lives inside, a deployed location.

    Comparison is case-insensitive and fully resolved, so ``..`` traversal,
    alternate separators and symlink/junction targets are all handled.
    Descendant matching is separator-anchored, so a sibling such as
    ``D:/FlicksBackup`` is NOT treated as living inside ``D:/Flicks``.
    """
    if path is None:
        return False
    try:
        candidate = Path(str(path)).resolve()
    except (OSError, ValueError):
        candidate = Path(str(path))
    key = norm(candidate)
    production_keys = {norm(p) for p in production_paths}
    if key in production_keys:
        return True
    for production in production_paths:
        prefix = norm(production).rstrip("\\/") + os.sep
        if key.startswith(prefix):
            return True
    return False