"""Grammar registry: every dependency-grammar feature has a resolvable and an
unsatisfiable CASES entry, each reached through a dependency of a fixture
ebuild (never a CLI atom), and the unsatisfiable one prints Portage's wording.

Registry: grammar_registry.py (GRAMMAR / EXEMPT). Plan:
portuale LLM/02.493-mechanise-recurring-issues.opus.md, Task 2.
"""
from pathlib import Path

import pytest

from grammar_registry import EXEMPT, GRAMMAR
from test_emerge_pretend_contract import CASES, _run

TITLES = {title: (args, rc) for title, args, rc in CASES}
CACHE = Path(__file__).resolve().parent.parent / "fixtures" / "repo" / "metadata" / "md5-cache"
DEP_KEYS = ("DEPEND", "RDEPEND", "PDEPEND", "BDEPEND", "IDEPEND")


def _dep_strings(ebuild: str) -> str:
    cat, pf = ebuild.split("/")
    lines = (CACHE / cat / pf).read_text().splitlines()
    return "\n".join(
        line.split("=", 1)[1] for line in lines if line.split("=", 1)[0] in DEP_KEYS
    )


def test_every_grammar_feature_has_a_resolvable_and_an_unsatisfiable_case():
    assert GRAMMAR
    for feature, row in GRAMMAR.items():
        assert row["resolvable"] in TITLES, (feature, "resolvable case missing")
        assert row["unsatisfiable"] in TITLES, (feature, "unsatisfiable case missing")
        assert TITLES[row["resolvable"]][1] == 0, feature
        assert TITLES[row["unsatisfiable"]][1] == 1, feature


def test_exempt_features_carry_a_reason():
    assert EXEMPT
    assert all(r.strip() for r in EXEMPT.values())
    assert not set(EXEMPT) & set(GRAMMAR)


def test_registered_cases_use_the_feature():
    """Vacuity guard: the token occurs in the dependency string of the fixture
    ebuild each case resolves through, so a right-rc case that never touches
    the feature fails here."""
    for feature, row in GRAMMAR.items():
        for ebuild, token in (
            (row["ebuild"], row["token"]),
            (row["unsat_ebuild"], row["unsat_token"]),
        ):
            assert token in _dep_strings(ebuild), (feature, ebuild, token)


@pytest.mark.parametrize("feature", sorted(GRAMMAR))
def test_unsatisfiable_cases_print_the_portage_text(feature, emerge_binary, fixture_env):
    row = GRAMMAR[feature]
    args, rc = TITLES[row["unsatisfiable"]]
    result = _run([str(emerge_binary)], args, fixture_env)
    assert result.returncode == rc, (feature, result.returncode)
    assert row["portage_text"] in result.stdout + result.stderr, (
        feature,
        row["portage_ref"],
    )
    assert row["portage_ref"].startswith("depgraph.py:")
