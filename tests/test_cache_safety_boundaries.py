"""Cache-root boundary tests - Stage A (A1-A5) only.

These tests exercise the boundary that every destructive cache operation
depends on, and nothing else:

    config.approved_cache_root()            config.py:81
    config.require_within_cache_root(...)   config.py:122

A1-A5 cover the properties that boundary asserts about ITSELF:

  A1  app.CACHE_DIR and config.CACHE_DIR answering differently is refused.
      Agreement is the only thing that establishes legitimacy - matching values
      prove consistency, they do not by themselves prove the path is correct.
  A2  A blank, whitespace-only or "." root is refused rather than silently
      becoming the process working directory.
  A3  A sibling that shares the root's textual prefix is outside the boundary.
  A4  A ".." path that normalises outside the root is refused, while one that
      normalises back inside is accepted.
  A5  A symlink that lives inside the root but resolves outside it is refused.

Stage B (A6-A12) covers the destructive call sites themselves: each one must
refuse a target outside the approved cache root, and must do so without
touching anything outside a root this module created.

  A6  purge_orphaned_caches() rejects a bad root BEFORE enumerating media.
  A7  it re-validates every audited item immediately before removing it, so a
      path that moved outside the root between audit and purge is refused.
  A8  BLOCKED - see the note below.
  A9  purge_transcode_caches_for_media() rejects a caller-supplied HLS
      directory that is not inside the approved root.
  A10 it also rejects a derived HLS directory and derived transcode files.
  A11 media_service.purge_media() surfaces preview, poster and backdrop
      refusals instead of deleting them.
  A12 subtitles_service refuses embedded and online cache deletions.

A8 IS DELIBERATELY ABSENT. cleanup_cache() validates only the transcodes
DIRECTORY once, at app/services/transcode_service.py:247, and then unlinks
individual files taken from transcode_dir.glob(...) at :256, :262 and :270
with no per-file re-validation. A test asserting per-file validation would
therefore have to fail, and a test asserting the directory check suffices
would encode the gap as correct. Neither is written. Whether cleanup_cache()
should re-validate each file is an application-code decision, not a test
decision; A8 stays blocked until that decision is made separately.

Deliberately NOT in this file, and tracked for later stages:

  * C-B1 (enumeration raises). Already covered by
    test_storage_retention.py:435, test_audit_fails_closed_when_enumeration_
    raises, with equivalent assertions, so it is not duplicated here.
  * refusal propagation for the paths Stage D deliberately leaves open:
    purge_media() returns success=True unconditionally (media_service.py:455),
    purge_subtitles_for_media() returns a flat purged list so its refusals
    reach no caller (subtitles_service.py:426-431), and
    apply_post_transcode_policy() reports status 'cache_purged' whatever the
    inner purge returned (transcode_service.py:685-692). Stage D covers only
    the two paths that already propagate correctly,
  * media-root deletion paths outside the cache boundary (A13/A14),
  * retention-test corrections (separate change, Stage G), including the
    isolation defect in CachePurgeSafetyTests, which still purges against the
    shared session cache.

Isolation rules observed by every test here:

  * Application modules are imported INSIDE each test body, so importing this
    file rebinds nothing and touches no filesystem.
  * Every path a test creates is beneath a root created by
    dedicated_cache_root() and removed by the autouse teardown fixture.
  * Every mutation of app.CACHE_DIR / config.CACHE_DIR is undone in a
    ``finally`` block.
  * No deployed location is named, opened, or operated on.

One assertion per direction is included as a positive control where a purely
negative test could pass for the wrong reason.
"""

import contextlib
import os
from pathlib import Path
from unittest import mock

import pytest

import _cache_test_support as _support


@contextlib.contextmanager
def _both_cache_roots(declared):
    """Set app.CACHE_DIR and config.CACHE_DIR to *declared*, restoring exactly.

    Used by A2, which must supply values that are NOT valid roots (None,
    whitespace, ".") and so cannot go through point_app_at()'s disposable-root
    precondition. It rebinds two attributes, calls nothing, and restores the
    previous values - including deleting the attribute when it was absent -
    in ``finally``.
    """
    import app
    from app import config as app_config

    missing = object()
    prev_app = getattr(app, "CACHE_DIR", missing)
    prev_cfg = getattr(app_config, "CACHE_DIR", missing)
    try:
        app.CACHE_DIR = declared
        app_config.CACHE_DIR = declared
        yield
    finally:
        if prev_app is missing:
            if hasattr(app, "CACHE_DIR"):
                delattr(app, "CACHE_DIR")
        else:
            app.CACHE_DIR = prev_app
        if prev_cfg is missing:
            if hasattr(app_config, "CACHE_DIR"):
                delattr(app_config, "CACHE_DIR")
        else:
            app_config.CACHE_DIR = prev_cfg


@pytest.fixture(autouse=True)
def _remove_disposable_roots():
    """Guaranteed teardown for every root created during a test in this file."""
    yield
    # Deepest first, so a nested disposable root is removed before its parent.
    # remove_tree() only accepts paths beneath a root it created, and is
    # idempotent for paths a test already removed itself.
    for root in _support.owned_roots(deepest_first=True):
        _support.remove_tree(root)


