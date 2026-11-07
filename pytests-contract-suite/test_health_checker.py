"""Unit tests for `health_checker.py`, on small hand-made plans.

Each broken plan must be flagged with the right property; each healthy
plan must produce no failure. Expected values come from PMS (version
comparison 3.3, atoms 8.3, dependency strings 8.2), not from any package
manager's output.
"""

from __future__ import annotations

import pytest

import health_checker as hc


def split(cpv):
    cat, _, pv = cpv.partition("/")
    pkg, _, version = pv.rpartition("-")
    if version.startswith("r") and version[1:].isdigit():
        pkg, _, base = pkg.rpartition("-")
        version = f"{base}-{version}"
    return cat, pkg, version


def entry(cpv, order, outcome="new", slot="0", deps=None, use=(), iuse=(),
          required_use="", from_version=None, source="ebuild", sub_slot=None):
    cat, pkg, version = split(cpv)
    e = {"category": cat, "package": pkg, "version": version, "merge_order": order,
         "outcome": outcome, "slot": slot, "source": source, "sub_slot": sub_slot,
         "dependencies": deps or {}, "use": list(use), "iuse": list(iuse),
         "required_use": required_use}
    if from_version:
        e["from_version"] = from_version
    return e


def kept(cpv, slot="0", deps=None, use=()):
    cat, pkg, version = split(cpv)
    return {"category": cat, "package": pkg, "version": version, "slot": slot,
            "dependencies": deps or {}, "use": list(use), "iuse": list(use)}


def plan(entries, kept_items=()):
    return {"entries": entries, "kept": list(kept_items), "aborted": None}


def failures(doc):
    return [(f.property, f.package, f.atom) for f in hc.check_plan(doc) if f.is_failure]


# --- versions and atoms -----------------------------------------------------

@pytest.mark.parametrize("a, b, expected", [
    ("1.0", "1.0", 0), ("1.0", "1.0-r0", 0), ("1.2", "1.10", -1),
    ("1.01", "1.1", -1), ("1.010", "1.01", 0), ("1.0a", "1.0", 1),
    ("1.0_alpha", "1.0_beta", -1), ("1.0_rc1", "1.0", -1), ("1.0_p1", "1.0", 1),
    ("1.0_pre", "1.0_pre1", -1), ("1.0-r2", "1.0-r10", -1), ("2", "1.9.9", 1),
    ("1.0.0", "1.0", 1), ("1.0_alpha_p1", "1.0_alpha", 1),
])
def test_vercmp(a, b, expected):
    assert hc.vercmp(a, b) == expected
    assert hc.vercmp(b, a) == -expected


def test_parse_atom():
    a = hc.parse_atom(">=dev-libs/foo-bar-1.2-r3:2/2.1=[baz,-qux(+),x?]")
    assert (a.op, a.cp, a.version, a.slot, a.subslot) == (">=", ("dev-libs", "foo-bar"), "1.2-r3", "2", "2.1")
    assert [(u.flag, u.kind, u.default) for u in a.use_deps] == [
        ("baz", "on", None), ("qux", "off", True), ("x", "if-on", None)]
    assert hc.parse_atom("!!dev-libs/foo::gentoo").blocker
    assert hc.parse_atom("=dev-libs/foo-1.2*").glob
    with pytest.raises(ValueError):
        hc.parse_atom(">=dev-libs/foo")


def package(cpv, slot="0", use=(), iuse=None):
    cat, pkg, version = split(cpv)
    return hc.Package(cat, pkg, version, slot, use=frozenset(use),
                      iuse=frozenset(use if iuse is None else iuse))


@pytest.mark.parametrize("atom, pkg, parent_use, expected", [
    ("~dev-libs/a-1.0", package("dev-libs/a-1.0-r3"), (), True),
    ("=dev-libs/a-1.2*", package("dev-libs/a-1.2.5"), (), True),
    ("<dev-libs/a-2", package("dev-libs/a-2.0"), (), False),
    ("dev-libs/a:1", package("dev-libs/a-1.0", slot="0"), (), False),
    ("dev-libs/a[x]", package("dev-libs/a-1", use=()), (), False),
    ("dev-libs/a[x(+)]", package("dev-libs/a-1", iuse=()), (), True),
    ("dev-libs/a[x=]", package("dev-libs/a-1", use=("x",)), ("x",), True),
    ("dev-libs/a[!x=]", package("dev-libs/a-1", use=("x",)), ("x",), False),
    ("dev-libs/a[x?]", package("dev-libs/a-1", iuse=("x",)), (), True),
    ("dev-libs/a[!x?]", package("dev-libs/a-1", use=("x",)), (), False),
])
def test_matches(atom, pkg, parent_use, expected):
    assert hc.matches(hc.parse_atom(atom), pkg, frozenset(parent_use)) is expected


