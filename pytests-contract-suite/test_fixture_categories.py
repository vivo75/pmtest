"""Every category dir in a fixture repo must be listed in that repo's
`profiles/categories` (Task 11a).

Portage drops every package whose category is not in `settings.categories`
(`porttree.py:1156` + `:1216-1225`), and that set comes only from the
profile chain, overlay `profiles/` dirs and `/etc/portage`
(`config.py:948-960`). The five fixture repos now commit the union file
the L0 fixture-oracle bed's `stage.sh` step 3 computes, so a future
fixture that adds a category dir without listing it would be silently
masked on Portage's side (and, once portuale honours the allow-list,
on portuale's too). This guard fails first instead.

A category dir is an immediate repo subdir holding at least one ebuild;
non-category dirs (`metadata`, `profiles`, `eclass`) need no listing.
`profiles/categories` itself may list extra names (today it carries the
full `stage.sh` union, `eclass`/`metadata`/`profiles` included) -- that
is harmless, so the check is one-directional coverage, not equality.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_REPOS = [
    REPO_ROOT / "fixtures" / name
    for name in (
        "repo",
        "overlay",
        "independentoverlay",
        "layoutmasteroverlay",
        "repnamerepo",
        "repo-341",
        "repo-341-formats",
        "repo-348",
        "repo-355",
        "repo-p571",
        "overlay-p571",
    )
]

# Backlog #571: `repo-p571` deliberately leaves category dirs unlisted in
# its own `profiles/categories` (the allow-list fixture: `p571-hidden` is
# listed nowhere, `p571-shared` only by the overlay). Every other repo
# must list every ebuild-bearing dir.
DELIBERATELY_UNLISTED = {
    "repo-p571": {"p571-hidden", "p571-shared"},
}


def _category_dirs(root: Path) -> list[str]:
    cats = []
    for child in sorted(root.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        if next(child.rglob("*.ebuild"), None) is not None:
            cats.append(child.name)
    return cats


def _listed_categories(path: Path) -> set[str]:
    listed = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            listed.add(line)
    return listed


@pytest.mark.parametrize("root", FIXTURE_REPOS,
                         ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_fixture_repo_profiles_categories_lists_every_category_dir(root: Path):
    categories_file = root / "profiles" / "categories"
    assert categories_file.is_file(), (
        f"{root}: profiles/categories is missing -- Portage masks "
        f"every package whose category is not listed there"
    )
    listed = _listed_categories(categories_file)
    # Backlog #571: the allow-list fixture's deliberate omissions (kept
    # minimal and named -- anything else missing still fails).
    excused = DELIBERATELY_UNLISTED.get(root.name, set())
    missing = [c for c in _category_dirs(root)
               if c not in listed and c not in excused]
    assert not missing, (
        f"{root}: category dir(s) not listed in profiles/categories "
        f"(Portage would mask them): {', '.join(missing)}"
    )
    # The excuse list itself must stay exact: no repo may list an
    # "unlisted" category, and no excused dir may go missing from disk.
    for cat in excused:
        assert cat not in listed, (
            f"{root}: {cat} is excused as unlisted but is listed"
        )
        assert (root / cat).is_dir(), (
            f"{root}: excused unlisted dir {cat} is missing from disk"
        )
