#!/usr/bin/env python3
"""Mutation test for health_checker.py: break clean plans on purpose and
check that the checker notices.

Each operator looks at a clean `--json` plan and offers changes that break a
charter property by construction (drop a needed package, swap two merges
across a build-time edge, flip a flag REQUIRED_USE needs, ...), each with the
finding it expects. One offer per operator and plan is drawn at random
(fixed seed). A mutant is killed when the checker reports a new finding of an
expected property; otherwise it survives and marks a blind spot. Portage is
not involved.

Usage: health-mutants.py --vdb VDB [--per-operator N] [--seed S] PLAN.json...
Prints one JSON line per mutant and a table per operator. Exit 1 when a
mutant survives.
"""

from __future__ import annotations

import copy
import json
import random
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pytests-contract-suite"))
import health_checker as hc  # noqa: E402

RUNTIME = {"runtime-deps"}
ORDER = {"build-order"}
# A control mutant is harmless: any new failure on it is a false alarm.
CONTROL = frozenset({"runtime-deps", "build-order", "blocker", "required-use", "slot"})
MAX_OFFERS = 40  # offers looked at per operator and plan


def required_atoms(pkg: hc.Package, classes) -> list[tuple[str, hc.Atom]]:
    """Top-level, non-blocker atoms the package needs under its USE (no
    `||` alternative, so each is needed by construction)."""
    return [(c, n[1]) for c in classes for n in hc._reduced(pkg, c)
            if n[0] == "atom" and not n[1].blocker]


def cpv_of(e) -> str:
    return f"{e['category']}/{e['package']}-{e['version']}"


def entry_for(doc, pkg: hc.Package):
    return next(e for e in doc["entries"]
                if e["outcome"] in hc.MERGE_BOUND and cpv_of(e) == pkg.cpv)


def outcome(doc, pkg: hc.Package) -> str:
    return entry_for(doc, pkg)["outcome"]


def renumber(doc):
    doc["entries"].sort(key=lambda e: e["merge_order"])
    for i, e in enumerate(doc["entries"]):
        e["merge_order"] = i


def sole_provider(plan: hc.Plan, cp) -> bool:
    """Only one version of `cp` is ever on the system, before or after."""
    return len({p.cpv for p in plan.final + plan.initial if p.cp == cp}) == 1


def dependants(plan: hc.Plan, pkg: hc.Package, classes):
    """(dependant, class, atom) for every needed atom `pkg` alone satisfies."""
    for p in plan.final:
        if p is not pkg:
            for cls, atom in required_atoms(p, classes):
                if hc.matches(atom, pkg, p.use):
                    yield p, cls, atom


def mutant(doc, change):
    """A deep copy of `doc` with `change(copy)` applied."""
    def make():
        out = copy.deepcopy(doc)
        change(out)
        return out
    return make


def new_entry(cat, pkg, version, order, slot="0", deps=None):
    return {"category": cat, "package": pkg, "version": version, "merge_order": order,
            "outcome": "new", "slot": slot, "sub_slot": None, "source": "ebuild",
            "dependencies": deps or {}, "use": [], "iuse": [], "required_use": ""}


def plain_blockers(pkg: hc.Package):
    """Blocker atoms simple enough to build a matching package for."""
    for cls in hc.RUNTIME_CLASSES + hc.BUILD_CLASSES:
        for node in hc._reduced(pkg, cls):
            atom = node[1] if node[0] == "atom" else None
            if (atom and atom.blocker and atom.op in ("", "=", "<=", ">=", "~")
                    and not atom.glob and not atom.use_deps):
                yield atom


# --- operators: each yields (description, make-mutant, expected properties) --

def drop_needed_merge(doc, plan):
    """Drop a new package another package needs and nothing else provides."""
    for _, m in plan.merges:
        if outcome(doc, m) == "new" and sole_provider(plan, m.cp):
            for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES + hc.BUILD_CLASSES):
                yield (f"drop {m.cpv} ({cls} {atom.text} of {p.cpv})", mutant(doc, lambda d, m=m: d.update(
                    entries=[x for x in d["entries"] if cpv_of(x) != m.cpv])), RUNTIME | ORDER)
                break


