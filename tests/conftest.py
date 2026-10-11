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

import pytest

_REPO = Path(__file__).resolve().parent.parent
_LIVE_CACHE = (_REPO / "cache").resolve()
_LIVE_DB = (_REPO / "media.db").resolve()


import contextlib
import sys

import _isolation_paths as _ip
import _write_guard

#: Deployed locations that must be refused EVEN IF .env is missing or unreadable.
#:
#: Phase 3.4 derived the protected set only from .env, so on a fresh clone / CI box
#: with no .env the set came back EMPTY: ``is_production_path("D:/Flicks")`` was
#: False, ``_point_app_at_temp()`` therefore declined to force MEDIA_ROOT (it only
#: forces when the current value is production), and the original leak returned.
#: ``app/config.py`` defaults MEDIA_ROOT to ``D:/Flicks`` on Windows, which is
#: exactly the value that would leak. These defaults are a conservative floor that
#: is UNIONed with whatever .env declares - never replaced by it.
_KNOWN_PRODUCTION_DEFAULTS = (
    "D:/Flicks",
    "D:/Flicks/.archive",
    "D:/Flicks/.uploads",
    str(_REPO / "cache"),
    str(_REPO / "media.db"),
)


def _build_production_paths():
    """Union of the hardcoded production floor, the .env values, and this checkout."""
    paths = set()
    for raw in _KNOWN_PRODUCTION_DEFAULTS:
        try:
            paths.add(Path(raw).resolve())
        except (OSError, ValueError):
            paths.add(Path(raw))
    paths |= _production_paths_from_env_file()
    paths |= {_LIVE_CACHE, _LIVE_DB}
    return paths


def _production_paths_from_env_file():
    """Read the DEPLOYED paths out of ``.env`` (keys only) so tests can refuse them.

    This is the third leak: the database was redirected but the *media root* was
    left pointing at the real library. ``app/routes/api.py::upload()`` writes
    straight to ``config.MEDIA_ROOT`` (it ignores ``UPLOAD_TARGET_DIR``), so any
    test that posts to ``/api/upload`` created a real file in ``D:\\Flicks`` and a
    real row in the live database. The deployed values are recorded here purely so
    the guards below can refuse them; nothing is ever written to them.
    """
    found = set()
    env_file = _REPO / ".env"
    try:
        raw = env_file.read_text(encoding="utf-8")
    except OSError:
        return found
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().upper()
        value = value.strip().strip('"').strip("'")
        if not value:
            continue
        if key in {
            "MEDIA_SERVER_MEDIA_ROOT",
            "MEDIA_SERVER_DATABASE",
            "MEDIA_SERVER_UPLOAD_TARGET_DIR",
            "MEDIA_SERVER_UPLOAD_TMP",
            "MEDIA_SERVER_ARCHIVE_DIR",
            "MEDIA_SERVER_DELETED_DIR",
        }:
            try:
                found.add(Path(value).resolve())
            except (OSError, ValueError):
                continue
    return found


#: Every deployed location the suite must never read from or write to.
_PRODUCTION_PATHS = _ip.build_production_paths(_REPO, extra=(_LIVE_CACHE, _LIVE_DB))


def _norm(path):
    """Case-insensitive, fully-resolved key for comparing Windows paths."""
    try:
        return os.path.normcase(os.path.realpath(str(path)))
    except (OSError, ValueError):
        return os.path.normcase(str(path)).lower()


_PRODUCTION_KEYS = {_norm(p) for p in _PRODUCTION_PATHS}


def is_production_path(path):
    """True when *path* is, or lives inside, a deployed/production location.

    Delegates to ``_isolation_paths`` so this module and ``tests/test_app.py``
    share one implementation (the latter cannot import ``conftest`` because
    ``tests/integration/conftest.py`` claims the same module name).
    """
    return _ip.is_production_path(path, _PRODUCTION_PATHS)


# One throwaway tree for everything the suite is allowed to touch.
_BASE = Path(tempfile.mkdtemp(prefix="mediaserver_tests_")).resolve()
_CACHE = _BASE / "cache"
_DB = _BASE / "media.db"
_MEDIA = _BASE / "media"
_UPLOADS = _BASE / "uploads"
_UPLOADS_TMP = _BASE / "uploads_tmp"
_ARCHIVE = _BASE / "archive"
_DELETED = _BASE / "deleted"
_UPDATES = _BASE / "updates"

