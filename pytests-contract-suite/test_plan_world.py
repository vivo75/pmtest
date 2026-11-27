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
    "outr": (["dev-libs/p569prov"], [("dev-libs/p698rebuild-1", _BIND_766, "")]),
    "outpin": (["dev-libs/p569prov"], [("dev-libs/p698reinst-1", _PIN_766, "")]),
    "bdout": (["dev-libs/p569prov"], [("dev-libs/p698rebuild-1", "", _BIND_766)]),
    "unred": (
        ["dev-libs/p569prov", "dev-libs/p698rebuild"],
        [("dev-libs/p698rebuild-1", "|| ( " + _BIND_766, "")],
    ),
    "a10": (["dev-libs/p569prov"], [("dev-libs/p573virt-1", _BIND_766, "")]),
    # #774: the only version of the holder that accepts the new provider is keyword-masked.
    "w774": (["dev-libs/p569prov", "dev-libs/p774mask"], [("dev-libs/p774mask-1", _PIN_766, "")]),
    # #775: installed 1 accepts the new provider; the newest visible version, 2, still pins the old one.
    "w775": (["dev-libs/p569prov", "dev-libs/p775pick"], [("dev-libs/p775pick-1", _PIN_766, "")]),
}
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


_PULL_766 = ("dev-libs/p573virt", "=dev-libs/p569prov-5.42*", _NEW_766)
_REINST_PIN_766 = ("dev-libs/p698reinst", "=dev-libs/p569prov-5.42*", _NEW_766)
_VIRT_766 = "dev-libs/p569virt"
# Owner decision 2026-11-22: the shared VDB's p569virt-1, stale outside the walk, records
# `|| ( =…5.42* … ~dev-libs/p569core-1.0 )`. The fast plan reads that `||` best-visible first,
# finds no pin and rebuilds it (with p569core); the resolver reads it installed-first and
# refuses on `=…5.42*` (residue #793). This is the only difference on these roots.
_VIRT_DIFF_768 = {"consumers only the resolver names": [_VIRT_766],
                  "stale reinstalls only the fast plan lists": [_VIRT_766]}


@pytest.mark.parametrize("solver", _SOLVERS_766)
@pytest.mark.parametrize("name, rows, reinstalls, virt", [
    pytest.param("ctl", set(), set(), False, id="ctl-nothing-stale"),
    pytest.param("r703", set(), set(), False, id="r703-provider-held-back"),
    # A recorded pin the tree ebuild lets go: both reinstall it (owner Q4(a), #769).
    pytest.param("r698", set(), {"dev-libs/p698rebuild", "dev-libs/p698reinst"}, True, id="r698-holder-route"),
    # Only the p569virt difference (owner decision 2026-11-22).
    pytest.param("prov", set(), set(), True, id="prov-consumer-outside-the-walk"),
    # A consumer inside the walk with the binding in DEPEND: both rebuild it.
    pytest.param("bdw", set(), {"dev-libs/p698rebuild"}, True, id="bdw-consumer-inside-the-walk"),
    # A recorded text that does not reduce: the tree decides on both sides (owner Q3(a)).
    pytest.param("unred", set(), {"dev-libs/p698rebuild"}, True, id="unred-tree-decides"),
    # Outside the walk, nothing holds it back: both rebuild it (owner Q1(a)).
    pytest.param("outr", set(), {"dev-libs/p698rebuild"}, True, id="outr-rebuilt-outside-the-walk"),
    # Outside the walk, binding only in DEPEND: silent on both sides (Q-A (i)).
    pytest.param("bdout", set(), set(), True, id="bdout-depend-only-outside"),
    # Outside the walk with a recorded pin and no `||`: refused on both sides, the tree is not asked.
    pytest.param("outpin", {_REINST_PIN_766}, set(), True, id="outpin-pin-outside"),
    pytest.param("pull", {_PULL_766}, {_VIRT_766}, False, id="pull-walked-consumer"),
    # A consumer with no ebuild left: both name it (owner Q2(b)); the rows differ by contract.
    pytest.param("gone", None, set(), True, id="gone-no-ebuild"),
])
def test_766_the_two_plans_agree_on_the_stale_consumers(
    mrg_binary, emerge_binary, fixture_env, tmp_path, solver, name, rows, reinstalls, virt
):
    """Backlog #766, #768: charter property 1 (a `:=` binding the plan breaks is repaired or
    said) and property 5 (named). On these roots `mrg --plan-world` and `emerge -puDN @world`
    (both solvers) print the same refusal ROWS (consumer, atom, provider) and rebuild the same
    consumers, except, where `virt` is set, the shared VDB's out-of-walk `p569virt-1`: the fast
    plan rebuilds it and the resolver refuses it (owner decision 2026-11-22, residue #793).
    Expected sets come from how each root is built (PMS `sec:slot-dep`) and from the owner's
    decisions of 2026-11-16 (Q1(a), Q3(a), Q-A (i)) and 2026-11-22, not from either program."""
    env = _root_766(fixture_env, tmp_path, name)
    root = tmp_path / "root"
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver)
    bound = _bound_766(root)
    fast, res = _view_766(fast_doc, bound, False), _view_766(res_doc, bound, True)
    assert _differences_766(fast, res) == (_VIRT_DIFF_768 if virt else {})
    extra_fast = {_VIRT_766} if virt else set()
    extra_res = {_VIRT_RES_766} if virt else set()
    if rows is None:  # `gone`: the fast plan says "no visible ebuild" (null provider), the resolver names the provider
        assert fast == ({("dev-libs/p766gone", _BIND_766, None)}, reinstalls | extra_fast), fast
        assert res == ({("dev-libs/p766gone", _BIND_766, _NEW_766)} | extra_res, reinstalls), res
    else:
        assert fast == (rows, reinstalls | extra_fast), fast
        assert res == (rows | extra_res, reinstalls), res
    if virt:  # the fast plan's rebuild can be built: the arm package is in the plan
        assert any(e["category"] + "/" + e["package"] == "dev-libs/p569core" and e.get("outcome") == "new"
                   for e in fast_doc["entries"]), fast_doc["entries"]