def drop_needed_upgrade(doc, plan):
    """Drop an upgrade a dependant's version range needs; the old one stays."""
    for order, m in plan.merges:
        if outcome(doc, m) != "upgrade":
            continue
        old = next(p for o, p in plan.replaced if o == order)
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES):
            if not hc.matches(atom, old, p.use):
                def change(d, m=m, old=old):
                    d["entries"] = [x for x in d["entries"] if cpv_of(x) != m.cpv]
                    d["kept"].append({"category": old.category, "package": old.package,
                                      "version": old.version, "slot": m.slot})
                yield f"keep {old.cpv}, not {m.version} ({atom.text} of {p.cpv})", mutant(doc, change), RUNTIME
                break


def swap_build_edge(doc, plan):
    """Merge a build dependency after the package that builds against it."""
    by_cpv = {m.cpv: (o, m) for o, m in plan.merges}
    installed = plan.kept + [p for _, p in plan.replaced]
    for ob, b in plan.merges:
        if b.binary:
            continue
        for cls, atom in required_atoms(b, hc.BUILD_CLASSES):
            if any(hc.matches(atom, p, b.use) for p in installed):
                continue  # an installed copy would satisfy it anyway
            for oa, a in by_cpv.values():
                if oa < ob and hc.matches(atom, a, b.use):
                    def change(d, a=a, b=b):
                        ea, eb = entry_for(d, a), entry_for(d, b)
                        ea["merge_order"], eb["merge_order"] = eb["merge_order"], ea["merge_order"]
                        renumber(d)
                    yield f"swap {a.cpv} after {b.cpv} ({cls} {atom.text})", mutant(doc, change), ORDER
                    break


def break_required_use(doc, plan):
    """Flip one flag of a merged package so its REQUIRED_USE breaks."""
    for _, m in plan.merges:
        for flag in sorted(m.iuse) if m.required_use else ():
            use = m.use ^ {flag}
            if hc.required_use_holds(m.required_use, use):
                yield (f"flip {flag} on {m.cpv} (REQUIRED_USE {m.required_use[:50]})",
                       mutant(doc, lambda d, m=m, use=use: entry_for(d, m).update(use=sorted(use))),
                       {"required-use"})


def second_in_slot(doc, plan):
    """Merge a second version into a slot a kept or merged package holds."""
    for p in plan.final:
        def change(d, p=p):
            e = new_entry(p.category, p.package, "99999", len(d["entries"]), p.slot)
            d["entries"].append(e)
        yield f"add {p.category}/{p.package}-99999 into the slot of {p.cpv}", mutant(doc, change), {"slot"}


def merge_what_kept_blocks(doc, plan):
    """Merge a package that a kept package's blocker forbids."""
    present = {p.cp for p in plan.final}
    for k in plan.kept:
        for atom in plain_blockers(k):
            if atom.cp not in present:
                version = atom.version or "1"
                yield (f"merge {atom.cp[0]}/{atom.cp[1]}-{version}, which kept {k.cpv} blocks ({atom.text})",
                       mutant(doc, lambda d, a=atom, v=version: d["entries"].append(
                           new_entry(*a.cp, v, len(d["entries"]), a.slot or "0"))), {"blocker"})


def keep_what_merge_blocks(doc, plan):
    """Keep installed a package that a merged package's blocker forbids."""
    present = {p.cp for p in plan.final}
    for _, m in plan.merges:
        for atom in plain_blockers(m):
            if atom.cp not in present:
                item = {"category": atom.cp[0], "package": atom.cp[1], "version": atom.version or "1",
                        "slot": atom.slot or "0", "dependencies": {}, "use": [], "iuse": []}
                yield (f"keep {atom.cp[0]}/{atom.cp[1]}, which merged {m.cpv} blocks ({atom.text})",
                       mutant(doc, lambda d, i=item: d["kept"].append(i)), {"blocker"})


