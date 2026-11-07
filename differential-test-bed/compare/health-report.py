#!/usr/bin/env python3
"""Summarise health_checker.py output (one JSON object per plan).

A plan is clean when it has no failure of its own: findings marked
`pre_existing` (already broken before the plan), `cycle-noted` notes and
`checker-limitation` records do not count. Plans portuale itself refuses
(`refused`: slot conflict, needed configuration change, unsolvable blocker)
are listed apart and do not fail the run. Per property, the report gives
how many plans and distinct (package, atom) pairs are affected, and up to
five examples.

With the run's meta.tsv (label, exit code, seconds, family) it also prints
one row per family of the list and the slowest probes and checks.

Usage: health-report.py health.jsonl [meta.tsv]
Exit: 0 when every plan portuale would run is clean, 1 otherwise.
"""

import json
import sys
from collections import defaultdict


def label(record: dict) -> str:
    return record["plan"].rsplit("/", 1)[-1].removesuffix(".json")


def family_table(records: list, dirty: set, meta_path: str) -> None:
    """One row per family: probes, plans checked, clean, refused, no plan."""
    meta = {}
    for line in open(meta_path):
        cells = line.rstrip("\n").split("\t")
        meta[cells[0]] = (cells[1], float(cells[2]) if len(cells) > 2 else 0.0,
                          cells[3] if len(cells) > 3 else "atoms")
    rows = defaultdict(lambda: defaultdict(int))
    for r in records:
        name = label(r)
        rc, secs, family = meta.get(name, ("?", 0.0, "?"))
        row = rows[family]
        row["probes"] += 1
        row["seconds"] += secs
        if "skipped" in r:
            row["no plan"] += 1
        elif r.get("refused"):
            row["refused"] += 1
            row["refused, findings"] += name in dirty
        else:
            row["would run"] += 1
            row["failing" if name in dirty else "clean"] += 1
            row["rc!=0 not refused"] += rc != "0"
    cols = ["probes", "would run", "clean", "failing", "refused", "refused, findings",
            "no plan", "rc!=0 not refused", "seconds"]
    print("\nper family: " + ", ".join(cols))
    for family, row in rows.items():
        print(f"{family:20}" + "".join(
            f"{row[c]:>8.1f}" if c == "seconds" else f"{row[c]:>6}" for c in cols))
    slow = sorted(meta.items(), key=lambda kv: -kv[1][1])[:5]
    print("slowest probes: " + ", ".join(f"{k} {v[1]:.1f}s" for k, v in slow))
    checks = sorted((r for r in records if "seconds" in r), key=lambda r: -r["seconds"])[:5]
    print("slowest checks: " + ", ".join(f"{label(r)} {r['seconds']:.2f}s" for r in checks))


def main(path: str, meta_path: str | None = None) -> int:
    records = [json.loads(line) for line in open(path) if line.strip()]
    skipped = [r for r in records if "skipped" in r]
    checked = [r for r in records if "findings" in r]
    by_key = defaultdict(lambda: defaultdict(set))  # (property, origin) -> pair -> plans
    dirty = set()
    for r in checked:
        plan = label(r)
        for f in r["findings"]:
            origin = "pre-existing" if f["pre_existing"] else "plan"
            if f["property"] not in ("cycle-noted", "checker-limitation") and origin == "plan":
                dirty.add(plan)
            by_key[(f["property"], origin)][(f["package"], f["atom"], f["reason"])].add(plan)
    refused = {label(r): r["refused"]
               for r in checked if r.get("refused")}
    failing = dirty - set(refused)
    print(f"plans: {len(records)}  checked: {len(checked)}  clean: {len(checked) - len(dirty)}"
          f"  with failures: {len(failing)}  refused by portuale, with findings:"
          f" {len(dirty & set(refused))}  skipped: {len(skipped)}")
    for r in skipped:
        print(f"  skipped {r['plan'].rsplit('/', 1)[-1]}: {r['skipped']}")
    for (prop, origin), pairs in sorted(by_key.items()):
        plans = set().union(*pairs.values())
        print(f"\n{prop} [{origin}]: {len(pairs)} distinct finding(s) in {len(plans)} plan(s)")
        for (pkg, atom, reason), where in sorted(pairs.items(), key=lambda kv: -len(kv[1]))[:5]:
            print(f"  {pkg}  {atom}  -- {reason}  ({len(where)} plan(s), e.g. {sorted(where)[0]})")
    for plan in sorted(dirty & set(refused)):
        print(f"\nrefused by portuale ({refused[plan]}): {plan}", end="")
    if failing:
        print("\n\nplans with failures: " + " ".join(sorted(failing)))
    print()
    if meta_path:
        family_table(records, dirty, meta_path)
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