# (fast refusals, fast reinstalls, resolver refusals, resolver reinstalls) per root and solver.
_PINS_766 = {
    "bdw": (set(), {"dev-libs/p698rebuild", _VIRT_766}, {_VIRT_RES_766}, set()),
}


@pytest.mark.parametrize("solver", _SOLVERS_766)
@pytest.mark.parametrize("name, extra, klass", [
    # A4: under --usepkg bdeps are off, so the resolver does not read DEPEND (#769). Kept on purpose (owner Q5(c)):
    # --usepkg can mix prebuilt and to-be-built packages, a clean rule would hold only for --usepkgonly.
    pytest.param("bdw", ("--usepkg",), "A4", id="bdw-usepkg-A4"),
])
def test_766_the_known_differences_are_pinned_exactly(
    mrg_binary, emerge_binary, fixture_env, tmp_path, solver, name, extra, klass
):
    """Backlog #766: the differences between the fast plan and the resolver that probes found
    (`LLM/evidence/02.766/before/classes.txt`), each as the exact fast set and the exact resolver
    set. These pins record CURRENT behaviour, not what is right: a change to either side moves a
    pin and has to be judged, not absorbed."""
    env = _root_766(fixture_env, tmp_path, name)
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver, extra)
    bound = _bound_766(tmp_path / "root")
    fast, res = _view_766(fast_doc, bound, False), _view_766(res_doc, bound, True)
    frows, freinst, rrows, rreinst = _PINS_766[name]
    assert fast == (frows, freinst), fast
    assert res == (rrows, rreinst), res


