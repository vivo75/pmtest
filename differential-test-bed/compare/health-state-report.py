#!/usr/bin/env python3
"""Report the health of the installed state an L1 merge left (charter
properties 1 and 4), from `health_checker.py --installed` output.

Usage: health-state-report.py portuale.health-after.jsonl [portage.health-after.jsonl]
Each file is the JSON line the checker printed after the merge, run with the
pre-merge findings as its baseline, so only what the merge introduced fails.
The second file (Portage, same merge) is a control: a failure both sides
introduce is listed as shared, which usually means the test set, not portuale.
Exit 1 when portuale introduced a failure, 0 otherwise.
"""

import json
import sys


def introduced(path: str) -> list[dict]:
    out = []
    for line in open(path):
        if line.startswith("{"):
            out += [f for f in json.loads(line)["findings"]
                    if f["failure"] and not f["pre_existing"]]
    return out


def key(f: dict) -> tuple:
    return (f["property"], f["package"], f["atom"])


def main(argv: list[str]) -> int:
    if not 1 <= len(argv) <= 2:
        print(__doc__)
        return 2
    ours = introduced(argv[0])
    theirs = {key(f) for f in introduced(argv[1])} if len(argv) == 2 else set()
    print(f"health of the installed state: {len(ours)} failure(s) introduced by the merge")
    for f in ours[:20]:
        shared = "  (Portage's merge shows it too)" if key(f) in theirs else ""
        print(f"  {f['property']}: {f['package']} {f['atom']} -- {f['reason']}{shared}")
    if len(ours) > 20:
        print(f"  ... and {len(ours) - 20} more")
    return 1 if ours else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
