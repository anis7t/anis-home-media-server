"""Adversarial regression tests for the Phase 3.6 pre-write guard (tests/_write_guard.py).

Every negative case asserts that a sentinel file or directory in a TEST-OWNED
temporary directory is still present and unchanged after the guard refuses. No
file is ever created beneath a production directory and the real SQLite database
is never opened - production paths appear only as synthetic STRINGS passed to the
primitives, and the guard rejects them before any syscall.

The production-path set is temporarily widened to include a temporary directory
(``isolation_guard['temporary_production_paths']``) where a real file is needed,
so the refusal is exercised against a genuine file without touching D:\\Flicks.
"""
import builtins
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = Path(__file__).resolve().parent


def _sentinel(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "precious.mkv"
    target.write_text("original payload", encoding="utf-8")
    return target


def _real_production_strings_are_classified(isolation_guard):
    """Production classification WITHOUT touching the filesystem.

    Every refusal test below marks a TEMPORARY directory as deployed, so a broken
    guard could never create anything under D:. This pins the fact that the real
    deployed paths are classified as production, using the pure predicate that
    never performs an I/O operation on them.
    """
    check = isolation_guard["is_production_path"]
    for candidate in (
        "D:/Flicks",
        "D:/Flicks/movie.mkv",
        "E:/MediaServer/cache",
        "E:/MediaServer/media.db",
    ):
        assert check(candidate), f"{candidate} must classify as deployed"


# --------------------------------------------------------------------------- #
# 1-3: write-capable opens and Path writers
# --------------------------------------------------------------------------- #

def test_write_open_to_production_path_refused_before_mutation(tmp_path):
    """open(path,'wb') on a deployed path raises and creates nothing."""
    import _write_guard

    forbidden = Path("D:/Flicks/newmovie.mkv")
    with pytest.raises(RuntimeError, match="TEST ISOLATION VIOLATION"):
        open(forbidden, "wb")
    assert not forbidden.exists()


def test_append_and_plus_modes_refused():
    for mode in ("a", "x", "r+", "w+", "a+"):
        with pytest.raises(RuntimeError):
            open(Path("D:/Flicks/append.mkv"), mode)


def test_read_modes_are_never_blocked(tmp_path):
    """Reads must pass straight through - libraries rely on them."""
    f = _sentinel(tmp_path)
    with open(f, "r", encoding="utf-8") as handle:
        assert handle.read() == "original payload"


def test_write_text_and_write_bytes_refused():
    with pytest.raises(RuntimeError):
        Path("D:/Flicks/notes.txt").write_text("x", encoding="utf-8")
    with pytest.raises(RuntimeError):
        Path("D:/Flicks/blob.bin").write_bytes(b"x")


def test_path_write_refused_before_mutation(isolation_guard, tmp_path):
    """A REAL file marked as deployed must be untouched after refusal."""
    victim = tmp_path / "deployed_media"
    target = _sentinel(victim)

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            target.write_text("overwritten", encoding="utf-8")
        with pytest.raises(RuntimeError):
            target.write_bytes(b"overwritten")

    assert target.read_text(encoding="utf-8") == "original payload"


def test_temporary_path_remains_writable(tmp_path):
    f = tmp_path / "fine.txt"
    f.write_text("ok", encoding="utf-8")
    assert f.read_text(encoding="utf-8") == "ok"
    with open(tmp_path / "via_open.txt", "w", encoding="utf-8") as h:
        h.write("ok")
    assert (tmp_path / "via_open.txt").exists()


# --------------------------------------------------------------------------- #
# 4-5: replace / rename / move reject a forbidden DESTINATION
# --------------------------------------------------------------------------- #

def test_path_replace_refuses_forbidden_destination(isolation_guard, tmp_path):
    src = _sentinel(tmp_path)
    victim = tmp_path / "deployed"
    victim.mkdir()

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            src.replace(victim / "landed.mkv")
    assert src.exists(), "source must survive a refused move"
    assert not (victim / "landed.mkv").exists()


def test_path_rename_refuses_forbidden_destination(isolation_guard, tmp_path):
    src = _sentinel(tmp_path)
    victim = tmp_path / "deployed"
    victim.mkdir()

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            src.rename(victim / "landed.mkv")
    assert src.exists()
    assert not (victim / "landed.mkv").exists()


def test_os_replace_and_rename_refuse_forbidden_destination(isolation_guard, tmp_path):
    src = _sentinel(tmp_path)
    victim = tmp_path / "deployed"
    victim.mkdir()
    dest = victim / "landed.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            os.replace(src, dest)
        with pytest.raises(RuntimeError):
            os.rename(src, dest)
    assert src.exists() and not dest.exists()


def test_shutil_move_refuses_forbidden_destination(isolation_guard, tmp_path):
    src = _sentinel(tmp_path)
    victim = tmp_path / "deployed"
    victim.mkdir()
    dest = victim / "landed.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            shutil.move(str(src), str(dest))
    assert src.exists(), "source must not be consumed"
    assert not dest.exists()


def test_shutil_move_works_for_temporary_targets(tmp_path):
    src = _sentinel(tmp_path)
    dest = tmp_path / "moved.mkv"
    shutil.move(str(src), str(dest))
    assert dest.exists() and not src.exists()


def test_shutil_copy_refuses_forbidden_destination(isolation_guard, tmp_path):
    src = _sentinel(tmp_path)
    victim = tmp_path / "deployed"
    victim.mkdir()
    dest = victim / "copied.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            shutil.copyfile(str(src), str(dest))
        with pytest.raises(RuntimeError):
            shutil.copy(str(src), str(dest))
        with pytest.raises(RuntimeError):
            shutil.copy2(str(src), str(dest))
    assert not dest.exists()


def test_shutil_copytree_refuses_forbidden_destination(isolation_guard, tmp_path):
    src = tmp_path / "tree_src"
    (src / "sub").mkdir(parents=True)
    (src / "sub" / "a.mkv").write_text("x", encoding="utf-8")
    victim = tmp_path / "deployed"
    victim.mkdir()
    dest = victim / "tree_dst"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            shutil.copytree(str(src), str(dest))
    assert not dest.exists()
    assert (src / "sub" / "a.mkv").exists()


# --------------------------------------------------------------------------- #
# 6: deletion guards still refuse before deleting
# --------------------------------------------------------------------------- #

def test_deletion_guards_refuse_before_deleting(isolation_guard, tmp_path):
    victim = tmp_path / "deployed_delete"
    target = _sentinel(victim)

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            os.remove(target)
        with pytest.raises(RuntimeError):
            target.unlink()
        with pytest.raises(RuntimeError):
            shutil.rmtree(victim)
        with pytest.raises(RuntimeError):
            os.removedirs(victim)
    assert target.exists() and target.read_text(encoding="utf-8") == "original payload"
    assert victim.exists()


# --------------------------------------------------------------------------- #
# 8: a configuration change during a test cannot enable a prohibited write
# --------------------------------------------------------------------------- #

def test_config_redirect_cannot_enable_a_prohibited_write(isolation_guard, tmp_path):
    """Even if config/env are pointed at production, the write is refused."""
    from app import config as app_config

    victim = tmp_path / "deployed_cfg"
    _sentinel(victim)

    with isolation_guard["temporary_production_paths"](victim):
        original = app_config.MEDIA_ROOT
        try:
            app_config.MEDIA_ROOT = victim          # simulate the redirect
            with pytest.raises(RuntimeError):
                (victim / "injected.mkv").write_text("payload", encoding="utf-8")
        finally:
            app_config.MEDIA_ROOT = original
    assert not (victim / "injected.mkv").exists()


def test_env_redirect_alone_does_not_enable_a_write(isolation_guard, tmp_path, monkeypatch):
    victim = tmp_path / "deployed_env"
    _sentinel(victim)
    with isolation_guard["temporary_production_paths"](victim):
        monkeypatch.setenv("MEDIA_SERVER_MEDIA_ROOT", str(victim))
        with pytest.raises(RuntimeError):
            (victim / "injected.mkv").write_text("payload", encoding="utf-8")
    assert not (victim / "injected.mkv").exists()


# --------------------------------------------------------------------------- #
# 9: SQLite - refuse the live database before it is opened
# --------------------------------------------------------------------------- #

def test_sqlite_connect_to_live_database_refused():
    """The real media.db must never be opened. Guard raises before connect()."""
    with pytest.raises(RuntimeError, match="TEST ISOLATION VIOLATION"):
        sqlite3.connect("E:/MediaServer/media.db")


def test_sqlite_connect_uri_form_refused():
    with pytest.raises(RuntimeError):
        sqlite3.connect("file:E:/MediaServer/media.db?mode=ro", uri=True)


def test_sqlite_connect_to_temporary_database_allowed(tmp_path):
    db = tmp_path / "scratch.db"
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("CREATE TABLE t (x int)")
        conn.commit()
    finally:
        conn.close()
    assert db.exists()


# --------------------------------------------------------------------------- #
# 10: aliases, traversal, case, siblings
# --------------------------------------------------------------------------- #

def test_alias_traversal_case_and_sibling_handling(isolation_guard, tmp_path):
    check = isolation_guard["is_production_path"]
    # case
    assert check(Path("d:/flicks/x.mkv"))
    # traversal that re-enters the deployed tree
    assert check(Path("D:/Flicks/../Flicks/x.mkv"))
    assert check(Path("D:/Flicks/sub/../../Flicks/x.mkv"))
    # sibling must not be treated as a child
    assert not check(Path("D:/FlicksBackup/x.mkv"))
    assert not check(Path("D:/Flicks2/x.mkv"))
    # resolved alias (symlink-free: a real temp symlink if the platform allows)
    link = tmp_path / "link_to_deployed"
    try:
        link.symlink_to(Path("D:/Flicks"), target_is_directory=True)
    except (OSError, NotImplementedError, AttributeError):
        pytest.skip("symlinks unavailable on this platform/permission set")
    assert check(link / "x.mkv")


def test_move_source_also_validated(isolation_guard, tmp_path):
    """A forbidden SOURCE is refused too, not just the destination."""
    victim = tmp_path / "deployed_src"
    src = _sentinel(victim)
    dest = tmp_path / "out.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            shutil.move(str(src), str(dest))
    assert src.exists() and not dest.exists()


# --------------------------------------------------------------------------- #
# 11-12: install / uninstall lifecycle and passthrough behaviour
# --------------------------------------------------------------------------- #

def test_guard_install_is_idempotent_and_uninstall_restores():
    import _write_guard

    original_open = _write_guard._orig.get("open")
    assert _write_guard.is_installed() is True
    assert _write_guard.install() is False, "second install must be a no-op"
    assert _write_guard.is_installed() is True

    assert _write_guard.uninstall() is True
    try:
        assert builtins_open_is_original(original_open)
    finally:
        _write_guard.install()
    assert _write_guard.is_installed() is True


def builtins_open_is_original(original_open):
    import builtins

    return builtins.open is original_open


def test_uninstall_is_safe_when_not_installed():
    import _write_guard

    was = _write_guard.is_installed()
    if was:
        _write_guard.uninstall()
    try:
        assert _write_guard.uninstall() is False, "uninstall must be safe when idle"
    finally:
        if was:
            _write_guard.install()


def test_original_behaviour_preserved_outside_writes(tmp_path):
    """Signatures/return values are unchanged for allowed operations."""
    f = tmp_path / "roundtrip.bin"
    with open(f, "wb") as h:
        assert h.write(b"abc") == 3
    with open(f, "rb") as h:
        assert h.read() == b"abc"

    text = tmp_path / "roundtrip.txt"
    assert text.write_text("hello", encoding="utf-8") == 5
    assert text.read_text(encoding="utf-8") == "hello"

    renamed = tmp_path / "renamed.txt"
    text.replace(renamed)
    assert renamed.exists() and not text.exists()


def test_read_only_text_mode_signature_preserved(tmp_path):
    f = tmp_path / "sig.txt"
    f.write_text("x", encoding="utf-8")
    with open(f, "r", encoding="utf-8") as h:
        assert h.read() == "x"


# =========================================================================== #
# Phase 3.7 - directory creation and touch
#
# Every refusal test marks a TEMPORARY directory as deployed. If the guard were
# broken and let the call through, the worst outcome is an empty file or empty
# directory inside pytest's own tmp_path - never anything under D:\Flicks. The
# real deployed paths are pinned separately by
# test_real_production_paths_classify_without_filesystem_access.
# =========================================================================== #


def test_real_production_paths_classify_without_filesystem_access(isolation_guard):
    _real_production_strings_are_classified(isolation_guard)


def test_path_touch_refused_forbidden_target(isolation_guard, tmp_path):
    victim = tmp_path / "deployed_touch"
    victim.mkdir()
    target = victim / "created.mkv"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError, match="os.open"):
            target.touch()
    assert not target.exists(), "touch must not create the file"


