#!/usr/bin/env python3
"""Self-test for `--count-categories` and the `flags` -> `action` + `columns` split (backlog #34 S0).

Exercises compare(split_action=True) and count_findings() in
resolve-compare.py plus the `--count-categories` CLI: a fixture pair
with one extra row, one order-only difference and one row differing
only in `~` must count `extra 1` and nothing else; without the option
the same pair reports the `~` row as `flags` (output unchanged).

Run: python3 differential-test-bed/compare/test-count-categories.py   (exit 0 = all good)
"""

import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare_resolve_cc", HERE / "resolve-compare.py")
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
# Registered before exec: module-level @dataclass needs
# sys.modules[name] to exist (same trap as dataclasses docs).
sys.modules["compare_resolve_cc"] = mod
spec.loader.exec_module(mod)

FAILED = 0


def check(label, cond, detail=""):
    global FAILED
    status = "ok" if cond else "FAIL"
    print(f"  [{status}] {label}" + (f": {detail}" if detail and not cond else ""))
    if not cond:
        FAILED += 1


COUNTED = ["missing", "extra", "version", "action", "exit"]

REAL = """[ebuild  N     ] dev-libs/pg34-a-1.0
[ebuild  N     ] dev-libs/pg34-b-1.0
[ebuild  R     ] dev-libs/pg34-d-1.0
"""

# vs real: pg34-c is extra, a/b are swapped (order-only), pg34-d
# differs only in the `~` bracket column.
PTL = """[ebuild  N     ] dev-libs/pg34-b-1.0
[ebuild  N     ] dev-libs/pg34-a-1.0
[ebuild  N     ] dev-libs/pg34-c-1.0
[ebuild  R    ~] dev-libs/pg34-d-1.0
"""


def run_case(portage_text, ptl_text, split_action=False, rrc=0, prc=0):
    with tempfile.TemporaryDirectory() as tmp:
        rp = Path(tmp) / "r.txt"
        pp = Path(tmp) / "p.txt"
        rp.write_text(portage_text)
        pp.write_text(ptl_text)
        return mod.compare("probe", "case", rrc, prc, rp, pp, split_action=split_action)


def cats(findings):
    return sorted(f["category"] for f in findings)


def main() -> int:
    # 1. split_flags unit cases
    check("split N", mod.split_flags("N") == ("N", ""), repr(mod.split_flags("N")))
    check("split R ~", mod.split_flags("R ~") == ("R", "~"), repr(mod.split_flags("R ~")))
    check("split NS", mod.split_flags("NS") == ("NS", ""), repr(mod.split_flags("NS")))
    check("split empty", mod.split_flags("") == ("", ""), repr(mod.split_flags("")))

    # 2. default mode is unchanged: the `~` row is a `flags` finding
    pr = run_case(REAL, PTL)
    check("default: flags finding for the ~ row",
          any(f["category"] == "flags" and "pg34-d" in f["detail"] for f in pr.findings),
          repr(pr.findings))
    check("default: no action/columns findings",
          not [f for f in pr.findings if f["category"] in ("action", "columns")],
          repr(pr.findings))

    # 3. split mode: extra + order + columns, nothing else
    pr = run_case(REAL, PTL, split_action=True)
    check("split: one extra row",
          len([f for f in pr.findings if f["category"] == "extra"]) == 1, repr(pr.findings))
    check("split: order-only difference is an order finding",
          len([f for f in pr.findings if f["category"] == "order"]) == 1, repr(pr.findings))
    check("split: ~-only difference is columns, not action",
          len([f for f in pr.findings if f["category"] == "columns"]) == 1
          and not [f for f in pr.findings if f["category"] == "action"], repr(pr.findings))
    check("split: no flags findings",
          not [f for f in pr.findings if f["category"] == "flags"], repr(pr.findings))

    # 4. the S0 acceptance: extra 1, nothing else counted
    counts = mod.count_findings(pr.findings, COUNTED)
    check("counts: extra 1, nothing else",
          counts == {"missing": 0, "extra": 1, "version": 0, "action": 0, "exit": 0},
          repr(counts))

    # 5. identical inputs compare clean in both modes
    check("identical: default clean",
          run_case(REAL, REAL).findings == [], repr(run_case(REAL, REAL).findings))
    check("identical: split clean",
          run_case(REAL, REAL, split_action=True).findings == [],
          repr(run_case(REAL, REAL, split_action=True).findings))

    # 6. a real action-letter change counts as action, not columns
    pr = run_case(REAL, REAL.replace("[ebuild  R     ] dev-libs/pg34-d-1.0",
                                     "[ebuild  U     ] dev-libs/pg34-d-1.0"),
                  split_action=True)
    check("action-letter change is one action finding",
          len([f for f in pr.findings if f["category"] == "action"]) == 1
          and not [f for f in pr.findings if f["category"] == "columns"], repr(pr.findings))
    check("action-letter change counts",
          mod.count_findings(pr.findings, COUNTED)["action"] == 1, repr(pr.findings))

    # 7. allowlist layer l0-pubgrub explains, other layers do not
    pr = run_case(REAL, PTL, split_action=True)
    extra = next(f for f in pr.findings if f["category"] == "extra")
    allow = [{"id": "pg", "layer": "l0-pubgrub", "categories": ["extra"], "match": "pg34-c"}]
    check("l0-pubgrub entry explains",
          mod.explained(extra, "s", "atom", allow) is not None,
          repr(mod.explained(extra, "s", "atom", allow)))
    other = [{"id": "other", "layer": "l1", "categories": ["extra"], "match": "pg34-c"}]
    check("l1 entry does not explain an l0 probe",
          mod.explained(extra, "s", "atom", other) is None,
          repr(mod.explained(extra, "s", "atom", other)))

    # 8. CLI end to end: --count-categories prints CAT\tcount lines
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "real").mkdir()
        (d / "portuale").mkdir()
        (d / "real" / "probe.txt").write_text(REAL)
        (d / "portuale" / "probe.txt").write_text(PTL)
        (d / "meta.tsv").write_text("probe\tatom\t0\t0\n")
        (d / "known.yaml").write_text("[]\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = mod.main(["--count-categories", ",".join(COUNTED), str(d), str(d / "known.yaml")])
        out = buf.getvalue()
    check("CLI rc is 1 (unexplained remain)", rc == 1, f"rc={rc}")
    check("CLI prints extra\\t1", "extra\t1" in out, out)
    for c in ("missing", "version", "action", "exit"):
        check(f"CLI prints {c}\\t0", f"{c}\t0" in out, out)
    check("CLI prints per-probe line", "probe\textra\t1" in out, out)
    check("CLI does not count order/columns",
          "order\t" not in out and "columns\t" not in out, out)

    # 9. CLI without the option: no counts section (output unchanged shape)
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "real").mkdir()
        (d / "portuale").mkdir()
        (d / "real" / "probe.txt").write_text(REAL)
        (d / "portuale" / "probe.txt").write_text(PTL)
        (d / "meta.tsv").write_text("probe\tatom\t0\t0\n")
        (d / "known.yaml").write_text("[]\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mod.main([str(d), str(d / "known.yaml")])
        out = buf.getvalue()
    check("default CLI has no counts section",
          "## counts" not in out and "extra\t1" not in out, out)
    check("default CLI still reports flags",
          "[flags]" in out, out)

    print("ALL OK" if FAILED == 0 else "FAILURES")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