@pytest.mark.parametrize("text, use, broken", [
    ("^^ ( a b )", {"a"}, []),
    ("^^ ( a b )", {"a", "b"}, ["^^ ( a b )"]),
    ("?? ( a b )", set(), []),
    ("|| ( a b )", set(), ["|| ( a b )"]),
    ("a? ( b )", {"a"}, ["b"]),
    ("a? ( !b )", {"b"}, []),
    ("x? ( ^^ ( a b ) ) c", {"x", "c"}, ["^^ ( a b )"]),
])
def test_required_use(text, use, broken):
    assert hc.required_use_holds(text, frozenset(use)) == broken


# --- property 1: the final set ---------------------------------------------

def test_healthy_plan_has_no_finding():
    doc = plan([
        entry("dev-libs/b-1", 0),
        entry("app-misc/a-1", 1, deps={"DEPEND": "dev-libs/b", "RDEPEND": "|| ( dev-libs/x dev-libs/b ) foo? ( dev-libs/missing )"}),
    ])
    assert hc.check_plan(doc) == []


def test_missing_runtime_dep_is_flagged():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "dev-libs/missing"})])
    assert failures(doc) == [("runtime-deps", "app-misc/a-1", "dev-libs/missing")]


def test_enabled_use_conditional_dep_is_checked():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "foo? ( dev-libs/missing )"},
                      use=["foo"], iuse=["foo"])])
    assert failures(doc) == [("runtime-deps", "app-misc/a-1", "dev-libs/missing")]


def test_use_dependency_is_checked():
    doc = plan([entry("dev-libs/b-1", 0, iuse=["bar"]),
                entry("app-misc/a-1", 1, deps={"RDEPEND": "dev-libs/b[bar]"})])
    assert failures(doc) == [("runtime-deps", "app-misc/a-1", "dev-libs/b[bar]")]


def test_upgrade_that_breaks_a_kept_package_is_flagged():
    doc = plan([entry("dev-libs/b-2", 0, outcome="upgrade", from_version="1")],
               [kept("app-misc/k-1", deps={"RDEPEND": "<dev-libs/b-2"})])
    found = hc.check_plan(doc)
    assert [(f.property, f.package, f.pre_existing) for f in found] == [
        ("runtime-deps", "app-misc/k-1", False)]


def test_new_sub_slot_breaks_a_bound_slot_operator_dep():
    doc = plan([entry("dev-libs/b-2", 0, outcome="upgrade", from_version="1", sub_slot="2")],
               [kept("app-misc/k-1", deps={"RDEPEND": "dev-libs/b:0/1="})])
    assert failures(doc) == [("runtime-deps", "app-misc/k-1", "dev-libs/b:0/1=")]


def test_broken_kept_package_is_marked_pre_existing():
    doc = plan([], [kept("app-misc/k-1", deps={"RDEPEND": "dev-libs/gone"})])
    [finding] = hc.check_plan(doc)
    assert finding.property == "runtime-deps" and finding.pre_existing


def test_blocker_on_a_kept_package_is_flagged():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "!dev-libs/old"})],
               [kept("dev-libs/old-1")])
    assert failures(doc) == [("blocker", "app-misc/a-1", "!dev-libs/old")]


def test_blocker_does_not_block_its_owner():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "!app-misc/a"})])
    assert failures(doc) == []


def test_broken_required_use_is_flagged():
    doc = plan([entry("app-misc/a-1", 0, use=["x", "y"], iuse=["x", "y"],
                      required_use="?? ( x y )")])
    assert failures(doc) == [("required-use", "app-misc/a-1", "?? ( x y )")]


