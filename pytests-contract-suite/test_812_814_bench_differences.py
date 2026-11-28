"""Three differences between portuale and Portage found by the portuale.org benchmark
(`emerge --pretend` on a real machine, 2026-11-27), reduced to the fixture tree so that nothing on
that machine is needed to work on them. Backlog entries #812, #813 and #814 in
`../portuale/LLM/backlog-tasks.md` say what was seen, what is decided and what is still unknown.

Expected behaviour comes from the charter, not from Portage; Portage's answer is recorded as the
comparison. Where the reduction stands:

* #813 reproduces and is decided (owner 2026-11-28): portuale keeps the installed binding, so the
  one test pins that answer; Portage's `[ebuild rR]` is a difference accepted on purpose.
* #812: the rule the owner ruled right (2026-11-28: Portage's, an installed version with no ebuild
  is not a candidate) already holds for portuale on the fixtures, so the test passes and guards it.
  What failed on the real machine (portuale saw no ebuild of the overlay at all) is NOT reproduced
  here; the entry lists what was ruled out.
* #814 is NOT reproduced: on the fixtures portuale plans nothing, as Portage does. The test is a
  non-strict xfail that states the intended answer; see the entry for what was tried.

Every root is built here (vdb entries and a world file under `tmp_path`) over the shared fixture
repo and binhost, so the tests do not read the host. Rows are limited to the `p81*` packages so the
profile's `@system` does not leak in.
"""

import os
import re
import subprocess

import pytest

from conftest import seed_updates_record

IS_PORTUALE = os.environ.get("PMTEST_PM", "portuale") == "portuale"
ROW = re.compile(r"^\[(ebuild|binary)\s+([^\]]*?)\s*\]\s+(dev-libs/p81[^\s:]+)(?::\S*)?(?:\s+\[([^\]:]+)[^\]]*\])?")


def _root(tmp_path, world, installed):
    """A scratch ROOT: a world file and vdb entries. `installed` is a list of
    `(cat/pf, slot, {file: content})`; CATEGORY, SLOT, EAPI and repository are written for you."""
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("".join(w + "\n" for w in world))
    for cpv, slot, files in installed:
        entry = root / "var/db/pkg" / cpv
        entry.mkdir(parents=True)
        for name, text in {"CATEGORY": cpv.split("/")[0], "SLOT": slot, "EAPI": "8",
                           "repository": "testrepo", **files}.items():
            (entry / name).write_text(text + "\n")
    seed_updates_record(root)
    return root


def _plan(emerge_binary, fixture_env, root, *args):
    """The merge rows of `emerge --pretend`, as `(kind, flags, cpv, replaced version or None)`."""
    env = dict(fixture_env, ROOT=str(root), PORTAGE_RUNNING_ROOT=str(root))
    run = subprocess.run([str(emerge_binary), "--pretend", "--verbose", *args],
                         capture_output=True, text=True, env=env, check=False)
    assert run.returncode == 0, run.stderr
    return [m.groups() for m in map(ROW.match, run.stdout.splitlines()) if m]


# --- #812: the installed version has no ebuild left ---------------------------------------------
#
# Real case: games-util/steam-launcher. Installed 1.0.0.87-r1; the overlay now has 1.0.0.87 and
# older, and the binhost still serves a 1.0.0.87-r1 binary. Portage (`_emerge/depgraph.py`,
# "If the ebuild no longer exists ... reject built instances (installed or binary)") drops both
# built instances, so `-u` plans `[ebuild UD] 1.0.0.87 [1.0.0.87-r1]`; the owner agrees (2026-11-28).
# On the fixtures portuale does the same, so this guards the rule. On the real machine portuale
# planned nothing, but because it found no ebuild of that overlay at all ("there are no ebuilds to
# satisfy"), a cause these fixtures do not reproduce: see backlog #812.

@pytest.mark.parametrize("opts", [["--getbinpkg=n", "--usepkg=n"], ["--getbinpkg"]],
                         ids=["no-binary", "binhost-has-the-installed-version"])
