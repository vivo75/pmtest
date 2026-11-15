"""The fixture-copy seam (backlog #757).

A copy of the shared fixture tree must never carry runtime lock state: the
vdb lockfile and its hardlink/inode-probe siblings are created and deleted
by concurrent suite runs, so a copier can list one just as its owner unlinks
it and die with ENOENT (`shutil.Error`) — that is a harness fault that reads
as a product failure, which is how it cost two runs in 2026-11-15 (backlog
#754 fixed the same shape in the bed, #757 its four remaining sites here).

Two pins:
  * the helper drops the whole volatile shape, not three literals, and drops
    nothing else;
  * no copy of `var`/the whole ROOT in this suite is made without it — a
    source-level check, because the failure mode is a *new* site written by
    someone who never saw this file.

The source scan reads text: a path held in a variable, an f-string, or an
alias (`cp = shutil.copytree`) is invisible to it. Every site in this suite
inlines its path, so the scan covers the idiom actually used — it is a
tripwire for the obvious form, not a proof of absence.
"""

from __future__ import annotations

import re
import shutil
from pathlib import Path

import pytest

from conftest import fixtures_copytree_ignore

SUITE = Path(__file__).resolve().parent

VOLATILE = [
    ".pkg.portage_lockfile",
    ".pkg.portage_lockfile.hardlock-h-1",
    ".pkg.portage_lockfile-inode-test",
    ".mtimedb.seed.lock",
    ".mtimedb.tmp.123456",
]


def _scratch_tree(root: Path) -> None:
    (root / "var/db/pkg/dev-libs/kept-1").mkdir(parents=True)
    (root / "var/db/pkg/dev-libs/kept-1/CATEGORY").write_text("dev-libs\n")
    (root / "var/lib/portage").mkdir(parents=True)
    (root / "var/lib/portage/world").write_text("dev-libs/kept\n")
    (root / "var/lib/portage/mtimedb").write_text("{}\n")
    for name in VOLATILE[:3]:
        (root / "var/db" / name).write_text("lock\n")
    for name in VOLATILE[3:]:
        (root / "var/lib/portage" / name).write_text("lock\n")


def test_the_copy_filter_drops_every_volatile_name_and_nothing_else(tmp_path):
    src, dst = tmp_path / "src", tmp_path / "dst"
    _scratch_tree(src)

    shutil.copytree(src, dst, symlinks=True, ignore=fixtures_copytree_ignore())

    for name in VOLATILE:
        where = "var/db" if name.startswith(".pkg.") else "var/lib/portage"
        assert not (dst / where / name).exists(), f"{name} travelled in the copy"
    # The positive control: a filter that drops everything is not a fix.
    assert (dst / "var/db/pkg/dev-libs/kept-1/CATEGORY").read_text() == "dev-libs\n"
    assert (dst / "var/lib/portage/world").read_text() == "dev-libs/kept\n"
    assert (dst / "var/lib/portage/mtimedb").exists(), "mtimedb must ride along"


def test_extra_names_compose_with_the_volatile_set(tmp_path):
    src, dst = tmp_path / "src", tmp_path / "dst"
    _scratch_tree(src)

    shutil.copytree(
        src, dst, symlinks=True, ignore=fixtures_copytree_ignore("mtimedb")
    )

    assert not (dst / "var/lib/portage/mtimedb").exists()
    assert not (dst / "var/db/.pkg.portage_lockfile").exists()
    assert (dst / "var/lib/portage/world").exists()


FIXTURE_ROOT_EXPR = re.compile(
    r"^(?:Path\()?\s*(?:fixtures_root|FIXTURES_ROOT|FIXTURES)\s*\)?$"
)
TAIL_SEGMENT = re.compile(r"/\s*(['\"])([^'\"]+)\1\s*$")


def _copies_shared_state(source: str) -> bool:
    """Whether a `copytree` source can meet the vdb lock or is the whole
    tree: `var`, the whole ROOT, a bare fixture root, or a `fixtures/`
    tail. A copy of `etc/`, `repo/`, `pkgdir` or an overlay cannot and is
    not flagged."""
    src = source[len("copytree(") :].strip() if source.startswith("copytree(") else source.strip()
    if src.startswith("src="):
        src = src[len("src=") :].strip()
    if any(marker in src for marker in ('/ "var"', "/ 'var'", '["ROOT"]', "['ROOT']")):
        return True
    if FIXTURE_ROOT_EXPR.match(src):
        return True
    tail = TAIL_SEGMENT.search(src)
    return bool(tail) and tail.group(2) in {"fixtures", "var"}


def _copytree_calls(text: str) -> list[tuple[int, str]]:
    """Every `copytree(` call, joined across continuation lines."""
    calls = []
    for match in re.finditer(r"copytree\(", text):
        start = match.start()
        depth, i = 0, match.end() - 1
        while i < len(text):
            ch = text[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        calls.append((text.count("\n", 0, start) + 1, text[start : i + 1]))
    return calls


def test_no_copy_of_the_vdb_or_the_whole_root_is_unfiltered():
    """The class pin: a copy that can meet `var/db/.pkg.portage_lockfile`
    must pass `ignore=fixtures_copytree_ignore(...)`. Subtree copies of
    `etc/`, `repo/`, `pkgdir` or an overlay cannot and are left alone."""
    offenders = []
    for path in sorted(SUITE.glob("*.py")):
        if path.name in {Path(__file__).name, "conftest.py"}:
            continue
        text = path.read_text()
        for line, call in _copytree_calls(text):
            source = call.split(",", 1)[0]
            # The helper must be the filter, not just any `ignore=`: an
            # unrelated pattern list does not guard the lock.
            if _copies_shared_state(source) and "fixtures_copytree_ignore(" not in call:
                offenders.append(f"{path.name}:{line}")
    assert not offenders, (
        "these copies can meet the vdb lockfile and must pass "
        "ignore=fixtures_copytree_ignore(): " + ", ".join(offenders)
    )


def test_the_source_level_pin_can_see_an_unfiltered_site(tmp_path):
    """The pin above is only worth its red: prove the scanner flags a bare
    `var` copy, so a future site cannot slip through a broken matcher."""
    for sample in (
        'shutil.copytree(Path(env["ROOT"]) / "var", root / "var", symlinks=True)\n',
        "shutil.copytree(fixtures_root, dest, symlinks=True)\n",
        "shutil.copytree(fixtures_root / 'fixtures', dest)\n",
        "shutil.copytree(src=fixture_env['ROOT'], dst=root)\n",
    ):
        calls = _copytree_calls(sample)
        assert len(calls) == 1, sample
        source = calls[0][1].split(",", 1)[0]
        assert _copies_shared_state(source), sample
        assert "fixtures_copytree_ignore(" not in calls[0][1], sample
    # ...and it must not flag the config copies that are legitimately bare.
    for safe in (
        'shutil.copytree(fixtures_root / "etc", root / "etc", symlinks=True)\n',
        'shutil.copytree(overlay / "metadata" / "md5-cache", cache)\n',
        'shutil.copytree(root / "pkgdir", root2 / "pkgdir", dirs_exist_ok=True)\n',
    ):
        calls = _copytree_calls(safe)
        assert not _copies_shared_state(calls[0][1].split(",", 1)[0]), safe
