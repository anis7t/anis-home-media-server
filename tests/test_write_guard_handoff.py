"""The write guard must read the production-path set it was given, not a guess.

Root cause of 18 "DID NOT RAISE RuntimeError" failures in the full suite (while
the guard was installed, working, and correctly classifying D:/Flicks):

    tests/conftest.py and tests/integration/conftest.py share a basename and neither
    directory has __init__.py, so pytest registers BOTH under the module name
    "conftest". sys.modules["conftest"] is whichever was imported last.
    _write_guard._production_paths() looked the set up by that name, got a module with
    no _PRODUCTION_PATHS, and silently fell back to its own set - so every path added
    through temporary_production_paths() was invisible to the guard.

The guard now takes the set by explicit handoff at session start. These tests pin
that contract without needing pytest's collection order to reproduce the collision.
"""
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import _write_guard


class ProductionPathHandoffTests(unittest.TestCase):
    def setUp(self):
        self._prev = _write_guard._PRODUCTION_PATHS_OVERRIDE
        self.addCleanup(self._restore)

    def _restore(self):
        _write_guard.set_production_paths(self._prev)

    def test_override_is_preferred_over_sys_modules(self):
        sentinel = {Path("Z:/only/in/the/handover")}
        _write_guard.set_production_paths(sentinel)
        self.assertEqual(_write_guard._production_paths(), sentinel)

    def test_held_reference_is_live_so_temporary_additions_are_visible(self):
        """A copy would silently break temporary_production_paths()."""
        held = {Path("Z:/base")}
        _write_guard.set_production_paths(held)
        held.add(Path("Z:/added/later"))
        active = _write_guard._production_paths()
        self.assertIn(Path("Z:/added/later"), active,
                      "the guard must observe mutations to the object it was given")
        self.assertIs(active, held)

    def test_falls_back_when_nothing_handed_over(self):
        _write_guard.set_production_paths(None)
        active = _write_guard._production_paths()
        self.assertTrue(active, "must still classify something when unconfigured")

    def test_ambiguous_conftest_module_is_not_trusted_over_handover(self):
        """The collision itself: a foreign 'conftest' in sys.modules is ignored."""
        sentinel = {Path("Z:/handover/wins")}
        _write_guard.set_production_paths(sentinel)

        impostor = types.ModuleType("conftest")          # no _PRODUCTION_PATHS
        impostor.__file__ = r"C:\somewhere\else\conftest.py"
        previous = sys.modules.get("conftest")
        sys.modules["conftest"] = impostor
        try:
            active = _write_guard._production_paths()
            self.assertIs(active, sentinel,
                          "a same-named module in sys.modules must not displace the "
                          "explicitly handed-over set")
        finally:
            if previous is not None:
                sys.modules["conftest"] = previous
            else:
                sys.modules.pop("conftest", None)

    def test_deployed_paths_classify_through_the_handover(self):
        held = {Path("D:/Flicks"), Path("E:/MediaServer/cache")}
        _write_guard.set_production_paths(held)
        self.assertTrue(_write_guard._is_production(Path("D:/Flicks/movie.mkv")))
        self.assertFalse(_write_guard._is_production(Path("Z:/somewhere/else")))


if __name__ == "__main__":
    unittest.main()