def test_path_touch_exist_ok_false_semantics_preserved_on_safe_path(tmp_path):
    """The guard must not change what exist_ok=False means on a safe path."""
    fresh = tmp_path / "fresh.mkv"
    fresh.touch(exist_ok=False)
    assert fresh.exists() and fresh.stat().st_size == 0
    with pytest.raises(FileExistsError):
        fresh.touch(exist_ok=False)
    # exist_ok=True on an existing file stays a silent no-op
    fresh.touch(exist_ok=True)
    assert fresh.stat().st_size == 0


def test_os_open_write_flags_refused(isolation_guard, tmp_path):
    """Path.touch is refused because os.open is, not because touch is wrapped."""
    victim = tmp_path / "deployed_osopen"
    victim.mkdir()
    target = victim / "raw.bin"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError, match="os.open"):
            os.open(str(target), os.O_CREAT | os.O_WRONLY, 0o666)
    assert not target.exists()


def test_os_open_read_only_flags_are_never_blocked(isolation_guard, tmp_path):
    """O_RDONLY is 0, so reads must pass straight through the os.open wrapper."""
    source = tmp_path / "readable.txt"
    source.write_text("payload", encoding="utf-8")

    with isolation_guard["temporary_production_paths"](tmp_path):
        fd = os.open(str(source), os.O_RDONLY)
        try:
            assert os.read(fd, 7) == b"payload"
        finally:
            os.close(fd)


