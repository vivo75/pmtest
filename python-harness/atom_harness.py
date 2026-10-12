#!/usr/bin/env python3
"""Neutral CLI test-harness binary (Python side) for the atom-matching
portuale -- see LLM/agent-context.md and crates/portage-dep/src/lib.rs
for the S2 grammar this exercises (EAPI-aware strict atoms incl. build-ids;
extended/wildcard syntax arrives in S3). Wraps Portage's
portage.dep.Atom / portage.dep.match_from_list rather than reimplementing
them, and rejects any atom that uses extended/wildcard syntax (S3 ports that
branch on the Rust side) so both harnesses
agree on the same input language rather than Python silently accepting a
wider one. Build-ids ARE accepted since S2 (see portage-dep's own doc
comment on the `=`-with-build-id match rule). Slot operators (":=", ":*",
":slot=") and USE deps ("foo[bar]", all 7 PMS 8.3.4 forms plus 4-style
defaults) ARE accepted -- see portage-dep's own doc comment on
why: Portage's own matching logic (_match_slot, and
match_from_list's own use-dep filtering, which it skips entirely for
plain-string candidates -- the only kind portuale has) never actually
needs either one to decide whether an atom matches a candidate, so
parsing them needed no new *matching* logic on either side, even though
the values themselves aren't enforced. The "=*" glob version operator
(PMS 8.3.1) IS accepted too -- see portage-dep's own doc comment
on the boundary-aware prefix-match port this needed; unlike slot
operators/USE deps, this one runs against Portage's match_from_list's actual
"=*" branch unmodified, so this file needed no new logic at all beyond
letting "=*" through _SUPPORTED_OPERATORS. The "::reponame" repo
constraint (PMS 3.1.5) IS accepted too -- see portage-dep's own
doc comment on the matching semantics (Portage's match_from_list's own final
post-pass filter, ported as `matches_repo`) and on why plain-string
candidates never carried repo identity before portuale's own
portage-repo started appending "::reponame" to the strings it builds.

Note on the reference: `_pinned_portage.py` imports the vendored checkout,
which has no compiled `_parser`, so this harness runs Portage's
pure-Python `Atom` path. That path is equal to the native C path for
`Atom` (0 differences over 120k fuzz cases, oracle report section 1.4),
so it is a valid reference here -- but NOT for `use_reduce` (S4/S10 must
not use it as the reference), where the C path diverges.

Usage:
    atom_harness.py parse [--eapi E] [--allow-repo 0|1] [--allow-build-id 0|1]
                           [--allow-wildcard] <atom>
                                            -> tab-separated fields (with
                                               trailing build-id field),
                                               or "INVALID"
    atom_harness.py match <atom> <cand...>    -> comma-joined matches
                                                  (possibly empty), or "INVALID"
    atom_harness.py affecting <atom> <dep...> -> sorted comma-joined
                                                  extract_affecting_use flags,
                                                  or "INVALID"
    atom_harness.py batch                     -> reads "parse <atom>",
                                                  "match <atom> <cand...>" or
                                                  "affecting <atom> <dep...>" lines
                                                  from stdin, one result per line
                                                  (`parse` lines take the same
                                                  flags, atom last)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pinned_portage import use_pinned_portage

use_pinned_portage()

from portage.dep import Atom, extract_affecting_use, match_from_list
from portage.exception import InvalidAtom, InvalidDependString
from portage.versions import catpkgsplit

_SUPPORTED_OPERATORS = {None, "=", "=*", ">", ">=", "<", "<=", "~"}


def _parse_v1_atom(s, eapi=None, allow_repo=None, allow_build_id=None,
                   allow_wildcard=False):
    """Returns a real Atom if `s` parses under the S2 grammar subset, else
    None (either it's not a valid atom at all, or it uses extended/wildcard
    syntax, which arrives in S3). Flags pass straight to `portage.dep.Atom`."""
    kwargs = {}
    if eapi is not None:
        kwargs["eapi"] = eapi
    if allow_repo is not None:
        kwargs["allow_repo"] = allow_repo
    if allow_build_id is not None:
        kwargs["allow_build_id"] = allow_build_id
    if allow_wildcard:
        kwargs["allow_wildcard"] = True
    try:
        a = Atom(s, **kwargs)
    except InvalidAtom:
        return None
    except ValueError:
        # A supported-but-unparseable `eapi` (e.g. "3_pre1", padded " 8"):
        # Portage raises ValueError out of `Eapi.__init__`.
        return None
    if a.extended_syntax or a.operator not in _SUPPORTED_OPERATORS:
        return None
    return a


def _format_parse(s, **kwargs):
    a = _parse_v1_atom(s, **kwargs)
    if a is None:
        return "INVALID"

    blocker = ""
    if a.blocker:
        blocker = "!!" if a.blocker.overlap.forbid else "!"

    if a.version is None:
        version = ""
        revision = ""
    else:
        _, _, version, rev = catpkgsplit(a.cpv)
        # catpkgsplit reports an absent revision as "r0" too; only an
        # explicit "-r0" in the atom is a revision field.
        revision = "" if rev == "r0" and not a.cpv.endswith("-r0") else rev[1:]

    category, package = a.cp.split("/", 1)
    fields = [
        blocker,
        a.operator or "",
        category,
        package,
        version,
        revision,
        a.slot or "",
        a.sub_slot or "",
        a.slot_operator or "",
        a.repo or "",
        ",".join(a.use.tokens) if a.use else "",
        "" if a.build_id is None else str(a.build_id),
    ]
    return "\t".join(fields)


def _format_match(atom_str, candidates):
    # NOTE (S2, review C-1): for an `=` atom with a build-id, Portage matches
    # plain-string candidates regardless of the build-id, while the Rust side
    # matches none (every portuale candidate models a `_pkg_str`/Package).
    # Match parity for build-id atoms is out of scope until S9; the Rust rule
    # is pinned by `eq_build_id_atom_matches_no_plain_candidate`.
    a = _parse_v1_atom(atom_str, allow_wildcard=True)
    if a is None:
        return "INVALID"
    matches = match_from_list(a, list(candidates))
    return ",".join(matches)


def _format_affecting(atom_str, dep_tokens):
    """Portage's own extract_affecting_use: sorted comma-joined
    flags, or "INVALID" on malformed dep syntax (Portage raises
    InvalidDependString; the Rust port returns None)."""
    try:
        flags = extract_affecting_use(" ".join(dep_tokens), atom_str)
    except InvalidDependString:
        return "INVALID"
    return ",".join(sorted(flags))


def _parse_flags(args):
    """Splits `parse` flags from the atom (always the last arg). Returns
    (kwargs, atom)."""
    kwargs = {}
    i = 0
    while i < len(args):
        if args[i] == "--eapi":
            i += 1
            kwargs["eapi"] = args[i]
        elif args[i] == "--allow-repo":
            i += 1
            kwargs["allow_repo"] = args[i] in ("1", "y", "yes", "true")
        elif args[i] == "--allow-build-id":
            i += 1
            kwargs["allow_build_id"] = args[i] in ("1", "y", "yes", "true")
        elif args[i] == "--allow-wildcard":
            kwargs["allow_wildcard"] = True
        else:
            break
        i += 1
    rest = args[i:]
    if len(rest) != 1:
        raise ValueError(f"parse expects 1 atom, got {rest!r}")
    return kwargs, rest[0]


def _dispatch(op, args):
    if op == "parse":
        kwargs, atom = _parse_flags(args)
        return _format_parse(atom, **kwargs)
    if op == "match":
        if len(args) < 1:
            raise ValueError("match expects at least 1 arg (the atom)")
        return _format_match(args[0], args[1:])
    if op == "affecting":
        if len(args) < 1:
            raise ValueError("affecting expects at least 1 arg (the atom)")
        return _format_affecting(args[0], args[1:])
    raise ValueError(f"unknown op {op!r}")


def _run_batch():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        print(_dispatch(parts[0], parts[1:]))


def main(argv):
    if not argv:
        print(
            "usage: atom_harness.py <parse atom | match atom cand... | batch>",
            file=sys.stderr,
        )
        return 2
    try:
        if argv[0] == "batch":
            _run_batch()
        else:
            print(_dispatch(argv[0], argv[1:]))
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