def test_approved_root_refuses_when_app_and_config_cache_disagree():
    """A1 - divergent app-level and config-level cache roots are refused.

    app/__init__.py binds CACHE_DIR by value from app.config, so the two are
    normally the same object. A reassignment of one name leaves the other
    pointing somewhere else, and every derived path (poster, backdrop,
    subtitle caches) is computed from the config name while some readers use
    the app name. When they disagree there is no single answer to "where is the
    cache root", so no destructive operation may proceed.
    """
    import app  # noqa: F401  - read for its current CACHE_DIR during the test
    from app import config as app_config

    agreed = _support.dedicated_cache_root("a1_agreed")
    diverged = _support.dedicated_cache_root("a1_diverged")

    with _both_cache_roots(agreed):
        # Positive control: agreement resolves to exactly the configured root.
        assert app_config.approved_cache_root() == Path(os.path.realpath(str(agreed)))

        # Divergence with the app name pointing elsewhere is refused.
        app.CACHE_DIR = diverged
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.approved_cache_root()

        # Divergence with the config name pointing elsewhere is equally refused;
        # a matching config.CACHE_DIR is not by itself sufficient authority.
        app.CACHE_DIR = agreed
        app_config.CACHE_DIR = diverged
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.approved_cache_root()


@pytest.mark.parametrize(
    "declared",
    [
        pytest.param(None, id="unset"),
        pytest.param("   ", id="whitespace_only"),
        pytest.param(Path("."), id="current_directory"),
    ],
)
def test_approved_root_refuses_blank_or_dot_root(declared):
    """A2 - a blank, whitespace-only or "." cache root is refused.

    Path("") stringifies to "." and os.path.realpath("") is the process working
    directory, so an unvalidated root would silently install the working
    directory as the cache root - and, once it is the approved root, as a
    legitimate target for deletion. Each shape is exercised separately because
    approved_cache_root() handles them in different branches: a blank or
    whitespace-only value is rejected at config.py:99-103, and "." is rejected
    just after it.
    """
    from app import config as app_config

    with _both_cache_roots(declared):
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.approved_cache_root()


def test_require_within_cache_root_refuses_sibling_with_shared_prefix():
    """A3 - a sibling sharing the root's textual prefix is outside the boundary.

    This is the case a naive ``target.startswith(str(root))`` gets wrong: on
    Windows the separator is a backslash, so "\\\\" + root.name + "_sibling"
    does share the root's characters but is a different directory. The
    production check is separator-anchored, and this pins that.
    """
    import app
    from app import config as app_config

    root = _support.dedicated_cache_root("a3")
    sibling = root.parent / (root.name + "_sibling")

    with _support.point_app_at(root, previous=app.CACHE_DIR):
        # Positive controls: the root itself and a genuine descendant are inside.
        assert app_config.require_within_cache_root(root, "a3") == Path(
            os.path.realpath(str(root))
        )
        descendant = root / "hls"
        assert app_config.require_within_cache_root(descendant, "a3") == Path(
            os.path.realpath(str(descendant))
        )

        # The sibling shares the prefix but is not beneath the root.
        assert not _support.within(sibling, root)
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.require_within_cache_root(sibling, "a3")


def test_require_within_cache_root_refuses_parent_traversal():
    """A4 - a ".." path that normalises outside the root is refused.

    Positive control first: a traversal that normalises back INSIDE the root
    ("hls/../previews") must be accepted, which proves the boundary resolves
    the path rather than pattern-matching on "..". The negative case then
    shows a traversal that lands outside is refused. The escape probe stays
    within the system temp directory and is never created, opened or removed.
    """
    import app
    from app import config as app_config

    root = _support.dedicated_cache_root("a4")
    round_trip = root / "hls" / ".." / "previews"
    escape = root / ".." / "a4_escape_probe"

    with _support.point_app_at(root, previous=app.CACHE_DIR):
        # Normalises back inside the root: legitimate.
        assert app_config.require_within_cache_root(round_trip, "a4") == Path(
            os.path.realpath(str(root / "previews"))
        )

        # Normalises outside the root: refused.
        assert not _support.within(escape, root)
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.require_within_cache_root(escape, "a4")


def test_require_within_cache_root_follows_link_before_deciding():
    """A5 - a link inside the root that resolves outside it is refused.

    require_within_cache_root() compares os.path.realpath() results, not
    strings, so a symlink placed inside the approved root cannot be used to
    reach a directory outside it.

    A platform that cannot create the link SKIPS. It never passes: an
    unsupported platform and a genuine containment failure are different
    outcomes, and only the second one is a test result.
    """
    import app
    from app import config as app_config

    root = _support.dedicated_cache_root("a5")
    outside = _support.dedicated_cache_root("a5_outside")
    link = root / "escape_link"

    try:
        os.symlink(str(outside), str(link), target_is_directory=True)
    except (OSError, NotImplementedError, AttributeError) as exc:
        pytest.skip(f"symlink creation is unavailable on this platform: {exc}")

    # The platform IS capable from here, so anything less than a refusal below
    # is a genuine failure.
    assert link.is_symlink(), f"symlink reported as created but {link} is not a link"
    assert _support.within(link, root), "the link must sit lexically inside the root"
    assert not _support.within(os.path.realpath(str(link)), root), (
        "the link's real target must sit outside the root for this test to mean anything"
    )

    with _support.point_app_at(root, previous=app.CACHE_DIR):
        with pytest.raises(app_config.CacheRootUnsafe):
            app_config.require_within_cache_root(link, "a5")


