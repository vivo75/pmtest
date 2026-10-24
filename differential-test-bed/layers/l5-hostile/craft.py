#!/usr/bin/env python3
"""Craft hostile gpkg archives for the L5 hostile-fault bed cell.

A self-contained port of the pmtest contract helper `_hostile_gpkg`
(`pytests-contract-suite/test_portuale.py`) plus the shape tables: the 23
`LLM/evidence/2026-10-23-500-501/` S1 shapes and the four #514 shapes.
Only stdlib `tarfile` is used; both inner tars are zstd-compressed
(`image.tar.zst`, `metadata.tar.zst`) like `build-hostile.py` writes them:
Portage 3.0.83 falls back to the package default compression for an
extensionless member (`gpkg._get_decompression_cmd`), so a plain
`image.tar` fails the control with a zstd error. The Manifest is
recomputed (BLAKE2B + SHA512).

Usage: craft.py BASE OUTDIR   -> OUTDIR/<shape>/dev-libs/packagepkg-1.0.gpkg.tar
Shapes with no metadata override keep the base metadata verbatim.
Requires the `zstd` CLI (present in the bed image; fails loud otherwise).
"""
import hashlib
import io
import sys
import tarfile

D, S, L, F = tarfile.DIRTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.REGTYPE


def pack(members):
    buf = io.BytesIO()
    with tarfile.open(mode="w", fileobj=buf, format=tarfile.GNU_FORMAT) as tf:
        for name, typ, link, data in members:
            ti = tarfile.TarInfo(name)
            ti.type, ti.linkname, ti.mtime = typ, link, 1700000000
            ti.mode = 0o755 if typ == D else 0o644
            if typ == tarfile.CHRTYPE:
                ti.devmajor, ti.devminor = 1, 3
            ti.size = len(data) if typ == F else 0
            tf.addfile(ti, io.BytesIO(data) if typ == F else None)
    return buf.getvalue()


def mrep(kind):
    def f(n):
        if kind == "symlink":
            return (n, S, "SLOT", b"")
        if kind == "hardlink":
            return (n, L, "metadata/SLOT", b"")
        if kind == "chardev":
            return (n, tarfile.CHRTYPE, "", b"")
        if kind == "dir":
            return (n, D, "", b"")
        if kind == "symlink-abs":
            return (n, S, "/etc/hostname", b"")
        raise AssertionError(kind)

    return f


# shape -> (extra image members, metadata override or None)
# metadata override: ("rep", kind) replaces metadata/EAPI, ("extra", member)
# appends one member.
SHAPES = {
    "control-benign": ([], None),
    "control-contained-symlink-parent": (
        [
            ("image/opt/real", D, "", b""),
            ("image/opt/bin", S, "real", b""),
            ("image/opt/bin/tool", F, "", b"t\n"),
        ],
        None,
    ),
    "img-abs-path": ([("/etc/evil", F, "", b"x")], None),
    "img-device": ([("image/hda", tarfile.BLKTYPE, "", b"")], None),
    "img-dir-through-symlink": (
        [
            ("image/link", S, "/var/tmp/outside-x", b""),
            ("image/./link", D, "", b""),
        ],
        None,
    ),
    "img-dotdot-bare": ([("..", D, "", b"")], None),
    "img-dotdot-dotslash": ([("./../evil", F, "", b"x")], None),
    "img-dotdot-leading": ([("image/../outside", F, "", b"x")], None),
    "img-dotdot-sub": ([("image/opt/..", D, "", b"")], None),
    "img-duplicate": (
        [("image/usr/share/packagepkg/hello.txt", F, "", b"d")],
        None,
    ),
    "img-hardlink-outside-archive": (
        [("image/shadow", L, "/etc/shadow", b"")],
        None,
    ),
    "img-hardlink-relocated-rel": (
        [
            ("marker", F, "", b"staging"),
            ("image/deep/link", S, "../../marker", b""),
            ("image/hard", L, "image/deep/link", b""),
        ],
        None,
    ),
    "img-hardlink-to-escaping-symlink-abs": (
        [
            ("image/link", S, "/var/tmp/outside-x", b""),
            ("image/hardlink", L, "image/link", b""),
        ],
        None,
    ),
    "img-symlink-parent-abs": (
        [
            ("image/link", S, "/nonexistent-outside", b""),
            ("image/link/marker", F, "", b"x"),
        ],
        None,
    ),
    "img-symlink-parent-rel": (
        [
            ("image/link", S, "../../../outside", b""),
            ("image/link/marker", F, "", b"x"),
        ],
        None,
    ),
    "img-symlink-root": (
        [("image/x", S, "/", b""), ("image/x/etc/evil", F, "", b"x")],
        None,
    ),
    "meta-chardev": ([], ("rep", "chardev")),
    "meta-dir": ([], ("rep", "dir")),
    "meta-extra-dir": ([], ("extra", ("metadata/subdir", D, "", b""))),
    "meta-extra-symlink": ([], ("extra", ("metadata/EXTRA", S, "SLOT", b""))),
    "meta-hardlink": ([], ("rep", "hardlink")),
    "meta-symlink": ([], ("rep", "symlink")),
    "meta-symlink-abs": ([], ("rep", "symlink-abs")),
    # #514: temp-root accept side (symlink to the temp root, bare and with
    # a member under it) and the hard-link-of-symlink truncation shape.
    "temp-root-bare": ([("image/opt/link", S, "../..", b"")], None),
    "temp-root-member": (
        [
            ("image/opt/link", S, "../..", b""),
            ("image/opt/link/tool", F, "", b"t\n"),
        ],
        None,
    ),
    "dotdot-hardlink": (
        [
            ("image/opt/marker", D, "", b""),
            ("image/opt/marker/f", F, "", b"m\n"),
            ("image/opt/deep", D, "", b""),
            ("image/opt/deep/link", S, "../marker", b""),
            ("image/opt/deep/hard", L, "image/opt/deep/link", b""),
            ("image/opt/deep/hard/x", F, "", b"x\n"),
        ],
        None,
    ),
    "relocated-in-place": (
        [
            ("image/opt/deep/link", S, "../x", b""),
            ("image/opt/hard2", L, "image/opt/deep/link", b""),
        ],
        None,
    ),
}