def test_path_mkdir_refused_forbidden_target(isolation_guard, tmp_path):
    victim = tmp_path / "deployed_mkdir"
    victim.mkdir()
    target = victim / "subdir"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError, match="os.mkdir"):
            target.mkdir()
    assert not target.exists(), "mkdir must not create the directory"


def test_os_mkdir_refused_forbidden_target(isolation_guard, tmp_path):
    victim = tmp_path / "deployed_osmkdir"
    victim.mkdir()
    target = victim / "subdir"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError, match="os.mkdir"):
            os.mkdir(str(target))
    assert not target.exists()


def test_os_makedirs_refused_forbidden_target(isolation_guard, tmp_path):
    """Recursive creation is refused, including the intermediate parents."""
    victim = tmp_path / "deployed_makedirs"
    victim.mkdir()
    target = victim / "a" / "b" / "c"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError, match="os.mkdir"):
            os.makedirs(str(target))
    assert not (victim / "a").exists(), "no intermediate directory may survive"


def test_makedirs_escape_into_production_is_refused(isolation_guard, tmp_path):
    """A traversal that re-enters the deployed tree cannot slip through."""
    victim = tmp_path / "deployed_escape"
    victim.mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    target = elsewhere / ".." / victim.name / "escaped"

    with isolation_guard["temporary_production_paths"](victim):
        with pytest.raises(RuntimeError):
            os.makedirs(str(target), exist_ok=True)
    assert not (victim / "escaped").exists()