# --------------------------------------------------------------------------- #
# Stage B - destructive call sites
#
# Every target below is a directory or file this module created under its own
# dedicated root. No purge target is ever the shared session cache, and no
# test is allowed to reach a real library, database, worker or subprocess:
# media enumeration, transcodes, subtitles, the database and the library scan
# are all mocked at their seams.
# --------------------------------------------------------------------------- #


def _synthetic_media(tag, name="StageB.2026.mkv", payload=b"synthetic media"):
    """A real file in a dedicated root of its own.

    Several call sites stat() or exists() the media argument before deciding
    anything, so the fixture must be a genuine file. It is never placed in the
    shared session cache and never under a configured media root, so the
    media-file deletion step in purge_media() declines to touch it.
    """
    root = _support.dedicated_cache_root(tag)
    media = root / name
    media.write_bytes(payload)
    return media


def test_purge_orphaned_caches_refuses_before_enumerating():
    """A6 - a bad cache root is refused BEFORE any media is enumerated.

    purge_orphaned_caches() gates on approved_cache_root() at
    transcode_service.py:503, before it reaches audit_orphaned_caches() at
    :520. This test pins that ordering: video_paths() is replaced with a
    tripwire that fails the test if it is ever called, so a regression that
    moved the gate after the audit would be caught rather than silently
    enumerating a real library.

    Disagreement is arranged with disposable roots only, so the application
    cannot fall back to a deployed default.
    """
    import app
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("a6_approved")
    intruder = _support.dedicated_cache_root("a6_intruder")

    def _tripwire(*_args, **_kwargs):
        raise AssertionError(
            "video_paths() was reached: the cache root must be rejected first"
        )

    with _both_cache_roots(approved):
        app.CACHE_DIR = intruder  # the two names now disagree
        with mock.patch.object(
            transcode_service, "video_paths", side_effect=_tripwire
        ) as enumeration:
            result = transcode_service.purge_orphaned_caches(dry_run=False)

        assert result["refused"] is True
        assert result["purged_count"] == 0
        assert result["purged_dirs"] == []
        assert result["failed_count"] == 0
        assert result["failed_dirs"] == []
        assert result["reason"]
        assert enumeration.call_count == 0


def test_purge_orphaned_caches_revalidates_each_item_before_removal():
    """A7 - every audited item is re-validated immediately before removal.

    purge_orphaned_caches() re-checks item['path'] against the approved root at
    transcode_service.py:548, after the audit reported it orphaned and before
    _remove_path_with_retries() at :563. The audit is mocked to report a
    directory that is NOT inside the approved root - exactly the shape a path
    swapped between audit and purge would take.

    The victim is a real directory in a dedicated root of its own, so "it
    survived" is a real observation rather than an absence of intent.
    """
    import app
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("a7_approved")
    outside = _support.dedicated_cache_root("a7_outside")
    victim = outside / "pretend_orphan"
    victim.mkdir(parents=True, exist_ok=True)
    (victim / "segment_000000.ts").write_bytes(b"X" * 32)

    # A healthy audit - degraded=False - so the only thing that can stop the
    # deletion is the per-item re-validation.
    forged_audit = {
        "orphaned_hls": [
            {
                "name": victim.name,
                "path": str(victim),
                "size_bytes": 32,
                "file_count": 1,
                "mtime": 0.0,
                "source_file": None,
            }
        ],
        "orphaned_previews": [],
        "active_hls": [],
        "active_previews": [],
        "total_orphaned_bytes": 32,
        "total_orphaned_dirs": 1,
        "total_active_bytes": 0,
        "total_active_dirs": 0,
        "degraded": False,
        "degraded_reasons": [],
        "media_roots_missing": [],
    }

    def _tripwire(*_args, **_kwargs):
        raise AssertionError("no media enumeration is needed: the audit is mocked")

    with _support.point_app_at(approved, previous=app.CACHE_DIR):
        with mock.patch.object(
            transcode_service, "audit_orphaned_caches", return_value=forged_audit
        ), mock.patch.object(
            transcode_service, "video_paths", side_effect=_tripwire
        ):
            result = transcode_service.purge_orphaned_caches(dry_run=False)

    # A per-item refusal is NOT the same thing as a whole-operation refusal:
    # the audit was healthy, so the operation proceeds and reports the item.
    assert result["refused"] is False
    assert result["purged_count"] == 0
    assert result["purged_dirs"] == []
    assert result["failed_count"] == 1
    assert "refused" in result["failed_dirs"][0]["remaining"]
    assert victim.is_dir()
    assert (victim / "segment_000000.ts").is_file()