@pytest.mark.parametrize("target", ["dev-libs/p812orphan", "@world"])
def test_812_an_installed_version_without_an_ebuild_is_not_a_candidate(
        emerge_binary, fixture_env, tmp_path, opts, target):
    """Charter property 3 as the owner reads it: the best visible version wins, and a version no
    repository can build is not visible. Installed `p812orphan-1.0-r1`, tree `1.0` only."""
    root = _root(tmp_path, ["dev-libs/p812orphan"], [("dev-libs/p812orphan-1.0-r1", "0", {})])
    rows = _plan(emerge_binary, fixture_env, root, "--update", "--deep", *opts, target)
    assert rows == [("ebuild", "UD", "dev-libs/p812orphan-1.0", "1.0-r1")], rows


# --- #813: a `:=` binding recorded on one slot while a higher slot is installed ------------------
#
# Real case: dev-python/psycopg built against dev-db/postgresql:18/18=, with postgresql 18.7 and
# 19.0 both installed and 19 the highest visible slot. The ebuild's `>=postgresql-8.1:=` now
# resolves to slot 19. Portage rebuilds psycopg (`[ebuild rR]`) so the binding follows; portuale
# keeps it, slot 18 being installed and satisfying the atom. The installed system is consistent
# either way. Owner 2026-11-28: keep portuale's behaviour. Related: the stale-binding family of #766 and upstream bug 439694.

def _root_813(tmp_path):
    return _root(tmp_path, ["dev-libs/p813user"], [
        ("dev-libs/p813prov-18.7", "18", {}),
        ("dev-libs/p813prov-19.0", "19", {}),
        ("dev-libs/p813user-1.0", "0",
         {"RDEPEND": ">=dev-libs/p813prov-1:18/18=", "DEPEND": ">=dev-libs/p813prov-1:18/18="}),
    ])


_OPTS_813 = ["--update", "--deep", "--getbinpkg=n", "--usepkg=n", "@world"]


@pytest.mark.skipif(not IS_PORTUALE, reason="pins portuale's current answer")
def test_813_today_portuale_keeps_the_holder_built_against_the_older_slot(emerge_binary, fixture_env, tmp_path):
    """Owner decision 2026-11-28: keep the installed binding. The system is consistent either way
    (slot 18 is installed and satisfies the atom), so no rebuild is planned; Portage plans
    `[ebuild rR]` here, a difference accepted on purpose."""
    assert _plan(emerge_binary, fixture_env, _root_813(tmp_path), *_OPTS_813) == []


# --- #814: a binary built with a different IUSE than the installed copy and the tree -------------
#
# Real case: sci-libs/gdal. The installed copy and the tree ebuild both have `mongodb` in IUSE (off);
# binhost builds 5 to 13 were made without it. With `--newuse --getbinpkg`, portuale compares the
# binary with the installed copy, sees a flag removed from IUSE, and plans `[binary Rg]`. Portage
# plans nothing: it ends up on the tree ebuild, which matches what is installed. The enabled USE is
# identical in both, so nothing the user gets would change. NOT reproduced here (backlog #814 closed
# as not reproducible):
# the fixture below is what was tried, and portuale plans nothing on it (backlog #814).

def _root_814(tmp_path):
    return _root(tmp_path, ["dev-libs/p814tool"], [
        ("dev-libs/p814tool-1.0", "0", {"IUSE": "p814old", "USE": ""}),
    ])


_OPTS_814 = ["--update", "--deep", "--newuse", "--getbinpkg", "--usepkg", "dev-libs/p814tool"]


@pytest.mark.xfail(
    IS_PORTUALE, strict=False,
    reason="#814 is not reproduced: the real machine shows `[binary Rg]` for sci-libs/gdal, these "
    "fixtures plan nothing, so this passes today. Backlog #814 is closed as not reproducible; "
    "reopen it only with a real case",
)
def test_814_portage_ignores_a_binary_whose_iuse_differs_from_the_tree(emerge_binary, fixture_env, tmp_path):
    """Comparison: Portage's answer. Delete if the owner decides `--newuse` should act on the binary."""
    assert _plan(emerge_binary, fixture_env, _root_814(tmp_path), *_OPTS_814) == []