def test_directory_state_unchanged_after_every_refusal(isolation_guard, tmp_path):
    """One combined check that no refusal left any trace behind."""
    victim = tmp_path / "deployed_all"
    victim.mkdir()
    keep = _sentinel(victim)
    before = sorted(p.name for p in victim.iterdir())

    with isolation_guard["temporary_production_paths"](victim):
        for call in (
            lambda: (victim / "t.bin").touch(),
            lambda: (victim / "d1").mkdir(),
            lambda: os.mkdir(str(victim / "d2")),
            lambda: os.makedirs(str(victim / "d3" / "deep")),
            lambda: os.open(str(victim / "r.bin"), os.O_CREAT | os.O_WRONLY, 0o666),
        ):
            with pytest.raises(RuntimeError):
                call()

    assert sorted(p.name for p in victim.iterdir()) == before
    assert keep.read_text(encoding="utf-8") == "original payload"


def test_valid_directory_creation_in_temporary_tree(tmp_path):
    """Safe paths keep working exactly as before the guard existed."""
    single = tmp_path / "single"
    single.mkdir()
    assert single.is_dir()

    nested = tmp_path / "a" / "b" / "c"
    os.makedirs(str(nested))
    assert nested.is_dir()


def test_makedirs_parents_true_behaviour(tmp_path):
    """parents=True builds the whole chain and leaves the root in place."""
    root = tmp_path / "root"
    root.mkdir()
    deep = root / "x" / "y" / "z"
    os.makedirs(str(deep), exist_ok=True)
    assert deep.is_dir() and root.is_dir()