IMAGE_BASE = [
    ("image", D, "", b""),
    ("image/usr", D, "", b""),
    ("image/usr/share", D, "", b""),
    ("image/usr/share/packagepkg", D, "", b""),
    ("image/usr/share/packagepkg/hello.txt", F, "", b"hello\n"),
]


def zst(data):
    import shutil
    import subprocess

    if shutil.which("zstd") is None:
        raise SystemExit("craft.py needs the zstd CLI")
    return subprocess.run(["zstd", "-q", "-c"], input=data, capture_output=True, check=True).stdout


def build(base, dest, extra_image, meta_override):
    import os
    import subprocess

    meta_name, image_name = "metadata.tar.zst", "image.tar.zst"

    parts = {}
    with tarfile.open(base) as outer:
        for m in outer.getmembers():
            b, _, name = m.name.partition("/")
            if name and name != "Manifest" and not name.endswith(".sig"):
                parts[name] = outer.extractfile(m).read()
    prefix = None
    # recover the <pf> prefix from the outer names
    with tarfile.open(base) as outer:
        prefix = outer.getnames()[0].split("/")[0]
    if meta_override is not None:
        old = next(n for n in parts if n.startswith("metadata.tar"))
        data = parts.pop(old)
        if old.endswith(".zst"):
            data = subprocess.run(
                ["zstd", "-dc"], input=data, capture_output=True, check=True
            ).stdout
        keep = []
        with tarfile.open(fileobj=io.BytesIO(data)) as inner:
            for m in inner.getmembers():
                if m.isreg():
                    keep.append(
                        (m.name, F, "", inner.extractfile(m).read())
                    )
        kind, arg = meta_override
        if kind == "rep":
            keep = [k for k in keep if k[0] != "metadata/EAPI"]
            keep.append(mrep(arg)("metadata/EAPI"))
        else:
            keep.append(arg)
        parts[meta_name] = zst(pack(keep))
    for n in [n for n in list(parts) if n.startswith("image.tar")]:
        del parts[n]
    parts[image_name] = zst(pack(IMAGE_BASE + extra_image))
    manifest = "".join(
        "DATA {n} {size} BLAKE2B {b2} SHA512 {s5}\n".format(
            n=n,
            size=len(d),
            b2=hashlib.blake2b(d).hexdigest(),
            s5=hashlib.sha512(d).hexdigest(),
        )
        for n, d in parts.items()
        if n != "gpkg-1"
    ) + "DATA gpkg-1 0 BLAKE2B {b} SHA512 {s}\n".format(
        b=hashlib.blake2b(b"").hexdigest(), s=hashlib.sha512(b"").hexdigest()
    )
    import os as _os

    _os.makedirs(_os.path.dirname(dest), exist_ok=True)
    with tarfile.open(dest, "w", format=tarfile.USTAR_FORMAT) as out:
        for n, d in [*parts.items(), ("Manifest", manifest.encode())]:
            ti = tarfile.TarInfo(f"{prefix}/{n}")
            ti.size, ti.mode, ti.mtime = len(d), 0o644, 1700000000
            out.addfile(ti, io.BytesIO(d))


if __name__ == "__main__":
    import os

    base, outdir = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or sorted(SHAPES)
    for name in names:
        extra, override = SHAPES[name]
        dest = os.path.join(outdir, name, "dev-libs/packagepkg-1.0.gpkg.tar")
        build(base, dest, extra, override)
        print(dest)
