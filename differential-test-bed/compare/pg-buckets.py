#!/usr/bin/env python3
"""Backlog #34 S0 Step 7: bucket the pubgrub-vs-Portage counted findings.

For each of the 5 mode run dirs and each probe, parses real vs portuale
rows (via resolve-compare.py's parse/split_flags/split_cpv -- imported,
not copied) plus a per-probe PORTUALE_PG_TRACE=1 capture
(<rundir>/pgtrace/<probe>.txt, captured separately: one container per
mode looping over only the probes that have extras, see trace-run.sh in
each run dir). Every counted missing/extra finding gets exactly ONE
bucket:

  MISSING (in Portage, not in portuale):
    Portage action letter R -> H-no-R; else H-slot if the same cp is
    present in portuale's output with another slot/version, else H-other.
  EXTRA (in portuale, not in Portage): shortest chain from a pg-target
  root over the pg-edge graph, rules in order:
    1. extra cp == target cp (trace shows pg-target slot=*) -> H-target-all-slots
    2. first edge ON THE CHAIN whose parent cpv is pg-installed: mode without D ->
       H-installed-expanded; with D: class DEPEND/BDEPEND ->
       H-installed-bdeps, class RDEPEND/PDEPEND/IDEPEND ->
       H-installed-config-USE
    3. chain passes through an edge whose child cp is pg-closure
       'shallow' while the parent is installed -> H-closure
    4. H-installed-only: skipped (not detectable from the trace alone)
    5. remainder -> H-other (incl. unreachable: no chain from any root)
  H-cycle / H-pdepend-idepend / H-switches / H-or-choice are reported as
  0 with the note 'not distinguishable by script'.

Writes LLM/evidence/2026-10-14-34-s0/buckets.md. stdlib only.

Usage: pg-buckets.py  (paths are baked in MODES / OUT below)
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

HERE = Path(__file__).resolve().parent
PMTEST = HERE.parent.parent  # differential-test-bed/compare -> pmtest

# mode -> (run dir, emerge opts used on both sides, has --deep)
MODES: list[tuple[str, str, str, bool]] = [
    ("-pv", "l0-20261014T100015Z", "-pv --getbinpkg=n --usepkg=n", False),
    ("-pvu", "l0-20261014T100547Z", "-pvu --getbinpkg=n --usepkg=n", False),
    ("-pvuD", "l0-20261014T101050Z", "-pvuD --getbinpkg=n --usepkg=n", True),
    ("-pvuDN", "l0-20261014T101728Z", "-pvuDN --getbinpkg=n --usepkg=n", True),
    ("-pve", "l0-20261014T102449Z", "-pve --getbinpkg=n --usepkg=n", False),
]

# Expected counted totals (modes.md §Totals, unexplained only).
EXPECTED: dict[str, dict[str, int]] = {
    "-pv": {"missing": 203, "extra": 1679},
    "-pvu": {"missing": 9, "extra": 1698},
    "-pvuD": {"missing": 82, "extra": 1698},
    "-pvuDN": {"missing": 2516, "extra": 137},
    "-pve": {"missing": 26078, "extra": 137},
}

BUCKETS = [
    "H-target-all-slots", "H-installed-expanded", "H-installed-config-USE",
    "H-installed-bdeps", "H-closure", "H-no-R", "H-installed-only",
    "H-switches", "H-slot", "H-or-choice", "H-cycle", "H-pdepend-idepend",
    "H-other",
]
MISSING_BUCKETS = {"H-no-R", "H-slot", "H-other"}
EXTRA_BUCKETS = {
    "H-target-all-slots", "H-installed-expanded", "H-installed-config-USE",
    "H-installed-bdeps", "H-closure", "H-installed-only", "H-switches",
    "H-or-choice", "H-cycle", "H-pdepend-idepend", "H-other",
}

OUT = Path("/home/vivo/repo/PORTUALE/portuale/LLM/evidence/2026-10-14-34-s0/buckets.md")

# --- import resolve-compare.py (hyphenated name) without copying ---------
_spec = importlib.util.spec_from_file_location(
    "resolve_compare", HERE / "resolve-compare.py")
assert _spec and _spec.loader
rc = importlib.util.module_from_spec(_spec)
sys.modules["resolve_compare"] = rc
_spec.loader.exec_module(rc)

RE_TARGET = re.compile(r"^pg-target (\S+) slot=(\S+)\s*$")
RE_EDGE = re.compile(r"^pg-edge (\S+) -> (\S+) \((\w+)\)\s*$")
RE_INST = re.compile(r"^pg-installed (\S+) slot=(\S+) policy=(\S+)\s*$")
RE_CLOS = re.compile(r"^pg-closure (\S+) (expanded|shallow)\s*$")

# Repair for the comparator's `-rN:slot` artifact: `split_cpv_slot`
# fails on tokens like `sys-devel/binutils-2.44-r4:2.44` (the CPV regex
# cannot match `-r4` followed by `:slot`), returning the whole token as
# cp with empty ver/slot. A cp never contains ':', and ':' never occurs
# in a version, so `ver == '' and ':' in cp` is exactly the artifact
# signature. Repaired with the same version grammar, used ONLY for
# bucket attribution (cp identity vs trace roots/graph); the
# comparator-identical keys stay authoritative for counting, so the
# totals still reconcile 1:1 with l0-report.json.
REPAIR = re.compile(r"^(?P<cp>.+?)-(?P<ver>\d[^-]*(?:-r\d+)?):(?P<slot>[^:]+)$")
repaired_artifacts = 0


def repaired(pkg: tuple[str, str, str]) -> tuple[str, str, str]:
    """(cp, ver, slot) with the `-rN:slot` artifact repaired."""
    global repaired_artifacts
    cp, ver, slot = pkg
    if ver == "" and ":" in cp:
        m = REPAIR.match(cp)
        if m:
            repaired_artifacts += 1
            return m.group("cp"), m.group("ver"), m.group("slot")
    return cp, ver, slot


def parse_trace(path: Path) -> dict:
    targets: dict[str, str] = {}
    installed: set[str] = set()
    installed_cp: set[str] = set()
    adj: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    closure: dict[str, str] = {}
    n_edge = 0
    for line in path.read_text(errors="replace").splitlines():
        m = RE_TARGET.match(line)
        if m:
            targets[m.group(1)] = m.group(2)
            continue
        m = RE_EDGE.match(line)
        if m:
            parent_cpv, child_cp, cls = m.group(1), m.group(2), m.group(3)
            parent_cp, _, _ = rc.split_cpv(parent_cpv)
            adj[parent_cp].append((child_cp, cls, parent_cpv))
            n_edge += 1
            continue
        m = RE_INST.match(line)
        if m:
            installed.add(m.group(1))
            cp, _, _ = rc.split_cpv(m.group(1))
            installed_cp.add(cp)
            continue
        m = RE_CLOS.match(line)
        if m:
            closure[m.group(1)] = m.group(2)
            continue
    return {"targets": targets, "installed": installed,
            "installed_cp": installed_cp, "adj": adj, "closure": closure,
            "n_edge": n_edge}


def shortest_chain(adj: dict, roots: set[str], goal: str,
                   ) -> list[tuple[str, str, str]] | None:
    """BFS over cp nodes; returns the edge path
    [(parent_cpv, child_cp, class), ...] or None."""
    if goal in roots:
        return []
    seen = set(roots)
    q: deque[tuple[str, list]] = deque((r, []) for r in roots)
    while q:
        node, path = q.popleft()
        for child, cls, pcpv in adj.get(node, []):
            if child in seen:
                continue
            npath = path + [(pcpv, child, cls)]
            if child == goal:
                return npath
            seen.add(child)
            q.append((child, npath))
    return None


def chain_str(roots: set[str], path: list, goal: str) -> str:
    if not path:
        return f"{goal} == target root"
    bits = []
    cur = None
    # find which root starts the path: first edge's parent cp
    first_cpv = path[0][0]
    first_cp, _, _ = rc.split_cpv(first_cpv)
    cur = first_cp
    parts = [cur]
    for pcpv, child, cls in path:
        parts.append(f"--[{cls} via {pcpv}]--> {child}")
    return " ".join(parts)


def main() -> int:
    counts: dict[str, dict[str, int]] = {b: {m: 0 for m, _, _, _ in MODES} for b in BUCKETS}
    # split view for verification: counts[b][mode] broken into missing/extra
    split: dict[str, dict[str, dict[str, int]]] = {
        b: {m: {"missing": 0, "extra": 0} for m, _, _, _ in MODES} for b in BUCKETS}
    examples: dict[str, dict[str, list[str]]] = {
        b: {m: [] for m, _, _, _ in MODES} for b in BUCKETS}
    samples: list[tuple[str, str, str, str, str]] = []  # mode, probe, extra, chain, bucket
    diagnostics: list[str] = []
    target_slot_star_violations = 0
    near_miss = 0
    unreachable = 0

    for mode, run, eopts, has_d in MODES:
        rundir = PMTEST / "differential-test-bed" / "logs" / run
        rep = json.loads((rundir / "l0-report.json").read_text())
        # cross-check: recomputed unexplained missing/extra vs summary counts
        recomp = {"missing": 0, "extra": 0}
        for p in rep["probes"]:
            for f in p["findings"]:
                if "explained_by" not in f and f["category"] in recomp:
                    recomp[f["category"]] += 1
        for cat in ("missing", "extra"):
            assert recomp[cat] == rep["summary"]["counts"][cat] == EXPECTED[mode][cat], \
                (mode, cat, recomp[cat], rep["summary"]["counts"][cat], EXPECTED[mode][cat])

        for p in rep["probes"]:
            slug = p["slug"]
            want_missing = sum(1 for f in p["findings"]
                               if f["category"] == "missing" and "explained_by" not in f)
            want_extra = sum(1 for f in p["findings"]
                             if f["category"] == "extra" and "explained_by" not in f)
            if not want_missing and not want_extra:
                continue
            rpkgs, _, _, _, _, _ = rc.parse(rundir / "real" / f"{slug}.txt")
            ppkgs, _, _, _, _, _ = rc.parse(rundir / "portuale" / f"{slug}.txt")
            rmap = {(x.type, x.cp, x.slot): x for x in rpkgs}
            pmap = {(x.type, x.cp, x.slot): x for x in ppkgs}
            miss_keys = sorted(rmap.keys() - pmap.keys())
            extra_keys = sorted(pmap.keys() - rmap.keys())
            assert len(miss_keys) == want_missing, (mode, slug, len(miss_keys), want_missing)
            assert len(extra_keys) == want_extra, (mode, slug, len(extra_keys), want_extra)

            # --- MISSING ---
            # cp identity uses the repaired parse (see REPAIR note); the
            # counting keys above stay comparator-identical.
            p_cps = {repaired((x.cp, x.ver, x.slot))[0] for x in ppkgs}
            for key in miss_keys:
                r = rmap[key]
                rcp, _, _ = repaired((r.cp, r.ver, r.slot))
                action, _ = rc.split_flags(r.flags)
                if "R" in action:
                    b = "H-no-R"
                elif rcp in p_cps:
                    b = "H-slot"
                else:
                    b = "H-other"
                assert b in MISSING_BUCKETS
                counts[b][mode] += 1
                split[b][mode]["missing"] += 1
                if len(examples[b][mode]) < 3 and slug not in examples[b][mode]:
                    examples[b][mode].append(slug)

            # --- EXTRA ---
            if not extra_keys:
                continue
            tpath = rundir / "pgtrace" / f"{slug}.txt"
            if not tpath.exists():
                print(f"FATAL: {mode}/{slug}: {want_extra} extra but no {tpath}",
                      file=sys.stderr)
                return 2
            tr = parse_trace(tpath)
            if not tr["targets"]:
                print(f"FATAL: {mode}/{slug}: trace has no pg-target lines", file=sys.stderr)
                return 2
            roots = set(tr["targets"])
            # Deterministic BFS seeding: set probes (@world/@system)
            # expand to ~50 roots and set iteration order varies with
            # hash randomisation, flipping shortest-chain tie-breaks
            # (and hence buckets) run to run. Lexicographic root order;
            # remaining ties break by trace order in the adjacency lists.
            root_order = sorted(roots)
            for key in extra_keys:
                raw_cp = key[1]
                cp, _, _ = repaired((raw_cp, pmap[key].ver, pmap[key].slot))
                if cp in roots:
                    b = "H-target-all-slots"
                    if tr["targets"][cp] != "*":
                        target_slot_star_violations += 1
                        diagnostics.append(
                            f"{mode}/{slug}: extra {cp} == target but slot="
                            f"{tr['targets'][cp]} (not *)")
                    path = []
                else:
                    path = shortest_chain(tr["adj"], root_order, cp)
                    if path is None:
                        unreachable += 1
                        b = "H-other"
                    else:
                        # First edge on the chain whose parent is installed;
                        # a chain leaving the target through not-installed
                        # parents first still over-merges via that edge.
                        inst_edge = next((e for e in path if e[0] in tr["installed"]), None)
                        pcpv, _, cls = inst_edge if inst_edge else path[0]
                        if inst_edge:
                            if not has_d:
                                b = "H-installed-expanded"
                            elif cls in ("DEPEND", "BDEPEND"):
                                b = "H-installed-bdeps"
                            elif cls in ("RDEPEND", "PDEPEND", "IDEPEND"):
                                b = "H-installed-config-USE"
                            else:
                                b = "H-other"  # unknown class; should not happen
                                diagnostics.append(
                                    f"{mode}/{slug}: installed parent but class {cls}")
                        else:
                            first_cp, _, _ = rc.split_cpv(pcpv)
                            if first_cp in tr["installed_cp"]:
                                near_miss += 1
                            b = None  # fall to rule 3
                            for e_pcpv, e_child, _ in path:
                                if (tr["closure"].get(e_child) == "shallow"
                                        and e_pcpv in tr["installed"]):
                                    b = "H-closure"
                                    break
                            if b is None:
                                b = "H-other"
                assert b in EXTRA_BUCKETS, (mode, slug, cp, b)
                counts[b][mode] += 1
                split[b][mode]["extra"] += 1
                if len(examples[b][mode]) < 3 and slug not in examples[b][mode]:
                    examples[b][mode].append(slug)
                if slug in ("net-libs_nodejs", "dev-lang_rust") or len(samples) < 200:
                    samples.append((mode, slug, cp, chain_str(roots, path, cp), b))

    # --- verification ---
    ok = True
    ver_lines = []
    for mode, _, _, _ in MODES:
        tot = sum(counts[b][mode] for b in BUCKETS)
        m = sum(split[b][mode]["missing"] for b in BUCKETS)
        e = sum(split[b][mode]["extra"] for b in BUCKETS)
        exp = EXPECTED[mode]
        line = (f"{mode}: buckets total {tot} vs missing+extra "
                f"{exp['missing'] + exp['extra']} (missing {m}/{exp['missing']}, "
                f"extra {e}/{exp['extra']})")
        ver_lines.append(line)
        if m != exp["missing"] or e != exp["extra"]:
            ok = False
    assert ok, "bucket totals do not match modes.md:\n" + "\n".join(ver_lines)

    modes_order = [m for m, _, _, _ in MODES]
    L: list[str] = []
    L.append("# Task S0 Step 7 — bucket counts (pubgrub vs Portage)")
    L.append("")
    L.append("Inputs: the 5 run dirs in `modes.md` (117 probes each), per-probe")
    L.append("`PORTUALE_PG_TRACE=1` captures in `<rundir>/pgtrace/` (one container")
    L.append("per mode, same mounts/env as `run/lib.sh podman_run_pm` +")
    L.append("`layers/l0/in-container.sh`, `GENTOO_MIRRORS` forwarded, stderr per")
    L.append("probe into `pgtrace/<probe>.txt`; loop over only the probes with")
    L.append("extras; driver `trace-run.sh` + probe list `pgtrace-probes.tsv` kept")
    L.append("in each run dir). Parsing reused from `resolve-compare.py` by import")
    L.append("(`parse`, `split_flags`, `split_cpv`); key rule `(type, cp, slot)` as")
    L.append("in `compare()`. Counting keys are comparator-identical (totals")
    L.append("reconcile 1:1 with `l0-report.json`); bucket attribution additionally")
    L.append("repairs the comparator's `-rN:slot` artifact (`split_cpv_slot` turns")
    L.append("e.g. `sys-devel/binutils-2.44-r4:2.44` into cp=whole-token, ver='': a")
    L.append("cp never contains ':', so the script re-splits such tokens with the")
    L.append("same version grammar for cp identity vs trace roots/graph only).")
    L.append("")
    L.append("Bucket rules (exactly one bucket per counted finding). MISSING:")
    L.append("Portage action `R` -> H-no-R; same cp in portuale output with another")
    L.append("slot/version -> H-slot; else H-other. EXTRA: shortest chain from a")
    L.append("pg-target root over pg-edge; (1) extra cp == target cp ->")
    L.append("H-target-all-slots; (2) first chain edge whose parent cpv is pg-installed: no-D ->")
    L.append("H-installed-expanded, D + DEPEND/BDEPEND -> H-installed-bdeps, D +")
    L.append("RDEPEND/PDEPEND/IDEPEND -> H-installed-config-USE; (3) chain through")
    L.append("an edge whose child is pg-closure shallow with an installed parent")
    L.append("-> H-closure; (4) H-installed-only skipped (not detectable from the")
    L.append("trace); (5) rest -> H-other. Chain ties: shortest wins; roots in")
    L.append("lexicographic order, then trace order in the adjacency lists")
    L.append("(deterministic across runs).")
    L.append("")
    L.append("## Bucket table (cells = unexplained missing+extra findings)")
    L.append("")
    L.append("| bucket | " + " | ".join(modes_order) + " |")
    L.append("|---|" + "|".join("---" for _ in modes_order) + "|")
    for b in BUCKETS:
        L.append("| " + b + " | " + " | ".join(str(counts[b][m]) for m in modes_order) + " |")
    L.append("| TOTAL | " + " | ".join(
        str(sum(counts[b][m] for b in BUCKETS)) for m in modes_order) + " |")
    L.append("| modes.md missing+extra | " + " | ".join(
        str(EXPECTED[m]["missing"] + EXPECTED[m]["extra"]) for m in modes_order) + " |")
    L.append("")
    L.append("Verification: " + ("ALL column totals equal the modes.md missing+extra "
                                 "totals." if ok else "MISMATCH (see below)."))
    for v in ver_lines:
        L.append(f"- {v}")
    L.append("")
    L.append("Zero buckets (value 0, not distinguishable by script): "
             "H-installed-only (rule 4 skipped: repo absence of an installed "
             "parent's version is not visible in the trace), H-switches, "
             "H-or-choice (`||` choice leaves no trace mark), H-cycle, "
             "H-pdepend-idepend.")
    L.append("")
    L.append(f"Diagnostics: `-rN:slot` repaired attributions: "
             f"{repaired_artifacts}; extra==target with pg-target slot!=* : "
             f"{target_slot_star_violations}; first-edge parent cp installed but "
             f"cpv not exact (near-miss, counted by fallthrough rules, not rule "
             f"2): {near_miss}; extras with no chain from any root (-> H-other): "
             f"{unreachable}.")
    if diagnostics:
        L.append("")
        L.append("First 10 diagnostic lines:")
        for d in diagnostics[:10]:
            L.append(f"- {d}")
    L.append("")
    L.append("## Example probes (up to 3 per bucket per mode)")
    L.append("")
    for b in BUCKETS:
        L.append(f"### {b}")
        for m in modes_order:
            ex = examples[b][m]
            if ex:
                L.append("- %s: %s (%d total)" % (
                    m, ", ".join("`" + s + "`" for s in ex), counts[b][m]))
            else:
                L.append("- %s: (0)" % m)
        L.append("")
    L.append("## Sample chains")
    L.append("")
    # 5 chains: nodejs, rust, and two others, different buckets if possible
    # 5 chains: 2 nodejs + 1 rust + one each from two other probes
    # (different buckets preferred).
    want: list[tuple[str, int]] = [("net-libs_nodejs", 2), ("dev-lang_rust", 1)]
    picked: list[tuple] = []
    used_buckets: set[str] = set()
    pool = samples
    for probe, n in want:
        got = 0
        cands = sorted((s for s in pool if s[1] == probe),
                       key=lambda s: s[4] in used_buckets)
        for s in cands:
            if s in picked:
                continue
            picked.append(s)
            used_buckets.add(s[4])
            got += 1
            if got >= n:
                break
    others: list[str] = []
    for s in sorted(pool, key=lambda s: (s[4] in used_buckets, s[1], s[2])):
        if len(picked) >= 5:
            break
        if s[1] in ("net-libs_nodejs", "dev-lang_rust"):
            continue
        if s[1] in others:
            continue
        picked.append(s)
        used_buckets.add(s[4])
        others.append(s[1])
    picked = picked[:5]
    for i, (m, slug, cp, ch, b) in enumerate(picked, 1):
        L.append(f"{i}. probe `{slug}` ({m}), extra `{cp}`, bucket {b}")
        L.append(f"   chain: {ch}")
    L.append("")
    OUT.write_text("\n".join(L))
    print("\n".join(L))
    print(f"\nwrote {OUT}", file=sys.stderr)
    print(f"diagnostics: slot-star-violations={target_slot_star_violations} "
          f"near-miss={near_miss} unreachable={unreachable}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