def test_purge_transcode_caches_for_media_refuses_foreign_known_hls_dir():
    """A9 - a caller-supplied HLS directory outside the root is refused.

    known_hls_dir arrives from a caller rather than being derived from the
    cache root, so it is the one target that cannot be trusted by construction.
    transcode_service.py:2091 validates it before it is queued for removal.

    path=None is passed on purpose: it isolates the known_hls_dir branch and
    removes every other effect this function has, so the only possible outcome
    here is the refusal.
    """
    import app
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("a9_approved")
    outside = _support.dedicated_cache_root("a9_outside")
    victim = outside / "foreign_hls"
    victim.mkdir(parents=True, exist_ok=True)
    (victim / "playlist.m3u8").write_text("#EXTM3U\n", encoding="utf-8")

    with _support.point_app_at(approved, previous=app.CACHE_DIR):
        result = transcode_service.purge_transcode_caches_for_media(
            None, known_hls_dir=victim
        )

    refusals = [f for f in result["failed"] if "refused" in str(f.get("remaining", ""))]
    assert len(refusals) == 1
    assert result["hls_dirs"] == []
    assert result["mp4_files"] == []
    assert victim.is_dir()
    assert (victim / "playlist.m3u8").is_file()


def test_purge_transcode_caches_for_media_refuses_foreign_derived_paths():
    """A10 - derived HLS and transcode paths outside the root are refused.

    Both derivations are mocked to point at a dedicated root outside the
    approved one: hls_cache_dir() at transcode_service.py:2105 and
    transcode_cache_path() at :2138. Each target is a real file or directory,
    so surviving is an observation.

    Note the derived-file branch breaks out of the mode loop on the first
    refusal (:2144), so exactly one file refusal is expected alongside the HLS
    one - not one per mode.
    """
    import app
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("a10_approved")
    outside = _support.dedicated_cache_root("a10_outside")
    media = _synthetic_media("a10_media")

    foreign_hls = outside / "derived_hls"
    foreign_hls.mkdir(parents=True, exist_ok=True)
    (foreign_hls / "playlist.m3u8").write_text("#EXTM3U\n", encoding="utf-8")
    foreign_mp4 = outside / "derived.mp4"
    foreign_mp4.write_bytes(b"not really a transcode")

    with _support.point_app_at(approved, previous=app.CACHE_DIR):
        with mock.patch.object(
            transcode_service, "hls_cache_dir", return_value=foreign_hls
        ), mock.patch.object(
            transcode_service, "transcode_cache_path", return_value=foreign_mp4
        ):
            result = transcode_service.purge_transcode_caches_for_media(media)

    refusals = [f for f in result["failed"] if "refused" in str(f.get("remaining", ""))]
    assert len(refusals) == 2
    assert result["hls_dirs"] == []
    assert result["mp4_files"] == []
    assert foreign_hls.is_dir()
    assert (foreign_hls / "playlist.m3u8").is_file()
    assert foreign_mp4.is_file()


def test_purge_media_refuses_preview_poster_backdrop_outside_root():
    """A11 - preview, poster and backdrop targets outside the root are refused
    and the refusals are surfaced in the result.

    purge_media() validates preview_dir() at media_service.py:363 and each of
    POSTER_CACHE/BACKDROP_CACHE at :385 before unlinking. All three are pointed
    at dedicated roots outside the approved one, so every one must be refused.

    Every other effect of purge_media() is mocked away: transcodes, subtitle
    caches, the database, the library scan and path resolution. The media file
    is deliberately NOT under a configured media root, so its own deletion
    step declines to touch it and no media workflow runs against a database.

    NOTE: this test asserts the REFUSALS are reported, not that the operation
    is reported as a failure. purge_media() returns success=True
    unconditionally at media_service.py:455 regardless of
    refused_cache_deletes; that is a propagation gap and belongs to Stage D.
    """
    import app
    from app import config as app_config
    from app.services import media_service, preview_service
    from app.services import scanner_service, subtitles_service, transcode_service

    approved = _support.dedicated_cache_root("a11_approved")
    outside = _support.dedicated_cache_root("a11_outside")
    media = _synthetic_media("a11_media")

    foreign_preview = outside / "previews" / "a11preview"
    foreign_preview.mkdir(parents=True, exist_ok=True)
    (foreign_preview / "thumb_0000.jpg").write_bytes(b"P" * 16)
    foreign_poster = outside / "posters"
    foreign_poster.mkdir(parents=True, exist_ok=True)
    (foreign_poster / "123.jpg").write_bytes(b"P" * 16)
    foreign_backdrop = outside / "backdrops"
    foreign_backdrop.mkdir(parents=True, exist_ok=True)
    (foreign_backdrop / "123.jpg").write_bytes(b"B" * 16)

    database = mock.MagicMock()
    database.execute.return_value.fetchone.return_value = None

    def _fake_value(_row, key):
        return "123" if key == "tmdb_id" else None

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(media_service, "safe_path", return_value=media), \
         mock.patch.object(media_service, "get_rel_path", return_value=media.name), \
         mock.patch.object(media_service, "get_db", return_value=database), \
         mock.patch.object(media_service, "value", side_effect=_fake_value), \
         mock.patch.object(transcode_service, "stop_transcodes_for_media", return_value=[]), \
         mock.patch.object(transcode_service, "purge_transcode_caches_for_media",
                           return_value={"hls_dirs": [], "mp4_files": [], "failed": []}), \
         mock.patch.object(transcode_service, "find_ffmpeg_info_for_path",
                           return_value=(None, None)), \
         mock.patch.object(transcode_service, "hls_cache_dir",
                           return_value=approved / "hls"), \
         mock.patch.object(transcode_service, "get_cache_dir", return_value=approved), \
         mock.patch.object(subtitles_service, "purge_subtitles_for_media", return_value=[]), \
         mock.patch.object(preview_service, "preview_dir", return_value=foreign_preview), \
         mock.patch.object(scanner_service, "trigger_library_scan"), \
         mock.patch.object(app_config, "POSTER_CACHE", foreign_poster), \
         mock.patch.object(app_config, "BACKDROP_CACHE", foreign_backdrop):
        result = media_service.purge_media(media.name)

    refused = result["refused_cache_deletes"]
    assert len(refused) == 3, refused
    assert all(entry["reason"] for entry in refused)
    assert result["purged_cache_dirs"] == []
    assert result["purged_posters"] == []
    assert foreign_preview.is_dir()
    assert (foreign_preview / "thumb_0000.jpg").is_file()
    assert (foreign_poster / "123.jpg").is_file()
    assert (foreign_backdrop / "123.jpg").is_file()
    database.commit.assert_not_called()


