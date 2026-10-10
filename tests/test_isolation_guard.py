"""Regression tests for the test-suite isolation guard (Phase 3.4).

Context: the suite used to redirect the database but leave the *media root*
pointing at the deployed library. ``app/routes/api.py::upload()`` writes directly
to ``config.MEDIA_ROOT`` (it does not consult ``UPLOAD_TARGET_DIR``), so any test
that posted to ``/api/upload`` created a real file in ``D:\\Flicks`` and, via
``scanner.scan_single_file()``, a real row in the live ``media.db``.

A second leak compounded it: ``scanner.py`` runs ``load_dotenv(ENV_FILE,
override=True)`` at import, which rewrote the isolation environment variables
back to the deployed values from ``.env`` the moment anything imported it.

These tests pin the guard itself, obtained through the ``isolation_guard``
fixture. They deliberately do NOT ``import conftest``: ``tests/integration/
conftest.py`` is registered under the same module name, so a bare import
resolves to whichever was loaded first. Fixtures are resolved by directory, so
the fixture is unambiguous.

These are plain pytest functions because ``unittest.TestCase`` cannot receive
fixtures. They touch only the throwaway tree.
"""
import os
from pathlib import Path

import pytest

_PRODUCTION_MEDIA_ROOT = "D:\\Flicks"
_PRODUCTION_MEDIA_ROOT_ALT = "d:/flicks"  # different case + separators
_PRODUCTION_DB = "E:\\MediaServer\\media.db"


# --------------------------------------------------------------------------- #
# Path comparison
# --------------------------------------------------------------------------- #

def test_production_media_root_is_rejected(isolation_guard):
    assert isolation_guard["is_production_path"](Path(_PRODUCTION_MEDIA_ROOT))


def test_production_media_root_is_rejected_case_insensitively(isolation_guard):
    """Windows paths compare case-insensitively; a naive prefix check fails here."""
    assert isolation_guard["is_production_path"](Path(_PRODUCTION_MEDIA_ROOT_ALT))


def test_live_database_is_rejected(isolation_guard):
    assert isolation_guard["is_production_path"](Path(_PRODUCTION_DB))


def test_child_of_production_media_root_is_rejected(isolation_guard):
    child = Path(_PRODUCTION_MEDIA_ROOT) / "Some Movie (2026).mkv"
    assert isolation_guard["is_production_path"](child)


def test_child_of_production_media_root_rejected_with_mixed_case(isolation_guard):
    assert isolation_guard["is_production_path"](Path("D:/FLICKS/subdir/file.mkv"))


def test_live_cache_is_rejected(isolation_guard):
    assert isolation_guard["is_production_path"](isolation_guard["live_cache"])


def test_temporary_media_root_is_accepted(isolation_guard):
    assert not isolation_guard["is_production_path"](isolation_guard["media"])


def test_temporary_database_is_accepted(isolation_guard):
    assert not isolation_guard["is_production_path"](isolation_guard["db"])


def test_unrelated_system_path_is_accepted(isolation_guard):
    other = Path(os.environ.get("TEMP", "C:/Temp"))
    assert not isolation_guard["is_production_path"](other)


def test_none_is_accepted(isolation_guard):
    assert not isolation_guard["is_production_path"](None)


# --------------------------------------------------------------------------- #
# Environment repair (scanner.py's load_dotenv(override=True))
# --------------------------------------------------------------------------- #

@pytest.fixture
def env_snapshot(isolation_guard):
    """Restore os.environ and the remembered-fallback dict after each test."""
    saved_env = dict(os.environ)
    saved_fallback = dict(isolation_guard["fallback"])
    yield
    os.environ.clear()
    os.environ.update(saved_env)
    isolation_guard["fallback"].clear()
    isolation_guard["fallback"].update(saved_fallback)


def test_clobbered_media_root_is_restored_to_temporary(isolation_guard, env_snapshot):
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = _PRODUCTION_MEDIA_ROOT
    restored = isolation_guard["restore_isolation_env"]()
    assert "MEDIA_SERVER_MEDIA_ROOT" in restored
    assert not isolation_guard["is_production_path"](
        os.environ["MEDIA_SERVER_MEDIA_ROOT"]
    )


def test_clobbered_database_is_restored_to_temporary(isolation_guard, env_snapshot):
    os.environ["MEDIA_SERVER_DATABASE"] = _PRODUCTION_DB
    isolation_guard["restore_isolation_env"]()
    assert not isolation_guard["is_production_path"](os.environ["MEDIA_SERVER_DATABASE"])


def test_missing_variable_is_restored(isolation_guard, env_snapshot):
    os.environ.pop("MEDIA_SERVER_MEDIA_ROOT", None)
    isolation_guard["restore_isolation_env"]()
    assert "MEDIA_SERVER_MEDIA_ROOT" in os.environ


