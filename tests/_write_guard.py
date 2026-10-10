"""Test-only pre-write guard: refuse writes to deployed paths BEFORE they happen.

Phase 3.5 could only DETECT a redirected path after the fact (``pytest_runtest_teardown``)
or ask test helpers to remember to call ``assert_isolated_path()``. A test that
repointed ``config.MEDIA_ROOT`` at ``D:\\Flicks`` and then wrote could therefore
still mutate production before anything noticed.

This module closes that gap by wrapping the filesystem primitives the application
actually uses, validating the resolved destination immediately before the
operation, and only then delegating to the original callable.

SCOPE AND SAFETY
----------------
* Installed by ``tests/conftest.py`` for the pytest session only, and removed in
  ``pytest_unconfigure``. Nothing here is imported by application code, so
  production runtime is untouched.
* READ operations are never intercepted - only write-capable modes and
  destructive/moving operations. Third-party readers (Werkzeug, Jinja, PIL,
  subprocess plumbing) are unaffected. The same holds for ``os.open``: only a flag
  set containing a write bit (or ``O_CREAT``/``O_TRUNC``/``O_APPEND``) is checked.
* Directory creation is covered through ``os.mkdir`` alone, which is the
  primitive ``os.makedirs`` and ``Path.mkdir`` both resolve at call time, and
  through ``os.open`` for ``Path.touch`` and ``tempfile``.
* Every wrapper preserves the original callable's signature and return value, and
  delegates unchanged once validation passes.
* A refused operation raises BEFORE the destination is created, truncated, moved
  or deleted. Nothing is silently redirected.
* ``sqlite3.connect`` is wrapped so a test cannot open or create the live
  database. PostgreSQL integration tests use a network connection and are
  unaffected.
"""
import builtins
import io
import os
import shutil
import sqlite3
import sys

import _isolation_paths as _ip

#: Modes that create, truncate, append to, or otherwise mutate a file.
_WRITE_MODES = frozenset("wax+")

#: ``os.open`` flag bits that request write access. ``O_RDONLY`` is 0, so a plain
#: read never matches - the same read-only guarantee :func:`_mode_is_write` gives
#: for ``open()``. ``Path.touch`` reaches ``os.open`` as
#: ``O_CREAT|O_WRONLY`` (plus ``O_EXCL`` when ``exist_ok=False``), and
#: ``tempfile`` reaches it through ``_os.open``, so covering this one primitive
#: covers file creation without wrapping ``Path.touch`` itself.
_WRITE_OFLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

_installed = False
_orig = {}
#: (module, attribute, original, wrapper) for every attribute this guard replaced.
_patched = []
#: Attribute names another plugin replaced after us; see uninstall().
_conflicts = []


def _production_paths():
    """The active deployed-path set, taken from conftest when available."""
    conftest = sys.modules.get("conftest")
    paths = getattr(conftest, "_PRODUCTION_PATHS", None)
    if paths:
        return paths
    return _ip.build_production_paths(_ip.Path(__file__).resolve().parent.parent)


def _is_production(path):
    try:
        return _ip.is_production_path(path, _production_paths())
    except Exception:
        return False


def _check(path, action):
    """Raise before a write if *path* resolves to a deployed location."""
    if path is None:
        return path
    if _is_production(path):
        raise RuntimeError(
            f"TEST ISOLATION VIOLATION: refused {action} on deployed path "
            f"{_ip.Path(str(path)).resolve()}. The file was not created, "
            "modified, moved or deleted."
        )
    return path


def _check_both(source, destination, action):
    _check(source, f"{action} source")
    _check(destination, f"{action} destination")


def _mode_is_write(mode):
    if isinstance(mode, int):
        return False  # raw fd: not a path we can resolve
    if not mode:
        return False
    return any(ch in _WRITE_MODES for ch in str(mode))


# --------------------------------------------------------------------------- #
# Wrappers
# --------------------------------------------------------------------------- #

