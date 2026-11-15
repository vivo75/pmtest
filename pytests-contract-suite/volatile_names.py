"""The volatile-name rule shared by every pmtest copy site (backlog #762).

Names that exist only while a lock is held, or while the updates-record seeder
writes: never tree content, and a copy that lists one just as its owner
unlinks it dies with ENOENT. Imported by `conftest.py`
(`fixtures_copytree_ignore`) and by `differential-test-bed/compare/check-world-mutants.py`.

LOCK_SUFFIXES and LOCK_INFIXES mirror `is_volatile_name` in portuale's
`crates/portuale/src/vdb_rw.rs` (Portage `locks.py`); `test_volatile_names.py`
fails when the two lists disagree. Every name starts with a dot.
"""

from __future__ import annotations

LOCK_SUFFIXES = (".portage_lockfile", "-inode-test")
LOCK_INFIXES = (".portage_lockfile.hardlock-",)
# pmtest-only: the updates-record seeder's lock and temporary files.
SEEDER_NAMES = (".mtimedb.seed.lock",)
SEEDER_PREFIXES = (".mtimedb.tmp.",)


def is_volatile_name(name: str) -> bool:
    """Whether a directory entry is lock/probe/seeder state, not content."""
    if not name.startswith("."):
        return False
    return (
        name.endswith(LOCK_SUFFIXES)
        or any(infix in name for infix in LOCK_INFIXES)
        or name in SEEDER_NAMES
        or name.startswith(SEEDER_PREFIXES)
    )
