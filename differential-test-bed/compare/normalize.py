#!/usr/bin/env python3
"""Normalise a snapshot.sh manifest + VDB tar in place for diff.py.

    normalize.py <out-prefix>

Reads  <prefix>.files.tsv  and  <prefix>.vdb.tar
Writes <prefix>.files.norm.tsv  and  <prefix>.vdb/  (unpacked + normalised)

Applies the ruleset in differential-test-bed/compare/normalize.md -- the code is the
authority, keep the prose in sync. stdlib only.
"""
from __future__ import annotations

import bz2
import posixpath
import re
import sys
import tarfile
from pathlib import Path

# --- filesystem: regenerated caches -> compare presence, not bytes ------
# a path whose sha256 is blanked to "-" before the diff (still a MISSING
# finding if it is absent on one side, but never a CONTENT finding).
PRESENCE_ONLY = [
    re.compile(r"^/etc/ld\.so\.cache$"),
    re.compile(r"\.py[co]$"),
    re.compile(r"/__pycache__/"),
    re.compile(r"^/usr/share/info/dir$"),
    re.compile(r"^/usr/share/mime/"),
    re.compile(r"/(icon-theme\.cache|gtk-update-icon-cache)"),
    re.compile(r"^/usr/lib\d*/gio/modules/giomodule\.cache$"),
    re.compile(r"/fonts\.(dir|scale)$"),
    re.compile(r"^/etc/ssl/certs/"),          # ca-certificates hash symlinks + bundle
    re.compile(r"^/var/lib/portage/config$"), # CONFIG_PROTECT hash db (key set only)
    re.compile(r"^/var/cache/"),
    re.compile(r"/\.keep(_[^/]*)?$"),
    re.compile(r"^/etc/\.(pwd\.lock|updated)$"),
    re.compile(r"^/usr/share/applications/mimeinfo\.cache$"),
    re.compile(r"^/etc/environment\.d/"),
]

# volatile env-file lines (env_update output) -- these files legitimately
# differ in ordering / a timestamp; blank the whole sha and let the
# presence check carry them.
ENV_FILES = {"/etc/profile.env", "/etc/csh.env", "/etc/environment"}

# --- filesystem: staging-hygiene drops (L3 full-tree only) -------------
# Paths that are part of the test harness / the container's identity, not
# of the merged rootfs, and so can never be portuale-vs-portage signal.
# `snapshot.sh` prunes them for fresh L3 walks; the normaliser mirrors
# the same rule so a saved pair re-normalises to the pruned equivalent.
# `/usr/local/bin` is the mounted PM binary + its cargo target dir
# (`deps/`, `.fingerprint/`, `*.rlib`, `*.d` …) -- identical on both
# sides by construction (same mount). `/etc/hosts`, `/etc/machine-id`
# and `/root/.bash_history` are per-container identity / shell scratch.
DROP = [
    re.compile(r"^/usr/local/bin/"),
    re.compile(r"^/etc/hosts$"),
    re.compile(r"^/etc/machine-id$"),
    re.compile(r"^/root/\.bash_history$"),
]


def _pruned(path: str) -> bool:
    return any(rx.match(path) for rx in DROP)


def _twin_families(prefix: Path) -> dict[str, str]:
    """Map every basename that is one of a set of byte-identical *real*
    files (a twin family) to its canonical member name.

    Family = ≥2 type-`f` rows with the same (dirname, size, sha256) --
    the keyed-libexec / getconf install pattern that bellwether binpkgs
    record on disk as N copies of the same file under different names
    (ld/ld.bfd, gcc-ar/x86_64-…-gcc-ar, the getconf managers, the
    porttest setuid triple).  The names a family ships are identical on
    the real and portuale sides, so the canonical (lexicographic minimum)
    is the same string on both sides without any cross-side coupling.
    Returns basename -> canonical (each member maps to the canonical;
    non-members are absent).  Non-`f` rows and presence-blanked rows
    (sha `-`) never join a family.
    """
    src = prefix.with_suffix(".files.tsv")
    if not src.exists():
        return {}
    fam: dict[tuple, set[str]] = {}
    for line in src.read_text().splitlines():
        p = line.split("\t")
        if len(p) != 9:
            continue
        path, typ, _, _, _, size, sha, _, _ = p
        if typ != "f" or sha == "-":
            continue
        if path.startswith("/usr/lib/debug/"):
            continue
        d, b = posixpath.split(path)
        fam.setdefault((d, size, sha), set()).add(b)
    twins: dict[str, str] = {}
    for members in fam.values():
        if len(members) < 2:
            continue
        canon = sorted(members)[0]
        for member in members:
            # a name shared by two families keeps the smaller canonical
            if member not in twins or canon < twins[member]:
                twins[member] = canon
    return twins


def _canon_debug_leaf(path: str, twins: dict[str, str]) -> str:
    """Canonicalise the stem of a `/usr/lib/debug/usr/…/foo.debug` leaf.

    Only used for split-debug trees, and only when the stem names a real
    twin member (so e.g. sln.debug or any non-twin debug file is left
    untouched).  Real-file rows are never renamed -- this is called only
    on paths under `/usr/lib/debug/`.
    """
    d, b = posixpath.split(path)
    stem = b[:-6] if b.endswith(".debug") else b
    canon = twins.get(stem)
    if canon is None or canon == stem:
        return path
    return d + "/" + canon + (".debug" if b.endswith(".debug") else "")


