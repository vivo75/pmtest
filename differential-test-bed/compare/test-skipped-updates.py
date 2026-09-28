#!/usr/bin/env python3
"""Self-test for the `skipped-updates` finding category (backlog #227).

Exercises parse()/compare() in resolve-compare.py (L0 + fixture
oracle): the `WARNING: One or more updates/rebuilds have been skipped
due to a dependency conflict:` block real prints from
`_show_missed_update_slot_conflicts`
(`3rdparty/portage/lib/_emerge/depgraph.py:1652`, 3.0.82.2) and
portuale renders from `GraphResult::skipped_updates`
(`rust/portuale/src/pretend.rs`). Synthetic outputs below follow the
shapes observed in
`differential-test-bed/logs/l0-fx-20260927T125711Z/` (both sides print,
different USE displays) and `l0-fx-20260924T211811Z/` (real-only block
followed by the `!!!` abbreviated tail).

Pinned behaviour: presence on one side only, and a different skipped
package list, are findings; the explanation text (USE/USE_EXPAND
displays, `^` markers, `to '<root>'` suffixes) is compared only when
both sides print the block; staged-root paths normalise to a
placeholder; portuale's one-block-per-parent grouping merges back to
real's one-block-per-slot shape.

Run: python3 differential-test-bed/compare/test-skipped-updates.py   (exit 0 = all good)
"""

import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare_resolve", HERE / "resolve-compare.py")
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
# Registered before exec: module-level @dataclass needs
# sys.modules[name] to exist (same trap as dataclasses docs).
sys.modules["compare_resolve"] = mod
spec.loader.exec_module(mod)

FAILED = 0


def check(label, cond, detail=""):
    global FAILED
    status = "ok" if cond else "FAIL"
    print(f"  [{status}] {label}" + (f": {detail}" if detail and not cond else ""))
    if not cond:
        FAILED += 1


MERGE = """[ebuild  N     ] dev-libs/r25up-2.0 [1.0]
[ebuild  N     ] dev-libs/r25target-1.0
"""

# Portuale's r25 shape (contract pin
# test_emerge_pretend_contract.py: the warning real never prints).
PTL_R25 = MERGE + """WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:

dev-libs/r25lib:0

  (dev-libs/r25lib-2.0:0/2::testrepo, ebuild scheduled for merge) USE="" conflicts with
    <dev-libs/r25lib-2.0:= required by (dev-libs/r25consumer-1.0:0/0::testrepo, installed) USE=""
    ^                ^^^

"""

# Real's blk0 shape: one group, two parents, USE_EXPAND displays and
# `merge to '<ROOT>'` suffixes (ROOT != "/" in the fixture-oracle bed).
REAL_BLK0 = MERGE + """WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:

dev-libs/blk0x:0

  (dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge) USE="(test-rust)" ABI_X86="(64)" LLVM_TARGETS="(X86)" conflicts with
    <dev-libs/blk0x-2 required by (dev-libs/blk0b-1:0/0::testrepo, ebuild scheduled for merge to '/tmp/l0-fixture-oracle/fixtures/') USE="(globalforceflag)"
    ^               ^
    <dev-libs/blk0x-3 required by (dev-libs/blk0c-1:0/0::testrepo, ebuild scheduled for merge to '/tmp/l0-fixture-oracle/fixtures/') USE="(globalforceflag)"
    ^               ^

"""

# Portuale's blk0 shape: same skipped packages, one block per parent,
# bare USE displays, no root suffixes.
PTL_BLK0 = MERGE + """WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:

dev-libs/blk0x:0

  (dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge) USE="" conflicts with
    <dev-libs/blk0x-2 required by (dev-libs/blk0b-1:0/0::testrepo, ebuild scheduled for merge) USE=""
    ^               ^

dev-libs/blk0x:0

  (dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge) USE="" conflicts with
    <dev-libs/blk0x-3 required by (dev-libs/blk0c-1:0/0::testrepo, ebuild scheduled for merge) USE=""
    ^               ^

"""


def run_case(real_text, ptl_text, rrc=0, prc=0):
    with tempfile.TemporaryDirectory() as tmp:
        rp = Path(tmp) / "r.txt"
        pp = Path(tmp) / "p.txt"
        rp.write_text(real_text)
        pp.write_text(ptl_text)
        return mod.compare("probe", "case", rrc, prc, rp, pp)