def delete_needed_kept(doc, plan):
    """Remove a kept package another package needs at run time."""
    for k in plan.kept:
        if sole_provider(plan, k.cp):
            for p, cls, atom in dependants(plan, k, hc.RUNTIME_CLASSES):
                key = (k.category, k.package, k.version)
                yield (f"remove kept {k.cpv} ({cls} {atom.text} of {p.cpv})", mutant(doc, lambda d, key=key: d.update(
                    kept=[x for x in d["kept"] if (x["category"], x["package"], x["version"]) != key])), RUNTIME)
                break


def drop_slot_rebuild(doc, plan):
    """Skip a slot-operator rebuild: the consumer keeps its old binding."""
    for _, m in plan.merges:
        if entry_for(doc, m).get("slot_operator_rebuild"):
            def change(d, m=m):
                d["entries"] = [x for x in d["entries"] if cpv_of(x) != m.cpv]
                d["kept"].append({"category": m.category, "package": m.package,
                                  "version": m.version, "slot": m.slot})
            yield f"skip the slot-operator rebuild of {m.cpv}", mutant(doc, change), RUNTIME


def bump_sub_slot(doc, plan):
    """Give a merged library a new sub-slot that kept consumers are bound to."""
    for _, m in plan.merges:
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES):
            if atom.subslot and p in plan.kept:
                yield (f"give {m.cpv} sub-slot 999 ({atom.text} of kept {p.cpv})",
                       mutant(doc, lambda d, m=m: entry_for(d, m).update(sub_slot="999")), RUNTIME)
                break


def break_use_dep(doc, plan):
    """Turn off a flag a dependant's USE dependency needs on a merge."""
    for _, m in plan.merges:
        if not sole_provider(plan, m.cp):
            continue
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES + hc.BUILD_CLASSES):
            on = [u.flag for u in atom.use_deps if u.kind == "on" and u.flag in m.use]
            if on:
                yield (f"turn {on[0]} off on {m.cpv} ({cls} {atom.text[:60]} of {p.cpv})",
                       mutant(doc, lambda d, m=m, f=on[0]: entry_for(d, m).update(
                           use=[x for x in entry_for(d, m)["use"] if x != f])), RUNTIME | ORDER)
                break


def wrong_slot(doc, plan):
    """Move a merged package to a slot a dependant's `:SLOT` atom excludes."""
    for _, m in plan.merges:
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES):
            if atom.slot and len([x for x in plan.final if x.cp == m.cp]) == 1:
                yield (f"put {m.cpv} in slot 999 ({atom.text} of {p.cpv})",
                       mutant(doc, lambda d, m=m: entry_for(d, m).update(slot="999")), RUNTIME)
                break


def enable_missing_conditional(doc, plan):
    """Turn on a flag whose conditional runtime dependency nothing provides."""
    present = {p.cp for p in plan.final}
    for _, m in plan.merges:
        for node in hc.parse_dep_string(m.dependencies.get("RDEPEND", "")):
            if node[0] != "if" or node[2] or node[1] in m.use or node[1] not in m.iuse:
                continue
            atoms = [n[1] for n in node[3] if n[0] == "atom" and not n[1].blocker]
            if atoms and atoms[0].cp not in present:
                yield (f"turn {node[1]} on for {m.cpv} (needs {atoms[0].text})",
                       mutant(doc, lambda d, m=m, f=node[1]: entry_for(d, m).update(
                           use=sorted(set(entry_for(d, m)["use"]) | {f}))), RUNTIME | {"required-use"})