def _canon_buildid_link(path: str, link: str, twins: dict[str, str]) -> tuple[str, str]:
    """Rewire a `/usr/lib/debug/.build-id/<xx>/<hash>[.debug]` symlink to
    `@buildid:<canonical-resolved-target>`.

    * the link target is relative to the link's dirname; resolve it to an
      absolute path (`../../usr/...` from `<xx>` lands in
      `/usr/lib/debug/usr/...`, the 5-up form lands in `/usr/...`);
    * canonicalise the resolved target's basename through the twin map
      (an `ld` link and an `ld.bfd` link pointing at the same inode must
      key to the same path);
    * the `@buildid:` prefix keeps the key out of the real-file path
      namespace, which matters here because two different hash dirs can
      resolve to the same binary (cc1/cc1plus).

    Returns (new_path, canonical_link); the caller sets the row's size to
    len(canonical_link) so a twin's differing link length can never fire
    a SYMLINK/SIZE finding.
    """
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), link))
    d, b = posixpath.split(resolved)
    stem = b[:-6] if b.endswith(".debug") else b
    canon = twins.get(stem, stem)
    canonical = d + "/" + canon + (".debug" if b.endswith(".debug") else "")
    return "@buildid:" + canonical, canonical


def norm_files(prefix: Path, twins: dict[str, str]) -> None:
    src = prefix.with_suffix(".files.tsv")
    if not src.exists():
        (prefix.parent / (prefix.name + ".files.norm.tsv")).write_text("")
        return
    out = []
    for line in src.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) != 9:
            continue
        path, typ, mode, uid, gid, size, sha, link, xattr = parts
        if _pruned(path):
            continue
        if path in ENV_FILES or any(rx.search(path) for rx in PRESENCE_ONLY):
            sha = "-"
            # a regenerated cache's *size* drifts too (e.g.
            # /etc/ld.so.cache between two different binpkgs);
            # presence-only means exactly that.
            size = "-"
        # a directory's st_size is filesystem-internal (hash-tree/block
        # allocation) -- not meaningful, and it drifts even between two
        # dirs with an identical entry set.
        if typ == "d":
            size = "-"
        # R3 build-id / split-debug canonicalisation (see `_canon_buildid_link`
        # and `_canon_debug_leaf`).  Order matters: a `.build-id` link is `l`,
        # a split-debug leaf is `f`, so the two branches never collide.
        if typ == "l" and path.startswith("/usr/lib/debug/.build-id/"):
            path, link = _canon_buildid_link(path, link, twins)
            sha = "-"
            size = str(len(link))
        elif typ == "f" and path.startswith("/usr/lib/debug/usr/") and path.endswith(".debug"):
            path = _canon_debug_leaf(path, twins)
        out.append("\t".join([path, typ, mode, uid, gid, size, sha, link, xattr]))
    out.sort()
    (prefix.parent / (prefix.name + ".files.norm.tsv")).write_text("\n".join(out) + "\n")


# --- VDB --------------------------------------------------------------
# BINPKGMD5 records the *archive* a package was merged from; L1 merges
# the same archives on both sides (equal by construction), but L2/L3
# cross-install compares different builds of the same package, where the
# archive md5 is expected to differ (like BUILD_ID). The merged payload
# comparison is what matters, not the source archive's digest.
BLANK_FILES = {"BUILD_TIME", "BUILD_ID", "COUNTER", "INSTALL_TIME", "BINPKGMD5"}
SORT_FILES = {"NEEDED", "NEEDED.ELF.2", "REQUIRES", "PROVIDES"}
# the consolidated `metadata` file (`#format=1` then KEY=value): blank
# the same volatile keys inline.
META_BLANK = re.compile(r"^(BUILD_TIME|BUILD_ID|COUNTER|INSTALL_TIME)=.*$", re.M)


def norm_metadata(text: str) -> str:
    text = META_BLANK.sub(lambda m: m.group(1) + "=<normalised>", text)
    # the md5-cache-style `#dir_mtime=<nanoseconds>` header is the vdb
    # dir's own mtime at write time -- pure noise.
    text = re.sub(r"^#dir_mtime=.*$", "#dir_mtime=<x>", text, flags=re.M)
    return "\n".join(sorted(text.splitlines())) + "\n"