@pytest.mark.parametrize("solver", _SOLVERS_766)
def test_768_a_stale_consumer_with_no_ebuild_is_named(emerge_binary, fixture_env, tmp_path, solver):
    """Backlog #768, owner decision Q2(b) of 2026-11-16, charter property 5 (the cause is named):
    an installed package whose `:=` binding the plan breaks and that has no ebuild left cannot be
    rebuilt, so `emerge -puDN @world` names it in the stale-binding NOTE and in `--json`, on both
    solvers. The expected text is the owner's wording, not Portage's (Portage prints nothing)."""
    env = _root_766(fixture_env, tmp_path, "gone")
    argv = [str(emerge_binary), *(["--solver=pubgrub"] if solver else []), "--pretend", "--update",
            "--deep", "--newuse", "--getbinpkg=n"]
    text = subprocess.run([*argv, "@world"], capture_output=True, text=True, env=env, check=False)
    assert text.returncode == 0, text.stderr
    assert ("  dev-libs/p766gone-1: its dependency dev-libs/p569prov:0/5.42= was built against a sub-slot "
            "dev-libs/p569prov-5.44 does not have, and no ebuild of it is left to rebuild it from"
            ) in text.stdout.splitlines(), text.stdout
    doc = hc.parse_json_output(
        subprocess.run([*argv, "--json", "@world"], capture_output=True, text=True, env=env, check=False).stdout)
    rows = [r for r in doc["stale-bindings"] if r["consumer"] == "dev-libs/p766gone-1"]
    assert rows == [{"consumer": "dev-libs/p766gone-1", "atom": _BIND_766, "provider": _NEW_766,
                     "reason": "no ebuild"}], rows


@pytest.mark.parametrize("solver", _SOLVERS_766)
@pytest.mark.parametrize("flags", [("--update", "--deep", "--newuse"), ("--update", "--deep")], ids=["uDN", "uD"])
def test_770_both_solvers_rebuild_the_walked_installed_virtual(emerge_binary, fixture_env, tmp_path, solver, flags):
    """Backlog #770, PMS `dependencies.tex` `sec:slot-dep` and charter property 1 (a `:=` binding
    the plan breaks is repaired or said): `p569pull-2` moves `p569prov` to 5.44, so the installed
    `p569virt-1`, recorded on `p569prov:0/5.42=` and walked below `p569pull`, is rebuilt, on both
    solvers. The expected rows are derived from the root (the binding and the move), and equal the
    default solver's output; nothing comes from Portage. The provider row's `r` tag is not compared
    (pubgrub does not print it, backlog #780)."""
    env = _root_766(fixture_env, tmp_path, "pull")
    argv = [str(emerge_binary), *(["--solver=pubgrub"] if solver else []), "--pretend", *flags, "--getbinpkg=n", "@world"]
    run = subprocess.run(argv, capture_output=True, text=True, check=False,
                         env={**env, "PORTUALE_PG_TRACE": "1"} if solver else env)
    assert run.returncode == 0, (run.stdout, run.stderr)
    assert bool(re.search(r"^pg-", run.stderr, re.M)) == bool(solver), run.stderr[:300]
    rows = [line for line in run.stdout.splitlines() if line.startswith("[ebuild")]
    assert any(re.match(r"\[ebuild  rR    \] dev-libs/p569virt-1\b", line) for line in rows), rows
    out = run.stdout
    assert "causes rebuilds for:" in out, out
    block = out.split("causes rebuilds for:")[0].splitlines()[-1] + out.split("causes rebuilds for:")[1].split("\n\n")[0]
    assert "dev-libs/p569prov-5.44" in block and "dev-libs/p569virt-1" in block, block


_A10_PIN_773 = ("dev-libs/p573virt", "=dev-libs/p569prov-5.42*", _NEW_766)
# (resolver refusal rows, resolver stale reinstalls) per solver on root `a10`.
_A10_773 = {
    "": (set(), {"dev-libs/p573virt"}),
    "pubgrub": ({_VIRT_RES_766, _A10_PIN_773}, set()),
}


@pytest.mark.parametrize("solver", _SOLVERS_766)
def test_773_a_consumer_whose_tree_pins_the_old_provider(mrg_binary, emerge_binary, fixture_env, tmp_path, solver):
    """Backlog #773. Root `a10`: the installed `p573virt-1` recorded `p569prov:0/5.42=`, and its
    tree ebuild needs `=dev-libs/p569prov-5.42*`. PMS `sec:slot-dep` and charter property 1: a
    plan may not rebuild it against `p569prov-5.44`. The fast plan and the default solver keep the
    provider and rebuild the consumer; the fast plan also rebuilds the shared VDB's `p569virt-1`
    through its recorded `||` (owner decision 2026-11-22), needlessly once the provider stays
    (residue #777). pubgrub keeps the upgrade, does not rebuild the consumer and names it in
    the stale-binding NOTE (owner decision Q1 (A), 2026-11-22; plan
    `LLM/02.773-pubgrub-rebuild-against-tree-pin.opus.md`); the default solver and the fast
    plan hold the provider back instead."""
    env = _root_766(fixture_env, tmp_path, "a10")
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver)
    bound = _bound_766(tmp_path / "root")
    fast, res = _view_766(fast_doc, bound, False), _view_766(res_doc, bound, True)
    assert fast == (set(), {"dev-libs/p573virt", "dev-libs/p569virt"}), fast
    assert res == _A10_773[solver], res
    moved = {e["package"] for e in res_doc["entries"] if e.get("outcome") == "upgrade"}
    assert ("p569prov" in moved) == bool(solver), moved


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