def skipped(findings):
    return [f for f in findings if f["category"] == "skipped-updates"]


def main() -> int:
    # 1. presence on one side only (the r25 shape that motivated #227)
    pr = run_case(MERGE, PTL_R25)
    s = skipped(pr.findings)
    check("portuale-only block is one skipped-updates finding",
          len(s) == 1 and "present for portuale, absent for real" in s[0]["detail"]
          and "dev-libs/r25lib:0" in s[0]["detail"], repr(pr.findings))
    check("block lines do not leak into error findings",
          not [f for f in pr.findings if f["category"] == "error"], repr(pr.findings))

    pr = run_case(PTL_R25, MERGE)
    s = skipped(pr.findings)
    check("real-only block mirrors the presence finding",
          len(s) == 1 and "present for real, absent for portuale" in s[0]["detail"],
          repr(pr.findings))

    # 2. byte-identical blocks compare clean
    pr = run_case(PTL_R25, PTL_R25)
    check("identical blocks: no findings", pr.findings == [], repr(pr.findings))

    # 3. different skipped package list (extra header on one side)
    pr = run_case(REAL_BLK0, REAL_BLK0 + PTL_R25.split(MERGE)[1])
    s = skipped(pr.findings)
    check("extra skipped header is a finding",
          len(s) == 1 and "present for portuale, absent for real: dev-libs/r25lib:0"
          in s[0]["detail"], repr(pr.findings))

    # 4. same header, different conflict atoms
    other = REAL_BLK0.replace("<dev-libs/blk0x-3 required by",
                              "<dev-libs/blk0x-4 required by")
    pr = run_case(REAL_BLK0, other)
    s = skipped(pr.findings)
    check("different conflict atoms are a package-list finding",
          len(s) == 1 and "skipped package list differs" in s[0]["detail"]
          and "dev-libs/blk0x:0" in s[0]["detail"], repr(pr.findings))

    # 5. same packages, different explanation (the live blk0 divergence:
    # USE_EXPAND displays + `to '<root>'` suffixes vs bare USE)
    pr = run_case(REAL_BLK0, PTL_BLK0)
    s = skipped(pr.findings)
    check("same packages: no package-list finding",
          not [f for f in s if "package list differs" in f["detail"]
               or "present for" in f["detail"]], repr(pr.findings))
    check("same packages: explanation finding cites both sides",
          len(s) == 1 and "explanation differs" in s[0]["detail"]
          and "real-only" in s[0]["detail"] and "portuale-only" in s[0]["detail"],
          repr(pr.findings))

    # 6. staged-root paths normalise away (same block, different roots)
    alt = REAL_BLK0.replace("/tmp/l0-fixture-oracle/fixtures/", "/tmp/other-stage/fx/")
    pr = run_case(REAL_BLK0, alt)
    check("staged-root path is volatile, not signal", pr.findings == [], repr(pr.findings))

    # 7. grouping merges: portuale's split blocks vs real's grouped
    # block with otherwise identical text compare clean
    grouped = PTL_BLK0.replace(
        '\ndev-libs/blk0x:0\n\n  (dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge) USE="" conflicts with\n'
        '    <dev-libs/blk0x-3 required by (dev-libs/blk0c-1:0/0::testrepo, ebuild scheduled for merge) USE=""\n'
        '    ^               ^\n',
        '    <dev-libs/blk0x-3 required by (dev-libs/blk0c-1:0/0::testrepo, ebuild scheduled for merge) USE=""\n'
        '    ^               ^\n')
    pr = run_case(grouped, PTL_BLK0)
    s = skipped(pr.findings)
    check("regrouping is not a package-list finding",
          not [f for f in s if "package list differs" in f["detail"]
               or "present for" in f["detail"]], repr(pr.findings))
    check("regrouping still reports the duplicated with-line as explanation",
          len(s) == 1 and "explanation differs" in s[0]["detail"]
          and "conflicts with" in s[0]["detail"], repr(pr.findings))

    # 8. the `!!!` abbreviated tail still flows to error findings and
    # its bare `cat/pkg:slot` lines do not become phantom groups
    tail = ("!!! The following update(s) have been skipped due to unsatisfied dependencies\n"
            "!!! triggered by backtracking:\n\ndev-libs/mgxb:0\ndev-libs/mgfb:0\n")
    pr = run_case(REAL_BLK0 + "\n" + tail, PTL_BLK0)
    s = skipped(pr.findings)
    check("tail does not corrupt the skipped parse",
          len(s) == 1 and "explanation differs" in s[0]["detail"], repr(pr.findings))
    check("tail !!! lines still surface as error findings",
          len([f for f in pr.findings if f["category"] == "error"]) == 2,
          repr(pr.findings))

    # 9. different missed versions under the same header
    other = REAL_BLK0.replace("(dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge)",
                              "(dev-libs/blk0x-2:0/0::testrepo, ebuild scheduled for merge)")
    pr = run_case(REAL_BLK0, other)
    s = skipped(pr.findings)
    check("different missed versions are a package-list finding",
          len(s) == 1 and "skipped package list differs" in s[0]["detail"],
          repr(pr.findings))

    # 10. parse() shape: groups keyed by header, sorted rows/expl
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "x.txt"
        p.write_text(PTL_BLK0)
        _, _, _, _, _, groups = mod.parse(p)
    check("parse groups duplicate headers into one entry",
          list(groups) == ["dev-libs/blk0x:0"]
          and len(groups["dev-libs/blk0x:0"]["rows"]) == 2
          and len(groups["dev-libs/blk0x:0"]["with"]) == 1, repr(groups))

    # 11. real's ` for <root>` header suffix (non-"/" ROOT, #210 g210 cells)
    real_for_root = (
        "WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:\n"
        "\n"
        "dev-libs/reinstslottarget:0 for /tmp/l0-fixture-oracle/fixtures/\n"
        "\n"
        "  (dev-libs/reinstslottarget-1.0:0/2::testrepo, ebuild scheduled for merge to '/tmp/l0-fixture-oracle/fixtures/') USE=\"\" ELIBC=\"glibc\" conflicts with\n"
        "    dev-libs/reinstslottarget:0/1 required by (dev-libs/reinstslotconsumer-1.0:0/0::testrepo, installed in '/tmp/l0-fixture-oracle/fixtures/') USE=\"\"\n"
        "                             ^^^^\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "x.txt"
        p.write_text(real_for_root)
        _, _, _, _, _, groups = mod.parse(p)
    check("a ` for <root>` header still opens a group keyed on the slot atom",
          list(groups) == ["dev-libs/reinstslottarget:0"], repr(groups))

    # 12. backlog #230 fix round 1: a merge parent with real's
    # `to '<root>'` suffix equals portuale's bare one. USE content is
    # identical on both sides here (post-#220 both render
    # `USE="" ELIBC="glibc"` on the parents); the live blk0 cells keep
    # an explanation finding only through the missed line's
    # running-root `ABI_X86` group, which is deliberately NOT
    # normalised.
    real_to_suffix = MERGE + (
        "WARNING: One or more updates/rebuilds have been skipped due to a dependency conflict:\n"
        "\n"
        "dev-libs/blk0x:0\n"
        "\n"
        "  (dev-libs/blk0x-3:0/0::testrepo, ebuild scheduled for merge) USE=\"\" ELIBC=\"glibc\" conflicts with\n"
        "    <dev-libs/blk0x-2 required by (dev-libs/blk0b-1:0/0::testrepo, ebuild scheduled for merge to '/tmp/l0-fixture-oracle/fixtures/') USE=\"\" ELIBC=\"glibc\"\n"
        "    ^               ^\n"
        "\n"
    )
    ptl_bare = real_to_suffix.replace("ebuild scheduled for merge to '/tmp/l0-fixture-oracle/fixtures/'",
                                      "ebuild scheduled for merge")
    pr = run_case(real_to_suffix, ptl_bare)
    check("merge-parent `to '<root>'` suffix is not an explanation finding",
          pr.findings == [], repr(pr.findings))
    # ... but USE content still is: restoring a USE delta on the same
    # pair must fire again (no USE normalisation).
    pr = run_case(real_to_suffix.replace('USE="" ELIBC="glibc" conflicts',
                                        'USE="" ABI_X86="(64)" conflicts'),
                  ptl_bare)
    s = skipped(pr.findings)
    check("missed-line USE content still reports an explanation finding",
          len(s) == 1 and "explanation differs" in s[0]["detail"], repr(pr.findings))

    print("ALL OK" if FAILED == 0 else "FAILURES")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
