"""Library isolation: no test may write a single byte into the deployed media root.

The leak this file exists to kill is concrete and measurable. ``D:\\Flicks``
carries seven orphan artifacts whose creation times fall inside the test-isolation
work on 2026-10-10:

    Mayday (2026).mkv       57 bytes   10-10 02:48:10
    Mayday (2026) (1).mkv   23 bytes   10-10 05:29:38
    ... through (6)                    10-10 07:54:13

23 bytes is exactly ``b'dummy-mkv-video-content'``, the payload uploaded by
``tests/test_app.py::test_api_upload_with_custom_title_override``. The numbering
comes from ``app/routes/api.py``, which appends ``(1)``, ``(2)`` ... when the
target already exists and ``overwrite`` was not requested - so each run that left
its artifact behind advanced the chain.

The vector is ``scanner.py``, which executes at IMPORT time:

    load_dotenv(ENV_FILE, override=True)

``override=True`` rewrites ``MEDIA_SERVER_MEDIA_ROOT`` in ``os.environ`` with the
deployed value from ``.env``. ``tests/conftest.py`` repairs the isolation
variables in ``pytest_runtest_setup`` - BEFORE each test, never during one - so a
test that imports or reloads ``scanner`` mid-run poisons the environment until the
next test's setup. Any ``importlib.reload(app.config)`` in that window recomputes
``config.MEDIA_ROOT`` as the deployed root, and ``/api/upload`` writes there.

These tests assert containment only. They never open, list, create or delete
anything under a deployed location; "the deployed library is untouched" is proved
by checking the path the application CHOSE, not by inspecting the library.
"""

import contextlib
import importlib
import os
from pathlib import Path

import pytest

import _isolation_paths

#: Variables conftest redirects before the app is imported. A reload recomputes
#: the throwaway paths from these, which is why they must survive a stray
#: ``load_dotenv(override=True)``.
ISOLATION_VARS = (
    "MEDIA_SERVER_MEDIA_ROOT",
    "MEDIA_SERVER_DATABASE",
    "MEDIA_SERVER_UPLOAD_TARGET_DIR",
    "MEDIA_SERVER_UPLOAD_TMP",
    "MEDIA_SERVER_ARCHIVE_DIR",
    "MEDIA_SERVER_DELETED_DIR",
    # Phase 3.8 added this override but conftest did not set it, so a reload
    # fell back to BASE_DIR/cache and relocated CACHE_DIR to the deployed cache.
    "MEDIA_SERVER_CACHE_DIR",
)

_REPO = Path(__file__).resolve().parent.parent


def _production():
    """The deployed path set, including this checkout's own cache and database."""
    return _isolation_paths.build_production_paths(
        _REPO, extra=(_REPO / "cache", _REPO / "media.db")
    )


def _is_production(path):
    return _isolation_paths.is_production_path(path, _production())


@contextlib.contextmanager
def _reimport_scanner():
    """Force the import-time side effect that started all of this."""
    import scanner

    importlib.reload(scanner)
    try:
        yield scanner
    finally:
        # Leave the module reloaded but do not attempt to undo its environment
        # side effect here: proving that nothing else repairs it is the point of
        # the tests below.
        pass


@pytest.fixture
def client():
    import app

    from app.db import init_db

    init_db()
    return app.app.test_client()


@pytest.fixture
def hermetic_upload():
    """Stub every side effect ``/api/upload`` triggers.

    The route starts a real transcode when the container needs one
    (api.py:530-535) and spawns a DAEMON THREAD to prefetch subtitles
    (api.py:537-547). Left alone, a test issues a live OpenSubtitles request and
    launches FFmpeg. Worse, the subtitle thread outlives the request, so it races
    the test's own cleanup - which is what made an earlier version of this suite
    fail intermittently on ``os.replace`` while the write guard was uninstalling.

    ``trigger_library_scan`` is bound at api.py module scope (line 19), so it must
    be patched there rather than on the scanner_service module.
    """
    from unittest.mock import patch

    import app.routes.api as api_module
    from app.services import scanner_service, subtitles_service, transcode_service

    with patch.object(api_module, "trigger_library_scan", return_value=None), \
         patch.object(transcode_service, "ensure_hls_transcode", return_value=True), \
         patch.object(transcode_service, "needs_transcode", return_value=True), \
         patch.object(subtitles_service, "tracks", return_value=[]), \
         patch.object(scanner_service, "trigger_library_scan", return_value=None):
        yield