# --- backlog #764: the fast plan's build-time closure is one level deep ----------------------------
#
# `build_time_used` protects only the DIRECT targets of a package's build-kind edges, so the runtime
# edges of a build tool are cut one level down (`crates/portage-world/src/order.rs`). PMS 8.1
# (`dependencies.tex`, "installed and usable") would want the tool's whole runtime closure present
# first; charter 2/2a, as the owner ruled it in #749 and on 2026-11-15, is literal and does not. These
# three shapes (`LLM/02.764-build-closure.opus.md` sec. 1, orders derived by hand from the cut rule)
# pin what that costs. Expected rows come from the rule, "literal clean/failure" from the literal
# checker (`hc`), the late package from the PMS over the fixture's declared deps.

def _plan_764(mrg_binary, fixture_env, tmp_path, atom):
    """The w764 rows and stderr of `--plan-world --json --sort depend` for a world holding `atom`
    on an empty VDB (like `test_740`), and the literal checker's failures on that plan."""
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text(atom + "\n")
    (root / "var/db/pkg").mkdir(parents=True)
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    run = subprocess.run(
        [str(mrg_binary), "--plan-world", "--json", "--sort", "depend"],
        capture_output=True, text=True, env=env, check=False,
    )
    assert run.returncode == 0, run.stderr
    doc = hc.parse_json_output(run.stdout)
    rows = [e["package"] for e in doc["entries"] if e["package"].startswith("w764")]
    assert rows, "no w764 rows: the fixtures are missing"
    found = [f for f in hc.check_document(doc, root / "var/db/pkg") if f.is_failure and not f.pre_existing]
    return rows, run.stderr, found


def test_764_a_tool_runtime_dependency_on_a_cut_cycle_lands_after_its_consumer(
    mrg_binary, fixture_env, tmp_path
):
    """Shape V2 (`w764a*`): `ab` builds with `at`, `at` runs with `am`, `am -> au -> ax -> am` is a
    runtime cycle. Only `at` is protected, so the cycle is cut at `(am,au)` and `au`, the runtime
    dependency of `am` (depth 2 of the tool `at`), merges AFTER `ab`: PMS 8.1 would call `at`
    unusable at `ab`. The literal checker (charter 2/2a, #749) is clean; that is the documented
    limitation, owner ruling 2026-11-15."""
    rows, _, found = _plan_764(mrg_binary, fixture_env, tmp_path, "dev-libs/w764ab")
    assert rows == ["w764am", "w764at", "w764ab", "w764ax", "w764au"], rows
    assert found == [], found
    assert rows.index("w764au") > rows.index("w764ab")  # the late package


def test_764_an_unavoidable_late_tool_dependency_is_literal_legal(mrg_binary, fixture_env, tmp_path):
    """Shape V1 (`w764c*`): as V2 but the runtime dependency `cu` of the tool's `cm` builds with the
    consumer `cb` (`cu -B-> cb`), so `cu` after `cb` is the only legal order (PMS-genuine). The cut
    `(cm,cu)` gives it; propagating the build-used status down the runtime closure would leave the
    cycle uncuttable and the walk would put `cu` first, a literal `build-order` failure."""
    rows, _, found = _plan_764(mrg_binary, fixture_env, tmp_path, "dev-libs/w764cb")
    assert rows == ["w764cm", "w764ct", "w764cb", "w764cu"], rows
    assert found == [], found


