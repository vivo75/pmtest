"""Charter property 1: `mrg --check-world` must notice damage to the tree.

`differential-test-bed/compare/check-world-mutants.py` breaks a copy of the
fixture tree one way at a time and requires the check to report it. The
expected findings come from the mutation itself (a change that removes the
only satisfying version must give NO MATCH), never from Portage.
"""

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
SCRIPT = ROOT / "differential-test-bed/compare/check-world-mutants.py"


def load():
    spec = importlib.util.spec_from_file_location("check_world_mutants", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_every_mutant_is_killed_and_the_control_changes_nothing(mrg_binary, tmp_path):
    cwm = load()
    results, ok = cwm.run(FIXTURES, [str(mrg_binary)], tmp_path)
    assert ok, [r for r in results if not r["good"]]
    assert [r["operator"] for r in results] == [
        "mask_best", "drop_keyword", "raise_bound", "remove_package", "unreadable", "harmless"]
    assert all(r["changed"] for r in results), results


def test_the_clean_copy_gives_the_result_of_the_original_tree(mrg_binary, tmp_path):
    cwm = load()
    first = cwm.check(FIXTURES, [str(mrg_binary)])
    copy = cwm.copy_tree(FIXTURES, tmp_path / "copy")
    assert cwm.check(copy, [str(mrg_binary)]) == first
    assert first[0] == 0 and first[2]["unsatisfiable"] == 0


def test_a_mutation_that_changes_nothing_is_an_error_not_a_kill(mrg_binary, tmp_path):
    cwm = load()
    noop = cwm.Operator("noop", "dev-libs/newpkg", lambda tree: None)
    results, ok = cwm.run(FIXTURES, [str(mrg_binary)], tmp_path, [noop])
    assert not ok and results[0]["changed"] == [] and not results[0]["good"]


def test_a_mutant_the_check_does_not_report_survives(mrg_binary, tmp_path):
    """A real change the check cannot see (a comment in an ebuild, cache
    untouched is still read) is reported as surviving, so exit code 1."""
    cwm = load()

    def comment_only(tree):
        p = tree / "etc/portage/package.mask"
        p.write_text(p.read_text() + "\n# nothing\n")

    survivor = cwm.Operator("survivor", "dev-libs/newpkg", comment_only)
    results, ok = cwm.run(FIXTURES, [str(mrg_binary)], tmp_path, [survivor])
    assert not ok and results[0]["changed"] and not results[0]["good"]
