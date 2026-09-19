#!/usr/bin/env python3
"""Self-test for the `fs:` and `backend:` allowlist qualifiers.

Exercises explained() in resolve-compare.py (L0) and diff.py (L1+):
unqualified entries match every run; fs-qualified entries only runs on
those filesystems; backend-qualified entries only runs on that backend
(VM-only guest-state findings never explain container runs). A run
without the flag matches nothing qualified.

Run: python3 differential-test-bed/compare/test-allowlist-fs.py
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    mod = importlib.util.module_from_spec(spec)
    # Registered before exec: module-level @dataclass needs
    # sys.modules[name] to exist (same trap as dataclasses docs).
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


l0_explained = load("compare_resolve", "resolve-compare.py").explained
ln_explained = load("compare_diff", "diff.py").explained


ALLOW = [
    {"id": "plain", "categories": ["order"], "match": "diverges"},
    {"id": "x-only", "categories": ["order"], "match": "diverges", "fs": "xfs"},
    {"id": "eb-pair", "categories": ["order"], "match": "diverges",
     "fs": ["ext4", "btrfs"]},
]

FINDING = {"category": "order", "detail": "merge order diverges at #8"}


def check(name, got, want):
    status = "ok" if got == want else "FAIL"
    print(f"  [{status}] {name}: got {got!r}, want {want!r}")
    return got == want


def main() -> int:
    ok = True
    print("resolve-compare.explained:")
    ok &= check("unqualified matches everywhere",
                l0_explained(FINDING, "s", "atom", ALLOW)["id"], "plain")
    ok &= check("xfs entry on xfs run",
                l0_explained(FINDING, "s", "atom", ALLOW, "xfs")["id"], "plain")
    # "plain" has no fs qualifier but matches first; force the
    # qualified path with an allowlist of only qualified entries.
    qual = ALLOW[1:]
    ok &= check("qualified skipped without --fs",
                l0_explained(FINDING, "s", "atom", qual), None)
    ok &= check("qualified skipped on other fs",
                l0_explained(FINDING, "s", "atom", qual, "ext4")["id"], "eb-pair")
    ok &= check("single-string fs form",
                l0_explained(FINDING, "s", "atom", ALLOW[1:2], "xfs")["id"], "x-only")

    print("diff.explained:")
    f = {"category": "CONTENT", "path": "/usr/bin/x", "detail": "diverges"}
    allow_ln = [
        {**e, "categories": ["CONTENT"]} for e in ALLOW
    ]
    qual_ln = [
        {**e, "categories": ["CONTENT"]} for e in qual
    ]
    ok &= check("unqualified matches everywhere",
                ln_explained(f, allow_ln, "l1"), "plain")
    ok &= check("qualified skipped without --fs",
                ln_explained(f, qual_ln, "l1"), None)
    ok &= check("qualified matched on listed fs",
                ln_explained(f, qual_ln, "l1", "btrfs"), "eb-pair")

    print("backend qualifier:")
    back = [{"id": "vm-only", "categories": ["order"],
             "match": "diverges", "backend": "vm"}]
    ok &= check("l0: backend entry skipped without --backend",
                l0_explained(FINDING, "s", "atom", back), None)
    ok &= check("l0: backend entry skipped on other backend",
                l0_explained(FINDING, "s", "atom", back, None, "container"), None)
    ok &= check("l0: backend entry matched on vm",
                l0_explained(FINDING, "s", "atom", back, None, "vm")["id"], "vm-only")
    ok &= check("diff: backend entry skipped without --backend",
                ln_explained(
                    {"category": "CONTENT", "path": "p", "detail": "diverges"},
                    [{**back[0], "categories": ["CONTENT"]}], "l1"), None)
    ok &= check("diff: backend entry matched on vm",
                ln_explained(
                    {"category": "CONTENT", "path": "p", "detail": "diverges"},
                    [{**back[0], "categories": ["CONTENT"]}], "l1", None, "vm"),
                "vm-only")
    print("ALL OK" if ok else "FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