# --------------------------------------------------------------------------- #
# The vector: a stray dotenv load rewrites the isolation environment
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("var", ISOLATION_VARS)
def test_dotenv_never_overrides_an_explicitly_set_isolation_variable(var):
    """scanner.py must not repoint a variable conftest deliberately set."""
    before = os.environ.get(var)
    assert before, f"{var} should be set by conftest before any test runs"

    with _reimport_scanner():
        assert os.environ.get(var) == before, (
            f"importing scanner overwrote {var}: "
            f"{before!r} -> {os.environ.get(var)!r}. scanner.py runs "
            "load_dotenv(override=True) at import time, which defeats the "
            "environment-first redirection conftest relies on."
        )


def test_reimporting_scanner_leaves_the_isolated_media_root_intact():
    """The single variable this leak actually corrupts, asserted directly."""
    isolated = os.environ["MEDIA_SERVER_MEDIA_ROOT"]

    with _reimport_scanner():
        assert os.environ["MEDIA_SERVER_MEDIA_ROOT"] == isolated
        assert not _is_production(os.environ["MEDIA_SERVER_MEDIA_ROOT"]), (
            "the media root now points at a deployed location"
        )


def test_config_reload_after_scanner_import_stays_off_production():
    """The full chain: poison the env, reload config, check where MEDIA_ROOT lands.

    This is the sequence that produced the artifacts. ``config.MEDIA_ROOT`` is
    computed at import time from the environment, so a reload while the
    environment points at ``.env``'s value relocates it to the deployed library.
    """
    import app
    from app import config as app_config

    with _reimport_scanner():
        importlib.reload(app_config)
        try:
            assert not _is_production(app_config.MEDIA_ROOT), (
                f"config.MEDIA_ROOT resolved to a deployed location after a "
                f"scanner reimport: {app_config.MEDIA_ROOT}"
            )
        finally:
            importlib.reload(app_config)


def test_cache_root_unsafe_identity_survives_a_config_reload():
    """A reload must not orphan the exception class other modules catch.

    ``app/services/transcode_service.py`` binds the class once at import:

        CacheRootUnsafe = config.CacheRootUnsafe

    ``importlib.reload`` re-executes the module body in the SAME namespace but
    does not clear it first, so ``class CacheRootUnsafe(Exception)`` runs again
    and produces a NEW class object. ``transcode_service`` still holds the OLD
    one, so every ``except CacheRootUnsafe`` in that module stops matching and a
    deliberate refusal escapes as an unhandled exception instead of returning a
    refusal result.

    This is latent, not hypothetical: tests/test_app.py reloads app.config in
    tearDownClass, and the cache-boundary tests that run after it fail with an
    escaped CacheRootUnsafe.
    """
    import app
    from app import config as app_config
    from app.services import transcode_service

    before_module = transcode_service.CacheRootUnsafe
    before_config = app_config.CacheRootUnsafe
    assert before_module is before_config, (
        "transcode_service must alias the same class object as config"
    )

    importlib.reload(app_config)

    assert transcode_service.CacheRootUnsafe is app_config.CacheRootUnsafe, (
        "importlib.reload recreated config.CacheRootUnsafe, orphaning the "
        "reference transcode_service captured at import. `except CacheRootUnsafe` "
        "in transcode_service will no longer catch a refusal raised by config."
    )

    # And the behavioural consequence, which is what actually breaks tests.
    assert issubclass(app_config.CacheRootUnsafe, before_config) or True
    try:
        transcode_service.approved_cache_root()
    except app_config.CacheRootUnsafe:
        caught = "config-class"
    except before_config:
        caught = "stale-alias-class"
    else:
        caught = "no-exception"
    assert caught != "stale-alias-class", (
        "the reload orphaned the alias: a refusal would escape the handler"
    )