def drop_any_of_provider(doc, plan):
    """Drop the only new package that satisfies a `|| ( )` group."""
    final = hc.index(plan.final)
    for p in plan.final:
        for node in hc._reduced(p, "RDEPEND"):
            if node[0] != "any":
                continue
            hits = [x for a in hc._plain_atoms([node]) for x in final.get(a.cp, ())
                    if hc.matches(a, x, p.use)]
            if len({h.cpv for h in hits}) == 1 and hits[0] in [m for _, m in plan.merges] \
                    and outcome(doc, hits[0]) == "new":
                yield (f"drop {hits[0].cpv}, the only match of {hc.render(node)[:60]} of {p.cpv}",
                       mutant(doc, lambda d, h=hits[0]: d.update(
                           entries=[x for x in d["entries"] if cpv_of(x) != h.cpv])), RUNTIME | ORDER)


def add_build_cycle(doc, plan):
    """Make an earlier new merge build-depend on a later new merge that
    already build-depends on it: an unserializable cycle."""
    for ob, b in plan.merges:
        if outcome(doc, b) != "new" or b.binary:
            continue
        for oa, a in plan.merges:
            if oa < ob and outcome(doc, a) == "new" and not a.binary and any(
                    hc.matches(atom, a, b.use) for _, atom in required_atoms(b, hc.BUILD_CLASSES)):
                def change(d, a=a, b=b):
                    e = entry_for(d, a)
                    e["dependencies"]["DEPEND"] = f"{e['dependencies'].get('DEPEND', '')} {b.category}/{b.package}"
                yield f"{a.cpv} now DEPENDs on {b.category}/{b.package} (which DEPENDs on it)", \
                    mutant(doc, change), {"cycle-noted"}
                break


def reaches(graph: dict, start: int, goal: int) -> bool:
    seen, todo = set(), [start]
    while todo:
        node = todo.pop()
        if node == goal:
            return True
        if node not in seen:
            seen.add(node)
            todo += graph.get(node, ())
    return False


def add_late_build_dep(doc, plan):
    """Make an early merge build-depend on a new package merged later (and
    not already needing the early one, which would make a cycle)."""
    graph = hc._build_graph(plan)
    merges = [(o, m) for o, m in plan.merges if outcome(doc, m) == "new" and not m.binary]
    for (oa, a), (ob, b) in zip(merges, merges[1:]):
        if sole_provider(plan, b.cp) and not reaches(graph, ob, oa):
            def change(d, a=a, b=b):
                e = entry_for(d, a)
                e["dependencies"]["BDEPEND"] = f"{e['dependencies'].get('BDEPEND', '')} {b.category}/{b.package}"
            yield f"{a.cpv} now BDEPENDs on {b.category}/{b.package}, merged later", mutant(doc, change), ORDER


def late_runtime_of_build_dep(doc, plan):
    """Move a new package that a build dependency needs at run time after the
    package that builds against it: the build dependency is there but not
    usable (PMS 8.1: DEPEND must be installed and usable). The moved package
    is not a direct build dependency of anything, so only the indirect check
    can see it."""
    by_cp = {m.cp: (o, m) for o, m in plan.merges}
    direct = {a.cp for _, m in plan.merges if not m.binary
              for _, node in hc._build_atoms(m) for a in hc._plain_atoms([node])}
    for ox, x in plan.merges:
        for _, atom in required_atoms(x, hc.BUILD_CLASSES) if not x.binary else ():
            y = by_cp.get(atom.cp)
            if not y or y[0] >= ox or not hc.matches(atom, y[1], x.use):
                continue
            for _, ratom in required_atoms(y[1], ("RDEPEND",)):
                z = by_cp.get(ratom.cp)
                if (z and z[0] < ox and outcome(doc, z[1]) == "new" and sole_provider(plan, ratom.cp)
                        and ratom.cp not in direct):
                    def change(d, z=z[1]):
                        entry_for(d, z)["merge_order"] = len(d["entries"]) + 1
                        renumber(d)
                    yield f"move {z[1].cpv} (RDEPEND of build dep {y[1].cpv}) after {x.cpv}", \
                        mutant(doc, change), ORDER
                    break


