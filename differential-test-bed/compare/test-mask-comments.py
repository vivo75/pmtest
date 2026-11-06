#!/usr/bin/env python3
"""Self-test for backlog #664: a `package.mask` comment that quotes the
`"All ebuilds ... have been masked" block` is not a masked-package block.

Run: python3 differential-test-bed/compare/test-mask-comments.py   (exit 0 = all good)
"""

import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare_resolve", HERE / "resolve-compare.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["compare_resolve"] = mod
spec.loader.exec_module(mod)


def advice(text: str) -> set:
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "o.txt"
        p.write_text(text)
        return mod.parse(p)[3]


def main() -> int:
    comment = (
        "- dev-libs/x-1.0::testrepo (masked by: package.mask)\n"
        "/t/profiles/package.mask:\n"
        '# "All ebuilds ... have been masked" block (never unmasked anywhere).\n'
    )
    ok = True
    a = advice(comment)
    if a:
        print("FAIL comment line produced advice:", a)
        ok = False
    real = '!!! All ebuilds that could satisfy "dev-libs/x" have been masked.\n'
    a = advice(real)
    if "masked-atom: dev-libs/x" not in a or not any(x.startswith("masked: ") for x in a):
        print("FAIL real block lost:", a)
        ok = False
    print("ALL OK" if ok else "FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