def test_purge_subtitles_for_media_refuses_caches_outside_root():
    """A12 - embedded and online subtitle caches outside the root are refused.

    purge_subtitles_for_media() validates SUBTITLE_EMBEDDED_CACHE at
    subtitles_service.py:376 and the derived online file at :397 before either
    is unlinked. Both are pointed at dedicated roots outside the approved one.

    RECORDED LIMITATION, NOT A CLAIM OF A FIX: both refusals are recorded in
    the local `refused` list and logged at :426-431, but the function returns
    only the flat `purged` list of deleted paths. The caller cannot tell a
    refusal from a file that was never there. What this test establishes is
    narrowly that NOTHING WAS DELETED; how a refusal should reach the caller
    is the Stage D propagation question and is not settled here.
    """
    import app
    from app import config as app_config
    from app.services import subtitles_service

    approved = _support.dedicated_cache_root("a12_approved")
    outside = _support.dedicated_cache_root("a12_outside")
    media = _synthetic_media("a12_media")

    foreign_embedded = outside / "subtitles" / "embedded"
    foreign_embedded.mkdir(parents=True, exist_ok=True)
    (foreign_embedded / "deadbeefdeadbeef_0.vtt").write_text("WEBVTT\n", encoding="utf-8")
    foreign_online = outside / "subtitles" / "online"
    foreign_online.mkdir(parents=True, exist_ok=True)
    (foreign_online / "cafebabecafebabe.vtt").write_text("WEBVTT\n", encoding="utf-8")

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "SUBTITLE_EMBEDDED_CACHE", foreign_embedded), \
         mock.patch.object(app_config, "SUBTITLE_ONLINE_CACHE", foreign_online):
        result = subtitles_service.purge_subtitles_for_media(media)

    # No subtitle cache path was deleted; the returned list carries only
    # successful deletions, so an empty list is the consistent result here.
    assert result == []
    assert (foreign_embedded / "deadbeefdeadbeef_0.vtt").is_file()
    assert (foreign_online / "cafebabecafebabe.vtt").is_file()


# --------------------------------------------------------------------------- #
# Stage C - media-enumeration completeness
#
# Two distinct conditions, deliberately not conflated:
#
#   KNOWN incomplete enumeration. A configured root is missing or is not a
#   directory (transcode_service.py:346-356), or enumeration itself raises
#   (:322-326). These are observable, and the audit reports them as degraded.
#   Stage C tests them.
#
#   UNKNOWN partial enumeration. Every configured root is present and
#   enumeration returns without error, but the walk silently omitted files.
#   video_paths() drops a missing root without a word (:58-59), deduplicates by
#   lowercased basename so two distinct files with the same name collapse into
#   one (:64-67), and swallows nothing because nothing raised. There is NO
#   signal for this, and Stage C does not pretend otherwise: see C-B7, which is
#   a limitation sentinel and not a claim that partial enumeration is solved.
#
# No test here invokes a real library walk. video_paths() and
# config.get_media_roots() are mocked at their seams for every case, and no
# purge is executed except C-B6, which exercises the refusal path with the
# removal seam replaced by a tripwire.
# --------------------------------------------------------------------------- #


def _media_root(tag, names=("Alpha.2026.mkv",)):
    """A dedicated directory holding synthetic media files."""
    root = _support.dedicated_cache_root(tag)
    for name in names:
        (root / name).write_bytes(b"synthetic media")
    return root


def _absent_sibling(root, suffix="_absent"):
    """A path beside *root* that deliberately does not exist.

    Same system-temp parent, so it is inside the disposable area, but it is
    never created - which is the whole point of the test using it. Nothing to
    clean up, and nothing was ever created to be cleaned up.
    """
    return root.parent / (root.name + suffix)


def _orphan_hls(cache_root, name, payload=b"O" * 64):
    """A synthetic orphaned HLS directory beneath an approved cache root."""
    orphan = cache_root / "hls" / name
    orphan.mkdir(parents=True, exist_ok=True)
    (orphan / "segment_000000.ts").write_bytes(payload)
    return orphan


