"""Unit tests for `health_checker.py`, on small hand-made plans.

Each broken plan must be flagged with the right property; each healthy
plan must produce no failure. Expected values come from PMS (version
comparison 3.3, atoms 8.3, dependency strings 8.2), not from any package
manager's output.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess

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


# --- property 4: removals keep linked libraries ------------------------------

def installed_root(tmp_path, packages):
    """A root with `packages`: cpv -> {path: soname-or-needed spec}. A spec
    `("lib", soname, needed)` installs a library and its soname link, `("bin",
    needed)` a program. Returns the VDB path."""
    vdb = tmp_path / "var/db/pkg"
    for cpv, files in packages.items():
        cat, pkg, version = split(cpv)
        d = vdb / cat / f"{pkg}-{version}"
        d.mkdir(parents=True)
        contents, needed = [], []
        for path, spec in files.items():
            (tmp_path / path.lstrip("/")).parent.mkdir(parents=True, exist_ok=True)
            (tmp_path / path.lstrip("/")).write_bytes(b"\x7fELF")
            contents.append(f"obj {path} 0 0")
            if spec[0] == "lib":
                link = f"{path.rsplit('/', 1)[0]}/{spec[1]}"
                (tmp_path / link.lstrip("/")).symlink_to(path.rsplit("/", 1)[1])
                contents.append(f"sym {link} -> {path.rsplit('/', 1)[1]} 0")
                needed.append(f"X86_64;{path};{spec[1]};;{spec[2]};x86_64")
            else:
                needed.append(f"X86_64;{path};;;{spec[1]};x86_64")
        (d / "SLOT").write_text("0\n")
        (d / "CONTENTS").write_text("\n".join(contents) + "\n")
        (d / "NEEDED.ELF.2").write_text("\n".join(needed) + "\n")
    return vdb


def removal(cpvs, preserved=()):
    return {"removal": [dict(zip(("category", "package", "version"), split(c)), slot="0")
                        for c in cpvs], "preserved": list(preserved)}


ZLIB = {"sys-libs/z-1": {"/usr/lib64/libz.so.1.3": ("lib", "libz.so.1", "")},
        "app-misc/tool-1": {"/usr/bin/tool": ("bin", "libz.so.1")}}


def test_removed_library_still_linked_is_flagged(tmp_path):
    vdb = installed_root(tmp_path, ZLIB)
    found = hc.check_removal_plan(removal(["sys-libs/z-1"]), vdb)
    assert [(f.property, f.package, f.atom) for f in found if f.is_failure] == [
        ("linked-library", "app-misc/tool-1", "libz.so.1")]


def test_preserved_library_keeps_the_program_working(tmp_path):
    vdb = installed_root(tmp_path, ZLIB)
    doc = removal(["sys-libs/z-1"], ["/usr/lib64/libz.so.1", "/usr/lib64/libz.so.1.3"])
    assert [f.property for f in hc.check_removal_plan(doc, vdb) if f.is_failure] == []


def test_preserving_the_file_but_not_its_soname_link_is_flagged(tmp_path):
    vdb = installed_root(tmp_path, ZLIB)
    doc = removal(["sys-libs/z-1"], ["/usr/lib64/libz.so.1.3"])
    assert [f.property for f in hc.check_removal_plan(doc, vdb)] == ["linked-library"]


def test_removing_the_consumers_too_needs_no_preservation(tmp_path):
    vdb = installed_root(tmp_path, ZLIB)
    assert hc.check_removal_plan(removal(["sys-libs/z-1", "app-misc/tool-1"]), vdb) == []


def test_preserved_library_needs_its_own_libraries(tmp_path):
    """A preserved library linking another removed library keeps it too."""
    vdb = installed_root(tmp_path, {
        "sys-libs/z-1": {"/usr/lib64/libz.so.1.3": ("lib", "libz.so.1", "")},
        "dev-libs/png-1": {"/usr/lib64/libpng.so.16.0": ("lib", "libpng.so.16", "libz.so.1")},
        "app-misc/view-1": {"/usr/bin/view": ("bin", "libpng.so.16")}})
    doc = removal(["sys-libs/z-1", "dev-libs/png-1"],
                  ["/usr/lib64/libpng.so.16", "/usr/lib64/libpng.so.16.0"])
    assert [(f.property, f.package, f.atom) for f in hc.check_removal_plan(doc, vdb)] == [
        ("linked-library", "dev-libs/png-1", "libz.so.1")]


def test_unmatched_dependency_after_removal_is_only_a_warning(tmp_path):
    vdb = installed_root(tmp_path, {"sys-libs/z-1": {}, "app-misc/tool-1": {}})
    (vdb / "app-misc/tool-1/RDEPEND").write_text("sys-libs/z\n")
    [finding] = hc.check_removal_plan(removal(["sys-libs/z-1"]), vdb)
    assert (finding.property, finding.atom, finding.is_failure) == ("removal-deps", "sys-libs/z", False)


def test_removal_document_is_found_in_the_output():
    text = 'junk\n{"removal":[],"preserved":[]}\nNumber removed: 0\n'
    assert hc.parse_json_output(text) == {"removal": [], "preserved": []}


def test_portuale_removal_document_passes_the_checker(tmp_path, emerge_binary, fixture_env):
    """End to end: `-pC --json` on a root where a program links the removed
    library prints the removal document, with the library preserved."""
    vdb = installed_root(tmp_path, ZLIB)
    (tmp_path / "etc").mkdir()
    (tmp_path / "etc/ld.so.conf").write_text("/usr/lib64\n")
    env = dict(fixture_env, ROOT=str(tmp_path), PORTAGE_RUNNING_ROOT=str(tmp_path),
               FEATURES="preserve-libs")
    run = subprocess.run([str(emerge_binary), "--pretend", "-C", "sys-libs/z", "--json"],
                         capture_output=True, text=True, env=env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert doc == {"removal": [{
        "category": "sys-libs", "package": "z", "version": "1", "slot": "0",
        "needed_libraries": ["/usr/lib64/libz.so.1", "/usr/lib64/libz.so.1.3"],
        "preserve_libs": True}],
        "preserved": ["/usr/lib64/libz.so.1", "/usr/lib64/libz.so.1.3"]}, run.stdout + run.stderr
    assert [f for f in hc.check_removal_plan(doc, vdb) if f.is_failure] == []


# --- property 3: best visible version ------------------------------------------

def config_root(tmp_path, ebuilds, make_conf="", package_files=None):
    """A root with one repository `test` and its profile. `ebuilds`: cpv ->
    md5-cache keys (KEYWORDS defaults to amd64, LICENSE to GPL-2)."""
    repo = tmp_path / "var/db/repos/test"
    prof = repo / "profiles/prof"
    prof.mkdir(parents=True)
    (prof / "make.defaults").write_text('ARCH="amd64"\nACCEPT_KEYWORDS="${ARCH}"\n'
                                        'ACCEPT_LICENSE="-* @FREE"\n')
    (repo / "profiles/license_groups").write_text("FREE GPL-2 @OSI\nOSI MIT\n")
    for cpv, meta in ebuilds.items():
        cat, pkg, version = split(cpv)
        (repo / cat / pkg).mkdir(parents=True, exist_ok=True)
        (repo / cat / pkg / f"{pkg}-{version}.ebuild").write_text("")
        cache = repo / "metadata/md5-cache" / cat
        cache.mkdir(parents=True, exist_ok=True)
        meta = {"SLOT": "0", "KEYWORDS": "amd64", "LICENSE": "GPL-2", "EAPI": "8", **meta}
        (cache / f"{pkg}-{version}").write_text("".join(f"{k}={v}\n" for k, v in meta.items()))
    etc = tmp_path / "etc/portage"
    (etc / "repos.conf").mkdir(parents=True)
    (etc / "repos.conf/test.conf").write_text("[test]\nlocation = /var/db/repos/test\n")
    (etc / "make.profile").symlink_to("../../var/db/repos/test/profiles/prof")
    (etc / "make.conf").write_text(make_conf)
    for name, text in (package_files or {}).items():
        (etc / name).write_text(text)
    (tmp_path / "var/db/pkg").mkdir(parents=True, exist_ok=True)
    hc.visibility.cache_clear()
    return tmp_path


def reason(root, cpv, use=()):
    cat, pkg, version = split(cpv)
    [cand] = [c for c in hc.visibility(root).candidates((cat, pkg)) if c.pkg.version == version]
    return hc.visibility(root).mask_reason(cand, frozenset(use))


@pytest.mark.parametrize("keywords, accept, package_keywords, visible", [
    ("amd64", "", "", True),
    ("~amd64", "", "", False),
    ("~amd64", "~amd64", "", True),
    ("-* amd64", "", "", True),
    ("-amd64 ~x86", "", "", False),
    ("", "", "", False),
    ("~amd64", "", "app-misc/a\n", True),  # no keyword given: ~ARCH
    ("", "", "app-misc/a **\n", True),
    ("~x86", "", "app-misc/a ~*\n", True),
    ("x86", "", "app-misc/a *\n", True),
    ("~amd64", "-amd64 ~amd64", "", True),
])
def test_keyword_visibility(tmp_path, keywords, accept, package_keywords, visible):
    """PMS 7.3 KEYWORDS and the Devmanual's `~arch`, `-arch`, `-*`, `*`, `~*`, `**`."""
    root = config_root(tmp_path, {"app-misc/a-1": {"KEYWORDS": keywords}},
                       f'ACCEPT_KEYWORDS="{accept}"\n' if accept else "",
                       {"package.accept_keywords": package_keywords})
    assert (reason(root, "app-misc/a-1") == "") is visible