def test_772_a_late_need_without_a_cycle_is_reported(mrg_binary, fixture_env, tmp_path):
    """Shape V3 (`w764d*`): `db -B-> dt`, `dt -R-> du`, `du -B-> db`. `dt` is build-used so its
    runtime edge is not cuttable and the name-ordered walk puts `du` before `db`; the literal
    checker fails `du` (BDEPEND `db` merged later) although `dt, db, du` is legal. The order is
    still the walk's, so the plan says so, truthfully: no build path joins `du` and `db` (the
    edge `dt -> du` is runtime), hence "no build cycle joins them". Charter 2a (literal) and 5;
    the wording is the owner's decision Q2/Q3 of 2026-11-16, not Portage's."""
    rows, err, found = _plan_764(mrg_binary, fixture_env, tmp_path, "dev-libs/w764db")
    assert rows == ["w764du", "w764dt", "w764db"], rows
    assert (
        'plan-world: this order builds dev-libs/w764du:0 before its build dependency '
        '"dev-libs/w764db", merged later; no build cycle joins them, so the order itself is wrong\n'
    ) in err, err
    assert [(f.property, f.package) for f in found] == [("build-order", "dev-libs/w764du-1")], found
    assert "merged later" in found[0].reason and "merge it first" in found[0].reason


# --- backlog #772: a cycle line only for a build need the produced order really breaks ------------
#
# The line used to list every build-time strongly connected component, whether or not the order it
# came with built anything early. Now it is a check of the final rows: a build atom whose target is
# merged later, that nothing installed (and still present) or earlier meets. Expected text from the
# owner's decision Q2/Q3 of 2026-11-16; charter 2/2a/5 and PMS `dependencies.tex:340`, `:348-350`
# (the `=` operator binds a `DEPEND` dependency only).

def _plan_772(mrg_binary, fixture_env, tmp_path, world, installed):
    """stderr lines about cycles and the literal failures of `--plan-world --json --sort depend`
    on a scratch ROOT whose world holds `world` and whose VDB holds `installed` (cpv -> SLOT)."""
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("".join(f"{w}\n" for w in world))
    (root / "var/db/pkg").mkdir(parents=True)
    for cpv, slot in installed.items():
        entry = root / "var/db/pkg" / cpv
        entry.mkdir(parents=True)
        for key, text in (("CATEGORY", cpv.split("/")[0]), ("EAPI", "8"), ("SLOT", slot), ("repository", "testrepo")):
            (entry / key).write_text(text + "\n")
    env = dict(fixture_env)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    run = subprocess.run([str(mrg_binary), "--plan-world", "--json", "--sort", "depend"],
                         capture_output=True, text=True, env=env, check=False)
    assert run.returncode == 0, run.stderr
    doc = hc.parse_json_output(run.stdout)
    assert any(e["package"].startswith("w772") for e in doc["entries"]), "no w772 rows: the fixtures are missing"
    found = [f for f in hc.check_document(doc, root / "var/db/pkg") if f.is_failure and not f.pre_existing]
    lines = [line for line in run.stderr.splitlines() if "build cycle" in line or "before its build dependency" in line]
    return lines, found


@pytest.mark.parametrize("world, installed", [
    pytest.param(["dev-libs/w772aone", "dev-libs/w772atwo"],
                 {"dev-libs/w772aone-1": "0", "dev-libs/w772atwo-1": "0"}, id="w772a-both-installed"),
    pytest.param(["dev-libs/w772cuser", "dev-libs/w772cslot"],
                 {"dev-libs/w772cuser-1": "0", "dev-libs/w772cslot-1": "1"}, id="w772c-older-slot-installed"),
    pytest.param(["dev-libs/w772euser", "dev-libs/w772eprov"],
                 {"dev-libs/w772euser-1": "0", "dev-libs/w772eprov-1": "0/1"}, id="w772e-bdepend-slot-operator"),
])
def test_772_a_cycle_the_installed_versions_satisfy_is_not_reported(mrg_binary, fixture_env, tmp_path, world, installed):
    """A build cycle whose late edge the installed version meets (any slot the atom allows; a
    `:=` only in `BDEPEND` is no binding) breaks nothing: charter 2a asks that a build
    dependency be installed before, not that it be in this plan earlier."""
    lines, found = _plan_772(mrg_binary, fixture_env, tmp_path, world, installed)
    assert lines == [], lines
    assert found == [], found


