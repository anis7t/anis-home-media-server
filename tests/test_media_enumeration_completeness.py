"""Media enumeration completeness - the failure that deleted production transcodes.

The orphan-cache purge concluded that a whole cache was orphaned because the
enumeration that should have described the library was silently short. The cause
was not the cache path - it was that nothing could tell an incomplete
enumeration from a complete one:

* a configured root that did not exist was skipped without a word;
* ``pathlib.Path.rglob()`` swallows ``PermissionError``, so a root that existed
  and was a directory but contained an unreadable subdirectory produced a short
  list and raised nothing;
* two distinct files sharing a basename collapsed into one entry, leaving the
  loser's cache directory looking orphaned.

These tests drive the real enumerator against disposable temporary trees. The
only patch is a narrow stand-in for an unreadable directory, because making a
directory genuinely unreadable on Windows needs privileges the test host does
not have. Nothing here touches a deployed location: every path is created under
this test's own temporary root.
"""

import contextlib
import os
from pathlib import Path

import pytest

import _cache_test_support as _support


def _video(path, payload=b"synthetic media"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return path


@contextlib.contextmanager
def _unreadable(directory):
    """Make os.scandir fail for *directory* only, as an ACL denial would."""
    target = str(Path(directory).resolve())
    real_scandir = os.scandir

    def guarded(path):
        if os.path.normcase(os.path.abspath(str(path))) == os.path.normcase(target):
            raise PermissionError(13, "Permission denied", str(path))
        return real_scandir(path)

    os.scandir = guarded
    try:
        yield
    finally:
        os.scandir = real_scandir


@pytest.fixture(autouse=True)
def _isolated_enumeration():
    """Point the enumerator at this test's roots and keep it side-effect free."""
    import app
    from app import config as app_config
    from app.services import media_service, scanner_service

    previous_roots = getattr(app_config, "get_media_roots", None)
    previous_paths = media_service._paths
    previous_app_paths = getattr(app, "_paths", None)

    media_service._paths = (0, [])
    if hasattr(app, "_paths"):
        app._paths = (0, [])
    # A changed library would otherwise trigger a real scan of whatever MEDIA_ROOT
    # currently is. The scan trigger is not what these tests are about.
    with mock_patch_trigger():
        yield

    media_service._paths = previous_paths
    if previous_app_paths is not None and hasattr(app, "_paths"):
        app._paths = previous_app_paths
    if previous_roots is not None:
        app_config.get_media_roots = previous_roots


@contextlib.contextmanager
def mock_patch_trigger():
    """Silence the library-scan trigger for the duration of a test."""
    from app.services import scanner_service

    real = scanner_service.trigger_library_scan
    calls = []
    scanner_service.trigger_library_scan = lambda *a, **k: calls.append(1)
    try:
        yield calls
    finally:
        scanner_service.trigger_library_scan = real


def _point_roots(roots):
    """Return a context manager pinning config.get_media_roots() to *roots*."""
    from app import config as app_config

    @contextlib.contextmanager
    def _cm():
        real = app_config.get_media_roots
        app_config.get_media_roots = lambda: list(roots)
        try:
            yield
        finally:
            app_config.get_media_roots = real

    return _cm()


def _enumerate():
    from app.services.media_service import enumerate_media_with_status

    return enumerate_media_with_status()


# --------------------------------------------------------------------------- #
# The walk succeeds
# --------------------------------------------------------------------------- #


def test_complete_when_every_root_walks_cleanly():
    """Two readable roots, no errors: the enumeration is provably complete."""
    root_a = _support.dedicated_cache_root("enum_a")
    root_b = _support.dedicated_cache_root("enum_b")
    _video(root_a / "Alpha.2026.mkv")
    _video(root_a / "nested" / "Beta.2026.mkv")
    _video(root_b / "Gamma.2026.mkv")

    with _point_roots([root_a, root_b]):
        paths, status = _enumerate()

    names = {p.name for p in paths}
    assert {"Alpha.2026.mkv", "Beta.2026.mkv", "Gamma.2026.mkv"} <= names
    assert status["complete"] is True
    assert status["walk_errors"] == []
    assert status["deduped"] == []
    assert [r["ok"] for r in status["roots"]] == [True, True]
    assert [r["count"] for r in status["roots"]] == [2, 1]


def test_uploads_subtree_is_skipped_without_breaking_completeness():
    """.uploads staging content is filtered, and that filter is not a failure."""
    root = _support.dedicated_cache_root("enum_uploads")
    _video(root / "Real.2026.mkv")
    _video(root / ".uploads" / "staging" / "Partial.part.mkv")

    with _point_roots([root]):
        paths, status = _enumerate()

    assert [p.name for p in paths] == ["Real.2026.mkv"]
    assert status["complete"] is True
    assert status["skipped_uploads"] == 1


def test_symlinked_directory_is_not_followed_and_is_not_an_error():
    """Symlink handling matches the previous rglob walk exactly."""
    root = _support.dedicated_cache_root("enum_link_root")
    elsewhere = _support.dedicated_cache_root("enum_link_target")
    _video(root / "Top.2026.mkv")
    _video(elsewhere / "Hidden.2026.mkv")
    try:
        os.symlink(str(elsewhere), str(root / "link"), target_is_directory=True)
    except (OSError, NotImplementedError, AttributeError) as exc:
        pytest.skip(f"symlink creation unavailable on this platform: {exc}")

    with _point_roots([root]):
        paths, status = _enumerate()

    assert [p.name for p in paths] == ["Top.2026.mkv"]
    assert status["complete"] is True


# --------------------------------------------------------------------------- #
# The walk does not succeed - this is what the purge incident looked like
# --------------------------------------------------------------------------- #


def test_unreadable_subdirectory_marks_enumeration_incomplete():
    """THE FIX: a subdirectory that cannot be read is recorded, not swallowed.

    pathlib's rglob() returned a short list here and raised nothing, so the
    audit saw a complete-looking library and classified every cache directory it
    did not recognise as orphaned.
    """
    root = _support.dedicated_cache_root("enum_locked")
    _video(root / "Visible.2026.mkv")
    hidden = root / "locked"
    _video(hidden / "Invisible.2026.mkv")

    with _unreadable(hidden), _point_roots([root]):
        paths, status = _enumerate()

    assert status["complete"] is False
    assert status["walk_errors"], "the unreadable directory must be reported"
    assert any("locked" in err for err in status["walk_errors"]), status["walk_errors"]
    # The file behind the unreadable directory is genuinely absent from the
    # listing - which is exactly why the failure has to be reported.
    assert "Invisible.2026.mkv" not in {p.name for p in paths}
    assert "Visible.2026.mkv" in {p.name for p in paths}
    assert status["roots"][0]["ok"] is False


def test_missing_root_marks_enumeration_incomplete():
    from app.services.media_service import _discover_media

    root = _support.dedicated_cache_root("enum_present")
    _video(root / "Alpha.2026.mkv")
    absent = root.parent / (root.name + "_absent")

    paths, status = _discover_media([root, absent])

    assert status["complete"] is False
    assert absent.name in status["roots"][1]["path"]
    assert status["roots"][1]["missing"] is True
    # A partial result is still returned, for callers that only want a listing.
    assert "Alpha.2026.mkv" in {p.name for p in paths}


def test_root_that_is_not_a_directory_marks_enumeration_incomplete():
    from app.services.media_service import _discover_media

    host = _support.dedicated_cache_root("enum_notdir")
    not_a_directory = host / "not_a_directory"
    not_a_directory.write_bytes(b"this is a file, not a media root")

    paths, status = _discover_media([not_a_directory])

    assert status["complete"] is False
    assert status["roots"][0]["missing"] is True
    assert paths == []


def test_basename_collision_across_roots_marks_enumeration_incomplete():
    """Decision A: a file lost to deduplication fails closed.

    Two distinct files named the same collapse to a single entry, so the loser's
    live cache directory would be classified orphaned. Refusing to purge costs
    "purge unavailable"; proceeding costs real transcodes.
    """
    from app.services.media_service import _discover_media

    root_a = _support.dedicated_cache_root("enum_dup_a")
    root_b = _support.dedicated_cache_root("enum_dup_b")
    _video(root_a / "Same Title (2026).mkv")
    _video(root_b / "Same Title (2026).mkv")

    paths, status = _discover_media([root_a, root_b])

    assert len(paths) == 1, "the collision itself is unchanged; only its reporting is new"
    assert status["complete"] is False
    assert len(status["deduped"]) == 1
    assert "Same Title (2026).mkv" in status["deduped"][0]


# --------------------------------------------------------------------------- #
# End to end: the audit refuses to authorise a purge
# --------------------------------------------------------------------------- #


def test_audit_refuses_when_a_subdirectory_could_not_be_read():
    """An unreadable subdirectory must stop the purge, not enable it.

    This is the end-to-end shape of the incident: a populated cache, a walk that
    silently loses media, and a purge that would otherwise treat every
    unrecognised directory as orphaned.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("enum_audit_cache")
    media_root = _support.dedicated_cache_root("enum_audit_media")
    _video(media_root / "Visible.2026.mkv")
    hidden = media_root / "locked"
    _video(hidden / "Invisible.2026.mkv")

    # A cache directory belonging to the file we cannot enumerate. If the walk
    # is not reported as incomplete, this is exactly the directory that gets
    # deleted.
    _video(approved / "hls" / "live_cache_for_invisible" / "playlist.m3u8")
    (approved / "hls" / "live_cache_for_invisible" / "segment_000000.ts").write_bytes(b"L" * 16)

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         _point_roots([media_root]), \
         _unreadable(hidden):
        audit = transcode_service.audit_orphaned_caches()
        # The audit ran against this test's disposable cache root.
        assert app_config.CACHE_DIR == approved
        assert app.CACHE_DIR == approved

    assert audit["degraded"] is True
    assert any("media enumeration is incomplete" in r for r in audit["degraded_reasons"]), \
        audit["degraded_reasons"]
    assert audit["orphaned_hls"] == []
    assert audit["orphaned_previews"] == []
    assert audit["total_orphaned_dirs"] == 0
    # Nothing on disk was touched, and the directory that would have been
    # deleted is still there.
    assert (approved / "hls" / "live_cache_for_invisible").is_dir()
    assert (approved / "hls" / "live_cache_for_invisible" / "segment_000000.ts").is_file()
    # point_app_at restored the application's previous root on the way out.
    assert app_config.CACHE_DIR != approved