# Environment first: config computes these at import, and recomputes them on reload.
# MEDIA_ROOT matters as much as the database: /api/upload writes to it directly.
os.environ["MEDIA_SERVER_MEDIA_ROOT"] = str(_MEDIA)
os.environ["MEDIA_SERVER_DATABASE"] = str(_DB)
os.environ["MEDIA_SERVER_UPLOAD_TARGET_DIR"] = str(_UPLOADS)
os.environ["MEDIA_SERVER_UPLOAD_TMP"] = str(_UPLOADS_TMP)

# The isolation values this suite depends on. ``scanner.py`` calls
# ``load_dotenv(ENV_FILE, override=True)`` at import time, so merely importing it
# (which several tests do) rewrites MEDIA_SERVER_MEDIA_ROOT / MEDIA_SERVER_DATABASE
# back to the deployed values from .env. Anything that then reads
# ``config.MEDIA_ROOT`` - notably app/routes/api.py::upload(), which writes there
# directly - operated on D:\Flicks and the live database. _restore_isolation_env()
# below repairs that before every test.
_ISOLATION_ENV = {
    "MEDIA_SERVER_MEDIA_ROOT": str(_MEDIA),
    "MEDIA_SERVER_DATABASE": str(_DB),
    "MEDIA_SERVER_UPLOAD_TARGET_DIR": str(_UPLOADS),
    "MEDIA_SERVER_UPLOAD_TMP": str(_UPLOADS_TMP),
    "MEDIA_SERVER_ARCHIVE_DIR": str(_ARCHIVE),
    "MEDIA_SERVER_DELETED_DIR": str(_DELETED),
}


_ISOLATION_FALLBACK = {}


def _is_run_owned(path):
    """True when *path* lives inside this run's own throwaway tree.

    Deliberately narrower than "somewhere under the system temp": a module's own
    TemporaryDirectory is reused only while it still exists (checked separately),
    and a path that has been cleaned up falls through to a fresh run-owned
    directory instead of being silently recreated by the application.
    """
    try:
        resolved = Path(str(path)).resolve()
        resolved.relative_to(_BASE)
        return True
    except (ValueError, OSError):
        return False


def _valid_fallback(key, isolated):
    """Return a safe restore target for *key*, or None if none can be established.

    Phase 3.5: the remembered fallback could point at a temporary directory that a
    test module had already cleaned up. Restoring it would hand the application a
    non-existent path, and ``app/routes/api.py::upload()`` calls
    ``config.MEDIA_ROOT.mkdir(parents=True, exist_ok=True)`` - silently recreating a
    tree nobody owned. A remembered value is therefore only reused when it is
    still a valid, existing, non-production path.
    """
    remembered = _ISOLATION_FALLBACK.get(key)
    if remembered:
        try:
            candidate = Path(remembered).resolve()
            if is_production_path(candidate):
                pass  # never fall back to a deployed path
            elif candidate.exists():
                return str(candidate)
            elif _is_run_owned(candidate):
                # Inside this run's own tree: safe even before it is created.
                return str(candidate)
        except (OSError, ValueError):
            pass
    # Fresh isolated directory owned by this run; never reuse a stale one.
    fresh = _BASE / f"restored_{key.lower()}"
    fresh.mkdir(parents=True, exist_ok=True)
    _ISOLATION_FALLBACK[key] = str(fresh)
    return str(fresh)


def _restore_isolation_env():
    """Put back any isolation variable that was clobbered with a deployed value.

    Only values that are missing or that resolve to a deployed location are
    replaced, so a test module that deliberately points one at its own temporary
    directory (tests/test_app.py uses its own TMP tree) keeps doing so. The last
    valid non-production value seen for a variable is remembered and used as the
    restore target, which is what keeps those deliberate overrides alive across the
    scanner import.
    """
    restored = []
    for key, isolated in _ISOLATION_ENV.items():
        current = os.environ.get(key)
        if current is None or is_production_path(current):
            os.environ[key] = _valid_fallback(key, isolated)
            restored.append(key)
        else:
            _ISOLATION_FALLBACK[key] = current
    return restored
