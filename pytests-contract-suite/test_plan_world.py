"""`mrg --plan-world[=update|emptytree]` on the fixture world. Expected behaviour comes from the
charter, not from Portage (`--plan-world` does not exist there): property 5 (a message names what
it did and what it did not do), property 1 (the JSON plan is one the health checker can judge),
and the PMS (`dependencies.tex`: everything is built, so every build-time edge binds)."""

import re
import shutil
import subprocess

import health_checker as hc
import pytest
from conftest import fixtures_copytree_ignore, seed_updates_record


def _plan(mrg_binary, fixture_env, *args):
    return subprocess.run(
        [str(mrg_binary), "--plan-world", *args],
        capture_output=True, text=True, env=fixture_env, check=False,
    )


def test_plan_world_update_says_on_stderr_what_it_did_not_check(mrg_binary, fixture_env):
    """Charter property 5: two stderr lines, the count and the order, then what was not looked
    at and the command that does look; stdout is the rows and nothing else."""
    run = _plan(mrg_binary, fixture_env, "--sort", "depend")
    assert run.returncode == 0, run.stderr
    assert run.stderr == (
        "plan-world: 4 to install (4 builds including 0 bootstrap), order depend\n"
        "not checked: blockers, REQUIRED_USE, slot conflicts, USE rebuilds; "
        "run 'mrg -puDN @world' for the full plan\n"
    )
    assert run.stdout.splitlines() == [
        "[ebuild  N     ] dev-libs/innernestedsetpkg-1.0:0",
        "[ebuild  N     ] dev-libs/newpkg-1.0:0",
        "[ebuild     U  ] dev-libs/upgradepkg-2.0:0 [1.0]",
        "[ebuild  N     ] dev-libs/withdeps-1.0:0",
    ]


