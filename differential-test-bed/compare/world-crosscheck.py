#!/usr/bin/env python3
"""Set three views of one @world side by side: the resolver's plan
(`emerge -pv --json --update --deep --newuse @world`), the fast plan
(`mrg --plan-world --json`) and, when given, the check
(`mrg --check-world --json`, one JSON object per line).

A difference is information to judge against the charter, not a failure
by itself. Each output line says which class it is:

  [judge] world-version-differs      one slot, two "best" versions
  [judge] world-invalid-but-planned  the check finds no version for a world
                                     atom, yet a plan holds one that matches
  [judge] world-clean-but-resolver-refused
                                     the check finds no problem, yet the
                                     resolver aborted or reported a conflict
  [note]  fast-only / resolver-only  a slot only one plan lists (the
                                     resolver's reinstalls are counted
                                     apart: the fast plan has no rebuild rows)

Atoms are matched by name, version and slot; USE dependencies are not judged.
Portage is not involved.

Usage: world-crosscheck.py RESOLVER.json FAST.json [--check CHECK.jsonl]
Exit 0 (the lines are the result); 2 when an input cannot be read.
"""

from __future__ import annotations

import dataclasses
import json
import sys
from pathlib import Path
from typing import NamedTuple

# health_checker.py sits in the repository, or next to this script in the bed's container
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent.parent / "pytests-contract-suite"), str(HERE)]
import health_checker as hc  # noqa: E402

UNSATISFIED = ("world-no-match", "world-invalid")


class Line(NamedTuple):
    cls: str  # "judge" or "note"
    kind: str
    text: str


def slot_key(entry: dict) -> tuple[str, str]:
    slot = entry.get("slot")
    return (f"{entry['category']}/{entry['package']}", "?" if slot is None else str(slot).split("/")[0])


def name(key: tuple[str, str]) -> str:
    return f"{key[0]}:{key[1]}"


def changed(doc: dict) -> dict[tuple[str, str], dict]:
    """Slots a plan changes: resolver entries that are neither kept nor
    already installed."""
    return {slot_key(e): e for e in doc["entries"] if e.get("outcome") != "already_installed"}


def fill_unknown_slots(theirs: dict, ours: dict) -> dict:
    """A resolver entry without a slot (a binary package) takes the slot of
    the fast plan's entry of the same package when that is unambiguous."""
    slots = {}
    for cp, slot in ours:
        slots.setdefault(cp, []).append(slot)
    out = {}
    for (cp, slot), entry in theirs.items():
        if slot == "?" and len(slots.get(cp, [])) == 1:
            slot = slots[cp][0]
        out[(cp, slot)] = entry
    return out


def satisfies(doc: dict, atom: hc.Atom) -> list[str]:
    """`cpv (outcome)` of every entry of the plan the atom matches, kept ones included."""
    found = {}
    for e in [*doc["entries"], *doc.get("kept", [])]:
        pkg = hc.Package(e["category"], e["package"], e["version"], e.get("slot") or atom.slot)
        if hc.matches(atom, pkg):
            found.setdefault(pkg.cpv, e.get("outcome", "kept"))
    return [f"{cpv} ({outcome})" for cpv, outcome in found.items()]


def crosscheck(resolver: dict, fast: dict, findings: list[dict] | None = None) -> list[Line]:
    """The lines to judge first, then the notes."""
    judge, notes = [], []
    ours = changed(fast)
    theirs = fill_unknown_slots(changed(resolver), ours)
    kept = {e["category"] + "/" + e["package"]: e["version"]
            for e in resolver["entries"] if e.get("outcome") == "already_installed"}
    for key in sorted(ours.keys() & theirs.keys()):
        if ours[key]["version"] != theirs[key]["version"]:
            judge.append(Line("judge", "world-version-differs",
                              f"{name(key)}  fast={ours[key]['version']}  resolver={theirs[key]['version']}"
                              f"  (resolver outcome {theirs[key]['outcome']})"))
    for finding in findings or []:
        if finding["property"] not in UNSATISFIED:
            continue
        try:
            atom = hc.parse_atom(finding["atom"])
        except ValueError:
            continue
        judged = "" if not atom.use_deps else " (its USE dependencies are not judged here)"
        atom = dataclasses.replace(atom, use_deps=())
        for who, doc in (("resolver", resolver), ("fast plan", fast)):
            for hit in satisfies(doc, atom):
                judge.append(Line("judge", "world-invalid-but-planned",
                                  f"{finding['atom']} (asked by {finding['package']}): "
                                  f"{finding['property']}, yet the {who} holds {hit}{judged}"))
    if not any(f["property"] in UNSATISFIED for f in findings or []) and findings is not None:
        why = resolver.get("aborted") and f"aborted: {resolver['aborted'].get('reason')}" \
            or resolver.get("slot_conflicts") and f"{len(resolver['slot_conflicts'])} slot conflict(s)"
        if why:
            judge.append(Line("judge", "world-clean-but-resolver-refused",
                              f"the check finds every world atom satisfiable; the resolver: {why}"))
    for key in sorted(ours.keys() - theirs.keys()):
        keeps = kept.get(key[0])
        extra = f"; the resolver keeps {key[0]}-{keeps} installed" if keeps else ""
        notes.append(Line("note", "fast-only",
                          f"{name(key)}  fast={ours[key]['version']} ({ours[key]['outcome']}){extra}"))
    reinstalls = 0
    for key in sorted(theirs.keys() - ours.keys()):
        if theirs[key]["outcome"] == "reinstall":
            reinstalls += 1
        else:
            notes.append(Line("note", "resolver-only",
                              f"{name(key)}  resolver={theirs[key]['version']} ({theirs[key]['outcome']})"))
    if reinstalls:
        notes.append(Line("note", "resolver-only-reinstall",
                          f"{reinstalls} reinstall(s) only the resolver lists (the fast plan has no rebuild rows yet)"))
    return judge + notes


def summary(lines: list[Line]) -> str:
    counts = {}
    for line in lines:
        counts[line.kind] = counts.get(line.kind, 0) + 1
    body = ", ".join(f"{n} {kind}" for kind, n in sorted(counts.items())) or "no difference"
    return f"world cross-check: {body}"


def load(path: str) -> dict:
    doc = hc.parse_json_output(Path(path).read_text(errors="replace"))
    if doc is None or "entries" not in doc:
        raise ValueError(f"{path}: no --json plan document")
    return doc


def main(argv: list[str]) -> int:
    check = None
    if "--check" in argv:
        i = argv.index("--check")
        check, argv = argv[i + 1], argv[:i] + argv[i + 2:]
    if len(argv) != 2:
        print(__doc__)
        return 2
    try:
        resolver, fast = load(argv[0]), load(argv[1])
        findings = None if check is None else [
            json.loads(line) for line in Path(check).read_text().splitlines()
            if line.startswith('{"property"')]
    except (OSError, ValueError) as error:
        print(f"world-crosscheck: {error}", file=sys.stderr)
        return 2
    lines = crosscheck(resolver, fast, findings)
    for line in lines:
        print(f"[{line.cls}] {line.kind}  {line.text}")
    print(summary(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
