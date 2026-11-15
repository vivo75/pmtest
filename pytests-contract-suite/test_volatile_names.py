"""One volatile-name rule for every copy site (backlog #762).

The names Portage's lock code creates next to a VDB entry exist only while a
lock is held. Three places filter them: the suite's `fixtures_copytree_ignore`
(`conftest.py`), the bed's `check-world-mutants.py`, and portuale's own
`vdb_rw.rs`. They had drifted (patterns without the leading dot in one,
required in the others). The first two now share `volatile_names.py`; the Rust
list stays where it is and this file fails when the three disagree.
"""

from __future__ import annotations

import importlib.util
import re
import shutil
from pathlib import Path

import pytest

import volatile_names
from conftest import fixtures_copytree_ignore

PMTEST = Path(__file__).resolve().parents[1]
BED = PMTEST / "differential-test-bed/compare/check-world-mutants.py"
VDB_RW = PMTEST.parent / "portuale/crates/portuale/src/vdb_rw.rs"

NAMES = [
    (".pkg.portage_lockfile", True),
    (".portage_lockfile", True),
    (".pkg.portage_lockfile.hardlock-host-123", True),
    (".pkg.portage_lockfile-inode-test", True),
    (".x-inode-test", True),
    (".mtimedb.seed.lock", True),
    (".mtimedb.tmp.99", True),
    # Leading dot required: a real file that merely ends alike is content.
    ("pkg.portage_lockfile", False),
    ("x-inode-test", False),
    ("world", False),
    ("portage_lockfile.txt", False),
]


def _bed():
    spec = importlib.util.spec_from_file_location("check_world_mutants", BED)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("name,volatile", NAMES)
def test_the_shared_predicate(name, volatile):
    assert volatile_names.is_volatile_name(name) is volatile


@pytest.mark.parametrize("name,volatile", NAMES)
def test_every_copy_site_uses_the_shared_rule(tmp_path, name, volatile):
    src, dst = tmp_path / "src", tmp_path / "dst"
    src.mkdir()
    (src / name).write_text("x\n")
    shutil.copytree(src, dst, ignore=fixtures_copytree_ignore())
    assert (not (dst / name).exists()) is volatile
    assert _bed().is_volatile_name(name) is volatile


def test_rust_list_agrees_with_the_shared_one():
    """`vdb_rw.rs::is_volatile_name` is `starts_with('.') && (ends_with(A) ||
    contains(B) || ends_with(C))`: read A, B, C from it and compare."""
    if not VDB_RW.is_file():
        pytest.skip("the sibling portuale checkout is not present")
    text = VDB_RW.read_text()
    body = text[text.index("fn is_volatile_name") :]
    body = body[: body.index("\n}\n")]
    assert "starts_with('.')" in body
    ends = re.findall(r'ends_with\("([^"]+)"\)', body)
    contains = re.findall(r'contains\("([^"]+)"\)', body)
    assert (ends, contains) == (
        list(volatile_names.LOCK_SUFFIXES),
        list(volatile_names.LOCK_INFIXES),
    ), "vdb_rw.rs and pmtest volatile_names.py disagree: change both"
