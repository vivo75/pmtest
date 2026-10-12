#!/usr/bin/env python3
"""Neutral CLI test-harness binary (Python side) for the
use_reduce(flat=True) portuale -- see LLM/agent-context.md and
crates/use-reduce-harness/src/use_reduce.rs for what is and isn't
ported. Wraps Portage's portage.dep.use_reduce rather than reimplementing
it, always called with flat=True and no masklist/excludeall/is_src_uri/
opconvert/subset/token_class -- see the Rust side's doc comment for why
those are out of v1 scope.

The `validate` op wraps the S4 shape instead (`matchall=True, flat=True,
token_class=Atom, is_valid_flag=…`, Portage `Package._validate_deps`) and
selects the message the way `_metadata_exception` does: a categorized
inner error prints bare, anything else the outer `InvalidDependString`
text. NOTE (review M-5): `_pinned_portage.py` imports the vendored
checkout, which has no compiled `_parser`, so the pure-Python `Atom` path
runs here -- equal to the C path for `Atom` (0 differences over the 120k
fuzz cases, oracle report section 1.4), so this differential is sound for
atom-level validation (it must NOT be reused for S10's native-scanner
quirk, where C and PY diverge).

Usage:
    use_reduce_harness.py reduce <mode> <uselist> <token...>
        mode: "normal" | "matchall" | "matchnone"
        uselist: comma-separated enabled flags, or "-" for none
        token...: the dep string's whitespace-separated tokens
      -> comma-joined flattened tokens (possibly empty), or "ERROR"
    use_reduce_harness.py validate <eapi> <validflags> <token...>
        eapi: EAPI text, or "None" for eapi=None
        validflags: comma-separated valid IUSE flags, or "-" for none
        token...: the dep string's whitespace-separated tokens
      -> "OK", or "ERR:<category>:<message>" with the
         `_metadata_exception` selection above
    use_reduce_harness.py batch
      -> reads "reduce ..." / "validate ..." lines from stdin, one
         result per line
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pinned_portage import use_pinned_portage

use_pinned_portage()

from portage.dep import Atom, use_reduce
from portage.exception import InvalidDependString


def _format_reduce(mode, uselist_arg, tokens):
    uselist = frozenset() if uselist_arg == "-" else frozenset(uselist_arg.split(","))
    depstr = " ".join(tokens)
    if mode == "normal":
        kwargs = {"uselist": uselist}
    elif mode == "matchall":
        kwargs = {"matchall": True}
    elif mode == "matchnone":
        kwargs = {"matchnone": True}
    else:
        raise ValueError(f"unknown mode {mode!r}")
    try:
        result = use_reduce(depstr, flat=True, **kwargs)
    except InvalidDependString:
        return "ERROR"
    return ",".join(result)


def _format_validate(eapi_arg, validflags_arg, tokens):
    eapi = None if eapi_arg == "None" else eapi_arg
    valid = (
        frozenset() if validflags_arg == "-" else frozenset(validflags_arg.split(","))
    )
    depstr = " ".join(tokens)
    try:
        use_reduce(
            depstr,
            eapi=eapi,
            matchall=True,
            is_valid_flag=valid.__contains__,
            token_class=Atom,
            flat=True,
        )
    except InvalidDependString as e:
        for err in e.errors or ():
            if getattr(err, "category", None) is not None:
                return f"ERR:{err.category}:{err}"
        return f"ERR:dependency.syntax:{e}"
    return "OK"


def _dispatch(op, args):
    if op == "reduce":
        if len(args) < 2:
            raise ValueError("reduce expects at least 2 args (mode, uselist)")
        return _format_reduce(args[0], args[1], args[2:])
    if op == "validate":
        if len(args) < 2:
            raise ValueError("validate expects at least 2 args (eapi, validflags)")
        return _format_validate(args[0], args[1], args[2:])
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
            "usage: use_reduce_harness.py <reduce mode uselist token... | batch>",
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
