#!/usr/bin/env python3
"""xpak (`.xpak`) binary-package tooling for the L2 test bed.

    xpak_diff.py [--mode strict|payload-tolerant] <a.xpak> <b.xpak>
    xpak_diff.py --structure [--packages] (--dir <PKGDIR> | <archive.xpak>...)

The xpak counterpart of `gpkg_diff.py` + `gpkg-structure.sh`. Format
(real Portage `lib/portage/xpak.py`, written by `__dyn_package` in
`bin/misc-functions.sh`):

    <tar of ${D}, compressed with BINPKG_COMPRESS>
    XPAKPACK be32(indexlen) be32(datalen) <index> <data> XPAKSTOP
    be32(len of the XPAKPACK..XPAKSTOP segment) STOP
    index entry: be32(namelen) name be32(data offset) be32(data length)

The XPAK members are the `build-info` files -- the same keys a gpkg
carries under `metadata/` -- and the payload tar is the image (members
`./...`, root entry `./`).

Diff mode applies THE SAME rules as gpkg_diff.py to the same kind of
data (it imports `compare_metadata` / `compare_image` / `collect_image`
from it; only the container parsing is new):

  outer-layout   payload compression kind differs (the xpak analogue of
                 gpkg_diff's member-kind-set check)
  metadata:<KEY> XPAK members after gpkg_diff.norm_meta (BUILD_TIME /
                 BUILD_ID / COUNTER blanked, NEEDED*/REQUIRES/PROVIDES
                 sorted, environment.bz2 through normalize.py, ...)
  image:paths / payload   exactly gpkg_diff.compare_image
  outer-name     the `<pf>-<BUILD_ID>` file stem (informational only)

Structure mode, one `[CATEGORY] <archive>: <detail>` line per finding
(categories as gpkg-structure.sh: OUTER, INNER, METADATA, MULTI, INDEX,
IO): trailer + index parse, the payload is a valid tar once decompressed
with the compressor its own bytes (and its BINPKG_COMPRESS member, when
present) name, the metadata key set (read from gpkg-structure.sh's
REQUIRED_METADATA, not copied), PF/BUILD_ID vs the file name, and with
--packages the `Packages` stanza checks of gpkg-structure.sh.

Exit: 0 no (hard) findings, 1 finding(s), 2 usage/IO (diff mode: an
archive that cannot be parsed, like gpkg_diff on a truncated archive).
"""
from __future__ import annotations

import bz2
import gzip
import hashlib
import io
import lzma
import re
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gpkg_diff  # noqa: E402  (the one ruleset: norm_meta, compare_*)


class XpakError(Exception):
    """The archive is not a well-formed xpak binary package."""


def be32(b: bytes) -> int:
    return int.from_bytes(b, "big")


class Xpak:
    def __init__(self, path: Path) -> None:
        self.path = path
        data = path.read_bytes()
        if len(data) < 8 or data[-4:] != b"STOP":
            raise XpakError("no `STOP` trailer")
        seglen = be32(data[-8:-4])
        if seglen < 24 or seglen > len(data) - 8:
            raise XpakError(f"trailer length {seglen} out of range (file is {len(data)} bytes)")
        seg = data[len(data) - 8 - seglen:len(data) - 8]
        if seg[:8] != b"XPAKPACK":
            raise XpakError("segment does not start with XPAKPACK (trailer offset wrong)")
        if seg[-8:] != b"XPAKSTOP":
            raise XpakError("segment does not end with XPAKSTOP")
        ilen, dlen = be32(seg[8:12]), be32(seg[12:16])
        if 16 + ilen + dlen + 8 != seglen:
            raise XpakError(f"index {ilen} + data {dlen} does not fill the {seglen}-byte segment")
        index, blob = seg[16:16 + ilen], seg[16 + ilen:16 + ilen + dlen]
        self.members: dict[str, bytes] = {}
        pos = 0
        while pos < len(index):
            if pos + 4 > len(index):
                raise XpakError("truncated index entry")
            nlen = be32(index[pos:pos + 4])
            if pos + 4 + nlen + 8 > len(index):
                raise XpakError("truncated index entry")
            name = index[pos + 4:pos + 4 + nlen].decode("utf-8", "replace")
            off = be32(index[pos + 4 + nlen:pos + 8 + nlen])
            ln = be32(index[pos + 8 + nlen:pos + 12 + nlen])
            pos += 12 + nlen
            if off + ln > len(blob):
                raise XpakError(f"member {name!r} runs past the data segment")
            if name in self.members:
                raise XpakError(f"duplicate member {name!r}")
            self.members[name] = blob[off:off + ln]
        self.payload = data[:len(data) - 8 - seglen]
        self.comp = sniff(self.payload)
        self.stem = path.name[:-len(".xpak")] if path.name.endswith(".xpak") else path.name

    def tar(self) -> tarfile.TarFile:
        return tarfile.open(fileobj=io.BytesIO(decompress(self.payload, self.comp)))