def test_audit_degraded_when_enumeration_empty_but_cache_populated():
    """C-B2 - an empty enumeration against a populated cache is degraded.

    OVERLAP, DELIBERATE: test_storage_retention.py:419
    (test_audit_fails_closed_when_enumeration_returns_nothing) asserts the same
    audit outcome. That version runs against the SHARED session cache and then
    performs a LIVE purge; this one runs against a dedicated root of its own
    and invokes no purge at all. The audit assertions are the same, so this is
    isolation-correct duplication rather than new behaviour.

    An empty library is legitimate, but an empty enumeration while cache
    directories still exist almost always means the roots or database were
    unreadable at this instant (transcode_service.py:373-384). The audit must
    say so rather than classify every directory as orphaned.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb2_cache")
    orphan = _orphan_hls(approved, "orphan_enumeration_empty")

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "get_media_roots", return_value=[approved]), \
         mock.patch.object(transcode_service, "video_paths", return_value=[]):
        audit = transcode_service.audit_orphaned_caches()

    assert audit["degraded"] is True
    assert audit["orphaned_hls"] == []
    assert audit["orphaned_previews"] == []
    assert audit["total_orphaned_dirs"] == 0
    # Nothing was acted on: the synthetic orphan is untouched on disk.
    assert orphan.is_dir()
    assert (orphan / "segment_000000.ts").is_file()


def test_audit_degraded_when_configured_media_root_missing():
    """C-B3 - THE INCIDENT SHAPE. A missing configured root means a partial
    inventory, so the audit is degraded and nothing is actionable.

    video_paths() skips a root that does not exist without raising and without
    reporting (media_service.py:58-59), so a missing root yields a NON-EMPTY
    list that is silently incomplete. That list is indistinguishable from a
    complete one at the enumeration seam - and is exactly what let a purge
    delete every cache directory on the host.

    Both roots are synthetic and beneath the system temp directory; the absent
    one is never created. No purge is invoked, so the assertion that the
    orphan is untouched is an observation, not a side effect of a refusal.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb3_cache")
    present = _media_root("cb3_present")
    absent = _absent_sibling(present)
    orphan = _orphan_hls(approved, "orphan_missing_root")

    # The partial inventory a silent skip would produce: one real file, and
    # nothing at all from the root that was never walked.
    partial_inventory = [str(present / "Alpha.2026.mkv")]

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "get_media_roots", return_value=[present, absent]), \
         mock.patch.object(transcode_service, "video_paths", return_value=partial_inventory):
        audit = transcode_service.audit_orphaned_caches()

    assert audit["degraded"] is True
    assert audit["media_roots_missing"] == [str(absent)]
    assert any(
        "media enumeration is incomplete" in reason
        for reason in audit["degraded_reasons"]
    )
    assert audit["orphaned_hls"] == []
    assert audit["orphaned_previews"] == []
    assert audit["total_orphaned_dirs"] == 0
    assert orphan.is_dir()
    assert (orphan / "segment_000000.ts").is_file()
    assert not absent.exists()


def test_audit_degraded_when_configured_media_root_is_not_a_directory():
    """C-B4 - a configured root that exists but is a regular file is degraded.

    transcode_service.py:348 tests `not root.exists() or not root.is_dir()`,
    so a path that exists and is not walkable is caught by the same branch as a
    missing one. The fixture is a real file in a dedicated root; nothing under
    a deployed location is named, opened or required.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb4_cache")
    host = _media_root("cb4_host")
    not_a_directory = host / "not_a_directory"
    not_a_directory.write_bytes(b"this is a file, not a media root")

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "get_media_roots", return_value=[not_a_directory]), \
         mock.patch.object(transcode_service, "video_paths", return_value=[]):
        audit = transcode_service.audit_orphaned_caches()

    assert audit["degraded"] is True
    assert audit["media_roots_missing"] == [str(not_a_directory)]
    assert not_a_directory.is_file()


def test_audit_not_degraded_when_every_configured_root_is_present():
    """C-B5 - two present roots are NOT reported missing.

    This is the guard against the completeness check being over-strict: a
    refusal is only safe if it does not fire on every healthy run, which would
    make the purge permanently unavailable while still looking correct.

    It deliberately does NOT interpret this result as proof that enumeration is
    complete. Two present roots and a non-empty inventory are the observable
    facts; completeness is not one of them.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb5_cache")
    root_a = _media_root("cb5_root_a", names=("Alpha.2026.mkv",))
    root_b = _media_root("cb5_root_b", names=("Beta.2026.mkv",))
    inventory = [str(root_a / "Alpha.2026.mkv"), str(root_b / "Beta.2026.mkv")]

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "get_media_roots", return_value=[root_a, root_b]), \
         mock.patch.object(transcode_service, "video_paths", return_value=inventory):
        audit = transcode_service.audit_orphaned_caches()

    assert audit["media_roots_missing"] == []
    assert audit["degraded"] is False
    assert audit["degraded_reasons"] == []


