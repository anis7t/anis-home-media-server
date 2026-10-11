"""Disposable-tree helpers for the cache-safety boundary tests.

Stage A scope only.

Two properties this module exists to guarantee:

1. **No application import at module scope.** Importing this file must not pull
   in ``app``, must not rebind a single application attribute, and must not
   touch the filesystem. ``point_app_at`` therefore imports ``app`` lazily
   inside the function body, after its own validation has already passed.
   Importing this module constructs function objects and nothing else.

2. **No path is ever created, rebound or removed without proof first.** Every
   root handed back by :func:`dedicated_cache_root` is recorded, and every
   validator re-derives containment from that record rather than from a caller
   assertion. A failed validation raises; it never degrades into "delete it
   anyway".

No deployed location is named anywhere in this file - not even as a comparison
constant. Containment is established structurally instead: a disposable root
must sit strictly beneath the system temp directory, must have been created by
:func:`dedicated_cache_root`, and must not overlap the previous root. That is
strictly stronger than comparing against a hardcoded list of production paths,
and it means this module has no reason to reference one.

Nothing here is imported by application code, and nothing here runs at import
time beyond defining the functions and the two module-level constants.
"""

import contextlib
import os
import shutil
import tempfile
from pathlib import Path

#: Roots created by dedicated_cache_root() in this process, as lexical keys.
#: Membership is the sole authority for what remove_tree() will touch.
_OWNED_ROOTS = set()

#: Sentinel distinguishing "attribute was absent" from "attribute was None",
#: so point_app_at() can restore the module to its exact prior shape.
_MISSING = object()


def lexical(path):
    """Normalise *path* for comparison WITHOUT touching the filesystem.

    os.path.realpath() resolves links by stat'ing each component, and stat'ing
    is itself an access to the path being judged, so the primary comparison is
    purely lexical: abspath + normcase, no filesystem access at all.
    """
    return os.path.normcase(os.path.abspath(str(path)))


def within(path, root):
    """True when *path* is *root* or lies beneath it.

    Separator-anchored, so a sibling that merely shares the root's textual
    prefix (``.../cache_backup`` against ``.../cache``) is NOT inside it. A
    plain startswith() would wrongly accept that sibling.
    """
    key = lexical(path)
    base = lexical(root)
    return key == base or key.startswith(base + os.sep)


def _owning_root(path):
    """Return the recorded root that contains *path*, or None."""
    key = lexical(path)
    best = None
    for root in _OWNED_ROOTS:
        if key == root or key.startswith(root + os.sep):
            if best is None or len(root) > len(best):
                best = root
    return best


def dedicated_cache_root(tag="cache"):
    """Create and record a uniquely named disposable root; return its Path.

    The directory is created immediately by mkdtemp, so two tests never share a
    root even when they use the same tag. Nothing else is created inside it:
    callers build whatever fixtures they need, under a path they have proven.
    """
    safe = "".join(ch for ch in str(tag) if ch.isalnum() or ch in "-_") or "cache"
    root = Path(tempfile.mkdtemp(prefix=f"mscache_{safe}_"))
    _OWNED_ROOTS.add(lexical(root))
    return root


def assert_dedicated_cache_root(target, previous=None):
    """Prove *target* is a fresh disposable root, or raise AssertionError.

    Called BEFORE anything is rebound or created, so a failure leaves the
    process exactly as it found it and no purge-capable call has been made.
    Three checks, in order:

    * strictly beneath the system temp directory (equal to temp is not enough);
    * actually created by dedicated_cache_root() - a caller-supplied path that
      merely looks temporary is refused, which is what makes remove_tree()
      unable to delete an arbitrary path;
    * not overlapping *previous*, the cache root the application is using now,
      in either direction.

    Returns the lexical key on success so callers can log or compare it.
    """
    key = lexical(target)
    temp = lexical(tempfile.gettempdir())
    if key == temp or not key.startswith(temp + os.sep):
        raise AssertionError(
            f"disposable root {key} is not strictly beneath the temp directory {temp}"
        )
    if key not in _OWNED_ROOTS:
        raise AssertionError(
            f"disposable root {key} was not created by dedicated_cache_root(); "
            "refusing to treat an arbitrary caller-supplied path as disposable"
        )
    if previous is not None:
        prev = lexical(previous)
        if key == prev or key.startswith(prev + os.sep) or prev.startswith(key + os.sep):
            raise AssertionError(
                f"disposable root {key} overlaps the previous/shared root {prev}"
            )
    return key


def owned_roots(deepest_first=False):
    """Recorded disposable roots, optionally deepest first for teardown."""
    roots = sorted(_OWNED_ROOTS, key=len, reverse=bool(deepest_first))
    return [Path(root) for root in roots]


def remove_tree(path):
    """Remove *path* - but only after proving it lies under a recorded root.

    Raises AssertionError for anything this module did not create, BEFORE any
    filesystem call, so a mistaken argument cannot delete a real directory.
    Idempotent: a path already gone is a no-op, which lets teardown run in a
    fixture without defensive noise.
    """
    key = lexical(path)
    root = _owning_root(path)
    if root is None:
        raise AssertionError(
            f"refusing to remove {key}: it does not lie beneath any root created "
            "by dedicated_cache_root()"
        )
    if not os.path.exists(key):
        if key in _OWNED_ROOTS:
            _OWNED_ROOTS.discard(key)
        return
    if os.path.isdir(key) and not os.path.islink(key):
        shutil.rmtree(key)
    else:
        os.remove(key)
    if key == root:
        _OWNED_ROOTS.discard(key)


@contextlib.contextmanager
def point_app_at(root, previous=None):
    """Rebind app.CACHE_DIR and config.CACHE_DIR to *root*, restoring exactly.

    Both names are rebound because approved_cache_root() refuses when they
    disagree, and a boundary test that set only one would be testing a refusal
    it had manufactured itself.

    The previous values are captured on entry from the live modules and put
    back in ``finally``, including the case where the attribute was absent
    before (then it is deleted again rather than set to None).

    No application function is called here: this rebinds two path attributes
    and nothing else. The import is deliberately inside the body so that
    importing this module stays inert.
    """
    assert_dedicated_cache_root(root, previous)

    import app
    from app import config as app_config

    prev_app = getattr(app, "CACHE_DIR", _MISSING)
    prev_cfg = getattr(app_config, "CACHE_DIR", _MISSING)
    target = Path(root)
    try:
        app.CACHE_DIR = target
        app_config.CACHE_DIR = target
        yield target
    finally:
        if prev_app is _MISSING:
            if hasattr(app, "CACHE_DIR"):
                delattr(app, "CACHE_DIR")
        else:
            app.CACHE_DIR = prev_app
        if prev_cfg is _MISSING:
            if hasattr(app_config, "CACHE_DIR"):
                delattr(app_config, "CACHE_DIR")
        else:
            app_config.CACHE_DIR = prev_cfg