def sniff(b: bytes) -> str:
    if b[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    if b[:2] == b"\x1f\x8b":
        return "gzip"
    if b[:3] == b"BZh":
        return "bzip2"
    if b[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if b[:4] == b"\x04\x22\x4d\x18":
        return "lz4"
    if b[:4] == b"LZIP":
        return "lzip"
    return "none"


def decompress(b: bytes, comp: str) -> bytes:
    if comp == "none":
        return b
    if comp == "gzip":
        return gzip.decompress(b)
    if comp == "bzip2":
        return bz2.decompress(b)
    if comp == "xz":
        return lzma.decompress(b)
    tool = {"zstd": ["zstd", "-dc"], "lz4": ["lz4", "-dc"], "lzip": ["lzip", "-dc"]}[comp]
    return subprocess.run(tool, input=b, check=True, capture_output=True).stdout


# BINPKG_COMPRESS value -> the sniffed kind it must produce
COMP_NAMES = {"zstd": "zstd", "bzip2": "bzip2", "gzip": "gzip", "xz": "xz",
              "lz4": "lz4", "lzip": "lzip", "": "none", "none": "none"}


# --- diff ----------------------------------------------------------------
def diff(a: Xpak, b: Xpak, mode: str) -> None:
    if a.comp != b.comp:
        gpkg_diff.hard("outer-layout", f"payload compression differs: a={a.comp} b={b.comp}")
    if a.stem != b.stem:
        gpkg_diff.soft("outer-name", f"file stem differs: {a.stem} vs {b.stem}")
    gpkg_diff.compare_metadata(a.members, b.members, mode)
    with a.tar() as ta, b.tar() as tb:
        ia, ga = image_of(ta)
        ib, gb = image_of(tb)
    gpkg_diff.compare_image(ia, ib, mode)
    for grp in sorted(ga - gb, key=sorted):
        gpkg_diff.hard("image:paths", f"hardlink group only in a: {sorted(grp)}")
    for grp in sorted(gb - ga, key=sorted):
        gpkg_diff.hard("image:paths", f"hardlink group only in b: {sorted(grp)}")


def image_of(t: tarfile.TarFile) -> tuple[dict[str, tuple], set[frozenset[str]]]:
    """gpkg_diff.collect_image over the payload tar, with hard links
    resolved. `gtar -cf - -C ${D} .` (misc-functions.sh `__dyn_package`)
    stores an inode's data under whichever name readdir order reaches
    first and a hard-link member (kind `o` in collect_image) under the
    others, so which name is the `f` and which the `o` is a property of
    directory order, not of the image. A link member therefore takes its
    target's kind and sha256 (own mode/uid/gid kept), and the link groups
    are compared as sets -- the information a gpkg image tar carries by
    construction (python tarfile, sorted order), not a looser rule."""
    img = gpkg_diff.collect_image(t, (".", "./"), ("./",))
    links: dict[str, str] = {}
    for m in t.getmembers():
        if m.islnk():
            links[m.name.removeprefix("./")] = m.linkname.removeprefix("./")
    groups: dict[str, set[str]] = {}
    for path in links:
        root = links[path]
        while root in links:
            root = links[root]
        groups.setdefault(root, {root}).add(path)
        if root in img and path in img:
            k, _, _, _, _, sha = img[root]
            _, mode, uid, gid, _, _ = img[path]
            img[path] = (k, mode, uid, gid, "", sha)
    return img, {frozenset(g) for g in groups.values()}


def main_diff(args: list[str], mode: str) -> int:
    if len(args) != 2:
        print(__doc__)
        return 2
    for p in args:
        if not Path(p).is_file():
            print(f"xpak_diff: not a file: {p}", file=sys.stderr)
            return 2
    try:
        a, b = Xpak(Path(args[0])), Xpak(Path(args[1]))
        diff(a, b, mode)
    except (XpakError, tarfile.TarError, OSError, ValueError,
            subprocess.CalledProcessError, EOFError, lzma.LZMAError) as e:
        print(f"xpak_diff: cannot read an archive: {e}", file=sys.stderr)
        return 2
    for line in gpkg_diff.findings:
        print(line)
    print(f"xpak-diff: mode={mode} hard={gpkg_diff.HARD} soft={gpkg_diff.PAYLOAD}")
    return 1 if gpkg_diff.HARD else 0


# --- structure -------------------------------------------------------------
def required_metadata() -> list[str]:
    """REQUIRED_METADATA from gpkg-structure.sh (one list, not a copy)."""
    text = (HERE / "gpkg-structure.sh").read_text()
    m = re.search(r'^REQUIRED_METADATA="((?:[^"\\]|\\\n)*)"', text, re.M)
    if not m:
        raise SystemExit("xpak_diff: REQUIRED_METADATA not found in gpkg-structure.sh")
    return m.group(1).replace("\\\n", " ").split()


class Structure:
    def __init__(self) -> None:
        self.findings = 0
        self.archives = 0

    def fail(self, cat: str, where: str, detail: str) -> None:
        print(f"[{cat}] {where}: {detail}")
        self.findings += 1

    def check_archive(self, path: Path, shown: str) -> None:
        self.archives += 1
        try:
            x = Xpak(path)
        except XpakError as e:
            self.fail("OUTER", shown, f"xpak trailer/index: {e}")
            return
        except OSError as e:
            self.fail("IO", shown, f"not a readable file: {e}")
            return
        # payload: compressor named by BINPKG_COMPRESS (when recorded) must
        # be the one the bytes are in; then it must be a valid tar
        named = x.members.get("BINPKG_COMPRESS")
        if named is not None:
            want = COMP_NAMES.get(named.decode("utf-8", "replace").strip())
            if want is None:
                self.fail("INNER", shown, f"BINPKG_COMPRESS member names unknown compressor {named!r}")
            elif want != x.comp:
                self.fail("INNER", shown, f"BINPKG_COMPRESS says {want} but the payload is {x.comp}")
        try:
            with x.tar() as t:
                names = [m.name for m in t.getmembers()]
        except (tarfile.TarError, OSError, EOFError, lzma.LZMAError,
                subprocess.CalledProcessError, FileNotFoundError) as e:
            self.fail("INNER", shown, f"payload is not a tar after {x.comp} decompression: {e}")
            names = []
        else:
            if not names:
                self.fail("INNER", shown, "payload tar is empty")
            for n in names:
                if n != "." and not n.startswith("./"):
                    self.fail("INNER", shown, f"payload member outside ./: {n}")
        # metadata key set + identity
        keys = set(x.members)
        for key in required_metadata():
            if key not in keys:
                self.fail("METADATA", shown, f"missing {key}")
        ebuilds = sorted(k for k in keys if k.endswith(".ebuild") and "/" not in k)
        pf = ebuilds[0][:-len(".ebuild")] if ebuilds else ""
        if not pf:
            self.fail("METADATA", shown, "no <pf>.ebuild member")
        else:
            pf_val = x.members.get("PF", b"").decode("utf-8", "replace").split("\n")[0]
            if pf_val != pf:
                self.fail("METADATA", shown, f"PF '{pf_val}' != ebuild member '{pf}'")
        build_id = x.members.get("BUILD_ID", b"").decode("utf-8", "replace").strip()
        if build_id:
            suffix = x.stem.rsplit("-", 1)[-1]
            if suffix != build_id:
                self.fail("MULTI", shown, f"BUILD_ID '{build_id}' != name suffix '{suffix}'")
        if pf and x.stem != pf and x.stem != f"{pf}-{build_id}":
            self.fail("MULTI", shown, f"file stem '{x.stem}' does not match pf '{pf}' (build_id '{build_id}')")

    def check_packages(self, pkgdir: Path, archives: list[Path]) -> None:
        pk = pkgdir / "Packages"
        if not pk.is_file():
            self.fail("INDEX", str(pkgdir),
                      "no Packages index (real Portage under pkgdir-index-trusted cannot see any archive)")
            return
        stanzas: dict[str, dict[str, str]] = {}
        for block in pk.read_text(errors="replace").split("\n\n"):
            d: dict[str, str] = {}
            for line in block.splitlines():
                k, _, v = line.partition(": ")
                if k:
                    d[k] = v
            if "PATH" in d:
                stanzas[d["PATH"]] = d
        for a in archives:
            rel = a.relative_to(pkgdir).as_posix()
            d = stanzas.get(rel)
            if d is None:
                self.fail("INDEX", str(a), f"no Packages stanza with PATH: {rel}")
                continue
            if d.get("SIZE") != str(a.stat().st_size):
                self.fail("INDEX", str(a), f"Packages SIZE '{d.get('SIZE')}' != file size")
            if d.get("MD5") != hashlib.md5(a.read_bytes()).hexdigest():
                self.fail("INDEX", str(a), "Packages MD5 mismatch")
            stem = a.name[:-len(".xpak")]
            if re.search(r"-[0-9]", stem):
                suffix = stem.rsplit("-", 1)[-1]
                bid = d.get("BUILD_ID", "")
                if bid and suffix != bid:
                    self.fail("INDEX", str(a), f"Packages BUILD_ID '{bid}' != filename suffix '{suffix}'")
            if not d.get("REPO"):
                self.fail("INDEX", str(a), "Packages stanza has no REPO field")
            if not d.get("BUILD_TIME"):
                self.fail("INDEX", str(a), "Packages stanza has no BUILD_TIME field")


def main_structure(args: list[str], pkgdir: str | None, want_index: bool) -> int:
    st = Structure()
    if pkgdir is not None:
        d = Path(pkgdir)
        if not d.is_dir():
            print(f"xpak_diff: no such directory: {pkgdir}", file=sys.stderr)
            return 2
        d = d.resolve()
        archives = sorted(d.rglob("*.xpak"), key=lambda p: str(p).encode())
        for a in archives:
            st.check_archive(a, str(a))
        for a in sorted(d.rglob("*.gpkg.tar")) + sorted(d.rglob("*.tbz2")):
            st.fail("INNER", str(a), "non-xpak binary format in an xpak pkgdir (formats mixed)")
        if want_index:
            st.check_packages(d, archives)
    elif args:
        for a in args:
            st.check_archive(Path(a), a)
    else:
        print(__doc__)
        return 2
    if st.findings:
        print(f"xpak-structure: {st.archives} archives checked, {st.findings} finding(s)", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str]) -> int:
    mode = "strict"
    structure = False
    want_index = False
    pkgdir: str | None = None
    args: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--mode":
            i += 1
            if i >= len(argv) or argv[i] not in ("strict", "payload-tolerant"):
                print(__doc__)
                return 2
            mode = argv[i]
        elif a == "--structure":
            structure = True
        elif a == "--packages":
            want_index = True
        elif a == "--dir":
            i += 1
            if i >= len(argv):
                print(__doc__)
                return 2
            pkgdir = argv[i]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            args.append(a)
        i += 1
    if structure:
        return main_structure(args, pkgdir, want_index)
    return main_diff(args, mode)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
