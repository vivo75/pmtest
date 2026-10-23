"""Registry of dependency-grammar features, each with a resolvable and an
unsatisfiable CASES entry reached through a dependency of a fixture ebuild
(a CLI-argument atom does not count).

A grammar slice adds a row here (see differential-test-bed/README.md).
Features without both cases are in EXEMPT with a reason and a backlog number.

Row keys: resolvable / unsatisfiable (CASES titles), ebuild / unsat_ebuild
(the fixture ebuild whose md5-cache dependency string carries the token for
each case, `cat/pf`), token / unsat_token (grammar token), portage_text (a
substring Portage prints for the unsatisfiable case), portage_ref (where, in
Portage 3.0.82.2 `_emerge/depgraph.py`).
"""

_NOEBUILD = 'there are no ebuilds to satisfy "dev-libs/subslotpkg:0/3"'

GRAMMAR = {
    "sub-slot": {
        "resolvable": "recursion: a sub-slot-restricted dependency atom actually matches",
        "unsatisfiable": "recursion: a sub-slot-restricted dependency atom genuinely rejects a mismatch",
        "ebuild": "dev-libs/subslotconsumer-1.0",
        "token": ":0/2",
        "unsat_ebuild": "dev-libs/subslotmismatchconsumer-1.0",
        "unsat_token": ":0/3",
        "portage_text": _NOEBUILD,
        "portage_ref": "depgraph.py:7031",
    },
    "use-dep": {
        "resolvable": "recursion: an installed || alternative's [use] dep matches its vdb USE (#74 S1)",
        "unsatisfiable": "recursion: [use]-dep unsat with the flag absent from IUSE -- real's Missing IUSE reason (backlog #20)",
        "ebuild": "dev-libs/altconsumer-1.0",
        "token": "[flip]",
        "unsat_ebuild": "dev-libs/unsatuseiuse-1.0",
        "unsat_token": "[noiuse]",
        "portage_text": "there are no ebuilds built with USE flags to satisfy",
        "portage_ref": "depgraph.py:6971",
    },
    "blocker": {
        "resolvable": "blocker: strong (!!) blocker vs an installed package no walk pulls in is satisfied (rc 0, Portage `b`)",
        "unsatisfiable": "blocker: weak (!) merge-vs-merge match is unsolvable (Portage `B`, rc 1)",
        "ebuild": "dev-libs/blockerpkg-1.0",
        "token": "!!",
        "unsat_ebuild": "dev-libs/weakblockerpkg-1.0",
        "unsat_token": "!",
        "portage_text": "Error: The above package list contains packages which cannot be",
        "portage_ref": "depgraph.py:10499",
    },
}

EXEMPT = {
    "slot (:slot only)": "no dependency-reached unsatisfiable slot-only atom: 'slot conflict: unsolvable' is a conflict between two satisfiable atoms, not an atom that matches nothing; fixture missing, backlog #494",
    "slot-operator (:= / :*)": "every slot-operator case is rc 0, none is unsatisfiable (Portage never rejects := by itself; needs a rebuild-forcing slot-operator fixture); backlog #495",
    "USE-dep default (+)/(-)": "resolvable exists (=udd0a-2 / -3) but no unsatisfiable dependency-reached case: the only candidate ('defaulted conditional USE-dep ... masks the package') is an invalid-metadata mask, not a failed (+)/(-) match; fixture missing, backlog #496",
    "::repo": "no dependency-reached case of either kind: every ::repo case passes the atom on the command line; needs a fixture with ::repo inside a *DEPEND, backlog #497",
    "package.provided": "config feature, not dependency grammar (covered by its own CASES, see 503/505 region)",
    "package.* fragments": "config feature, not dependency grammar (backlog #89)",
}