def test_two_packages_in_one_slot_are_flagged():
    doc = plan([entry("dev-libs/b-2", 0)], [kept("dev-libs/b-1")])
    assert failures(doc) == [("slot", "dev-libs/b", "dev-libs/b:0")]


# --- property 2: the order -------------------------------------------------

def test_build_dep_merged_later_is_flagged():
    doc = plan([entry("app-misc/a-1", 0, deps={"BDEPEND": "dev-libs/b"}),
                entry("dev-libs/b-1", 1)])
    found = hc.check_plan(doc)
    assert [(f.property, f.atom) for f in found] == [("build-order", "dev-libs/b")]
    assert "merge it first" in found[0].reason


def test_runtime_dep_merged_later_is_fine():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "dev-libs/b"}),
                entry("dev-libs/b-1", 1)])
    assert hc.check_plan(doc) == []


def test_installed_version_satisfies_its_own_rebuild():
    doc = plan([entry("dev-lang/c-2", 0, outcome="upgrade", from_version="1",
                      deps={"BDEPEND": "dev-lang/c"})])
    assert hc.check_plan(doc) == []


def test_binary_package_needs_no_build_deps():
    doc = plan([entry("app-misc/a-1", 0, source="binary", deps={"DEPEND": "dev-libs/b"}),
                entry("dev-libs/b-1", 1)])
    assert hc.check_plan(doc) == []


def test_build_time_cycle_is_noted_not_failed():
    doc = plan([entry("dev-libs/a-1", 0, deps={"DEPEND": "dev-libs/b"}),
                entry("dev-libs/b-1", 1, deps={"DEPEND": "dev-libs/a"})])
    found = hc.check_plan(doc)
    assert [(f.property, f.package) for f in found] == [("cycle-noted", "dev-libs/a-1")]
    assert not any(f.is_failure for f in found)


def test_build_dep_never_provided_is_flagged():
    doc = plan([entry("app-misc/a-1", 0, deps={"DEPEND": "dev-libs/nowhere"})])
    [finding] = hc.check_plan(doc)
    assert (finding.property, finding.atom) == ("build-order", "dev-libs/nowhere")
    assert "not matched by anything" in finding.reason


def test_vdb_is_read_for_kept_packages(tmp_path):
    d = tmp_path / "app-misc" / "k-1"
    d.mkdir(parents=True)
    (d / "SLOT").write_text("0\n")
    (d / "USE").write_text("foo\n")
    (d / "IUSE").write_text("+foo\n")
    (d / "RDEPEND").write_text("foo? ( dev-libs/gone )\n")
    doc = {"entries": [], "aborted": None,
           "kept": [{"category": "app-misc", "package": "k", "version": "1", "slot": "0"}]}
    [finding] = hc.check_plan(doc, tmp_path)
    assert (finding.property, finding.atom, finding.pre_existing) == (
        "runtime-deps", "dev-libs/gone", True)


def test_missing_data_is_a_checker_limitation():
    doc = {"entries": [], "aborted": None,
           "kept": [{"category": "app-misc", "package": "k", "version": "1", "slot": "0"}]}
    assert [f.property for f in hc.check_plan(doc)] == ["checker-limitation"]


def test_unparsable_string_is_a_checker_limitation():
    doc = plan([entry("app-misc/a-1", 0, deps={"RDEPEND": "|| ( dev-libs/b"})])
    assert [(f.property, f.atom) for f in hc.check_plan(doc)] == [("checker-limitation", "RDEPEND")]


def test_refusal_names_why_portuale_would_not_run_the_plan():
    doc = plan([entry("app-misc/a-1", 0)])
    assert hc.refusal(doc) == ""
    doc["slot_conflicts"] = [{}]
    doc["autounmask_use_changes"] = [{}]
    assert hc.refusal(doc) == "slot conflict, needs configuration changes"


# --- blind spots found by mutating real plans (differential-test-bed/compare/health-mutants.py)

def vdb_package(root, cpv, slot="0", rdepend=""):
    cat, pkg, version = split(cpv)
    d = root / cat / f"{pkg}-{version}"
    d.mkdir(parents=True)
    (d / "SLOT").write_text(slot + "\n")
    (d / "RDEPEND").write_text(rdepend + "\n")