def lower_version(doc, plan):
    """Merge a version below what a dependant's `>=` atom asks."""
    for _, m in plan.merges:
        if not sole_provider(plan, m.cp):
            continue
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES):
            if atom.op in (">=", ">", "~", "="):
                yield (f"merge {m.category}/{m.package}-0_alpha, below {atom.text[:60]} of {p.cpv}",
                       mutant(doc, lambda d, m=m: entry_for(d, m).update(version="0_alpha")), RUNTIME)
                break


def stale_build_dep(doc, plan):
    """Rebuild a slot-operator consumer only after a package that builds
    against it: that build sees the old copy, bound to a sub-slot gone."""
    for oy, y in plan.merges:
        if not entry_for(doc, y).get("slot_operator_rebuild"):
            continue
        for ox, x in plan.merges:
            if ox > oy and not x.binary and any(
                    hc.matches(a, y, x.use) for _, a in required_atoms(x, hc.BUILD_CLASSES)):
                def change(d, y=y):
                    entry_for(d, y)["merge_order"] = len(d["entries"]) + 1
                    renumber(d)
                yield f"rebuild {y.cpv} after {x.cpv}, which builds against it", mutant(doc, change), ORDER
                break


def keep_what_build_blocks(doc, plan):
    """Keep installed a package that only a DEPEND/BDEPEND blocker forbids."""
    present = {p.cp for p in plan.final}
    for _, m in plan.merges:
        runtime = {a.cp for c in hc.RUNTIME_CLASSES for n in hc._reduced(m, c)
                   if n[0] == "atom" for a in [n[1]]}
        for atom in plain_blockers(m):
            if atom.cp not in present and atom.cp not in runtime and not m.binary:
                item = {"category": atom.cp[0], "package": atom.cp[1], "version": atom.version or "1",
                        "slot": atom.slot or "0", "dependencies": {}, "use": [], "iuse": []}
                yield (f"keep {atom.cp[0]}/{atom.cp[1]} while {m.cpv} builds ({atom.text})",
                       mutant(doc, lambda d, i=item: d["kept"].append(i)), {"blocker"})


def drop_sub_slot(doc, plan):
    """Merge a library with no sub-slot (so its sub-slot is its slot) under a
    dependant bound to another sub-slot."""
    for _, m in plan.merges:
        for p, cls, atom in dependants(plan, m, hc.RUNTIME_CLASSES):
            if atom.subslot and atom.subslot != m.slot:
                yield (f"merge {m.cpv} without a sub-slot ({atom.text} of {p.cpv})",
                       mutant(doc, lambda d, m=m: entry_for(d, m).update(sub_slot=None)), RUNTIME)
                break


def two_level_runtime_of_build_dep(doc, plan):
    """Like late_runtime_of_build_dep, one level deeper: x builds with y, y
    needs z at run time, z needs w; w moves after x."""
    by_cp = {m.cp: (o, m) for o, m in plan.merges}
    near = {a.cp for _, m in plan.merges if not m.binary for _, node in hc._build_atoms(m)
            for a in hc._plain_atoms([node])}
    near |= {a.cp for cp in list(near) if cp in by_cp
             for _, a in required_atoms(by_cp[cp][1], ("RDEPEND",))}
    for ox, x in plan.merges:
        for _, atom in required_atoms(x, hc.BUILD_CLASSES) if not x.binary else ():
            y = by_cp.get(atom.cp)
            for _, a2 in required_atoms(y[1], ("RDEPEND",)) if y and y[0] < ox else ():
                z = by_cp.get(a2.cp)
                for _, a3 in required_atoms(z[1], ("RDEPEND",)) if z and z[0] < ox else ():
                    w = by_cp.get(a3.cp)
                    if (w and w[0] < ox and a3.cp not in near and outcome(doc, w[1]) == "new"
                            and sole_provider(plan, a3.cp)):
                        def change(d, w=w[1]):
                            entry_for(d, w)["merge_order"] = len(d["entries"]) + 1
                            renumber(d)
                        yield (f"move {w[1].cpv} (RDEPEND of {z[1].cpv}, RDEPEND of build dep "
                               f"{y[1].cpv}) after {x.cpv}", mutant(doc, change), ORDER)
                        return