def test_mkdir_parents_and_exist_ok_semantics(tmp_path):
    """Path.mkdir(parents=True, exist_ok=True) on a safe path is a no-op."""
    target = tmp_path / "p" / "q"
    target.mkdir(parents=True, exist_ok=True)
    assert target.is_dir()
    target.mkdir(parents=True, exist_ok=True)          # idempotent
    assert target.is_dir()

    leaf = target / "leaf"
    leaf.mkdir()
    with pytest.raises(FileExistsError):
        leaf.mkdir()                                   # exist_ok defaults to False
    leaf.mkdir(exist_ok=True)
    assert leaf.is_dir()


def test_mkdir_error_type_preserved_when_parent_missing(tmp_path):
    """Ordinary FileNotFoundError still surfaces - the guard only adds refusals."""
    with pytest.raises(FileNotFoundError):
        (tmp_path / "missing" / "child").mkdir()


# =========================================================================== #
# Phase 3.7 - transactional install and cooperative uninstall
# =========================================================================== #


def test_install_rolls_back_when_a_patch_fails(monkeypatch):
    """A mid-installation failure restores everything and re-raises."""
    import _write_guard as g

    real_open = g._orig["open"]          # the genuine builtin, captured at install
    real_mkdir = g._orig["os_mkdir"]     # NOT os.mkdir, which is still wrapped here

    assert g.uninstall() is True
    assert builtins.open is real_open

    class _BoomModule:
        """A stand-in module whose attribute assignment always fails."""

        def __init__(self):
            object.__setattr__(self, "boom", real_open)

        def __setattr__(self, name, value):
            raise RuntimeError("injected patch failure")

    boom = _BoomModule()
    monkeypatch.setattr(
        g,
        "_PATCHES",
        (
            ("open", builtins, "open", g._guarded_open),        # succeeds
            ("boom", boom, "boom", g._guarded_open),            # fails here
            ("os_mkdir", os, "mkdir", g._guarded_os_mkdir),     # must never be reached
        ),
    )

    try:
        with pytest.raises(RuntimeError, match="injected patch failure"):
            g.install()

        assert builtins.open is real_open, "earlier patch must be rolled back"
        assert os.mkdir is real_mkdir, "later patch must not have been applied"
        assert g.is_installed() is False
        assert g._orig == {}, "saved originals must be consistent with reality"
        assert g._patched == [], "no half-applied patch may remain recorded"
        assert g.uninstall() is False, "uninstall after a failed install is a no-op"
    finally:
        monkeypatch.undo()
        assert g.install() is True
    assert g.is_installed() is True
    assert builtins.open is g._guarded_open


def test_repeated_install_after_rollback_is_clean():
    """install() following a rollback captures the true originals again."""
    import _write_guard as g

    real_open = g._orig["open"]
    assert g.uninstall() is True
    assert g.install() is True
    assert builtins.open is g._guarded_open
    # the new install must have saved the genuine builtin, not our own wrapper
    assert g._orig["open"] is real_open
    assert g.install() is False, "still idempotent"


