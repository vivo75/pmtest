#!/usr/bin/env python3
"""Materialise a doins oracle input tree (plan #326 S6).

    materialise.py <manifest> <dest-dir> <src-dir> <dist-dir>

The manifest is the checked-in source of truth for an input tree, because
symlink targets, hardlinks, non-UTF-8 names and file contents do not
survive plain directory checkouts well. Format (pure ASCII, one entry per
line, sorted by the encoded path, like the chmod-lite in.manifest):

    d <mode4> <qpath>
    f <mode4> <qpath> [|<qcontent>]
    l ---- <qpath> -> <qtarget>
    h <mode4> <qpath> => <qearlier-path>

qpath is relative to <dest-dir> (no absolute paths, no `.` or `..`
components); every byte outside [A-Za-z0-9._/+-] is %XX-escaped (uppercase
hex), so non-UTF-8 names stay git-safe. <qcontent> is the file's bytes in
the same escaping (absent means an empty file). <qtarget> is raw readlink
bytes in the same escaping (for `l`), or the earlier entry's path (for
`h`). The placeholders `@SRC@` and `@DISTDIR@` in a link target are
substituted with <src-dir> / <dist-dir> (bytes), so absolute-symlink
fixtures stay reproducible across runs and hosts.

Effects: entries are created in manifest order (parents first, so every
parent must be an explicit `d` entry); then, as a final deepest-first
pass, modes are applied (never for symlinks; hardlinks share their
target's inode and are skipped) and every entry's mtime is pinned to
MTIME, so the `-p` (preserve-timestamps) cases are reproducible. Ownership
is never set: every entry stays owned by the invoker.
"""
import os
import re
import sys

MTIME = 1700000000


def unesc(s: str) -> bytes:
    return re.sub(rb"%([0-9A-F]{2})", lambda m: bytes([int(m.group(1), 16)]),
                  s.encode("ascii"))


def main() -> int:
    manifest, dest, src, dist = (
        sys.argv[1], os.fsencode(sys.argv[2]),
        os.fsencode(sys.argv[3]), os.fsencode(sys.argv[4]))
    os.makedirs(dest, exist_ok=True)
    entries = []
    prev = None
    for ln, line in enumerate(open(manifest, encoding="ascii"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        t = line.split(" ")
        if len(t) < 3:
            sys.exit(f"{manifest}:{ln}: too few fields")
        typ, mode_s, qpath = t[0], t[1], t[2]
        extra = t[3:]
        if typ in ("d", "f"):
            if len(mode_s) != 4 or any(c not in "01234567" for c in mode_s):
                sys.exit(f"{manifest}:{ln}: mode must be 4 octal digits")
            mode, target, content = int(mode_s, 8), None, None
            if extra and extra[0].startswith("|"):
                if typ != "f":
                    sys.exit(f"{manifest}:{ln}: only f takes |content")
                content = unesc(" ".join(extra)[1:])
            elif extra:
                sys.exit(f"{manifest}:{ln}: unexpected fields")
        elif typ == "l":
            if mode_s != "----" or len(extra) < 2 or extra[0] != "->":
                sys.exit(f"{manifest}:{ln}: symlink needs '----' and '-> target'")
            mode, target = None, unesc(extra[1])
            if len(extra) > 2:
                sys.exit(f"{manifest}:{ln}: target must not contain spaces")
            content = None
        elif typ == "h":
            if len(mode_s) != 4 or len(extra) != 2 or extra[0] != "=>":
                sys.exit(f"{manifest}:{ln}: hardlink needs '<mode4>' and '=> path'")
            mode, target, content = int(mode_s, 8), unesc(extra[1]), None
        else:
            sys.exit(f"{manifest}:{ln}: bad type {typ!r}")
        path = unesc(qpath)
        if prev is not None and not prev < qpath:
            sys.exit(f"{manifest}:{ln}: lines must be sorted by encoded path")
        prev = qpath
        comps = path.split(b"/")
        if path.startswith(b"/") or any(c in (b"", b".", b"..") for c in comps):
            sys.exit(f"{manifest}:{ln}: path must be relative without . or ..")
        if target is not None:
            target = target.replace(b"@SRC@", src).replace(b"@DISTDIR@", dist)
        full = os.path.join(dest, path)
        entries.append((typ, mode, path, target, content, full))
    made = {dest}
    for typ, mode, path, target, content, full in entries:
        parent = os.path.dirname(full)
        if parent not in made:
            sys.exit(f"{manifest}: parent of {path!r} is not an explicit d entry")
        if typ == "d":
            os.mkdir(full)
            made.add(full)
        elif typ == "f":
            with open(full, "wb") as f:
                f.write(content or b"")
        elif typ == "l":
            os.symlink(target, full)
        elif typ == "h":
            # hardlink target: an in-tree relative path (to an earlier
            # entry, so they share the inode) or an absolute path.
            other = target if target.startswith(b"/") else os.path.join(dest, target)
            os.link(other, full)
    for typ, mode, path, target, content, full in sorted(
            entries, key=lambda e: e[2].count(b"/"), reverse=True):
        if typ == "l":
            pass
        elif typ == "h":
            continue
        else:
            os.chmod(full, mode)
        os.utime(full, (MTIME, MTIME), follow_symlinks=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