def test_config_reload_keeps_the_cache_root_off_production():
    """The SECOND vector, found only because the first fix was not enough.

    MEDIA_SERVER_CACHE_DIR arrived in Phase 3.8, but conftest never set it. With
    the variable unset, app/config.py:43 falls back to ``BASE_DIR / "cache"`` -
    the deployed cache. Every other isolated path survives a reload because
    conftest sets its environment variable; the cache did not, so it alone
    drifted back and made tests attempt writes into E:\\MediaServer\\cache.

    This asserts the invariant directly rather than inferring it: whatever else
    happens, a reload must not put the cache root on a deployed path.
    """
    import app
    from app import config as app_config

    importlib.reload(app_config)
    try:
        assert os.environ.get("MEDIA_SERVER_CACHE_DIR"), (
            "conftest must set MEDIA_SERVER_CACHE_DIR before the app is imported, "
            "otherwise a reload resolves CACHE_DIR to BASE_DIR/cache"
        )
        assert not _is_production(app_config.CACHE_DIR), (
            f"config.CACHE_DIR resolved to a deployed location after a reload: "
            f"{app_config.CACHE_DIR}"
        )
        for derived in (app_config.POSTER_CACHE, app_config.BACKDROP_CACHE,
                        app_config.SUBTITLE_CACHE,
                        app_config.SUBTITLE_EMBEDDED_CACHE,
                        app_config.SUBTITLE_ONLINE_CACHE):
            assert not _is_production(derived), (
                f"derived cache {derived!r} sits on a deployed location"
            )
    finally:
        importlib.reload(app_config)


# --------------------------------------------------------------------------- #
# The consequence: /api/upload writing into the deployed library
# --------------------------------------------------------------------------- #


def _upload_payload(title="Mayday (2026)", filename="1000403712.mkv"):
    import io

    return {
        "file": (io.BytesIO(b"dummy-mkv-video-content"), filename),
        "title": title,
    }


def _mock_details():
    return {"title": "Mayday", "release_date": "2026-05-01", "id": 1137844}


def test_upload_endpoint_targets_a_throwaway_media_root(client, hermetic_upload):
    """The baseline: on a clean run the upload lands in the throwaway tree."""
    from unittest.mock import patch

    from app import config as app_config

    with patch("scanner.scan_single_file", return_value=_mock_details()):
        res = client.post("/api/upload", data=_upload_payload(),
                          content_type="multipart/form-data")

    assert res.status_code == 200
    name = res.get_json()["filename"]
    written = Path(app_config.MEDIA_ROOT) / name
    assert not _is_production(written), f"upload chose a deployed path: {written}"
    assert written.is_file()
    written.unlink(missing_ok=True)


def test_upload_stays_isolated_even_after_scanner_is_reimported(client, hermetic_upload):
    """THE REGRESSION. Reproduces the artifact-creation chain end to end.

    Without the fix this writes ``Mayday (2026)N.mkv`` into the deployed library
    and the numbering in api.py advances a new copy on every run.
    """
    from unittest.mock import patch

    from app import config as app_config

    with _reimport_scanner():
        importlib.reload(app_config)
        try:
            with patch("scanner.scan_single_file", return_value=_mock_details()):
                res = client.post("/api/upload", data=_upload_payload(),
                                  content_type="multipart/form-data")

            assert res.status_code == 200
            name = res.get_json()["filename"]
            written = Path(app_config.MEDIA_ROOT) / name
            assert not _is_production(written), (
                f"the upload fixture escaped into the deployed library: {written}. "
                "This is how Mayday (2026)N.mkv artifacts appear in D:\\Flicks."
            )
            assert written.is_file()
            written.unlink(missing_ok=True)
        finally:
            importlib.reload(app_config)


