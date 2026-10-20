"""Metamorphic tests (`docs/second_python_copy_removal.md` §5): input
transforms that must not change portuale's resolver output.

Five transforms, each applied to a private copy of `fixtures/`:

1. duplicate an IUSE token in a package the case resolves (the
   motivating bug -- IUSE `x x` rendered twice -- was invisible to the
   removed Python mirror because both copies shared it);
2. add an unrelated package to the main repo;
3. add an empty overlay repo to `repos.conf`;
4. rename a fixture category consistently, everywhere including the
   vdb and every atom string (output normalised back);
5. reorder two non-overlapping `package.use` lines.

A representative subset of `CASES` runs pristine and transformed;
`(exit, stdout, stderr)` must be byte-identical. This is a property test,
not an exhaustive one (the plan's own wording). The subset covers the
IUSE/IUSE_EXPAND/config-file heavy fixtures (at most three cases per
fixture atom) plus one representative atom group per other resolver area
(blockers, slot conflicts / slot operators, circular deps, keyword/mask
visibility, `||`-group selection, autounmask, binary packages), and three
description-matched cases whose argv carries no selectable atom (`@world` /
`@system` expand from files, not from an atom string). A transform that
changes output is a genuine bug: fix it and keep the failing case as a
permanent regression fixture rather than relaxing the transform.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
from collections import Counter
from collections.abc import Callable
from pathlib import Path

import pytest

from conftest import FIXTURES_ROOT
from test_emerge_pretend_contract import CASES

REPO_NAMES = ("repo", "overlay", "independentoverlay", "layoutmasteroverlay", "repnamerepo")

SUBSET_ATOMS = (
    # USE-flag shapes (the original eight): IUSE/IUSE_EXPAND evaluation,
    # package.use layering, REQUIRED_USE, wildcard expansion, build flags.
    "dev-libs/useflagpkg",
    "dev-libs/useexpandpkg",
    "dev-libs/iusedefaultpkg",
    "dev-libs/packageuseenablepkg",
    "dev-libs/packageusedisablepkg",
    "dev-libs/requireduseokpkg",
    "dev-libs/wildexpandpkg",
    "dev-libs/usebuildpkg",
    # Blockers: upstream pg0 merge-order permutations (each ordering pulls
    # all three atoms, so only blk0a is listed), a satisfied strong blocker,
    # and an unsolvable weak blocker (rc 1, the `B` graph path).
    "dev-libs/blk0a",
    "dev-libs/blockerpkg",
    "dev-libs/graphblockerparent",
    # Slot conflicts / slot operators: backtrack-reconciled conflict,
    # reported unsolvable conflict (rc 1, incl. the --backtrack=30 hint
    # variant), and slot-operator dep atoms that must resolve, not drop.
    "dev-libs/slotconflictparent",
    "dev-libs/slotconflictunsolvable",
    "dev-libs/slotoperatorpkg",
    # Circular deps: upstream pg0 failure with USE suggestions (versioned
    # `=dev-libs/cyc0z-N` atoms), the four-ring cycle trailer, and a plain
    # cycle that terminates (rc 0).
    "dev-libs/cyc0z",
    "dev-libs/cyc4a",
    "dev-libs/cycle-a",
    # Keyword / mask visibility: installed-but-masked top-level atom,
    # avoid_update keeping a masked dependency (its --emptytree downgrade
    # and USE-dep siblings match the same atom prefix, covering the
    # --emptytree shape too).
    "dev-libs/keywordmaskedpkg",
    "dev-libs/needskeywordmasked",
    # `||`-group selection: the masked-alternative allow_masked pass, the
    # installed-alternative preference (+ the unsatisfiable fallback and
    # the LICENSE `||` sibling, which share the atom prefix).
    "dev-libs/omasked",
    "dev-libs/anyof",
    # Autounmask: the backward USE cascade (plain, -v, and --autounmask-use=n
    # siblings match the same atom).
    "dev-libs/aucasctop",
    # Binary packages: the --usepkg pool (invisible without it, eligible
    # with it, excluded by --usepkg-exclude).
    "dev-libs/binaryonlypkg",
)

# Cases whose argv carries no selectable atom: `@world` / `@system` expand
# from the world file / profile packages files, not from an atom string, so
# atom matching cannot reach them. Matched by exact description instead; a
# renamed description fails loudly at import (see below), never silently.
SUBSET_DESCRIPTIONS = (
    "@world expands to the fixture world file's own atoms",
    "@world combined with an explicit atom too",
    "@system expands to the fixture profile chain's own packages files",
)


def _subset() -> list[tuple[str, list[str], int]]:
    picked: list[tuple[str, list[str], int]] = []
    counts: Counter[str] = Counter()
    for case in CASES:
        _, args, _ = case
        joined = " ".join(args)
        for atom in SUBSET_ATOMS:
            if atom in joined:
                if counts[atom] < 3:
                    counts[atom] += 1
                    picked.append(case)
                break
    return picked


SUBSET = _subset()


def _subset_extra() -> list[tuple[str, list[str], int]]:
    by_description = {case[0]: case for case in CASES}
    missing = [d for d in SUBSET_DESCRIPTIONS if d not in by_description]
    if missing:
        raise ValueError(f"metamorphic SUBSET_DESCRIPTIONS drifted, missing: {missing}")
    picked = [c for c in SUBSET if c[0] in SUBSET_DESCRIPTIONS]
    if picked:
        raise ValueError(f"metamorphic subsets overlap, already atom-matched: {[d for d, _, _ in picked]}")
    return [by_description[d] for d in SUBSET_DESCRIPTIONS]


SUBSET = SUBSET + _subset_extra()

_CAT_PKG = re.compile(r"(?<![\w/.-])([a-z0-9][\w.+-]*)/([\w.+-]+)")


def _atoms(args: list[str]) -> list[tuple[str, str]]:
    seen: list[tuple[str, str]] = []
    for arg in args:
        for m in _CAT_PKG.finditer(arg):
            cp = (m.group(1), m.group(2))
            if cp not in seen:
                seen.append(cp)
    return seen


def _materialize(dst: Path) -> Path:
    root = dst / "fixtures"
    # symlinks=True: `etc/portage/make.profile` is a relative symlink, and
    # following it breaks the profile's `../base` parent -- every run then
    # fails identically and the comparison proves nothing.
    shutil.copytree(FIXTURES_ROOT, root, symlinks=True)
    return root


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".mt-tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def _tree_fingerprint(root: Path) -> tuple:
    return tuple(
        (str(p.relative_to(root)), p.stat().st_size, p.stat().st_mtime_ns)
        for p in sorted(root.rglob("*")) if p.is_file()
    )


def _run(emerge: Path, root: Path, args: list[str]) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PORTAGE_CONFIGROOT"] = str(root)
    env["ROOT"] = str(root)
    env["PORTAGE_RUNNING_ROOT"] = str(root)
    env["DISTDIR"] = str(root / "distfiles")
    return subprocess.run([str(emerge), *args], capture_output=True, text=True,
                          env=env, check=False)


_PRISTINE: dict[tuple[str, ...], subprocess.CompletedProcess] = {}


def _pristine(emerge: Path, root: Path, args: list[str]) -> subprocess.CompletedProcess:
    key = tuple(args)
    if key not in _PRISTINE:
        _PRISTINE[key] = _run(emerge, root, args)
    return _PRISTINE[key]


def _normalised(result: subprocess.CompletedProcess, roots: list[Path],
                rewrite=None) -> tuple:
    out = []
    for field in (result.returncode, result.stdout, result.stderr):
        if isinstance(field, str):
            for root in roots:
                field = field.replace(str(root), "<ROOT>")
            if rewrite is not None:
                field = rewrite(field)
        out.append(field)
    return tuple(out)


# -- transforms ----------------------------------------------------------


def _duplicate_iuse(root: Path, args: list[str]) -> tuple[list[str], None]:
    """Duplicate the first IUSE token of every fixture package the subset's
    cases name (one pass over the whole tree, shared by all cases)."""
    changed = False
    for cat, pkg in _atoms(args):
        cache = [
            f for repo in REPO_NAMES
            for f in sorted((root / repo / "metadata" / "md5-cache" / cat).glob(f"{pkg}-*"))
            if f.is_file()
        ]
        ebuilds = sorted(root.glob(f"*/{cat}/{pkg}/*.ebuild"))
        for path in [*cache, *ebuilds]:
            lines = path.read_text().splitlines(keepends=True)
            for i, line in enumerate(lines):
                m = re.match(r"^(IUSE=)(['\"]?)([^'\"]*)\2\s*$", line)
                if not m or not m.group(3).split():
                    continue
                tokens = m.group(3).split()
                dup = " ".join([tokens[0], *tokens])
                lines[i] = f"{m.group(1)}{m.group(2)}{dup}{m.group(2)}\n"
                _atomic_write(path, "".join(lines))
                changed = True
                break
    assert changed, "no fixture package with a non-empty IUSE in the subset's atoms"
    return args, None


_UNRELATED_EBUILD = """EAPI=8
DESCRIPTION="fixture package: metamorphic control, referenced by nothing"
SLOT="0"
KEYWORDS="amd64"
"""

_UNRELATED_CACHE = """DEFINED_PHASES=-
DESCRIPTION=fixture package: metamorphic control, referenced by nothing
EAPI=8
IUSE=
KEYWORDS=amd64
SLOT=0
_md5_={md5}
"""


def _add_unrelated_package(root: Path, args: list[str]) -> tuple[list[str], None]:
    pkgdir = root / "repo" / "dev-libs" / "mtunrelated"
    pkgdir.mkdir(parents=True)
    (pkgdir / "mtunrelated-1.0.ebuild").write_text(_UNRELATED_EBUILD)
    # The real md5 of the emitted ebuild, not a placeholder (backlog #46
    # S1: the committed-fixture guard and the S3 reader validation both
    # check `_md5_`).
    (root / "repo" / "metadata" / "md5-cache" / "dev-libs" / "mtunrelated-1.0").write_text(
        _UNRELATED_CACHE.format(
            md5=hashlib.md5(_UNRELATED_EBUILD.encode()).hexdigest()))
    return args, None


def _add_empty_overlay(root: Path, args: list[str]) -> tuple[list[str], None]:
    overlay = root / "mtoverlay"
    (overlay / "metadata").mkdir(parents=True)
    (overlay / "profiles").mkdir(parents=True)
    (overlay / "profiles" / "repo_name").write_text("mtoverlay\n")
    repos = root / "etc" / "portage" / "repos.conf" / "repos.conf"
    text = repos.read_text()
    if not text.endswith("\n"):
        text += "\n"
    _atomic_write(repos, text + "\n[mtoverlay]\nlocation = mtoverlay\npriority = 50\n")
    return args, None


_CATEGORY_OLD = "dev-libs"
# Same length as the old name, so column-aligned markers (`^   ^`) do not move.
_CATEGORY_NEW = "dev-libx"


def _rename_category(root: Path, args: list[str]) -> tuple[list[str], Callable]:
    old, new = _CATEGORY_OLD, _CATEGORY_NEW
    for repo in REPO_NAMES:
        for base in (root / repo, root / repo / "metadata" / "md5-cache"):
            d = base / old
            if d.is_dir():
                d.rename(base / new)
    vdb = root / "var" / "db" / "pkg" / old
    if vdb.is_dir():
        vdb.rename(vdb.parent / new)
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        if old + "/" in text:
            _atomic_write(path, text.replace(old + "/", new + "/"))
    rewritten = [a.replace(old + "/", new + "/") for a in args]
    # the bare name too: --json prints the category on its own
    return rewritten, lambda s: s.replace(new, old)


def _reorder_package_use(root: Path, args: list[str]) -> tuple[list[str], None]:
    path = root / "etc" / "portage" / "package.use"
    lines = path.read_text().splitlines(keepends=True)
    for i in range(len(lines) - 1):
        a = lines[i].split()
        b = lines[i + 1].split()
        if a and b and a[0] != b[0]:
            lines[i], lines[i + 1] = lines[i + 1], lines[i]
            _atomic_write(path, "".join(lines))
            return args, None
    pytest.skip("package.use has no two adjacent non-overlapping lines")


TRANSFORMS = [
    pytest.param(_duplicate_iuse, id="duplicate-iuse"),
    pytest.param(_add_unrelated_package, id="add-unrelated-package"),
    pytest.param(_add_empty_overlay, id="add-empty-overlay"),
    pytest.param(_rename_category, id="rename-category"),
    pytest.param(_reorder_package_use, id="reorder-package-use"),
]


# -- tests ---------------------------------------------------------------


@pytest.fixture(scope="session")
def pristine_fixtures(tmp_path_factory: pytest.TempPathFactory) -> Path:
    return _materialize(tmp_path_factory.mktemp("metamorphic-pristine"))


def _subset_args() -> list[str]:
    return [arg for _, args, _ in SUBSET for arg in args]


def _rewrite_args(transform_id: str, args: list[str]) -> list[str]:
    if transform_id == "rename-category":
        return [a.replace(_CATEGORY_OLD + "/", _CATEGORY_NEW + "/") for a in args]
    return args


@pytest.fixture(scope="session")
def transformed_fixtures(tmp_path_factory: pytest.TempPathFactory):
    """One transformed copy of `fixtures/` per transform, built on first use
    and shared by every case: the runs only read the tree (the pristine copy
    has always been shared the same way), so copying 24 MB per case was most
    of this file's run time."""
    built: dict[str, tuple[Path, Callable | None]] = {}

    def get(transform_id: str, transform) -> tuple[Path, Callable | None]:
        if transform_id not in built:
            root = _materialize(tmp_path_factory.mktemp(f"metamorphic-{transform_id}"))
            before = _tree_fingerprint(root)
            _, rewrite = transform(root, _subset_args())
            assert _tree_fingerprint(root) != before, (
                f"transform {transform_id!r} did not modify the fixture tree")
            built[transform_id] = (root, rewrite)
        return built[transform_id]

    return get


@pytest.mark.parametrize("case", SUBSET, ids=[d for d, _, _ in SUBSET])
@pytest.mark.parametrize("transform", TRANSFORMS)
def test_transform_does_not_change_output(case, transform, emerge_binary,
                                          pristine_fixtures, transformed_fixtures):
    description, args, _ = case
    transform_id = transform.__name__.lstrip("_").replace("_", "-")
    root, rewrite = transformed_fixtures(transform_id, transform)
    transformed_args = _rewrite_args(transform_id, list(args))

    want = _pristine(emerge_binary, pristine_fixtures, args)
    assert want.returncode == case[2], (
        f"{description}: the pristine run exited {want.returncode}, not the "
        f"case's {case[2]}: {want.stderr[:200]!r}")
    got = _run(emerge_binary, root, transformed_args)
    assert _normalised(got, [root, pristine_fixtures], rewrite) == \
        _normalised(want, [root, pristine_fixtures], rewrite), (
        f"{description}: transform changed the output")
