#!/usr/bin/env python3
"""Mutation test for `mrg --check-world`: break a copy of a tree on purpose
and require the check to report the damage (charter property 1).

Each operator makes one change to a copy of the tree (repository, config,
VDB) that, by construction, leaves a package `@world` reaches with no visible
version, or makes an ebuild unreadable, and names the finding it expects:
mask_best (a profile `package.mask` line), drop_keyword (the only version
becomes testing), raise_bound (a dependency bound above every version),
remove_package (ebuild and cache entry deleted), unreadable (cache entry
deleted and the ebuild cannot be sourced). The control `harmless` masks a
package nobody reaches; the result must not change at all. Portage is not
involved.

A mutant is killed when the check exits 1 with a finding of an expected
property that names the mutated package. A mutation that changes no file is
an error, never a kill. Before any mutant runs, the unmutated copy must give
the result of the original tree. Each mutant prints the files it changed.

Usage: check-world-mutants.py [--tree DIR] [--mrg PROGRAM...]
TREE defaults to pmtest's fixtures/; PROGRAM defaults to `$PORTUALE_BIN mrg`
(or `portuale mrg`). Exit 1 when a mutant survives, a mutation changed
nothing, or the control changes the result; 2 when the check cannot run.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

DEFAULT_TREE = Path(__file__).resolve().parents[2] / "fixtures"
UNSATISFIED = frozenset({"world-no-match", "world-invalid"})
CACHE = "repo/metadata/md5-cache"


class Operator:
    """`change(tree)` damages the copy; `properties` are the findings that
    must name `target` afterwards, or None for a control (no change at all)."""

    def __init__(self, name: str, target: str, change: Callable[[Path], None],
                 properties: frozenset | None = UNSATISFIED):
        self.name, self.target, self.change, self.properties = name, target, change, properties


class CheckError(RuntimeError):
    """The check did not run or did not print what it promises."""


def copy_tree(src: Path, dst: Path) -> Path:
    """Copy keeping symlinks (a copy that follows or drops them tests another tree)."""
    shutil.copytree(src, dst, symlinks=True)
    links = lambda root: sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_symlink())  # noqa: E731
    if links(src) != links(dst) or not links(dst):
        raise CheckError("the copy lost the symlinks of the tree")
    return dst


def check(tree: Path, mrg: list[str]) -> tuple[int, list[dict], dict]:
    """`mrg --check-world --json` on `tree`: (exit code, findings, summary)."""
    env = dict(os.environ, ROOT=str(tree), PORTAGE_CONFIGROOT=str(tree),
               PORTAGE_RUNNING_ROOT=str(tree), DISTDIR=str(tree / "distfiles"))
    run = subprocess.run([*mrg, "--check-world", "--json"], capture_output=True,
                         text=True, env=env, check=False)
    try:
        lines = [json.loads(line) for line in run.stdout.splitlines()]
        assert run.returncode in (0, 1) and lines and "atoms" in lines[-1]
    except (ValueError, AssertionError):
        raise CheckError(f"rc={run.returncode}\n{run.stdout[-500:]}{run.stderr[-500:]}") from None
    return run.returncode, lines[:-1], lines[-1]


def snapshot(tree: Path) -> dict[str, str]:
    """Relative path -> content hash (link target for a symlink)."""
    out = {}
    for p in sorted(tree.rglob("*")):
        if p.is_symlink():
            out[str(p.relative_to(tree))] = "-> " + os.readlink(p)
        elif p.is_file():
            out[str(p.relative_to(tree))] = hashlib.md5(p.read_bytes()).hexdigest()
    return out


def changed(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """Paths added, removed or changed, with a `+`, `-` or `~`."""
    return ([f"- {p}" for p in before if p not in after]
            + [f"+ {p}" for p in after if p not in before]
            + [f"~ {p}" for p in before if p in after and before[p] != after[p]])


# --- operators ---------------------------------------------------------------

def append(path: Path, text: str) -> None:
    path.write_text(path.read_text() + text)


def edit_ebuild(tree: Path, cpv: str, edit: Callable[[str], str], cache: dict[str, str]) -> None:
    """Rewrite an ebuild and its md5-cache entry together: `cache` gives the
    new value of each key, and `_md5_` is the md5 of the new ebuild."""
    cat, pvr = cpv.split("/")
    pn = pvr.rsplit("-", 1)[0]
    ebuild = tree / "repo" / cat / pn / f"{pvr}.ebuild"
    ebuild.write_text(edit(ebuild.read_text()))
    entry = tree / CACHE / cpv
    cache = dict(cache, _md5_=hashlib.md5(ebuild.read_bytes()).hexdigest())
    seen, lines = set(), []
    for line in entry.read_text().splitlines():
        key = line.split("=", 1)[0]
        seen.add(key)
        lines.append(f"{key}={cache[key]}" if key in cache else line)
    if seen != seen | set(cache):
        raise CheckError(f"{entry} has no key {sorted(set(cache) - seen)}")
    entry.write_text("\n".join(lines) + "\n")


def mask_best(tree: Path) -> None:
    """Mask every version of a package `@world` names."""
    append(tree / "repo/profiles/base/package.mask", "dev-libs/newpkg\n")


def drop_keyword(tree: Path) -> None:
    """The only version of a world package is no longer keyworded for the arch."""
    edit_ebuild(tree, "dev-libs/withdeps-1.0", lambda t: t.replace('KEYWORDS="amd64"', 'KEYWORDS="~amd64"'),
                {"KEYWORDS": "~amd64"})


def raise_bound(tree: Path) -> None:
    """A dependency asks for a version above every one in the repository."""
    edit_ebuild(tree, "dev-libs/withdeps-1.0",
                lambda t: t.replace("dev-libs/upgradepkg", ">=dev-libs/upgradepkg-3"),
                {"RDEPEND": "dev-libs/newpkg >=dev-libs/upgradepkg-3"})


def remove_package(tree: Path) -> None:
    """A package `@world` names is deleted, metadata cache included."""
    shutil.rmtree(tree / "repo/dev-libs/newpkg")
    (tree / CACHE / "dev-libs/newpkg-1.0").unlink()


def unreadable(tree: Path) -> None:
    """A version `@world` reaches has no cache entry and cannot be sourced."""
    ebuild = tree / "repo/dev-libs/upgradepkg/upgradepkg-2.0.ebuild"
    append(ebuild, "if [[ ((\n")
    (tree / CACHE / "dev-libs/upgradepkg-2.0").unlink()


def harmless(tree: Path) -> None:
    """Mask a package nothing in `@world` reaches."""
    append(tree / "repo/profiles/base/package.mask", "dev-libs/w701lowhi\n")


OPERATORS = [
    Operator("mask_best", "dev-libs/newpkg", mask_best),
    Operator("drop_keyword", "dev-libs/withdeps", drop_keyword),
    Operator("raise_bound", "dev-libs/upgradepkg", raise_bound),
    Operator("remove_package", "dev-libs/newpkg", remove_package),
    Operator("unreadable", "dev-libs/upgradepkg-2.0", unreadable, frozenset({"checker-limitation"})),
    Operator("harmless", "dev-libs/w701lowhi", harmless, None),
]


def run(tree: Path, mrg: list[str], work: Path, operators: list[Operator] | None = None):
    """(results, ok): one dict per operator, and whether all are good."""
    tree, work = Path(tree), Path(work)
    original = check(tree, mrg)
    if original[0] != 0:
        raise CheckError(f"the original tree is not clean: {original[1:]}")
    clean = copy_tree(tree, work / "clean")
    if check(clean, mrg) != original:
        raise CheckError("the unmutated copy gives another result than the original tree")
    before = snapshot(clean)
    shutil.rmtree(clean)
    results = []
    for op in operators or OPERATORS:
        copy = copy_tree(tree, work / op.name)
        op.change(copy)
        files = changed(before, snapshot(copy))
        rc, findings, summary = check(copy, mrg)
        shutil.rmtree(copy)
        named = [f for f in findings if op.properties and f["property"] in op.properties
                 and op.target in f"{f['package']} {f['atom']} {f['reason']}"]
        if op.properties is None:
            good = (rc, findings, summary) == original
        else:
            good = rc == 1 and bool(named)
        good = good and bool(files)
        results.append({"operator": op.name, "target": op.target, "changed": files,
                        "rc": rc, "reported": sorted({f["property"] for f in findings}),
                        "named": len(named), "good": good})
    return results, all(r["good"] for r in results)


def main(argv: list[str]) -> int:
    tree = DEFAULT_TREE
    mrg = [os.environ.get("PORTUALE_BIN", "portuale"), "mrg"]
    while argv:
        opt, argv = argv[0], argv[1:]
        if opt == "--tree" and argv:
            tree, argv = Path(argv[0]), argv[1:]
        elif opt == "--mrg" and argv:
            mrg, argv = argv, []
        else:
            print(__doc__)
            return 2
    work = Path(tempfile.mkdtemp(prefix="check-world-mutants-", dir="/var/tmp"))
    try:
        results, ok = run(tree, mrg, work)
    except CheckError as error:
        print(f"check-world-mutants: {error}", file=sys.stderr)
        return 2
    finally:
        shutil.rmtree(work, ignore_errors=True)
    for r in results:
        what = "control unchanged" if r["operator"] == "harmless" and r["good"] else \
            ("killed" if r["good"] else "SURVIVED / BAD")
        print(f"{r['operator']:15} {what:18} rc={r['rc']} reported={r['reported']} "
              f"naming {r['target']}: {r['named']}")
        for line in r["changed"] or ["  (no file changed: the mutation is void)"]:
            print(f"    {line}")
    print(f"\n{sum(r['good'] for r in results)}/{len(results)} good")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