@pytest.mark.parametrize("license, use, make_conf, visible", [
    ("GPL-2", (), "", True),
    ("MIT", (), "", True),  # @FREE includes @OSI
    ("EULA", (), "", False),
    ("|| ( EULA MIT )", (), "", True),
    ("foo? ( EULA )", ("foo",), "", False),
    ("foo? ( EULA )", (), "", True),
    ("EULA", (), 'ACCEPT_LICENSE="EULA"\n', True),
    ("MIT", (), 'ACCEPT_LICENSE="-@OSI"\n', False),
    ("EULA", (), 'ACCEPT_LICENSE="* -EULA"\n', False),
])
def test_license_visibility(tmp_path, license, use, make_conf, visible):
    root = config_root(tmp_path, {"app-misc/a-1": {"LICENSE": license}}, make_conf)
    assert (reason(root, "app-misc/a-1", use) == "") is visible


def test_package_mask_and_unmask(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-1": {}, "app-misc/a-2": {}},
                       package_files={"package.mask": ">=app-misc/a-2\n"})
    assert (reason(root, "app-misc/a-1"), reason(root, "app-misc/a-2")) == ("", "package.mask")
    (root / "etc/portage/package.unmask").write_text("=app-misc/a-2\n")
    hc.visibility.cache_clear()
    assert reason(root, "app-misc/a-2") == ""