def test_uninstall_leaves_a_later_wrapper_intact():
    """Cooperative uninstall: another plugin's wrapper is never clobbered."""
    import _write_guard as g

    real_open = g._orig["open"]
    real_mkdir = g._orig["os_mkdir"]

    def sentinel_wrapper(*args, **kwargs):
        return "sentinel"

    assert g.uninstall() is True
    assert g.install() is True
    assert builtins.open is g._guarded_open

    builtins.open = sentinel_wrapper      # a later plugin layers on top of ours
    try:
        assert g.uninstall() is True
        assert builtins.open is sentinel_wrapper, "must not overwrite the later wrapper"
        assert "open" in g.conflicts(), "the conflict must be reported"
        assert g.is_installed() is False
        # everything we still owned was restored normally
        assert os.mkdir is real_mkdir
        assert g._orig == {}
    finally:
        # Hand the true builtin back before reinstalling, otherwise install()
        # would faithfully capture the sentinel as the "original".
        builtins.open = real_open
        assert g.install() is True

    assert g.is_installed() is True
    assert builtins.open is g._guarded_open
    assert g.conflicts() == (), "a clean install clears prior conflicts"
    assert os.mkdir is g._guarded_os_mkdir


# =========================================================================== #
# Phase 3.7 - import-only must not install
# =========================================================================== #


def test_importing_conftest_outside_pytest_does_not_install():
    """A bare ``import conftest`` must not patch globals with no teardown."""
    code = (
        "import sys; sys.path.insert(0, r'{tests}');"
        "import builtins, os, sqlite3;"
        "real = (builtins.open, os.mkdir, os.makedirs, sqlite3.connect);"
        "import conftest, _write_guard as g;"
        "print('INSTALLED', g.is_installed());"
        "print('UNTOUCHED', builtins.open is real[0], os.mkdir is real[1],"
        " os.makedirs is real[2], sqlite3.connect is real[3])"
    ).format(tests=str(TESTS_DIR))
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr
    assert "INSTALLED False" in result.stdout
    assert "UNTOUCHED True True True True" in result.stdout


def test_importing_helper_module_alone_does_not_install():
    """_write_guard on its own is inert - only conftest's hook installs."""
    code = (
        "import sys; sys.path.insert(0, r'{tests}');"
        "import builtins, os;"
        "real = (builtins.open, os.mkdir);"
        "import _write_guard as g;"
        "print('INSTALLED', g.is_installed());"
        "print('UNTOUCHED', builtins.open is real[0], os.mkdir is real[1])"
    ).format(tests=str(TESTS_DIR))
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=300,
    )
    assert result.returncode == 0, result.stderr
    assert "INSTALLED False" in result.stdout
    assert "UNTOUCHED True True" in result.stdout


def test_real_session_installs_then_removes_the_guard(tmp_path):
    """End-to-end: installed for the session, gone after pytest_unconfigure.

    Runs a real pytest session in a subprocess (the safe tmp-path-only test
    ``test_read_modes_are_never_blocked``) with a temporary plugin that reports
    the guard's state at session start and at unconfigure. The plugin lives in
    tmp_path, never in the repository.
    """
    plugin = tmp_path / "guard_lifecycle_plugin.py"
    plugin.write_text(
        "import sys\n"
        f"sys.path.insert(0, r'{TESTS_DIR}')\n"
        "def pytest_sessionstart(session):\n"
        "    import _write_guard as g\n"
        "    print('AUDIT_INSTALLED_AT_SESSION', g.is_installed())\n"
        "def pytest_unconfigure(config):\n"
        "    import _write_guard as g\n"
        "    print('AUDIT_INSTALLED_AT_UNCONFIGURE', g.is_installed())\n",
        encoding="utf-8",
    )
    env = dict(os.environ)
    env["PYTHONPATH"] = str(tmp_path) + os.pathsep + env.get("PYTHONPATH", "")
    result = subprocess.run(
        [
            sys.executable, "-m", "pytest",
            "tests/test_write_guard.py::test_read_modes_are_never_blocked",
            "-q", "-s", "-p", "guard_lifecycle_plugin",
        ],
        cwd=str(REPO_ROOT), env=env, capture_output=True, text=True, timeout=600,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "1 passed" in result.stdout
    assert "AUDIT_INSTALLED_AT_SESSION True" in result.stdout
    assert "AUDIT_INSTALLED_AT_UNCONFIGURE False" in result.stdout