def test_deliberate_temporary_override_is_preserved(isolation_guard, env_snapshot):
    """A module that points MEDIA_ROOT at its own TMP keeps doing so."""
    override = str(Path(os.environ["TEMP"]) / "some_test_owned_tree")
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = override
    restored = isolation_guard["restore_isolation_env"]()
    assert "MEDIA_SERVER_MEDIA_ROOT" not in restored
    assert os.environ["MEDIA_SERVER_MEDIA_ROOT"] == override


def test_deliberate_override_survives_a_later_clobber(isolation_guard, tmp_path, env_snapshot):
    """The regression that produced 404s: the override was lost after a scanner import.

    A module's own TemporaryDirectory exists for the duration of its run, so the
    remembered override is still valid when scanner.py clobbers the variable.
    """
    override_tree = tmp_path / "some_test_owned_tree"
    override_tree.mkdir()
    override = str(override_tree)

    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = override
    isolation_guard["restore_isolation_env"]()  # learns the override
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = _PRODUCTION_MEDIA_ROOT  # scanner.py
    isolation_guard["restore_isolation_env"]()  # must return to the override
    assert os.environ["MEDIA_SERVER_MEDIA_ROOT"] == override


# --------------------------------------------------------------------------- #
# HIGH-1: protection must not depend on .env being present
# --------------------------------------------------------------------------- #

def test_env_absent_still_protects_known_production_defaults(tmp_path, monkeypatch):
    """A checkout with no .env must still refuse D:\\Flicks and the live database."""
    import _isolation_paths

    # Synthetic repo root that contains no .env at all.
    empty_repo = tmp_path / "no_env_checkout"
    empty_repo.mkdir()

    assert _isolation_paths.production_paths_from_env_file(empty_repo) == set()

    production = _isolation_paths.build_production_paths(empty_repo)
    assert _isolation_paths.is_production_path("D:/Flicks", production)
    assert _isolation_paths.is_production_path("d:/flicks", production)
    assert _isolation_paths.is_production_path(r"E:\MediaServer\media.db", production)
    assert _isolation_paths.is_production_path(
        "D:/Flicks/subdir/movie.mkv", production
    )


def test_env_text_is_unioned_not_substituted(tmp_path, monkeypatch):
    """A .env declaring an extra path adds to the floor; it never removes it."""
    import _isolation_paths

    env_text = 'MEDIA_SERVER_MEDIA_ROOT="D:/Flicks"\nMEDIA_SERVER_DATABASE=D:/x.db\n'
    declared = _isolation_paths.production_paths_from_env_text(env_text, tmp_path)
    assert declared  # the synthetic path was picked up

    production = _isolation_paths.build_production_paths(tmp_path)
    production |= declared
    assert _isolation_paths.is_production_path("D:/Flicks", production)
    assert _isolation_paths.is_production_path("D:/x.db", production)


def test_partial_env_does_not_drop_the_defaults(tmp_path, monkeypatch):
    """A .env missing MEDIA_ROOT still leaves D:\\Flicks protected."""
    import _isolation_paths

    (tmp_path / ".env").write_text(
        'MEDIA_SERVER_DATABASE=D:/only.db\n', encoding="utf-8"
    )
    production = _isolation_paths.build_production_paths(tmp_path)
    assert _isolation_paths.is_production_path("D:/Flicks", production)
    assert _isolation_paths.is_production_path("D:/only.db", production)


# --------------------------------------------------------------------------- #
# Path-comparison edge cases
# --------------------------------------------------------------------------- #

def test_sibling_path_is_not_rejected(isolation_guard):
    """D:/FlicksBackup is a sibling, not a descendant."""
    assert not isolation_guard["is_production_path"](Path("D:/FlicksBackup"))
    assert not isolation_guard["is_production_path"](Path("D:/Flicks2"))
    assert not isolation_guard["is_production_path"](Path("D:/Flicks.bak"))


def test_dotdot_traversal_is_collapsed_then_rejected(isolation_guard):
    assert isolation_guard["is_production_path"](
        Path("D:/Flicks/../Flicks/movie.mkv")
    )
    assert isolation_guard["is_production_path"](
        Path("D:/Flicks/subdir/../../Flicks/movie.mkv")
    )


def test_trailing_and_alternate_separator_spellings(isolation_guard):
    assert isolation_guard["is_production_path"](Path("D:/Flicks/"))
    assert isolation_guard["is_production_path"](Path("D:\\Flicks\\"))
    assert isolation_guard["is_production_path"](Path("D:/FLICKS/./sub"))


def test_non_existent_paths_are_handled(isolation_guard):
    """An unrelated, not-yet-created path must be allowed."""
    assert not isolation_guard["is_production_path"](Path("Q:/nowhere/at/all.mkv"))


