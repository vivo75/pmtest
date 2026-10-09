#!/usr/bin/env python3
"""Materialise an image.manifest into a real directory tree (plan #326 S4).

    materialise.py <image.manifest> <dest-dir>

The manifest is the checked-in source of truth for an image tree, because
owners, setuid bits, hardlinks and >100-byte paths do not survive git.
Format (see ../README.md): one entry per line, blank lines and `#` comments
ignored; fields separated by single spaces:

    <type> <mode4> <uid> <gid> <path> [-> <target> | => <hardlink-to>] [|<content>]

type   d dir, f regular file, l symlink, h hardlink (to an earlier path)
path   relative to <dest-dir>; `.` is <dest-dir> itself.  Every byte outside
       [A-Za-z0-9._/+-] is %XX-escaped (uppercase hex), so names that are not
       UTF-8 stay git-safe.
target raw readlink bytes, same escaping (for `l`); the earlier entry's path
       (for `h`).
|content  file contents, same escaping (`f` only; absent = empty file).

Effects: entries are created in manifest order (parents first); then, as a
final deepest-first pass, ownership (only when running as root: lchown to the
uid/gid in the manifest -- as a normal user every entry stays owned by the
invoker), mode (not for symlinks; chmod AFTER chown because chown clears the
setuid bit) and a fixed mtime (so the image tar differs between runs in
nothing a field dump looks at) are applied.  Hardlinks share the inode of
their target, so they are skipped in the final pass.
"""
import os
import re
import sys

MTIME = 1700000000


def unesc(s: str) -> bytes:
    return re.sub(rb"%([0-9A-F]{2})", lambda m: bytes([int(m.group(1), 16)]),
                  s.encode("ascii"))


def main() -> int:
    manifest, dest = sys.argv[1], os.fsencode(sys.argv[2])
    os.makedirs(dest, exist_ok=True)
    is_root = os.geteuid() == 0
    entries = []
    for ln, line in enumerate(open(manifest, encoding="ascii"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        t = line.split(" ")
        if len(t) < 5:
            sys.exit(f"{manifest}:{ln}: too few fields")
        typ, mode, uid, gid, rel = t[0], (0 if t[1] == "----" else int(t[1], 8)), int(t[2]), int(t[3]), unesc(t[4])
        extra = t[5:]
        target = content = None
        if extra and extra[0] in ("->", "=>"):
            target = unesc(extra[1])
            extra = extra[2:]
        if extra and extra[0].startswith("|"):
            content = unesc(" ".join(extra)[1:])
        path = dest if rel == b"." else os.path.join(dest, rel)
        if typ == "d":
            os.makedirs(path, exist_ok=True)
        elif typ == "f":
            with open(path, "wb") as f:
                f.write(content or b"")
        elif typ == "l":
            os.symlink(target, path)
        elif typ == "h":
            os.link(os.path.join(dest, target), path)
        else:
            sys.exit(f"{manifest}:{ln}: bad type {typ!r}")
        entries.append((typ, mode, uid, gid, path))
    for typ, mode, uid, gid, path in sorted(entries, key=lambda e: e[4].count(b"/"),
                                            reverse=True):
        if typ == "h":
            continue
        if is_root:
            os.lchown(path, uid, gid)
        if typ != "l":
            os.chmod(path, mode)
        os.utime(path, (MTIME, MTIME), follow_symlinks=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