def test_purge_refuses_and_deletes_nothing_when_audit_degraded():
    """C-B6 - a degraded audit stops the purge before the removal seam.

    purge_orphaned_caches() returns at transcode_service.py:521-533 without
    reaching _remove_path_with_retries(). The seam itself is replaced by a
    tripwire, so this is not merely an assertion about the returned counters -
    any attempt to remove a path fails the test immediately.

    The synthetic orphan is real, so "it survived" is an observation. No media
    enumeration runs: the audit is mocked wholesale, exactly as a degraded
    audit would be reached in practice.
    """
    import app
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb6_cache")
    orphan = _orphan_hls(approved, "orphan_degraded_audit")

    degraded_audit = {
        "orphaned_hls": [
            {
                "name": orphan.name,
                "path": str(orphan),
                "size_bytes": 64,
                "file_count": 1,
                "mtime": 0.0,
                "source_file": None,
            }
        ],
        "orphaned_previews": [],
        "active_hls": [],
        "active_previews": [],
        "total_orphaned_bytes": 64,
        "total_orphaned_dirs": 1,
        "total_active_bytes": 0,
        "total_active_dirs": 0,
        "degraded": True,
        "degraded_reasons": ["media enumeration is incomplete: synthetic"],
        "media_roots_missing": ["/synthetic/absent/root"],
    }

    def _no_removal(*_args, **_kwargs):
        raise AssertionError(
            "a degraded audit must never reach the removal seam"
        )

    def _no_enumeration(*_args, **_kwargs):
        raise AssertionError("no media enumeration is needed: the audit is mocked")

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(transcode_service, "approved_cache_root",
                           return_value=approved.resolve()), \
         mock.patch.object(transcode_service, "audit_orphaned_caches",
                           return_value=degraded_audit), \
         mock.patch.object(transcode_service, "_remove_path_with_retries",
                           side_effect=_no_removal) as removal, \
         mock.patch.object(transcode_service, "video_paths", side_effect=_no_enumeration):
        result = transcode_service.purge_orphaned_caches(dry_run=False)

    assert result["refused"] is True
    assert result["purged_count"] == 0
    assert result["purged_dirs"] == []
    assert result["freed_bytes"] == 0
    assert "media enumeration is incomplete" in result["reason"]
    assert removal.call_count == 0
    assert orphan.is_dir()
    assert (orphan / "segment_000000.ts").is_file()