# --------------------------------------------------------------------------- #
# Deletion guards (MEDIUM from the Phase 3.4 audit)
# --------------------------------------------------------------------------- #

def test_is_live_covers_production_and_cache(isolation_guard, tmp_path):
    assert isolation_guard["is_live"](isolation_guard["live_cache"])
    assert isolation_guard["is_live"](Path("D:/Flicks"))
    assert not isolation_guard["is_live"](tmp_path)


def test_guarded_unlink_refuses_before_deleting(isolation_guard, tmp_path):
    """A guarded unlink on a forbidden target must leave the file intact."""
    victim = tmp_path / "forbidden"
    victim.mkdir()
    target = victim / "precious.mkv"
    target.write_text("keep me", encoding="utf-8")

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["guarded_os_remove"](target)
    assert target.exists(), "guarded os.remove must refuse before unlinking"
    assert target.read_text(encoding="utf-8") == "keep me"


def test_guarded_rmtree_refuses_before_removing(isolation_guard, tmp_path):
    victim = tmp_path / "forbidden_tree"
    (victim / "sub").mkdir(parents=True)
    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["guarded_rmtree"](victim)
    assert victim.exists(), "guarded rmtree must refuse before deleting"
    assert (victim / "sub").exists()


def test_guarded_remove_refuses_before_deleting(isolation_guard, tmp_path):
    victim = tmp_path / "forbidden_remove"
    victim.mkdir()
    target = victim / "precious.mkv"
    target.write_text("keep me", encoding="utf-8")
    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["guarded_os_remove"](target)
    assert target.exists()


def test_guarded_path_unlink_and_rmdir_refuse(isolation_guard, tmp_path):
    victim = tmp_path / "forbidden_paths"
    (victim / "sub").mkdir(parents=True)
    f = victim / "precious.mkv"
    f.write_text("keep me", encoding="utf-8")
    d = victim / "sub"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["guarded_path_unlink"](f)
        with pytest.raises(RuntimeError):
            isolation_guard["guarded_path_rmdir"](d)
    assert f.exists() and f.read_text(encoding="utf-8") == "keep me"
    assert d.exists()


def test_violation_message_is_clear_and_records(isolation_guard, tmp_path):
    target = Path("D:/Flicks/movie.mkv")
    error = isolation_guard["violation"]("unlink", target)
    assert isinstance(error, RuntimeError)
    message = str(error)
    assert "TEST ISOLATION VIOLATION" in message
    assert "unlink" in message
    assert "D:/Flicks" in message.replace("\\", "/")

    log = Path(isolation_guard["base"]) / "_violations.log"
    assert log.exists(), "violations must be recorded for later inspection"


def test_guards_allow_operations_inside_the_throwaway_tree(isolation_guard):
    """The guards must not be so broad that legitimate temp work is refused."""
    scratch = Path(isolation_guard["base"]) / "guard_probe_scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    f = scratch / "ok.txt"
    f.write_text("fine", encoding="utf-8")

    isolation_guard["guarded_path_unlink"](f)   # must not raise
    assert not f.exists()

    isolation_guard["guarded_rmtree"](scratch)  # must not raise
    assert not scratch.exists()


# --------------------------------------------------------------------------- #
# MEDIUM-1: write targets refused before mutation
# --------------------------------------------------------------------------- #

def test_assert_isolated_path_refuses_production_before_mutation(isolation_guard, tmp_path):
    """A forbidden write target is refused and its contents are untouched."""
    victim = tmp_path / "forbidden_media"
    victim.mkdir()
    target = victim / "upload.mkv"
    target.write_text("original", encoding="utf-8")

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["assert_isolated_path"](target, action="upload")
    assert target.read_text(encoding="utf-8") == "original", "content must be untouched"


def test_assert_isolated_path_refuses_real_production_path(isolation_guard):
    """The real deployed media root is refused without touching it."""
    with pytest.raises(RuntimeError):
        isolation_guard["assert_isolated_path"](Path("D:/Flicks/newmovie.mkv"))
    with pytest.raises(RuntimeError):
        isolation_guard["assert_isolated_path"](Path("E:/MediaServer/media.db"))


def test_assert_isolated_path_refuses_move_destination(isolation_guard, tmp_path):
    victim = tmp_path / "forbidden_dest"
    victim.mkdir()
    src = tmp_path / "src.mkv"
    src.write_text("payload", encoding="utf-8")
    dest = victim / "dest.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            isolation_guard["assert_isolated_path"](dest, action="move destination")
    assert not dest.exists()
    assert src.exists(), "source must not be consumed"


def test_assert_isolated_path_allows_throwaway_tree(isolation_guard):
    target = isolation_guard["base"] / "ok.mkv"
    resolved = isolation_guard["assert_isolated_path"](target, action="write")
    assert resolved == target.resolve()


