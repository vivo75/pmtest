#!/usr/bin/env python3
"""Mutation test for the installed-state check of health_checker.py.

Copies the VDB of a healthy root, breaks the copy on purpose (drop a package
another one needs, add a blocker, break a REQUIRED_USE, put a second version in
a slot, make an ELF file need a library that does not exist), and checks that
`check_installed` reports a new finding of the expected property. A mutant that
is not reported survives and marks a blind spot; a harmless change (a control)
must not be reported. Portage is not involved.

Usage: health-state-mutants.py [--per-operator N] [--seed S] ROOT
ROOT is a root with `var/db/pkg` (the container's `/`, or a merged test root);
its disk is only read. Exit 1 when a mutant survives or a control is reported.
"""

from __future__ import annotations

import itertools
import json
import random
import shutil
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pytests-contract-suite"))
import health_checker as hc  # noqa: E402

CONTROL = "control"


def package_dirs(vdb: Path):
    return sorted(d for d in vdb.glob("*/*") if d.is_dir() and hc.split_pv(d.name))


def read(d: Path, key: str) -> str:
    return (d / key).read_text(errors="replace") if (d / key).is_file() else ""


def drop_needed_provider(vdb, rng):
    """Remove a package that another installed package names in its RDEPEND."""
    plan = hc.installed_plan(vdb)
    packages = list(plan.final)
    rng.shuffle(packages)
    for pkg in packages:
        for dep_class in hc.RUNTIME_CLASSES:
            for node in hc._reduced(pkg, dep_class):
                hits = [p for p in plan.final if p is not pkg and hc._satisfied(node, hc.index([p]), pkg)]
                if len(hits) == 1 and hits[0] is not pkg:
                    yield (f"drop {hits[0].cpv}, needed by {pkg.cpv}", "runtime-deps",
                           lambda v, h=hits[0]: shutil.rmtree(v / h.category / f"{h.package}-{h.version}"))


def add_blocker(vdb, rng):
    """Make one installed package block another."""
    dirs = package_dirs(vdb)
    for _ in range(8 if len(dirs) > 1 else 0):
        a, b = rng.sample(dirs, 2)
        cp_b = f"{b.parent.name}/{hc.split_pv(b.name)[0]}"
        if cp_b != f"{a.parent.name}/{hc.split_pv(a.name)[0]}":
            yield (f"{a.parent.name}/{a.name} blocks {cp_b}", "blocker",
                   lambda v, a=a, cp_b=cp_b: (v / a.parent.name / a.name / "RDEPEND").write_text(
                       read(a, "RDEPEND").rstrip() + f" !{cp_b}\n"))


def break_required_use(vdb, rng):
    """Give a package a REQUIRED_USE its USE violates."""
    for d in rng.sample(dirs := package_dirs(vdb), len(dirs)):
        yield (f"break REQUIRED_USE of {d.parent.name}/{d.name}", "required-use",
               lambda v, d=d: ((v / d.parent.name / d.name / "IUSE").write_text("mutx muty\n"),
                               (v / d.parent.name / d.name / "USE").write_text("mutx muty\n"),
                               (v / d.parent.name / d.name / "REQUIRED_USE").write_text(
                                   "^^ ( mutx muty )\n")))
        return


def second_in_slot(vdb, rng):
    """Install a second version into the slot of a package."""
    for d in rng.sample(dirs := package_dirs(vdb), len(dirs)):
        pkg, version = hc.split_pv(d.name)
        yield (f"a second version of {d.parent.name}/{pkg} in its slot", "slot",
               lambda v, d=d, pkg=pkg: shutil.copytree(
                   v / d.parent.name / d.name, v / d.parent.name / f"{pkg}-99999"))
        return


def library_missing(vdb, rng):
    """Make an installed ELF file need a library that is nowhere."""
    elf_dirs = [d for d in package_dirs(vdb) if read(d, "NEEDED.ELF.2").strip()]
    for d in rng.sample(elf_dirs, len(elf_dirs)):
        yield (f"{d.parent.name}/{d.name} needs libmutant.so.9", "linked-library",
               lambda v, d=d: (v / d.parent.name / d.name / "NEEDED.ELF.2").write_text(
                   read(d, "NEEDED.ELF.2").rstrip() +
                   "\nX86_64;/usr/bin/mutant;;;libmutant.so.9;x86_64\n"))
        return


def harmless(vdb, rng):
    """A change no property cares about: an extra file in a VDB entry."""
    for d in rng.sample(dirs := package_dirs(vdb), len(dirs)):
        yield (f"add a note to {d.parent.name}/{d.name}", CONTROL,
               lambda v, d=d: (v / d.parent.name / d.name / "NOTE").write_text("x\n"))
        return


OPERATORS = [drop_needed_provider, add_blocker, break_required_use, second_in_slot,
             library_missing, harmless]


def run(root: Path, per_op: int = 3, seed: int = 20261108):
    """Return (results, ok): one dict per mutant, and whether every mutant of a
    real operator was killed and no control was reported."""
    root = Path(root)
    base = hc.check_installed(root)
    base_keys = {hc.finding_key(f) for f in base}
    rng = random.Random(seed)
    results, ok = [], True
    for op in OPERATORS:
        offers = list(itertools.islice(op(root / "var/db/pkg", rng), per_op))
        for desc, expected, change in offers:
            with tempfile.TemporaryDirectory(prefix="health-state-") as tmp:
                vdb = Path(tmp) / "pkg"
                shutil.copytree(root / "var/db/pkg", vdb)
                change(vdb)
                found = [f for f in hc.check_installed(root, vdb=vdb)
                         if f.is_failure and hc.finding_key(f) not in base_keys]
            new = {f.property for f in found}
            killed = bool(new) if expected == CONTROL else expected in new
            good = (not new) if expected == CONTROL else killed
            ok &= good
            results.append({"operator": op.__name__, "mutant": desc, "expected": expected,
                            "reported": sorted(new), "good": good})
    return results, ok


def main(argv):
    per_op, seed = 3, 20261108
    while argv and argv[0].startswith("--"):
        opt, value, argv = argv[0], argv[1], argv[2:]
        per_op, seed = (int(value), seed) if opt == "--per-operator" else (per_op, int(value))
    if len(argv) != 1:
        print(__doc__)
        return 2
    results, ok = run(Path(argv[0]), per_op, seed)
    counts = defaultdict(lambda: [0, 0])
    for r in results:
        print(json.dumps(r))
        counts[r["operator"]][0 if r["good"] else 1] += 1
    print(f"\n{'operator':26} good  bad   (control: good = not reported)")
    for op in OPERATORS:
        print(f"{op.__name__:26} {counts[op.__name__][0]:4} {counts[op.__name__][1]:4}")
    return 0 if ok and results else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