# saved-env lines to drop outright (`declare -x KEY=…` or bare `KEY=…`):
# volatile bash internals, plus the locale vars (LANG/LC_*): the two
# consumer containers are invoked with different locale env (`consume.sh`
# exports `LC_ALL`; the portage side ends up with a bare `LANG`), and the
# regenerated binpkg env keeps whatever the phase inherited -- a
# test-harness difference, not a portuale bug.
# FEATURES / PORTAGE_FEATURES are NOT dropped -- L1-c's PORTAGE_UPDATE_ENV
# regeneration makes them match real. Nor are EMERGE_DEFAULT_OPTS /
# PORTAGE_RUNNING_ROOT / O -- L1-f's phase-env whitelist keeps them out.
ENV_DROP = re.compile(
    r"^(declare (-[-x]+ )?)?"
    r"(SRANDOM|EPOCHREALTIME|EPOCHSECONDS|SECONDS|BASHPID|PPID|BUILD_TIME|BUILD_ID|"
    r"HOSTNAME|SANDBOX_PID|PORTAGE_PID|PORTAGE_IPC_KEY|"
    r"COLUMNS|LINES|RANDOM|"
    r"LANG|LC_[A-Z]+)="
)
ENV_MASK = re.compile(
    r"^((?:declare (?:-[-x]+ )?)?(T|WORKDIR|PORTAGE_BUILDDIR|HOME|PWD|OLDPWD|"
    r"PORTAGE_LOG_FILE|EMERGE_FROM|MERGE_TYPE))=.*$"
)
BUILDDIR = re.compile(r"/var/tmp/portage/[^ \t\"']+")


def norm_environment(raw: bytes) -> str:
    try:
        text = bz2.decompress(raw).decode("utf-8", "replace")
    except OSError:
        text = raw.decode("utf-8", "replace")
    kept = []
    for ln in text.splitlines():
        if ENV_DROP.match(ln):
            continue
        ln = BUILDDIR.sub("<builddir>", ln)
        ln = ENV_MASK.sub(r"\1=<x>", ln)
        kept.append(ln)
    kept.sort()
    return "\n".join(kept) + "\n"


def norm_contents(text: str, twins: dict[str, str]) -> str:
    out = []
    for ln in text.splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] == "obj" and len(f) >= 4:
            # obj <path> <md5> <mtime>  -- blank mtime, keep md5.
            # A split-debug obj entry names the .debug leaf; twin members
            # collide once canonicalised (the twin .debug files' md5s match
            # across sides, so the two renamed entries become identical).
            if f[1].startswith("/usr/lib/debug/usr/") and f[1].endswith(".debug"):
                f[1] = _canon_debug_leaf(f[1], twins)
            out.append(f"obj {' '.join(f[1:-1])} <mtime>")
        elif f[0] == "sym" and len(f) >= 4:
            # sym <path> -> <target> <mtime>  -- blank mtime, keep target.
            # A `.build-id/<xx>/<hash>[.debug]` sym entry keys by the
            # canonical resolved target (`@buildid:` prefix) and rewrites
            # the arrow target to that same absolute path, so a twin pair
            # (ld vs ld.bfd) and a cross-side hash-dir pair (cc1/cc1plus)
            # both become identical on the two sides.
            if f[1].startswith("/usr/lib/debug/.build-id/"):
                f[1], f[3] = _canon_buildid_link(f[1], f[3], twins)
            out.append(f"sym {' '.join(f[1:-1])} <mtime>")
        elif f[0] == "dir" and len(f) >= 2 and f[1].startswith("/usr/lib/debug/.build-id/"):
            # dir /usr/lib/debug/.build-id/<xx>  -- the per-architecture
            # hash subdir the split-debug manager creates for a binary
            # (cc1 appears under `5d` for the real side, `5a` for
            # portuale).  Drop the hash, keep parent presence: the parent
            # `dir /usr/lib/debug/.build-id` row already exists, so the
            # collapse only ever dedupes to a line both sides emit.
            out.append("dir /usr/lib/debug/.build-id")
        else:
            out.append(ln.rstrip())
    out.sort()
    return "\n".join(out) + "\n"


def norm_vdb(prefix: Path, twins: dict[str, str]) -> None:
    tar = prefix.with_suffix(".vdb.tar")
    dest = prefix.parent / (prefix.name + ".vdb")
    if dest.exists():
        import shutil

        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    if not tar.exists():
        return
    with tarfile.open(tar) as tf:
        tf.extractall(dest, filter="data")
    pkgroot = dest / "pkg"
    if not pkgroot.is_dir():
        return
    for entry in sorted(pkgroot.glob("*/*")):
        if not entry.is_dir():
            continue
        for f in sorted(entry.iterdir()):
            if not f.is_file():
                continue
            name = f.name
            if name in BLANK_FILES:
                f.write_text("<normalised>\n")
            elif name in SORT_FILES:
                f.write_text("\n".join(sorted(f.read_text().splitlines())) + "\n")
            elif name == "environment.bz2":
                (entry / "environment").write_text(norm_environment(f.read_bytes()))
                f.unlink()
            elif name == "environment":
                f.write_text(norm_environment(f.read_bytes()))
            elif name == "CONTENTS":
                f.write_text(norm_contents(f.read_text(), twins))
            elif name == "metadata":
                f.write_text(norm_metadata(f.read_text()))
            elif name == "repository":
                f.write_text(f.read_text().strip() + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    prefix = Path(argv[0])
    twins = _twin_families(prefix)
    norm_files(prefix, twins)
    norm_vdb(prefix, twins)
    print(f"normalised {prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