def test_assert_isolated_path_refuses_none(isolation_guard):
    with pytest.raises(RuntimeError):
        isolation_guard["assert_isolated_path"](None, action="write")


# --------------------------------------------------------------------------- #
# MEDIUM-3: stale fallback directories
# --------------------------------------------------------------------------- #

def test_stale_fallback_directory_is_not_restored(isolation_guard, env_snapshot):
    """A fallback whose directory was deleted must not be handed back."""
    import tempfile

    gone = Path(tempfile.mkdtemp(prefix="doomed_"))
    isolation_guard["fallback"]["MEDIA_SERVER_MEDIA_ROOT"] = str(gone)
    gone.rmdir()  # the owning test cleaned it up

    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = "D:/Flicks"
    isolation_guard["restore_isolation_env"]()

    restored = Path(os.environ["MEDIA_SERVER_MEDIA_ROOT"])
    assert restored != gone
    assert restored.exists(), "a fresh, run-owned directory must be used"
    assert not isolation_guard["is_production_path"](restored)


def test_valid_fallback_is_reused(isolation_guard, env_snapshot):
    live = isolation_guard["base"] / "still_here"
    live.mkdir(parents=True, exist_ok=True)
    isolation_guard["fallback"]["MEDIA_SERVER_MEDIA_ROOT"] = str(live)
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = "D:/Flicks"
    isolation_guard["restore_isolation_env"]()
    assert os.environ["MEDIA_SERVER_MEDIA_ROOT"] == str(live)


def test_fallback_never_restores_a_deployed_path(isolation_guard, env_snapshot):
    isolation_guard["fallback"]["MEDIA_SERVER_MEDIA_ROOT"] = "D:/Flicks"
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = "D:/Flicks"
    isolation_guard["restore_isolation_env"]()
    assert not isolation_guard["is_production_path"](
        os.environ["MEDIA_SERVER_MEDIA_ROOT"]
    )


# --------------------------------------------------------------------------- #
# MEDIUM-2: configuration reload / init_db
# --------------------------------------------------------------------------- #

def _norm_under_temp_for_test(isolation_guard, path):
    """True when *path* lives inside a temporary tree (never a deployed path)."""
    import tempfile

    resolved = Path(str(path)).resolve()
    for root in (Path(tempfile.gettempdir()), Path(isolation_guard["base"])):
        try:
            resolved.relative_to(root.resolve())
            return True
        except (ValueError, OSError):
            continue
    return False


def test_config_reload_scenario_stays_isolated(isolation_guard):
    """Reloading config under isolated env must not produce production paths."""
    import importlib

    isolation_guard["restore_isolation_env"]()
    isolation_guard["point_app_at_temp"]()

    import app.config as app_config
    importlib.reload(app_config)

    for attr in ("MEDIA_ROOT", "DATABASE"):
        value = Path(str(getattr(app_config, attr))).resolve()
        assert not isolation_guard["is_production_path"](value), attr
        assert _norm_under_temp_for_test(isolation_guard, value), (
            f"{attr} must stay inside a temporary tree after a reload: {value}"
        )


def test_reload_under_production_env_is_detected(isolation_guard, env_snapshot):
    """If the env is clobbered, the guard must still see production paths."""
    os.environ["MEDIA_SERVER_MEDIA_ROOT"] = "D:/Flicks"
    assert isolation_guard["is_production_path"](
        os.environ["MEDIA_SERVER_MEDIA_ROOT"]
    )


def test_effective_config_paths_reports_all_six(isolation_guard):
    isolation_guard["restore_isolation_env"]()
    isolation_guard["point_app_at_temp"]()
    paths = isolation_guard["effective_config_paths"]()
    for key in ("MEDIA_ROOT", "DATABASE", "UPLOAD_TARGET_DIR",
                "UPLOAD_TMP", "ARCHIVE_DIR", "DELETED_DIR"):
        assert key in paths
        if paths[key] is not None:
            assert not isolation_guard["is_production_path"](paths[key])


# --------------------------------------------------------------------------- #
# The configuration actually in force
# --------------------------------------------------------------------------- #

def test_active_config_paths_are_not_production(isolation_guard):
    from app import config as app_config

    isolation_guard["restore_isolation_env"]()
    isolation_guard["point_app_at_temp"]()

    for attr in ("MEDIA_ROOT", "DATABASE", "UPLOAD_TARGET_DIR",
                 "UPLOAD_TMP", "ARCHIVE_DIR", "DELETED_DIR"):
        value = getattr(app_config, attr, None)
        if value is None:
            continue
        resolved = Path(str(value)).resolve()
        assert not isolation_guard["is_production_path"](resolved), (
            f"config.{attr} points at a deployed location: {resolved}"
        )