def test_enumeration_completeness_is_not_observable():
    """C-B7 - LIMITATION SENTINEL. This test proves nothing is fixed.

    It exists to record, executably, that the audit CANNOT distinguish a
    complete inventory from a silently truncated one.

    Both roots are present and readable, and enumeration raises in neither
    case - so every observable check at transcode_service.py:322-384 passes for
    both runs. Yet the second run omits media_a entirely, and the live HLS
    cache directory belonging to media_a is therefore classified ORPHANED
    (:414) and handed to the purge as actionable.

    That is the unresolved half of the incident mechanism, and this suite does
    not address it:

      * video_paths() returns no completeness signal, no count, and no
        per-root confirmation, so the audit has nothing to compare against;
      * dedup by lowercased basename (media_service.py:64-67) means two
        distinct files sharing a name collapse to one entry, which is
        indistinguishable from a smaller library;
      * detecting either would require a coverage threshold or an enumeration
        self-report, and inventing a threshold is explicitly out of bounds.

    NOTHING HERE ASSERTS THAT EITHER INVENTORY IS COMPLETE, and no assertion
    below should be read as a claim that partial enumeration has been fixed.
    The only claim is the negative one the test is named for: the observable
    verdict is identical for both inventories.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    approved = _support.dedicated_cache_root("cb7_cache")
    root_a = _media_root("cb7_root_a", names=("Alpha.2026.mkv",))
    root_b = _media_root("cb7_root_b", names=("Beta.2026.mkv",))
    media_a = root_a / "Alpha.2026.mkv"
    media_b = root_b / "Beta.2026.mkv"

    # A real, live HLS cache directory for media_a, under the approved root.
    live_cache = transcode_service.hls_cache_dir(media_a)
    live_cache.mkdir(parents=True, exist_ok=True)
    (live_cache / "playlist.m3u8").write_text("#EXTM3U\n", encoding="utf-8")
    (live_cache / "segment_000000.ts").write_bytes(b"L" * 32)

    complete_inventory = [str(media_a), str(media_b)]
    # Same roots, same absence of errors - media_a simply never enumerated.
    truncated_inventory = [str(media_b)]
    assert len(complete_inventory) != len(truncated_inventory)

    with _support.point_app_at(approved, previous=app.CACHE_DIR), \
         mock.patch.object(app_config, "get_media_roots", return_value=[root_a, root_b]):
        with mock.patch.object(transcode_service, "video_paths",
                               return_value=complete_inventory):
            audit_complete = transcode_service.audit_orphaned_caches()
        with mock.patch.object(transcode_service, "video_paths",
                               return_value=truncated_inventory):
            audit_truncated = transcode_service.audit_orphaned_caches()

    # The only difference the audit can see is none.
    assert audit_complete["degraded"] is False
    assert audit_truncated["degraded"] is False, (
        "If this ever becomes True, enumeration completeness gained a signal "
        "and this sentinel should be replaced with a real safety test."
    )
    assert audit_complete["media_roots_missing"] == []
    assert audit_truncated["media_roots_missing"] == []
    assert audit_truncated["degraded_reasons"] == []

    # And the consequence: media_a's live cache is classified orphaned purely
    # because media_a was not enumerated, with no degradation reported.
    active_names = {item["name"] for item in audit_complete["active_hls"]}
    orphan_names = {item["name"] for item in audit_truncated["orphaned_hls"]}
    assert live_cache.name in active_names
    assert live_cache.name in orphan_names, (
        "A truncated inventory marks a live cache orphaned while reporting no "
        "degradation. This is the unresolved completeness gap, NOT a defect "
        "this test fixes."
    )


# --------------------------------------------------------------------------- #
# Stage D - refusal propagation, passing subset only
#
# Exactly two paths, both of which already propagate correctly. Each asserts
# the CURRENT behaviour of api.py:736 and worker_service.py:174-181; neither
# asks for an application change, and neither would pass if that propagation
# regressed.
#
# Deliberately NOT covered - the propagation gaps that remain open:
#   * purge_media() -> success=True regardless of refused_cache_deletes
#     (media_service.py:455)
#   * purge_subtitles_for_media() refusals reach no caller
#     (subtitles_service.py:426-431)
#   * apply_post_transcode_policy() always reports 'cache_purged'
#     (transcode_service.py:685-692)
# --------------------------------------------------------------------------- #


def test_storage_purge_orphans_reports_success_false_on_refusal():
    """Stage D - a refused orphan purge is reported as a FAILED operation.

    The route at api.py:731-738 returns the purge result unchanged and derives
    success from `not res.get('refused')`, so a refusal must never reach a
    client looking like a successful purge.

    purge_orphaned_caches() is replaced wholesale, so no enumeration, audit,
    purge, cleanup or database operation runs and no cache root is needed at
    all - the seam sits above the cache. The endpoint declares no
    authentication and registers no before_request handler, so the request is
    made directly with a plain test client.
    """
    import app
    from app.services import transcode_service

    refusal_reason = "cache audit degraded: synthetic refusal"
    refusal_result = {
        "freed_bytes": 0,
        "purged_count": 0,
        "purged_dirs": [],
        "failed_count": 0,
        "failed_dirs": [],
        "dry_run": False,
        "refused": True,
        "reason": refusal_reason,
    }

    with mock.patch.object(
        transcode_service, "purge_orphaned_caches", return_value=refusal_result
    ) as purge:
        client = app.app.test_client()
        response = client.post("/api/storage/purge-orphans")

    assert response.status_code == 200
    payload = response.get_json()
    assert payload["success"] is False
    # The result payload is preserved intact, so existing clients keep parsing.
    assert payload["result"] == refusal_result
    assert payload["result"]["refused"] is True
    assert payload["result"]["reason"] == refusal_reason
    assert payload["result"]["purged_dirs"] == []
    assert payload["result"]["purged_count"] == 0
    assert purge.call_count == 1


def test_worker_logs_refusal_distinctly_from_zero_purged(caplog):
    """Stage D - a refused periodic purge is logged as a REFUSAL, not as a
    successful purge of zero items.

    worker_service.py:174-181 branches on res['refused'] BEFORE the
    purged_count check, so a refusal cannot be mistaken for a healthy cache
    that happened to have nothing to do. That ordering is what this pins.

    cache_maintenance_loop() is an unbounded loop (`while not
    SHUTDOWN_EVENT.is_set()`, preceded by a 60-second sleep), so the test runs
    exactly one iteration: time.sleep is replaced, and the SECOND sleep - the
    one inside the inter-iteration wait at :205 - sets a stand-in shutdown
    event, which ends both loops naturally. No thread, timer, scheduler or
    two-hour wait is involved, and start_cache_maintenance_worker() is never
    called.

    repair_understated_caches() is replaced too. It is reached on the same
    iteration and would otherwise walk real HLS directories and can queue a
    re-render through ensure_hls_transcode().
    """
    import logging

    from app import config as app_config
    from app.services import transcode_service, worker_service

    refusal_reason = "cache audit degraded: synthetic refusal"
    refusal_result = {
        "freed_bytes": 0,
        "purged_count": 0,
        "purged_dirs": [],
        "failed_count": 0,
        "failed_dirs": [],
        "dry_run": False,
        "refused": True,
        "reason": refusal_reason,
    }

    class _StandInShutdownEvent:
        """Minimal threading.Event stand-in the fake sleep can trip."""

        def __init__(self):
            self.stopped = False

        def is_set(self):
            return self.stopped

        def set(self):
            self.stopped = True

    shutdown = _StandInShutdownEvent()
    sleeps = {"count": 0}

    def _fake_sleep(_seconds):
        sleeps["count"] += 1
        if sleeps["count"] >= 2:
            # The first sleep is the 60s startup wait at :169, before the loop.
            # The second is the inter-iteration wait at :205, after the body has
            # run once - ending the loop here leaves exactly one iteration.
            shutdown.set()

    caplog.set_level(logging.INFO)

    with mock.patch("time.sleep", side_effect=_fake_sleep), \
         mock.patch.object(app_config, "SHUTDOWN_EVENT", shutdown), \
         mock.patch.object(transcode_service, "purge_orphaned_caches",
                           return_value=refusal_result) as purge, \
         mock.patch.object(transcode_service, "repair_understated_caches",
                           return_value={"repaired": [], "stripped": []}) as repair:
        worker_service.cache_maintenance_loop()

    assert purge.call_count == 1
    assert repair.call_count == 1, "one full loop iteration should have completed"

    messages = [record.getMessage() for record in caplog.records]
    refusal_lines = [m for m in messages if "REFUSED to purge" in m]
    assert len(refusal_lines) == 1, messages
    assert refusal_reason in refusal_lines[0]

    # The refusal must not also be reported as an ordinary successful purge.
    assert not any(m.startswith("Periodic cache maintenance purged") for m in messages), messages
    assert not any("orphaned directories" in m for m in messages), messages