def _guarded_open(file, mode="r", *args, **kwargs):
    if _mode_is_write(mode):
        _check(file, f"open({mode!r})")
    return _orig["open"](file, mode, *args, **kwargs)


def _guarded_io_open(file, mode="r", *args, **kwargs):
    if _mode_is_write(mode):
        _check(file, f"io.open({mode!r})")
    return _orig["io_open"](file, mode, *args, **kwargs)


def _guarded_os_replace(src, dst, *args, **kwargs):
    _check_both(src, dst, "os.replace")
    return _orig["os_replace"](src, dst, *args, **kwargs)


def _guarded_os_rename(src, dst, *args, **kwargs):
    _check_both(src, dst, "os.rename")
    return _orig["os_rename"](src, dst, *args, **kwargs)


def _guarded_os_removedirs(name, *args, **kwargs):
    _check(name, "os.removedirs")
    return _orig["os_removedirs"](name, *args, **kwargs)


def _guarded_move(src, dst, *args, **kwargs):
    _check_both(src, dst, "shutil.move")
    return _orig["shutil_move"](src, dst, *args, **kwargs)


def _guarded_copy(src, dst, *args, **kwargs):
    _check_both(src, dst, "shutil.copy")
    return _orig["shutil_copy"](src, dst, *args, **kwargs)


def _guarded_copy2(src, dst, *args, **kwargs):
    _check_both(src, dst, "shutil.copy2")
    return _orig["shutil_copy2"](src, dst, *args, **kwargs)


def _guarded_copyfile(src, dst, *args, **kwargs):
    _check_both(src, dst, "shutil.copyfile")
    return _orig["shutil_copyfile"](src, dst, *args, **kwargs)


def _guarded_copytree(src, dst, *args, **kwargs):
    _check_both(src, dst, "shutil.copytree")
    return _orig["shutil_copytree"](src, dst, *args, **kwargs)


def _guarded_sqlite_connect(database, *args, **kwargs):
    """Refuse opening/creating the deployed SQLite database.

    Covers the plain-path form (``sqlite3.connect(config.DATABASE)``) and the URI
    form the app/tests use (``sqlite3.connect("file:...?mode=ro", uri=True)``).
    The isolated temporary database is untouched.
    """
    target = database
    if isinstance(database, (str, bytes, os.PathLike)):
        text = os.fsdecode(database)
        if text.startswith("file:"):
            try:
                target = text.split("?", 1)[0][len("file:"):]
            except Exception:
                target = text
    _check(target, "sqlite3.connect")
    return _orig["sqlite_connect"](database, *args, **kwargs)


def _guarded_os_mkdir(path, *args, **kwargs):
    """Refuse directory creation at, or inside, a deployed location.

    This single wrapper covers all three directory APIs the application uses,
    because each resolves ``os.mkdir`` as a module attribute at call time:
    ``os.mkdir`` directly, ``os.makedirs`` (whose recursion ends in a global
    ``mkdir`` lookup, so every intermediate parent is validated too), and
    ``Path.mkdir`` (``os.mkdir(self, mode)``). Wrapping them separately would be
    redundant.
    """
    _check(path, "os.mkdir")
    return _orig["os_mkdir"](path, *args, **kwargs)


def _guarded_os_open(path, flags, *args, **kwargs):
    """Refuse file creation/truncation via ``os.open``.

    ``Path.touch`` is implemented as ``os.open(self, O_CREAT|O_WRONLY[, O_EXCL])``
    followed by ``os.close``, so wrapping the primitive covers ``touch`` without
    patching the method. Reads (any flag set without a write bit, including plain
    ``O_RDONLY`` which is 0) pass straight through, which keeps importlib, zipfile
    and the standard library's readers unaffected.
    """
    if isinstance(path, int):
        # Already-open descriptor: no path to resolve, nothing to validate.
        return _orig["os_open"](path, flags, *args, **kwargs)
    try:
        writes = bool(int(flags) & _WRITE_OFLAGS)
    except (TypeError, ValueError):
        writes = False
    if writes:
        _check(path, f"os.open(flags={flags!r})")
    return _orig["os_open"](path, flags, *args, **kwargs)