os.environ["MEDIA_SERVER_UPLOAD_TMP"] = str(_UPLOADS_TMP)
os.environ["MEDIA_SERVER_ARCHIVE_DIR"] = str(_ARCHIVE)
os.environ["MEDIA_SERVER_DELETED_DIR"] = str(_DELETED)
os.environ["MEDIA_SERVER_UPDATES_DIR"] = str(_UPDATES)

for _sub in (
    "media",
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
    # MEDIA_ROOT is only forced when it points at a deployed location. Test modules
    # setUpClass with their own temporary root (tests/test_seek_preview.py does),
    # and clobbering that would make safe_path() reject their fixtures. Repairing
    # only production values keeps those overrides intact while still guaranteeing
    # a test can never operate on the real library.
    current_media = getattr(app_config, "MEDIA_ROOT", None)
    if current_media is None or is_production_path(current_media):
        mapping["MEDIA_ROOT"] = Path(
            os.environ.get("MEDIA_SERVER_MEDIA_ROOT") or str(_MEDIA)
        ).resolve()
    for name, value in mapping.items():
        setattr(app_config, name, value)
        if hasattr(app, name):
            setattr(app, name, value)


_ORIG_RMTREE = shutil.rmtree
_ORIG_UNLINK = os.unlink
_ORIG_REMOVE = os.remove
_ORIG_PATH_UNLINK = Path.unlink
_ORIG_PATH_RMDIR = Path.rmdir


def assert_isolated_path(path, *, action="write"):
    """Refuse a filesystem target that is not provably isolated. Fail closed.

    MEDIUM-1 (Phase 3.5): deletion was guarded but writes were not - the original
    leak used ``open(part_path, 'wb')`` and ``Path.replace()``, neither of which any
    guard patched. Rather than monkeypatching ``builtins.open`` (broad and
    fragile), test-owned helpers and fixtures call this immediately before they
    touch the filesystem. It raises BEFORE any mutation happens.
    """
    if path is None:
        raise _violation(action, "<none>")
    if is_production_path(path):
        raise _violation(action, Path(str(path)).resolve())
    resolved = Path(str(path)).resolve()
    try:
        resolved.relative_to(_BASE)
    except ValueError:
        raise _violation(
            f"{action} outside the throwaway test tree", resolved
        ) from None
    return resolved


def _effective_config_paths():
    """The writable paths the application will actually use right now."""
    from app import config as app_config

    return {
        name: getattr(app_config, name, None)
        for name in (
            "MEDIA_ROOT", "DATABASE", "UPLOAD_TARGET_DIR",
            "UPLOAD_TMP", "ARCHIVE_DIR", "DELETED_DIR",
        )
    }


def _violation(kind, target):
    message = f"TEST ISOLATION VIOLATION: refused {kind} on live path {target!r}"
    try:
        with open(_VIOLATIONS, "a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    except OSError:
        pass
    return RuntimeError(message)


def _is_live(path):
    """True for the live cache tree and for ANY deployed/production location."""
    if is_production_path(path):
        return True
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


# Phase 3.6/3.7: pre-write enforcement. Installed from pytest_sessionstart and
# removed in pytest_unconfigure below, so the guard exists only for the lifetime of
# a test session. It validates the resolved destination of write-capable opens,
# directory creation, os.replace/rename, shutil move/copy and sqlite3.connect
# BEFORE the operation happens.
#
# Installing from a hook rather than at import matters: ``tests/conftest.py`` is
# also importable as a plain module (Phase 3.5 notes ``tests/integration/conftest.py``
# registers under the same name), and an import-time install would patch global
# filesystem primitives in that interpreter with no pytest_unconfigure to undo it.


def pytest_sessionstart(session):
    """Install the pre-write guard at the start of a real pytest session."""
    _write_guard.install()


def pytest_unconfigure(config):
    """Restore the patched filesystem primitives when the session ends.

    Scoping matters: a wrapper left installed after the run would affect any later
    code sharing this interpreter state, so removal is unconditional and also runs
    when the session fails part-way.
    """
    try:
        _write_guard.uninstall()
    except Exception as e:  # never let cleanup mask a test result
        print(f"WARNING: write guard uninstall failed: {e}", file=sys.stderr)


@contextlib.contextmanager
def temporary_production_paths(*paths):
    """Treat *paths* as deployed for the duration of a test.

    Lets a guard test use a REAL sentinel file inside a temporary directory and
    prove the guard refuses before mutating it, without ever pointing a
    destructive operation at an actual production path.
    """
    added = []
    for raw in paths:
        resolved = Path(raw).resolve()
        _PRODUCTION_PATHS.add(resolved)
        added.append(resolved)
    try:
        yield
    finally:
        for resolved in added:
            _PRODUCTION_PATHS.discard(resolved)


@pytest.fixture
def isolation_guard():
    """The isolation guard, exposed as a fixture.

    Tests must NOT ``import conftest``: ``tests/integration/conftest.py`` is
    imported under the same module name, so ``import conftest`` resolves to
    whichever was registered first. Fixtures are resolved by directory, so this is
    unambiguous.
    """
    return {
        "is_production_path": is_production_path,
        "restore_isolation_env": _restore_isolation_env,
        "point_app_at_temp": _point_app_at_temp,
        "assert_isolated_path": assert_isolated_path,
        "effective_config_paths": _effective_config_paths,
        "production_paths": _PRODUCTION_PATHS,
        "is_live": _is_live,
        "violation": _violation,
        "guarded_rmtree": _guarded_rmtree,
        "guarded_os_remove": _guarded_os_remove,
        "guarded_path_unlink": _guarded_path_unlink,
        "guarded_path_rmdir": _guarded_path_rmdir,
        "temporary_production_paths": temporary_production_paths,
        "base": _BASE,
        "fallback": _ISOLATION_FALLBACK,
        "isolation_env": _ISOLATION_ENV,
        "live_cache": _LIVE_CACHE,
        "live_db": _LIVE_DB,
        "media": _MEDIA,
        "db": _DB,
        "build_production_paths": _ip.build_production_paths,
    }


def pytest_runtest_setup(item):
    """Re-point the app at the throwaway tree and fail loudly if that did not take effect.

    Running before every test is what makes the isolation robust: no import-order accident or
    `importlib.reload(app.config)` in another module can leave a live path active for a test.
    """
    from app import config as app_config
    from app.services.transcode_service import get_cache_dir

    # Repair any isolation variable clobbered by scanner.py's load_dotenv(override=True).
    # _point_app_at_temp() then re-applies the values onto the already-imported config
    # module, which is how the suite has always redirected paths (no reload needed).
    _restore_isolation_env()

    _point_app_at_temp()

    resolved_cache = Path(str(get_cache_dir())).resolve()
    if resolved_cache == _LIVE_CACHE or _LIVE_CACHE in resolved_cache.parents:
        raise _violation("cache directory resolution", resolved_cache)

    resolved_db = Path(str(app_config.DATABASE)).resolve()
    if resolved_db == _LIVE_DB:
        raise _violation("database resolution", resolved_db)

    # The media root was the third leak: /api/upload writes to it directly, so a
    # test that posts an upload created a real file in the deployed library and a
    # real row in the live database. Refuse any deployed location here.
    for attr in ("MEDIA_ROOT", "DATABASE", "UPLOAD_TARGET_DIR", "UPLOAD_TMP",
                 "ARCHIVE_DIR", "DELETED_DIR"):
        value = getattr(app_config, attr, None)
        if value is None:
            continue
        resolved = Path(str(value)).resolve()
        if is_production_path(resolved):
            raise _violation(
                f"config.{attr} resolution (points at a deployed location)",
                resolved,
            )


def pytest_runtest_teardown(item, nextitem):
    """Re-check isolation AFTER the test ran, before teardown fixtures can act.

    MEDIUM-1 (Phase 3.5): ``pytest_runtest_setup`` only proves the paths were
    isolated on entry. Something inside a test - a config reload, a direct
    ``app.config.MEDIA_ROOT = ...`` assignment, or the import-time
    ``load_dotenv(override=True)`` in scanner.py - can repoint them mid-test. This
    hook detects that drift and fails closed. It is DETECTION, not prevention: it
    runs after any write the test already performed. Test helpers that write should
    still call ``assert_isolated_path()`` first, which refuses before mutating.
    """
    for attr, value in _effective_config_paths().items():
        if value is None:
            continue
        resolved = Path(str(value)).resolve()
        if is_production_path(resolved):
            raise _violation(
                f"config.{attr} drifted to a deployed location during "
                f"{getattr(item, 'nodeid', 'the test')}",
                resolved,
            )