def best(root, entries, kept_items=(), request=("app-misc/a",)):
    doc = dict(plan(entries, kept_items), request=list(request))
    return [(f.property, f.package, f.atom) for f in hc.check_best_versions(doc, root / "var/db/pkg")]


A12 = {"app-misc/a-1": {}, "app-misc/a-2": {}, "app-misc/a-3": {"KEYWORDS": "~amd64"}}


def test_older_version_than_the_best_visible_is_flagged(tmp_path):
    root = config_root(tmp_path, A12)
    assert best(root, [entry("app-misc/a-1", 0)]) == [("best-version", "app-misc/a-1", "=app-misc/a-2")]
    assert best(root, [entry("app-misc/a-2", 0)]) == []


def test_a_constraint_of_another_package_explains_the_older_version(tmp_path):
    root = config_root(tmp_path, A12)
    consumer = kept("app-misc/k-1", deps={"RDEPEND": "<app-misc/a-2"})
    assert best(root, [entry("app-misc/a-1", 0)], [consumer]) == []


def test_the_requested_version_is_not_flagged(tmp_path):
    root = config_root(tmp_path, A12)
    assert best(root, [entry("app-misc/a-1", 0)], request=["=app-misc/a-1"]) == []


def test_masked_version_in_the_plan_is_flagged(tmp_path):
    root = config_root(tmp_path, A12)
    assert best(root, [entry("app-misc/a-3", 0)]) == [("visibility", "app-misc/a-3", "")]