def test_772_an_unmet_build_cycle_names_its_real_path(mrg_binary, fixture_env, tmp_path):
    """Control, charter 2a: the same cycle with nothing installed has no legal order, and the
    line names the real build path, once."""
    lines, _ = _plan_772(mrg_binary, fixture_env, tmp_path, ["dev-libs/w772bone", "dev-libs/w772btwo"], {})
    assert lines == [
        'plan-world: build cycle: dev-libs/w772btwo:0 -> dev-libs/w772bone:0 -> dev-libs/w772btwo:0; '
        'this order builds dev-libs/w772btwo:0 before its build dependency "dev-libs/w772bone", merged later '
        '(disable a USE flag on one of these packages to break the cycle)'], lines


def test_772_a_moved_binding_is_still_a_need(mrg_binary, fixture_env, tmp_path):
    """PMS `dependencies.tex:348-350`: the `=` binding of a `DEPEND` dependency is to the installed
    sub-slot; a plan that replaces the provider with another sub-slot later leaves the binding
    stale, although an installed version "meets" the atom."""
    lines, found = _plan_772(mrg_binary, fixture_env, tmp_path, ["dev-libs/w772duser", "dev-libs/w772dprov"],
                             {"dev-libs/w772duser-1": "0", "dev-libs/w772dprov-1": "0/1"})
    assert lines == [
        'plan-world: build cycle: dev-libs/w772duser:0 -> dev-libs/w772dprov:0 -> dev-libs/w772duser:0; '
        'this order builds dev-libs/w772duser:0 before its build dependency "dev-libs/w772dprov:=", merged later; '
        'the installed dev-libs/w772dprov-1 meets it, but this plan replaces it with sub-slot 2, so '
        "dev-libs/w772duser:0's binding would go stale "
        '(disable a USE flag on one of these packages to break the cycle)'], lines
    assert found == [], found  # the literal checker cannot see a moved `:=` binding


@pytest.mark.parametrize("solver", _SOLVERS_766)
def test_774_a_masked_only_version_is_not_a_route(mrg_binary, emerge_binary, fixture_env, tmp_path, solver):
    """Backlog #774, charter property 1 (a kept package keeps its dependencies; the user can only
    install a visible version): `p774mask-2` accepts `p569prov-5.44` but is keyword-masked, so the
    installed `p774mask-1` (pinned to 5.42) has no route. Both plans keep the provider and the
    holder where they are and neither plans the masked version. Before the fix the resolver took
    the masked version as the route and the whole `-puDN @world` failed. Expected set: the root is
    built so (PMS `sec:slot-dep`, `KEYWORDS`), not taken from either program."""
    env = _root_766(fixture_env, tmp_path, "w774")
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver)
    for label, doc in (("fast", fast_doc), ("resolver", res_doc)):
        moved = {e["category"] + "/" + e["package"] for e in doc["entries"]
                 if e.get("outcome") in ("new", "upgrade", "reinstall", "downgrade")}
        assert not moved & {"dev-libs/p569prov", "dev-libs/p774mask"}, (label, moved)
        assert not any(e.get("version") == "2" and e["package"] == "p774mask" for e in doc["entries"]), label


@pytest.mark.parametrize("solver", _SOLVERS_766)
def test_775_the_two_plans_agree_when_the_newest_holder_pins_the_old_provider(
    mrg_binary, emerge_binary, fixture_env, tmp_path, solver
):
    """Backlog #775 (S0 result), charter property 1: `p775pick-1` is installed and accepts the new
    provider, the newest visible `p775pick-2` pins the old one. The two plans do not differ on
    the stale-binding verdict: neither refuses, both take the holder to 2, and the provider stays
    at 5.42 in the resolver. The refusal the entry predicted ("the fast plan tests 2 and refuses
    by name") does not appear."""
    env = _root_766(fixture_env, tmp_path, "w775")
    fast_doc, res_doc = _both_766(mrg_binary, emerge_binary, env, solver)
    for label, doc in (("fast", fast_doc), ("resolver", res_doc)):
        assert not doc.get("stale-bindings"), (label, doc.get("stale-bindings"))
        assert [e["version"] for e in doc["entries"] if e["package"] == "p775pick"] == ["2"], label