def test_installed_package_missing_from_kept_breaks_its_dependants(tmp_path):
    """delete_needed_kept: the VDB, not `kept`, says what was installed."""
    vdb_package(tmp_path, "app-misc/k-1", rdepend="acct-group/adm")
    vdb_package(tmp_path, "acct-group/adm-0")
    doc = {"entries": [], "aborted": None,
           "kept": [{"category": "app-misc", "package": "k", "version": "1", "slot": "0"}]}
    found = hc.check_plan(doc, tmp_path)
    assert [(f.property, f.atom, f.pre_existing) for f in found] == [
        ("runtime-deps", "acct-group/adm", False)]


def test_runtime_dep_of_a_build_dep_merged_too_late_is_flagged():
    """late_runtime_of_build_dep (PMS 8.1: a DEPEND must be usable)."""
    doc = plan([entry("dev-libs/y-1", 0, deps={"RDEPEND": "dev-libs/z"}),
                entry("app-misc/x-1", 1, deps={"DEPEND": "dev-libs/y"}),
                entry("dev-libs/z-1", 2)])
    assert failures(doc) == [("build-order", "app-misc/x-1", "dev-libs/z")]


def test_two_levels_of_runtime_deps_of_a_build_dep_are_followed():
    """two_level_runtime_of_build_dep."""
    doc = plan([entry("dev-libs/y-1", 0, deps={"RDEPEND": "dev-libs/z"}),
                entry("dev-libs/z-1", 1, deps={"RDEPEND": "dev-libs/w"}),
                entry("app-misc/x-1", 2, deps={"DEPEND": "dev-libs/y"}),
                entry("dev-libs/w-1", 3)])
    assert failures(doc) == [("build-order", "app-misc/x-1", "dev-libs/w")]


def test_build_against_a_stale_slot_operator_consumer_is_flagged(tmp_path):
    """stale_build_dep: x builds while the installed y is still bound to
    the lib sub-slot the upgrade just removed; y is rebuilt only later."""
    vdb_package(tmp_path, "dev-libs/lib-1", slot="0/1")
    vdb_package(tmp_path, "dev-libs/y-1", rdepend="dev-libs/lib:0/1=")
    doc = plan([entry("dev-libs/lib-2", 0, outcome="upgrade", from_version="1", sub_slot="2"),
                entry("app-misc/x-1", 1, deps={"DEPEND": "dev-libs/y"}),
                entry("dev-libs/y-1", 2, outcome="reinstall", deps={"RDEPEND": "dev-libs/lib:0/2="})])
    found = [f for f in hc.check_plan(doc, tmp_path) if f.is_failure]
    assert [(f.property, f.package, f.atom) for f in found] == [
        ("build-order", "app-misc/x-1", "dev-libs/lib:0/1=")]
    assert "met only by dev-libs/y-1, merged later" in found[0].reason


def test_runtime_cycle_through_a_build_dep_is_noted_not_failed():
    doc = plan([entry("app-misc/x-1", 0, deps={"DEPEND": "dev-libs/y", "RDEPEND": "dev-libs/y"}),
                entry("dev-libs/y-1", 1, deps={"RDEPEND": "app-misc/x"})])
    found = hc.check_plan(doc)
    assert [(f.property, f.package) for f in found] == [("cycle-noted", "app-misc/x-1")]


def test_build_time_blocker_is_checked_when_the_package_builds():
    """keep_what_build_blocks: a DEPEND blocker does not outlive the build,
    but must hold while it runs."""
    doc = plan([entry("app-misc/a-1", 0, deps={"DEPEND": "!dev-libs/old"})],
               [kept("dev-libs/old-1")])
    assert failures(doc) == [("blocker", "app-misc/a-1", "!dev-libs/old")]


def test_no_sub_slot_means_the_sub_slot_is_the_slot():
    """drop_sub_slot (PMS 7.2)."""
    doc = plan([entry("dev-libs/b-2", 0, outcome="upgrade", from_version="1")],
               [kept("app-misc/k-1", deps={"RDEPEND": "dev-libs/b:0/1="})])
    assert failures(doc) == [("runtime-deps", "app-misc/k-1", "dev-libs/b:0/1=")]