def test_a_higher_version_needing_other_packages_is_only_a_limitation(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-1": {}, "app-misc/a-2": {"RDEPEND": "dev-libs/new"}})
    assert best(root, [entry("app-misc/a-1", 0)]) == [
        ("checker-limitation", "app-misc/a-1", "=app-misc/a-2")]


def test_other_slot_counts_only_when_the_slot_is_free(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-1": {}, "app-misc/a-2": {"SLOT": "2"}})
    assert best(root, [entry("app-misc/a-1", 0)]) == [("best-version", "app-misc/a-1", "=app-misc/a-2")]
    consumer = kept("app-misc/k-1", deps={"RDEPEND": "app-misc/a:0"})
    assert best(root, [entry("app-misc/a-1", 0)], [consumer]) == []


def test_rebuild_at_the_installed_version_is_not_flagged_for_a_set(tmp_path):
    root = config_root(tmp_path, A12)
    rebuild = [entry("app-misc/a-1", 0, outcome="reinstall")]
    assert best(root, rebuild, request=["@world"]) == []
    assert best(root, rebuild) == [("best-version", "app-misc/a-1", "=app-misc/a-2")]


def test_masked_rebuild_is_flagged_even_for_a_set(tmp_path):
    root = config_root(tmp_path, A12)
    rebuild = [entry("app-misc/a-3", 0, outcome="reinstall")]
    assert best(root, rebuild, request=["@world"]) == [("visibility", "app-misc/a-3", "")]


# --- the installed state after a real merge ---------------------------------

def put(vdb, cpv, **files):
    """Add VDB variables (RDEPEND, USE, REQUIRED_USE, ...) to one installed package."""
    cat, pkg, version = split(cpv)
    d = vdb / cat / f"{pkg}-{version}"
    d.mkdir(parents=True, exist_ok=True)
    if not (d / "SLOT").exists():
        (d / "SLOT").write_text("0\n")
    for key, text in files.items():
        (d / key).write_text(text + "\n")


def state_failures(root, baseline=frozenset()):
    return [(f.property, f.package, f.atom, f.pre_existing)
            for f in hc.check_installed(root, baseline) if f.is_failure]


def test_a_healthy_installed_state_has_no_finding(tmp_path):
    vdb = installed_root(tmp_path, ZLIB)
    put(vdb, "app-misc/tool-1", RDEPEND="sys-libs/z")
    assert hc.check_installed(tmp_path) == []


def test_an_installed_program_whose_library_is_gone_is_flagged(tmp_path):
    installed_root(tmp_path, ZLIB)
    (tmp_path / "usr/lib64/libz.so.1").unlink()
    assert state_failures(tmp_path) == [("linked-library", "app-misc/tool-1", "libz.so.1", False)]


def test_a_library_that_is_only_preserved_on_disk_is_still_found(tmp_path):
    """Property 4 after a merge: the package is gone from the VDB, the file
    stays on disk (preserved), so the program still links."""
    vdb = installed_root(tmp_path, ZLIB)
    import shutil
    shutil.rmtree(vdb / "sys-libs/z-1")
    assert hc.check_installed(tmp_path) == []


def test_an_installed_package_with_an_unmatched_runtime_dependency_is_flagged(tmp_path):
    vdb = installed_root(tmp_path, {"app-misc/tool-1": {}})
    put(vdb, "app-misc/tool-1", RDEPEND="dev-libs/gone")
    assert state_failures(tmp_path) == [("runtime-deps", "app-misc/tool-1", "dev-libs/gone", False)]


def test_an_installed_blocker_REQUIRED_USE_and_double_slot_are_flagged(tmp_path):
    vdb = installed_root(tmp_path, {"app-misc/a-1": {}, "app-misc/b-1": {},
                                    "dev-libs/s-1": {}, "dev-libs/s-2": {}})
    put(vdb, "app-misc/a-1", RDEPEND="!app-misc/b")
    put(vdb, "app-misc/b-1", USE="x y", IUSE="x y", REQUIRED_USE="^^ ( x y )")
    assert sorted(state_failures(tmp_path)) == [
        ("blocker", "app-misc/a-1", "!app-misc/b", False),
        ("required-use", "app-misc/b-1", "^^ ( x y )", False),
        ("slot", "dev-libs/s", "dev-libs/s:0", False)]


def test_a_baseline_finding_is_pre_existing_and_a_new_one_is_not(tmp_path):
    installed_root(tmp_path, ZLIB)
    (tmp_path / "usr/lib64/libz.so.1").unlink()
    baseline = frozenset(hc.finding_key(f) for f in hc.check_installed(tmp_path))
    assert state_failures(tmp_path, baseline) == [("linked-library", "app-misc/tool-1", "libz.so.1", True)]
    put(tmp_path / "var/db/pkg", "app-misc/tool-1", RDEPEND="dev-libs/gone")
    assert sorted((p, pre) for p, _, _, pre in state_failures(tmp_path, baseline)) == [
        ("linked-library", True), ("runtime-deps", False)]


def test_installed_mode_exit_code_counts_only_what_the_merge_introduced(tmp_path, capsys):
    before = tmp_path / "before.jsonl"
    root = tmp_path / "root"
    vdb = installed_root(root, ZLIB)
    (root / "usr/lib64/libz.so.1").unlink()
    assert hc.main(["--installed", str(root)]) == 1
    before.write_text(capsys.readouterr().out)
    assert hc.main(["--installed", str(root), "--baseline", str(before)]) == 0
    put(vdb, "app-misc/tool-1", RDEPEND="dev-libs/gone")
    assert hc.main(["--installed", str(root), "--baseline", str(before)]) == 1


def load_state_mutants():
    import importlib.util
    from pathlib import Path
    path = Path(__file__).resolve().parents[1] / "differential-test-bed/compare/health-state-mutants.py"
    spec = importlib.util.spec_from_file_location("health_state_mutants", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_state_mutation_test_kills_every_mutant_and_leaves_the_control_clean(tmp_path):
    """The installed-state check notices each kind of breakage it claims to."""
    vdb = installed_root(tmp_path, {
        **ZLIB,
        "dev-libs/png-1": {"/usr/lib64/libpng.so.16.0": ("lib", "libpng.so.16", "libz.so.1")}})
    put(vdb, "app-misc/tool-1", RDEPEND="sys-libs/z dev-libs/png")
    put(vdb, "dev-libs/png-1", RDEPEND="sys-libs/z")
    assert hc.check_installed(tmp_path) == []
    mutants = load_state_mutants()
    results, ok = mutants.run(tmp_path, per_op=2)
    assert ok, [r for r in results if not r["good"]]
    assert {r["operator"] for r in results} == {op.__name__ for op in mutants.OPERATORS}


def test_a_library_installed_outside_the_search_path_is_a_note_not_a_failure(tmp_path):
    """A JDK or systemd keeps private libraries that their own program finds
    through its RUNPATH; the default linker lookup misses them, and that is fine."""
    installed_root(tmp_path, {
        **ZLIB,
        "dev-java/jdk-1": {"/opt/jdk/lib/libjvm.so.1.0": ("lib", "libjvm.so.1", ""),
                           "/opt/jdk/lib/libjava.so.1.0": ("lib", "libjava.so.1", "libjvm.so.1")}})
    found = hc.check_installed(tmp_path)
    assert [(f.property, f.package, f.atom, f.is_failure) for f in found] == [
        ("private-library", "dev-java/jdk-1", "libjvm.so.1", False)]


def test_a_library_that_is_found_nowhere_is_still_a_failure_next_to_private_ones(tmp_path):
    installed_root(tmp_path, {
        **ZLIB, "dev-java/jdk-1": {"/opt/jdk/lib/libjava.so.1.0": ("lib", "libjava.so.1", "libjvm.so.1")}})
    assert state_failures(tmp_path) == [("linked-library", "dev-java/jdk-1", "libjvm.so.1", False)]


def test_files_of_an_abi_this_system_cannot_run_are_not_checked(tmp_path):
    """maven-bin ships jline for ppc64 and arm: they need a libc nobody here has."""
    vdb = installed_root(tmp_path, ZLIB)
    foreign = tmp_path / "usr/share/maven/jline/ppc64/libjline.so"
    foreign.parent.mkdir(parents=True)
    foreign.write_bytes(b"\x7fELF")
    put(vdb, "dev-java/maven-1")
    (vdb / "dev-java/maven-1/NEEDED.ELF.2").write_text(
        "PPC64;/usr/share/maven/jline/ppc64/libjline.so;libjline.so;;libc.so.6;ppc_64\n")
    assert hc.check_installed(tmp_path) == []


# --- property 3 for binary packages -------------------------------------------

def binary_index(root, packages):
    """Write the local binary index: cpv -> keys (KEYWORDS defaults to amd64)."""
    pkgdir = root / "var/cache/binpkgs"
    pkgdir.mkdir(parents=True, exist_ok=True)
    blocks = ["VERSION: 0\nPACKAGES: %d\n" % len(packages)]
    for cpv, meta in packages.items():
        meta = {"CPV": cpv, "SLOT": "0", "KEYWORDS": "amd64", "LICENSE": "GPL-2", "EAPI": "8",
                "IUSE": "", "USE": "", "BUILD_ID": "1", **meta}
        blocks.append("".join(f"{k}: {v}\n" for k, v in meta.items()))
    (pkgdir / "Packages").write_text("\n".join(blocks))
    hc.visibility.cache_clear()


def best_bin(root, entries, options, request=("app-misc/a",)):
    doc = dict(plan(entries), request=list(request))
    if options is not None:
        doc["options"] = options
    return [(f.property, f.package, f.atom, f.is_failure)
            for f in hc.check_best_versions(doc, root / "var/db/pkg")]


USEPKG = {"usepkg": True, "usepkgonly": False, "getbinpkg": False, "getbinpkgonly": False}
USEPKGONLY = dict(USEPKG, usepkg=False, usepkgonly=True)


def bin_entry(cpv, **kw):
    return entry(cpv, 0, source="binary", **kw) | {"build_id": "1"}


def test_an_older_binary_than_the_best_visible_binary_is_flagged(tmp_path):
    root = config_root(tmp_path, {})
    binary_index(root, {"app-misc/a-1": {}, "app-misc/a-2": {}})
    for options in (USEPKG, USEPKGONLY, None):
        assert best_bin(root, [bin_entry("app-misc/a-1")], options) == [
            ("best-version", "app-misc/a-1", "=app-misc/a-2", True)]
    assert best_bin(root, [bin_entry("app-misc/a-2")], USEPKG) == []


def test_a_higher_ebuild_beats_a_merged_binary_with_usepkg_but_not_with_usepkgonly(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-2": {}})
    binary_index(root, {"app-misc/a-1": {}})
    merged = [bin_entry("app-misc/a-1")]
    assert best_bin(root, merged, USEPKG) == [("best-version", "app-misc/a-1", "=app-misc/a-2", True)]
    assert best_bin(root, merged, USEPKGONLY) == []


def test_without_options_a_higher_ebuild_for_a_merged_binary_is_only_a_note(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-2": {}})
    binary_index(root, {"app-misc/a-1": {}})
    assert best_bin(root, [bin_entry("app-misc/a-1")], None) == [
        ("checker-limitation", "app-misc/a-1", "=app-misc/a-2", False)]


def test_a_higher_binary_beats_a_merged_ebuild_only_with_usepkg(tmp_path):
    root = config_root(tmp_path, {"app-misc/a-1": {}})
    binary_index(root, {"app-misc/a-2": {}})
    merged = [entry("app-misc/a-1", 0)]
    assert best_bin(root, merged, USEPKG) == [("best-version", "app-misc/a-1", "=app-misc/a-2", True)]
    assert best_bin(root, merged, dict(USEPKG, usepkg=False)) == []
    assert best_bin(root, merged, None) == []


def test_a_binary_whose_use_differs_from_the_configured_one_is_not_a_candidate(tmp_path):
    """binpkg-respect-use: the newer binary was built with another flag."""
    root = config_root(tmp_path, {})
    binary_index(root, {"app-misc/a-1": {"IUSE": "x", "USE": "x"},
                        "app-misc/a-2": {"IUSE": "x", "USE": ""}})
    merged = [bin_entry("app-misc/a-1", use=["x"], iuse=["x"])]
    assert best_bin(root, merged, USEPKG) == []


def test_a_masked_newer_binary_is_not_flagged_and_a_masked_merged_one_is(tmp_path):
    root = config_root(tmp_path, {})
    binary_index(root, {"app-misc/a-1": {}, "app-misc/a-2": {"KEYWORDS": "~amd64"}})
    assert best_bin(root, [bin_entry("app-misc/a-1")], USEPKG) == []
    assert best_bin(root, [bin_entry("app-misc/a-2")], USEPKG) == [
        ("visibility", "app-misc/a-2", "", True)]


def test_a_merged_binary_missing_from_the_local_index_is_a_limitation_and_so_is_getbinpkg(tmp_path):
    root = config_root(tmp_path, {})
    binary_index(root, {"app-misc/a-2": {}})
    assert best_bin(root, [bin_entry("app-misc/a-1")], dict(USEPKG, getbinpkg=True)) == [
        ("checker-limitation", "", "", False),
        ("checker-limitation", "app-misc/a-1", "", False)]


def _xpak(meta):
    index = data = b""
    for name, value in meta.items():
        raw = value.encode()
        index += len(name).to_bytes(4, "big") + name.encode() + len(data).to_bytes(4, "big") \
            + len(raw).to_bytes(4, "big")
        data += raw
    xpak = b"XPAKPACK" + len(index).to_bytes(4, "big") + len(data).to_bytes(4, "big") \
        + index + data + b"XPAKSTOP"
    return b"\0" * 16 + xpak + len(xpak).to_bytes(4, "big") + b"STOP"


def _gpkg(path, meta):
    import io
    import tarfile
    inner = io.BytesIO()
    with tarfile.open(fileobj=inner, mode="w:gz") as tar:
        for name, value in meta.items():
            info = tarfile.TarInfo(f"{path.stem}/metadata/{name}")
            info.size = len(value)
            tar.addfile(info, io.BytesIO(value.encode()))
    with tarfile.open(path, "w") as tar:
        info = tarfile.TarInfo(f"{path.name.removesuffix('.gpkg.tar')}/metadata.tar.gz")
        info.size = len(inner.getvalue())
        tar.addfile(info, io.BytesIO(inner.getvalue()))


def test_a_cached_remote_index_is_read_for_getbinpkg(tmp_path):
    """A binhost named in binrepos.conf: the copy Portage cached under
    var/cache/edb/binhost/<host>/<path> is read, never the network."""
    root = config_root(tmp_path, {})
    (root / "etc/portage/binrepos.conf").write_text(
        "[remote]\nsync-uri = https://binhost.example/gentoo/\n")
    cache = root / "var/cache/edb/binhost/binhost.example/gentoo"
    cache.mkdir(parents=True)
    (cache / "Packages").write_text(
        "VERSION: 0\n\nCPV: app-misc/a-2\nSLOT: 0\nKEYWORDS: amd64\nLICENSE: GPL-2\n"
        "BUILD_ID: 1\n\nCPV: app-misc/a-1\nSLOT: 0\nKEYWORDS: amd64\nLICENSE: GPL-2\n"
        "BUILD_ID: 1\n")
    hc.visibility.cache_clear()
    options = dict(USEPKG, getbinpkg=True)
    assert best_bin(root, [bin_entry("app-misc/a-1")], options) == [
        ("best-version", "app-misc/a-1", "=app-misc/a-2", True)]


def test_portage_binhost_names_a_cached_index_too(tmp_path):
    root = config_root(tmp_path, {}, make_conf='PORTAGE_BINHOST="https://h.example/b"\n')
    cache = root / "var/cache/edb/binhost/h.example/b"
    cache.mkdir(parents=True)
    (cache / "Packages").write_text(
        "VERSION: 0\n\nCPV: app-misc/a-2\nSLOT: 0\nKEYWORDS: amd64\nLICENSE: GPL-2\nBUILD_ID: 1\n")
    hc.visibility.cache_clear()
    pool = hc.visibility(root).binary_candidates(("app-misc", "a"))
    assert [c.pkg.version for c in pool] == ["2"]


def test_pkgdir_files_without_an_index_line_are_candidates(tmp_path):
    """A flat PKGDIR (no index, or a file the index does not list): category
    and version come from the path, the slot from the file's own metadata."""
    root = config_root(tmp_path, {})
    pkgdir = root / "var/cache/binpkgs/app-misc"
    pkgdir.mkdir(parents=True)
    (pkgdir / "a-1.tbz2").write_bytes(_xpak({"SLOT": "1/2", "KEYWORDS": "amd64", "USE": "x"}))
    _gpkg(pkgdir / "a-2.gpkg.tar", {"SLOT": "3", "KEYWORDS": "amd64"})
    hc.visibility.cache_clear()
    pool = hc.visibility(root).binary_candidates(("app-misc", "a"))
    assert sorted((c.pkg.version, c.pkg.slot, c.pkg.subslot) for c in pool) == [
        ("1", "1", "2"), ("2", "3", "")]
    assert hc.visibility(root).binary_candidates(("app-misc", "zz")) == []


@pytest.mark.parametrize("flag, expected", [
    ("--usepkg", {"usepkg": True, "usepkgonly": False, "getbinpkg": False, "getbinpkgonly": False}),
    ("--usepkgonly", {"usepkg": False, "usepkgonly": True, "getbinpkg": False, "getbinpkgonly": False}),
])
def test_portuale_json_records_the_binary_options_and_the_checker_reads_a_binary_entry(
        flag, expected, emerge_binary, fixture_env):
    """`-v --json` carries the options that decide the candidates (a plan
    checker needs them for property 3 with binary packages); a binary entry
    whose index line the checker cannot read is a note, never a failure of
    property 3 (the fixture's VDB has failures of its own)."""
    run = subprocess.run([str(emerge_binary), "--pretend", "-v", "--json", flag,
                          "dev-libs/binaryonlypkg"],
                         capture_output=True, text=True, env=fixture_env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert doc["options"] == expected, run.stdout + run.stderr
    assert [e["source"] for e in doc["entries"]] == ["binary"]
    vdb = hc.Path(fixture_env["ROOT"]) / "var/db/pkg"
    assert [f for f in hc.check_best_versions(doc, vdb) if f.is_failure] == []


def test_the_json_without_verbose_has_no_options(emerge_binary, fixture_env):
    """`options` is part of the `-v` extras, like `kept` and `request`."""
    run = subprocess.run([str(emerge_binary), "--pretend", "--json", "--usepkg",
                          "dev-libs/binaryonlypkg"],
                         capture_output=True, text=True, env=fixture_env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert doc is not None and "options" not in doc and "request" not in doc


def test_the_binary_mutation_operator_breaks_a_clean_plan_and_the_checker_notices(tmp_path):
    """health-mutants.py `older_visible_binary`: swap the merged binary for an
    older visible one; the checker must report best-version."""
    import importlib.util
    from pathlib import Path
    path = Path(__file__).resolve().parents[1] / "differential-test-bed/compare/health-mutants.py"
    spec = importlib.util.spec_from_file_location("health_mutants", path)
    mutants = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mutants)
    root = config_root(tmp_path, {})
    binary_index(root, {"app-misc/a-1": {}, "app-misc/a-2": {}})
    vdb = root / "var/db/pkg"
    mutants.VDB = vdb
    doc = dict(plan([bin_entry("app-misc/a-2")]), request=["app-misc/a"], options=USEPKG)
    assert hc.check_best_versions(doc, vdb) == []
    offers = list(mutants.older_visible_binary(doc, hc.load_plan(doc, vdb)))
    assert [desc for desc, _, _ in offers] == ["merge binary app-misc/a-1 instead of 2"]
    _, make, expected = offers[0]
    assert expected == {"best-version"}
    assert [f.property for f in hc.check_best_versions(make(), vdb)] == ["best-version"]


def _check_world_json(mrg_binary, fixture_env, tmp_path, world):
    root = tmp_path / "root"
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("".join(a + "\n" for a in world))
    env = dict(fixture_env, ROOT=str(root), PORTAGE_RUNNING_ROOT=str(root))
    run = subprocess.run([str(mrg_binary), "--check-world", "--json"],
                         capture_output=True, text=True, env=env, check=False)
    lines = [json.loads(line) for line in run.stdout.splitlines()]
    return run.returncode, lines[:-1], lines[-1]


def test_692_check_world_json_loads_as_findings(mrg_binary, fixture_env, tmp_path):
    """Charter property 1: `mrg --check-world --json` speaks the checker's `Finding`
    shape, so the report groups it unchanged; a missing package is a failure."""
    rc, findings, summary = _check_world_json(
        mrg_binary, fixture_env, tmp_path, ["app-misc/doesnotexist", "dev-libs/w701two"])
    loaded = [hc.Finding(**f) for f in findings]
    assert rc == 1 and summary["unsatisfiable"] == 1
    assert [(f.property, f.atom, f.is_failure) for f in loaded] == [
        ("world-no-match", "app-misc/doesnotexist", True)]
    rc, findings, summary = _check_world_json(
        mrg_binary, fixture_env, tmp_path / "clean", [])
    assert (rc, findings, summary["unsatisfiable"]) == (0, [], 0)
    assert not hc.Finding("world-unneeded", "a/b:1", "", "x").is_failure


def test_693_plan_world_json_loads_and_the_checker_judges_it(mrg_binary, fixture_env):
    """Charter properties 1 and 2: `mrg --plan-world --json` is a plan the
    checker loads (entries in `depend` order, the rest of the VDB as `kept`)
    and finds nothing wrong in that the installed system did not have already.
    Source: the checker, written from the PMS."""
    run = subprocess.run([str(mrg_binary), "--plan-world", "--json", "--sort", "depend"],
                         capture_output=True, text=True, env=fixture_env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert run.returncode == 0 and doc is not None, run.stdout + run.stderr
    assert [e["outcome"] for e in doc["entries"]].count("upgrade") == 1
    assert [e["merge_order"] for e in doc["entries"]] == list(range(len(doc["entries"])))
    vdb = hc.Path(fixture_env["ROOT"]) / "var/db/pkg"
    found = [f for f in hc.check_document(doc, vdb) if f.is_failure and not f.pre_existing]
    assert found == [], found


def _write_ebuild(repo, cpv, slot, deps=()):
    """An ebuild and its md5-cache entry in `repo` (a copy of the fixtures)."""
    category, pf = cpv.split("/")
    package = pf.rsplit("-", 1)[0]
    variables = [("EAPI", "8"), ("SLOT", slot), ("KEYWORDS", "amd64"), *deps]
    pdir = repo / "repo" / category / package
    pdir.mkdir(parents=True, exist_ok=True)
    text = "".join(f'{k}="{v}"\n' for k, v in variables)
    (pdir / f"{pf}.ebuild").write_text(text)
    cache = repo / "repo/metadata/md5-cache" / category
    cache.mkdir(parents=True, exist_ok=True)
    md5 = hashlib.md5(text.encode()).hexdigest()
    lines = sorted(f"{k}={v}\n" for k, v in variables)
    (cache / pf).write_text("".join(lines) + f"_md5_={md5}\n")


def _write_installed(root, cpf, slot, **recorded):
    """A VDB entry for `cpf` with `SLOT` and the recorded variables."""
    vdir = root / "var/db/pkg" / cpf
    vdir.mkdir(parents=True)
    files = {"CATEGORY": cpf.split("/")[0], "SLOT": slot, "EAPI": "8", **recorded}
    for name, value in files.items():
        (vdir / name).write_text(value + "\n")


def test_693_a_sub_slot_upgrade_rebuilds_the_slot_operator_consumer(mrg_binary, fixture_env, tmp_path):
    """Charter property 1: the provider moves from sub-slot 0/1 to 0/2, so
    the `:=` consumer that recorded `0/1` is rebuilt after it; the `:*`
    consumer is not. The plan loads in the checker and finds nothing wrong.
    Source: PMS `dependencies.tex`, `sec:slot-dep`."""
    root = tmp_path / "tree"
    shutil.copytree(fixture_env["ROOT"], root, symlinks=True)
    _write_ebuild(root, "dev-libs/w693prov-2", "0/2")
    _write_installed(root, "dev-libs/w693prov-1", "0/1")
    _write_ebuild(root, "dev-libs/w693cons-1", "0", [("RDEPEND", "dev-libs/w693prov:=")])
    _write_installed(root, "dev-libs/w693cons-1", "0", RDEPEND="dev-libs/w693prov:0/1=")
    _write_ebuild(root, "dev-libs/w693star-1", "0", [("RDEPEND", "dev-libs/w693prov:*")])
    _write_installed(root, "dev-libs/w693star-1", "0", RDEPEND="dev-libs/w693prov:*")
    with (root / "var/lib/portage/world").open("a") as world:
        world.write("dev-libs/w693cons\ndev-libs/w693star\n")
    env = dict(fixture_env, ROOT=str(root), PORTAGE_CONFIGROOT=str(root), PORTAGE_RUNNING_ROOT=str(root))
    run = subprocess.run([str(mrg_binary), "--plan-world", "--json", "--sort", "depend"],
                         capture_output=True, text=True, env=env, check=False)
    doc = hc.parse_json_output(run.stdout)
    assert run.returncode == 0 and doc is not None, run.stdout + run.stderr
    found = [f for f in hc.check_document(doc, root / "var/db/pkg") if f.is_failure and not f.pre_existing]
    assert found == [], found
    ours = [(e["package"], e["outcome"]) for e in doc["entries"] if e["package"].startswith("w693")]
    assert ours == [("w693prov", "upgrade"), ("w693cons", "reinstall")], ours