def harmless_move(doc, plan):
    """Control, must NOT be flagged: move to the end a new package nothing
    needs while building (nor at run time while something else builds)."""
    by_cp = {m.cp: (o, m) for o, m in plan.merges}
    near = {a.cp for _, m in plan.merges if not m.binary for _, node in hc._build_atoms(m)
            for a in hc._plain_atoms([node])}
    near |= {a.cp for cp in list(near) if cp in by_cp
             for _, n in [(0, n) for n in hc._reduced(by_cp[cp][1], "RDEPEND")]
             for a in hc._plain_atoms([n])}
    for _, m in plan.merges:
        if m.cp not in near and outcome(doc, m) == "new" and not list(plain_blockers(m)):
            def change(d, m=m):
                entry_for(d, m)["merge_order"] = len(d["entries"]) + 1
                renumber(d)
            yield f"move {m.cpv} to the end", mutant(doc, change), CONTROL


OPERATORS = [drop_needed_merge, drop_needed_upgrade, swap_build_edge, break_required_use,
             second_in_slot, merge_what_kept_blocks, keep_what_merge_blocks, delete_needed_kept,
             drop_slot_rebuild, bump_sub_slot, break_use_dep, wrong_slot,
             enable_missing_conditional, drop_any_of_provider, add_build_cycle,
             add_late_build_dep, late_runtime_of_build_dep, lower_version, stale_build_dep,
             keep_what_build_blocks, drop_sub_slot, two_level_runtime_of_build_dep, harmless_move]


def new_findings(base, findings, props):
    def keys(fs):
        return {(f.property, f.package, f.atom) for f in fs if f.property in props and not f.pre_existing}
    return sorted(keys(findings) - keys(base))


def main(argv: list[str]) -> int:
    vdb, per_op, seed = None, 4, 20261107
    while argv and argv[0].startswith("--"):
        opt, value, argv = argv[0], argv[1], argv[2:]
        if opt == "--vdb":
            vdb = Path(value)
        elif opt == "--per-operator":
            per_op = int(value)
        elif opt == "--seed":
            seed = int(value)
    rng = random.Random(seed)
    names = sorted(argv)
    rng.shuffle(names)  # spread the mutants over many plans
    counts = defaultdict(lambda: [0, 0])
    plans_used = set()
    for name in names:
        doc = hc.parse_json_output(Path(name).read_text(errors="replace"))
        if not doc or doc.get("aborted") or hc.refusal(doc) or not any(
                e["outcome"] in hc.MERGE_BOUND for e in doc["entries"]):
            continue
        base = hc.check_plan(doc, vdb)
        if any(f.is_failure and not f.pre_existing for f in base):
            continue  # only clean plans are mutated
        plan = hc.load_plan(doc, vdb)
        for op in OPERATORS:
            if sum(counts[op.__name__]) >= per_op:
                continue
            offers = []
            for offer in op(doc, plan):
                offers.append(offer)
                if len(offers) >= MAX_OFFERS:
                    break
            if not offers:
                continue
            desc, make, expected = rng.choice(offers)
            new = new_findings(base, hc.check_plan(make(), vdb), expected)
            counts[op.__name__][0 if new else 1] += 1
            if expected is CONTROL:
                desc = ("FALSE ALARM: " if new else "control ok: ") + desc
            plans_used.add(Path(name).stem)
            print(json.dumps({"operator": op.__name__, "plan": Path(name).stem, "mutant": desc,
                              "killed": bool(new), "by": new[:2]}))
    print(f"\n{'operator':32} killed survived   ({len(plans_used)} plans mutated;"
          " for the control, killed = false alarm)")
    for op in OPERATORS:
        print(f"{op.__name__:32} {counts[op.__name__][0]:6} {counts[op.__name__][1]:8}")
    survivors = sum(s for name, (_, s) in counts.items() if name != "harmless_move")
    return 1 if survivors or counts["harmless_move"][0] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
