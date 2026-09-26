"""Pytest bootstrap: keep the test run out of the host's live application data.

WHY THIS FILE EXISTS
--------------------
The suite both wrote to and deleted from production data. Two independent leaks:

1. **Cache deletion.** Isolation was done by rebinding Python attributes at import time, which
   two other modules silently undo:
   * `tests/test_app.py::MediaServerTests.tearDownClass` calls `importlib.reload(app.config)`
     after restoring the environment, so `app.config.CACHE_DIR` becomes the live path again.
   * `tests/test_selenium_multi_seek_coyote.py` executes
     `app_module.CACHE_DIR = app_module.config.CACHE_DIR`, pointing the app back at the live
     cache and defeating `tests/test_storage_retention.py`'s import-time patch.
   The non-dry-run purge tests in `tests/test_storage_retention.py` then walked the *live*
   cache, treated every directory as orphaned (the active set comes from the test media root)
   and deleted real transcodes.

2. **Library and database pollution.** `app/config.py::_resolve_upload_dirs()` returns
   `MEDIA_ROOT` while pytest is running and no upload target is configured, and the rest of
   the suite shares the host's real `MEDIA_SERVER_DATABASE`. Upload fixtures therefore landed
   in the live library (a 23-byte `Mayday (2026).mkv`) and fixtures such as `Mock.mkv` were
   inserted straight into the production database.

HOW ISOLATION WORKS HERE
------------------------
Redirection happens through the **environment first**, before the app is imported, so an
`importlib.reload(app.config)` recomputes the same throwaway paths instead of restoring the
live ones. On top of that, `pytest_runtest_setup` re-asserts the cache and upload paths before
every test, and a guard on the removal primitives refuses any deletion inside the checkout's
`cache/` tree. The media root is deliberately left real: the page and library tests read real
media files, and the template/CSS constants that `app/__init__.py` reads from `BASE_DIR` must
resolve.
"""
import os
import shutil
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
_LIVE_CACHE = (_REPO / "cache").resolve()
_LIVE_DB = (_REPO / "media.db").resolve()

# One throwaway tree for everything the suite is allowed to touch.
_BASE = Path(tempfile.mkdtemp(prefix="mediaserver_tests_")).resolve()
_CACHE = _BASE / "cache"
_DB = _BASE / "media.db"
_UPLOADS = _BASE / "uploads"
_UPLOADS_TMP = _BASE / "uploads_tmp"
_ARCHIVE = _BASE / "archive"
_DELETED = _BASE / "deleted"
_UPDATES = _BASE / "updates"

# Environment first: config computes these at import, and recomputes them on reload.
os.environ["MEDIA_SERVER_DATABASE"] = str(_DB)
os.environ["MEDIA_SERVER_UPLOAD_TARGET_DIR"] = str(_UPLOADS)
os.environ["MEDIA_SERVER_UPLOAD_TMP"] = str(_UPLOADS_TMP)
os.environ["MEDIA_SERVER_ARCHIVE_DIR"] = str(_ARCHIVE)
os.environ["MEDIA_SERVER_DELETED_DIR"] = str(_DELETED)
os.environ["MEDIA_SERVER_UPDATES_DIR"] = str(_UPDATES)

for _sub in (
    "cache/hls",
    "cache/previews",
    "cache/posters",
    "cache/backdrops",
    "cache/subtitles/embedded",
    "cache/subtitles/online",
    "uploads",
    "uploads_tmp",
    "archive",
    "deleted",
    "updates",
    "updates/production",
    "updates/developer",
):
    (_BASE / _sub).mkdir(parents=True, exist_ok=True)

_VIOLATIONS = _BASE / "_violations.log"

# Cache paths are read dynamically (`config.POSTER_CACHE`, ...), so they can also be
# re-asserted per test, which is what makes this robust against module reloads.
_CACHE_ATTRS = {
    "CACHE_DIR": _CACHE,
    "POSTER_CACHE": _CACHE / "posters",
    "BACKDROP_CACHE": _CACHE / "backdrops",
    "SUBTITLE_CACHE": _CACHE / "subtitles",
    "SUBTITLE_EMBEDDED_CACHE": _CACHE / "subtitles" / "embedded",
    "SUBTITLE_ONLINE_CACHE": _CACHE / "subtitles" / "online",
    "UPDATES_DIR": _UPDATES,
}


def _point_app_at_temp():
    """Rebind every writable path the application resolves dynamically at call time."""
    import app
    from app import config as app_config

    mapping = dict(_CACHE_ATTRS)
    mapping.update(
        {
            "UPLOAD_TARGET_DIR": _UPLOADS,
            "UPLOAD_TMP": _UPLOADS_TMP,
            "DATABASE": _DB,
            "ARCHIVE_DIR": _ARCHIVE,
            "DELETED_DIR": _DELETED,
        }
    )
    for name, value in mapping.items():
        setattr(app_config, name, value)
        if hasattr(app, name):
            setattr(app, name, value)


_ORIG_RMTREE = shutil.rmtree
_ORIG_UNLINK = os.unlink
_ORIG_REMOVE = os.remove
_ORIG_PATH_UNLINK = Path.unlink
_ORIG_PATH_RMDIR = Path.rmdir


def _violation(kind, target):
    message = f"TEST ISOLATION VIOLATION: refused {kind} on live path {target!r}"
    try:
        with open(_VIOLATIONS, "a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    except OSError:
        pass
    return RuntimeError(message)


def _is_live(path):
    try:
        candidate = Path(path).resolve()
    except (OSError, ValueError):
        return False
    return candidate == _LIVE_CACHE or _LIVE_CACHE in candidate.parents


def _guarded_rmtree(path, *args, **kwargs):
    if _is_live(path):
        raise _violation("shutil.rmtree", path)
    return _ORIG_RMTREE(path, *args, **kwargs)


def _guarded_os_remove(path, *args, **kwargs):
    if _is_live(path):
        raise _violation("os.remove/os.unlink", path)
    return _ORIG_UNLINK(path, *args, **kwargs)


def _guarded_path_unlink(self, *args, **kwargs):
    if _is_live(self):
        raise _violation("Path.unlink", self)
    return _ORIG_PATH_UNLINK(self, *args, **kwargs)


def _guarded_path_rmdir(self, *args, **kwargs):
    if _is_live(self):
        raise _violation("Path.rmdir", self)
    return _ORIG_PATH_RMDIR(self, *args, **kwargs)


shutil.rmtree = _guarded_rmtree
os.unlink = _guarded_os_remove
os.remove = _guarded_os_remove
Path.unlink = _guarded_path_unlink
Path.rmdir = _guarded_path_rmdir


def pytest_runtest_setup(item):
    """Re-point the app at the throwaway tree and fail loudly if that did not take effect.

    Running before every test is what makes the isolation robust: no import-order accident or
    `importlib.reload(app.config)` in another module can leave a live path active for a test.
    """
    from app import config as app_config
    from app.services.transcode_service import get_cache_dir

    _point_app_at_temp()

    resolved_cache = Path(str(get_cache_dir())).resolve()
    if resolved_cache == _LIVE_CACHE or _LIVE_CACHE in resolved_cache.parents:
        raise _violation("cache directory resolution", resolved_cache)

    resolved_db = Path(str(app_config.DATABASE)).resolve()
    if resolved_db == _LIVE_DB:
        raise _violation("database resolution", resolved_db)