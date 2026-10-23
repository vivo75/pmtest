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
    "slot (:slot only)": {
        "resolvable": "#494: a slot-only (:2) dependency atom that gxslotdep satisfies resolves (rc 0, Portage 3.0.82.2)",
        "unsatisfiable": "#494: a slot-only (:9) dependency atom no ebuild satisfies aborts with `no ebuilds to satisfy` (rc 1, Portage 3.0.82.2)",
        "ebuild": "dev-libs/gxslotonlyok-1.0",
        "token": ":2",
        "unsat_ebuild": "dev-libs/gxslotonlybad-1.0",
        "unsat_token": ":9",
        "portage_text": 'there are no ebuilds to satisfy "dev-libs/gxslotdep:9"',
        "portage_ref": "depgraph.py:7031",
    },
    "slot-operator (:= / :*)": {
        "resolvable": "recursion: slot-operator dependency atoms are resolved, not dropped",
        "unsatisfiable": "#495: a slot-operator (:9=) dependency atom no ebuild satisfies aborts with `no ebuilds to satisfy` (rc 1, Portage 3.0.82.2)",
        "ebuild": "dev-libs/slotoperatorpkg-1.0",
        "token": ":=",
        "unsat_ebuild": "dev-libs/gxslotopbad-1.0",
        "unsat_token": ":9=",
        "portage_text": 'there are no ebuilds to satisfy "dev-libs/gxslotdep:9="',
        "portage_ref": "depgraph.py:7031",
    },
    "USE-dep default (+)/(-)": {
        "resolvable": "usedep: upstream test_use_dep_defaults pg0 =udd0a-2 merges like Portage (rc 0; B[foo(+)] default-on via B-2, pinned below)",
        "unsatisfiable": "#496: a [flag(-)] USE-dep on a target without flag in IUSE fails to match (rc 1, Portage 3.0.82.2)",
        "ebuild": "dev-libs/udd0a-2",
        "token": "[foo(+)]",
        "unsat_ebuild": "dev-libs/gxuddbad-1.0",
        "unsat_token": "[flag(-)]",
        "portage_text": 'there are no ebuilds to satisfy "dev-libs/gxuddtarget[flag(-)]"',
        "portage_ref": "depgraph.py:7031",
    },
}

EXEMPT = {
    "::repo": "Portage rejects a ::repo atom inside an ebuild dependency string as invalid metadata (`masked by: invalid: RDEPEND: Invalid atom (dev-libs/gxslotdep::testrepo), token 1`, rc 1) for the matching and the non-matching repo alike, so no resolvable dependency-reached case exists; portuale agrees (checked with throwaway fixtures, #497). ::repo is CLI/config-only grammar and stays covered by the CLI-atom CASES",
    "package.provided": "config feature, not dependency grammar (covered by its own CASES, see 503/505 region)",
    "package.* fragments": "config feature, not dependency grammar (backlog #89)",
}