def test_plan_world_with_the_mode_named_is_the_bare_plan(mrg_binary, fixture_env):
    """Owner decision Q1 of plan 02.692: a bare `--plan-world` is `--plan-world=update`."""
    bare = _plan(mrg_binary, fixture_env, "--sort", "depend")
    named = subprocess.run(
        [str(mrg_binary), "--plan-world=update", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False,
    )
    assert (named.returncode, named.stdout, named.stderr) == (0, bare.stdout, bare.stderr)


def test_plan_world_emptytree_lists_every_reached_slot_and_names_its_full_plan(mrg_binary, fixture_env):
    """Charter property 5 and the PMS: everything is built, so a kept version is an `R` row, and
    the stderr line names `mrg -pe @world`, with no USE rebuilds left to mention."""
    run = subprocess.run(
        [str(mrg_binary), "--plan-world=emptytree", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False,
    )
    assert run.returncode == 0, run.stderr
    rows = run.stdout.splitlines()
    assert "[ebuild   R    ] dev-libs/systempkg-1.0:0" in rows
    assert "[ebuild     U  ] dev-libs/upgradepkg-2.0:0 [1.0]" in rows
    assert all(r.startswith("[ebuild") for r in rows)
    assert run.stderr == (
        f"plan-world: {len(rows)} to install ({len(rows)} builds including 0 bootstrap), order depend\n"
        "not checked: blockers, REQUIRED_USE, slot conflicts; "
        "run 'mrg -pe @world' for the full plan\n"
    )


def test_plan_world_unknown_mode_is_a_usage_error_naming_both(mrg_binary, fixture_env):
    """Charter property 5: the message names the two modes that exist."""
    run = subprocess.run([str(mrg_binary), "--plan-world=full"],
                         capture_output=True, text=True, env=fixture_env, check=False)
    assert (run.returncode, run.stdout) == (2, "")
    assert "update" in run.stderr and "emptytree" in run.stderr, run.stderr


def test_plan_world_emptytree_json_is_a_plan_the_checker_loads(mrg_binary, fixture_env):
    """Charter property 1: a kept version is a `reinstall` entry, is not repeated in `kept`, and
    the checker finds nothing wrong that the installed system did not have already."""
    run = subprocess.run(
        [str(mrg_binary), "--plan-world=emptytree", "--json", "--sort", "depend"],
        capture_output=True, text=True, env=fixture_env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert run.returncode == 0 and doc is not None, run.stdout + run.stderr
    assert len(run.stdout.splitlines()) == 1
    by_package = {e["package"]: e["outcome"] for e in doc["entries"]}
    assert by_package["systempkg"] == "reinstall" and by_package["upgradepkg"] == "upgrade"
    assert "systempkg" not in {k["package"] for k in doc["kept"]}
    assert [e["merge_order"] for e in doc["entries"]] == list(range(len(doc["entries"])))
    vdb = hc.Path(fixture_env["ROOT"]) / "var/db/pkg"
    found = [f for f in hc.check_document(doc, vdb) if f.is_failure and not f.pre_existing]
    assert found == [], found


def test_740_the_plan_takes_the_newest_arm(mrg_binary, fixture_env, tmp_path):
    """Charter property 3 (backlog #740): the fast plan takes the `||` arm whose atoms the
    best visible candidates match, so the compat package is new and the provider upgrades
    instead of staying pinned to the installed sub-slot. A CASES/`emerge` pin is the wrong
    shape: this is the fast plan, not `emerge`."""
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("dev-libs/w740user\ndev-libs/w740sudo\n")
    for pf, slot in (("dev-libs/w740prov-3", "0/3"), ("dev-libs/w740sudo-1", "0")):
        vdb = root / "var/db/pkg" / pf
        vdb.mkdir(parents=True)
        (vdb / "CATEGORY").write_text("dev-libs\n")
        (vdb / "SLOT").write_text(f"{slot}\n")
        (vdb / "EAPI").write_text("8\n")
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    run = subprocess.run(
        [str(mrg_binary), "--plan-world"],
        capture_output=True, text=True, env=env, check=False,
    )
    assert run.returncode == 0, run.stderr
    assert "[ebuild  N     ] dev-libs/w740compat-3:3" in run.stdout.splitlines(), run.stdout
    assert "[ebuild     U  ] dev-libs/w740prov-4:0 [3]" in run.stdout.splitlines(), run.stdout


# --- backlog #766: the fast plan and the resolver judge stale slot-operator bindings ---------------
#
# Two implementations of one PMS rule (`sec:slot-dep`: a `:=` dependency recorded on `prov:0/5.42`
# breaks when the plan leaves `prov` on another sub-slot), over two data models. Decision (owner,
# 2026-11-16, plan `LLM/02.766-stale-rule-one-place.opus.md`): keep both and pin their agreement
# here. Comparison key: the consumer `cat/pkg`. Atom and provider are compared per consumer and
# reported apart. "Reinstalls" are the `reinstall` rows of installed packages whose VDB entry records
# a slot-operator binding with a sub-slot: the fast plan answers `-uD`, the resolver `-uDN`, so other
# `--newuse` reinstalls are not stale consumers. Agreement pins take their expected sets from how the
# root is built (PMS rule + the #761 ruling); DIFFERENCE pins record current behaviour exactly, with
# the gate class and the residue in the id (plan 02.766, `before/classes.txt`).

_BIND_766 = "dev-libs/p569prov:0/5.42="
_PIN_766 = "=dev-libs/p569prov-5.42* " + _BIND_766
_NEW_766 = "dev-libs/p569prov-5.44"
# Roots: name -> (world atoms added, installed entries added as (cpv, RDEPEND, DEPEND)).
_ROOTS_766 = {
    "ctl": ([], []),
    "prov": (["dev-libs/p569prov"], []),
    "r698": (
        ["dev-libs/p698rebuild", "dev-libs/p698reinst", "dev-libs/p698upg"],
        [("dev-libs/p698rebuild-1", _BIND_766, ""), ("dev-libs/p698reinst-1", _PIN_766, ""),
         ("dev-libs/p698upg-1", _PIN_766, "")],
    ),
    "r703": (
        ["dev-libs/p698rebuild", "dev-libs/p573virt"],
        [("dev-libs/p698rebuild-1", _BIND_766, ""), ("dev-libs/p698reinst-1", _PIN_766, ""),
         ("dev-libs/p698upg-1", _PIN_766, ""), ("dev-libs/p573virt-1", _PIN_766, "")],
    ),
    "bdw": (["dev-libs/p569prov", "dev-libs/p698rebuild"], [("dev-libs/p698rebuild-1", "", _BIND_766)]),
    "pull": (["dev-libs/p569pull"], [("dev-libs/p573virt-1", _PIN_766, "")]),
    "gone": (["dev-libs/p569prov"], [("dev-libs/p766gone-1", _BIND_766, "")]),
    "unred": (
        ["dev-libs/p569prov", "dev-libs/p698rebuild"],
        [("dev-libs/p698rebuild-1", "|| ( " + _BIND_766, "")],
    ),
}
_VIRT_FAST_766 = ("dev-libs/p569virt", _BIND_766, None)  # D1: outside the walk, null provider
_VIRT_RES_766 = ("dev-libs/p569virt", "=dev-libs/p569prov-5.42*", _NEW_766)


def _root_766(fixture_env, tmp_path, name):
    """A scratch ROOT mirroring `_698_root`: the shared vdb plus installed consumers that recorded
    a binding on the provider's old sub-slot; the updates record is seeded so `--pretend` applies
    no global update to it."""
    world, installed = _ROOTS_766[name]
    root = tmp_path / "root"
    shutil.copytree(fixture_env["ROOT"] + "/var", root / "var", symlinks=True,
                    ignore=fixtures_copytree_ignore())
    wfile = root / "var/lib/portage/world"
    wfile.write_text(wfile.read_text() + "".join(f"{w}\n" for w in world))
    seed_updates_record(root)
    for cpv, rdepend, depend in installed:
        entry = root / "var/db/pkg" / cpv
        entry.mkdir(parents=True)
        for key, text in (("CATEGORY", cpv.split("/")[0]), ("EAPI", "8"), ("SLOT", "0"),
                          ("repository", "testrepo"), ("RDEPEND", rdepend)):
            (entry / key).write_text(text + "\n")
        if depend:
            (entry / "DEPEND").write_text(depend + "\n")
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    return env


def _cp_766(cpv):
    return re.sub(r"-\d.*$", "", cpv)


def _bound_766(root):
    """Installed cps whose VDB entry records a `:slot/sub=` binding in any dependency key."""
    found = set()
    for entry in (root / "var/db/pkg").glob("*/*"):
        text = " ".join((entry / k).read_text() for k in ("DEPEND", "RDEPEND", "PDEPEND", "BDEPEND", "IDEPEND")
                        if (entry / k).exists())
        if re.search(r":[^\s/]+/[^\s=]+=", text):
            found.add(entry.parent.name + "/" + _cp_766(entry.name))
    return found


def _view_766(doc, bound, resolver):
    """(refusal rows, stale reinstalls) of one plan document, rows as (consumer cp, atom, provider)."""
    rows = {(_cp_766(r["consumer"]) if resolver else r["consumer"], r["atom"], r["provider"])
            for r in doc.get("stale-bindings", [])}
    reinstalls = {e["category"] + "/" + e["package"] for e in doc["entries"] if e.get("outcome") == "reinstall"}
    return rows, reinstalls & bound


def _differences_766(fast, resolver):
    """What the two views disagree on, at the consumer key: {} means the plans agree."""
    (frows, freinst), (rrows, rreinst) = fast, resolver
    fcons, rcons = {r[0] for r in frows}, {r[0] for r in rrows}
    found = {"consumers only the fast plan names": fcons - rcons,
             "consumers only the resolver names": rcons - fcons,
             "stale reinstalls only the fast plan lists": freinst - rreinst,
             "stale reinstalls only the resolver lists": rreinst - freinst}
    return {k: sorted(v) for k, v in found.items() if v}


def _both_766(mrg_binary, emerge_binary, env, solver, extra=()):
    """The fast plan and the resolver's `-uDN @world` on one ROOT as parsed documents; the pubgrub
    run must carry the closure trace, the default run none (the lesson of #765/#767)."""
    fast = subprocess.run([str(mrg_binary), "--plan-world", "--json", "--sort", "depend"],
                          capture_output=True, text=True, env=env, check=False)
    argv = [str(emerge_binary), *(["--solver=pubgrub"] if solver else []), "--pretend", "--json", "--update",
            "--deep", "--newuse", "--getbinpkg=n", *extra, "@world"]
    res = subprocess.run(argv, capture_output=True, text=True, check=False,
                         env={**env, "PORTUALE_PG_TRACE": "1"} if solver else env)
    for run in (fast, res):
        assert run.returncode == 0, (run.stdout, run.stderr)
    assert bool(re.search(r"^pg-", res.stderr, re.M)) == bool(solver), res.stderr[:300]
    docs = [hc.parse_json_output(run.stdout) for run in (fast, res)]
    assert all(d is not None for d in docs), (fast.stdout[:200], res.stdout[:200])
    return docs


_SOLVERS_766 = [pytest.param("", id="default"), pytest.param("pubgrub", id="pubgrub")]


@pytest.mark.parametrize("solver", _SOLVERS_766)
@pytest.mark.parametrize("name, consumers, reinstalls", [
    pytest.param("ctl", set(), set(), id="ctl-nothing-stale"),
    pytest.param("r703", set(), set(), id="r703-provider-held-back"),
    # D1 makes the row text differ (fast: null provider), but both name the same consumer.
    pytest.param("prov", {"dev-libs/p569virt"}, set(), id="prov-consumer-outside-the-walk"),
    # A consumer inside the walk with the binding in DEPEND: both rebuild it.
    pytest.param("bdw", {"dev-libs/p569virt"}, {"dev-libs/p698rebuild"}, id="bdw-consumer-inside-the-walk"),
])
def test_766_the_two_plans_agree_on_the_stale_consumers(
    mrg_binary, emerge_binary, fixture_env, tmp_path, solver, name, consumers, reinstalls
):
    """Backlog #766, charter property 1 (a `:=` binding the plan breaks is repaired or said) and
    property 5 (named): on these roots `mrg --plan-world` and `emerge -puDN @world` (both solvers)
    name the same stale consumers and rebuild the same ones, from PMS `sec:slot-dep` and the #761
    ruling. The expected sets are explicit, so an empty agreement cannot pass for a real one; `prov`
    and `bdw` are the non-empty witnesses. No root makes both sides print the same refusal ROW from
    inside the walk: a consumer the resolver refuses is outside the @world walk, where the fast
    plan prints a null provider (D1, #768); inside the walk the fast plan's hold-back refusal is
    what the resolver reinstalls (D-698, #769)."""
    env = _root_766(fixture_env, tmp_path, name)
    root = tmp_path / "root"
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver)
    bound = _bound_766(root)
    fast, res = _view_766(fast_doc, bound, False), _view_766(res_doc, bound, True)
    assert _differences_766(fast, res) == {}
    assert {r[0] for r in fast[0]} == consumers and fast[1] == reinstalls, fast


# (fast refusals, fast reinstalls, resolver refusals, resolver reinstalls) per root and solver.
_PINS_766 = {
    "r698": (
        {_VIRT_FAST_766, ("dev-libs/p698reinst", "=dev-libs/p569prov-5.42*", _NEW_766)},
        {"dev-libs/p698rebuild"},
        {_VIRT_RES_766}, {"dev-libs/p698rebuild", "dev-libs/p698reinst"},
    ),
    "gone": ({_VIRT_FAST_766, ("dev-libs/p766gone", _BIND_766, None)}, set(), {_VIRT_RES_766}, set()),
    "unred": (
        {_VIRT_FAST_766, ("dev-libs/p698rebuild", _BIND_766, _NEW_766)}, set(),
        {_VIRT_RES_766}, {"dev-libs/p698rebuild"},
    ),
    "pull": (
        {("dev-libs/p573virt", _BIND_766, None)}, {"dev-libs/p569virt"},
        {("dev-libs/p573virt", "=dev-libs/p569prov-5.42*", _NEW_766)}, {"dev-libs/p569virt"},
    ),
    "bdw": ({_VIRT_FAST_766}, {"dev-libs/p698rebuild"}, {_VIRT_RES_766}, set()),
}


@pytest.mark.parametrize("solver", _SOLVERS_766)
@pytest.mark.parametrize("name, extra, klass", [
    # D-698: the fast plan refuses what the resolver's holder route reinstalls (#769).
    pytest.param("r698", (), "D-698", id="r698-D-698"),
    # A1: the fast plan names a consumer that has no ebuild; the resolver is silent (#768).
    pytest.param("gone", (), "A1", id="gone-A1"),
    # A3/A3b: the fast plan refuses a recorded text that does not reduce ("not satisfied by"),
    # the resolver is silent on it and reinstalls the consumer from its tree text (#768).
    pytest.param("unred", (), "A3", id="unred-A3"),
    # S: the default solver files the `rR` of a walked stale consumer, pubgrub does not (#770).
    pytest.param("pull", (), "S", id="pull-S"),
    # A4: under --usepkg bdeps are off, so the resolver does not read DEPEND (#769).
    pytest.param("bdw", ("--usepkg",), "A4", id="bdw-usepkg-A4"),
])
def test_766_the_known_differences_are_pinned_exactly(
    mrg_binary, emerge_binary, fixture_env, tmp_path, solver, name, extra, klass
):
    """Backlog #766: the differences between the fast plan and the resolver that probes found
    (`LLM/evidence/02.766/before/classes.txt`), each as the exact fast set and the exact resolver
    set. These pins record CURRENT behaviour, not what is right: a change to either side moves a
    pin and has to be judged, not absorbed. Every refusal row of a consumer outside the @world walk
    carries the fast plan's D1 text (null provider, "no visible ebuild" although the ebuild is
    visible; #768). Class S differs only on pubgrub: there the resolver set has no reinstall (the two plans agree
    on the default solver)."""
    env = _root_766(fixture_env, tmp_path, name)
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver, extra)
    bound = _bound_766(tmp_path / "root")
    fast, res = _view_766(fast_doc, bound, False), _view_766(res_doc, bound, True)
    frows, freinst, rrows, rreinst = _PINS_766[name]
    if klass == "S" and solver:  # pubgrub schedules no rebuild of the walked consumer
        rreinst = set()
    assert fast == (frows, freinst), fast
    assert res == (rrows, rreinst), res


def test_766_the_agreement_check_can_fail():
    """A self-test of the comparison: documents that differ are reported, so a green agreement
    test is not vacuous. Hand-made views, no program run."""
    row = ("a/b", "c/d:0/1=", None)
    assert _differences_766(({row}, {"a/b"}), ({row}, {"a/b"})) == {}
    assert _differences_766(({row}, set()), (set(), set())) == {
        "consumers only the fast plan names": ["a/b"]}
    assert _differences_766((set(), set()), ({row}, {"x/y"})) == {
        "consumers only the resolver names": ["a/b"],
        "stale reinstalls only the resolver lists": ["x/y"]}