# --------------------------------------------------------------------------- #
# Install / uninstall
# --------------------------------------------------------------------------- #

#: (saved-original key, module, attribute name, wrapper).
#:
#: The key and the attribute name are kept separate on purpose: several patched
#: attributes share a short name across modules (``builtins.open`` and ``io.open``,
#: ``os.open``), and the saved originals are addressed by key from inside the
#: wrappers. Conflating the two made install() fail on ``io.io_open``, which the
#: transactional rollback reported immediately.
_PATCHES = (
    ("open", builtins, "open", _guarded_open),
    ("io_open", io, "open", _guarded_io_open),
    ("os_replace", os, "replace", _guarded_os_replace),
    ("os_rename", os, "rename", _guarded_os_rename),
    ("os_removedirs", os, "removedirs", _guarded_os_removedirs),
    ("os_open", os, "open", _guarded_os_open),
    ("os_mkdir", os, "mkdir", _guarded_os_mkdir),
    ("shutil_move", shutil, "move", _guarded_move),
    ("shutil_copy", shutil, "copy", _guarded_copy),
    ("shutil_copy2", shutil, "copy2", _guarded_copy2),
    ("shutil_copyfile", shutil, "copyfile", _guarded_copyfile),
    ("shutil_copytree", shutil, "copytree", _guarded_copytree),
    ("sqlite_connect", sqlite3, "connect", _guarded_sqlite_connect),
)


def is_installed():
    return _installed


def conflicts():
    """Attribute names left wrapped because another plugin replaced them.

    Populated by the most recent :func:`uninstall`. Non-empty means some wrapper
    chain could not be safely unwound: see :func:`uninstall` for the limitation.
    """
    return tuple(_conflicts)


def install():
    """Install every wrapper transactionally. Idempotent; never double-wraps.

    A patch that raises part-way through is rolled back: every attribute this
    attempt already replaced is restored, in reverse order, and the original
    exception propagates unchanged. After a rollback the module state matches the
    process state exactly - ``_installed`` is False and ``_orig`` is empty - so a
    later :func:`uninstall` is a safe no-op and a later :func:`install` starts
    from the true originals rather than from a half-applied guard.
    """
    global _installed
    if _installed:
        return False

    _orig.clear()
    _patched.clear()
    _conflicts.clear()
    try:
        for key, module, attr, wrapper in _PATCHES:
            original = getattr(module, attr)
            _orig[key] = original
            setattr(module, attr, wrapper)
            # Recorded only after a successful assignment, so the rollback list
            # can never claim an attribute that was not actually replaced.
            _patched.append((module, attr, original, wrapper))
    except BaseException:
        for module, key, original, _wrapper in reversed(_patched):
            setattr(module, key, original)
        _patched.clear()
        _orig.clear()
        _installed = False
        raise
    _installed = True
    return True


def uninstall():
    """Restore the patched primitives. Safe to call when not installed.

    Restoration is *cooperative*: an attribute is only rewritten when it still
    holds this guard's own wrapper. If another plugin layered a further wrapper
    on top of ours after installation, overwriting it would silently delete that
    plugin's patch, so the attribute is left alone and recorded in
    :func:`conflicts` instead.

    Limitation: because the intervening wrapper is not ours, the chain cannot be
    unwound to the true original - whoever installed last is responsible for its
    own teardown. In practice a session ends here, so this path is defensive
    rather than routine.
    """
    global _installed
    if not _installed:
        return False

    for module, key, original, wrapper in reversed(_patched):
        current = getattr(module, key, None)
        if current is wrapper:
            setattr(module, key, original)
        else:
            _conflicts.append(key)

    _patched.clear()
    _orig.clear()
    _installed = False
    if _conflicts:
        print(
            "WARNING: write guard left these attributes wrapped by another "
            f"plugin and did not overwrite them: {', '.join(sorted(_conflicts))}",
            file=sys.stderr,
        )
    return True