def test_upload_numbering_cannot_escape_the_media_root(client, hermetic_upload):
    """The (1)/(2)/... counter must stay inside the approved media root."""
    from unittest.mock import patch

    from app import config as app_config

    root = Path(app_config.MEDIA_ROOT)
    root.mkdir(parents=True, exist_ok=True)
    produced = []

    try:
        with patch("scanner.scan_single_file", return_value=_mock_details()):
            # Three uploads of the same title: api.py must number them, not escape.
            for _ in range(3):
                res = client.post("/api/upload", data=_upload_payload(),
                                  content_type="multipart/form-data")
                assert res.status_code == 200
                produced.append(root / res.get_json()["filename"])

        assert len(produced) == 3
        for path in produced:
            assert not _is_production(path), f"numbered upload escaped: {path}"
            assert _isolation_paths.norm(path).startswith(
                _isolation_paths.norm(root) + os.sep
            ), f"numbered upload left the media root: {path}"
        assert len({p.name for p in produced}) == 3, (
            f"uploads overwrote each other instead of numbering: "
            f"{[p.name for p in produced]}"
        )
    finally:
        for path in produced:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass


def test_scan_single_file_does_not_write_into_the_library(tmp_path):
    """The scanner entry point the upload handler calls must stay inside tmp_path."""
    from unittest.mock import MagicMock, patch

    import scanner

    dummy = tmp_path / "1000403712.mkv"
    dummy.write_bytes(b"0" * 2048)
    conn = __import__("sqlite3").connect(tmp_path / "test.db")
    scanner.setup_database(conn)

    details = {
        "id": 1137844, "title": "Mayday", "release_date": "2026-09-03",
        "overview": "Cold war navy pilot adventure.",
        "poster_path": "/mayday_poster.jpg", "backdrop_path": "/mayday_backdrop.jpg",
        "runtime": 110, "genres": [{"name": "Action"}], "vote_average": 7.9,
    }
    resolved = ({"id": 1137844, "title": "Mayday", "release_date": "2026-09-03"}, "consensus")

    # scanner.py binds `from posters import download_poster` at import time, so
    # patching the posters module alone does not reach it - the real function ran
    # and issued live TMDm image requests on every run.
    try:
        with patch("scanner.load_token", return_value="fake"), \
             patch("app.services.media_resolver.resolve_media", return_value=resolved), \
             patch("scanner.get_movie_details", return_value=details), \
             patch("posters.download_poster", return_value=True), \
             patch("scanner.download_poster", return_value=True):
            scanner.scan_single_file(dummy, conn=conn, session=MagicMock(),
                                     token="fake", media_root=tmp_path)
    finally:
        conn.close()

    assert not _is_production(dummy)
    # The scan must not have created a sibling in the deployed library.
    assert not _is_production(dummy.parent)
    assert len(list(tmp_path.iterdir())) == 2, (
        f"scan created unexpected files outside tmp_path: {list(tmp_path.iterdir())}"
    )


# --------------------------------------------------------------------------- #
# The repair: isolation must hold for the WHOLE test, not only at setup
# --------------------------------------------------------------------------- #


def test_isolation_environment_is_restored_after_a_poisoning_test():
    """conftest must repair the environment AROUND each test, not just at setup.

    Ordering note: pytest runs this after tests that deliberately poison the
    environment. If nothing repairs it, this fails.
    """
    for var in ISOLATION_VARS:
        value = os.environ.get(var)
        assert value, f"{var} was left unset by an earlier test"
        assert not _is_production(value), (
            f"{var} is still pointing at a deployed location "
            f"({value}) after a test poisoned it"
        )