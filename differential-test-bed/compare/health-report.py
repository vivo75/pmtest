#!/usr/bin/env python3
"""Summarise health_checker.py output (one JSON object per plan).

A plan is clean when it has no failure of its own: findings marked
`pre_existing` (already broken before the plan), `cycle-noted` notes and
`checker-limitation` records do not count. Plans portuale itself refuses
(`refused`: slot conflict, needed configuration change, unsolvable blocker)
are listed apart and do not fail the run. Per property, the report gives
how many plans and distinct (package, atom) pairs are affected, and up to
five examples.

Usage: health-report.py health.jsonl
Exit: 0 when every plan portuale would run is clean, 1 otherwise.
"""

import json
import sys
from collections import defaultdict


def main(path: str) -> int:
    records = [json.loads(line) for line in open(path) if line.strip()]
    skipped = [r for r in records if "skipped" in r]
    checked = [r for r in records if "findings" in r]
    by_key = defaultdict(lambda: defaultdict(set))  # (property, origin) -> pair -> plans
    dirty = set()
    for r in checked:
        plan = r["plan"].rsplit("/", 1)[-1].removesuffix(".json")
        for f in r["findings"]:
            origin = "pre-existing" if f["pre_existing"] else "plan"
            if f["property"] not in ("cycle-noted", "checker-limitation") and origin == "plan":
                dirty.add(plan)
            by_key[(f["property"], origin)][(f["package"], f["atom"], f["reason"])].add(plan)
    refused = {r["plan"].rsplit("/", 1)[-1].removesuffix(".json"): r["refused"]
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
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
