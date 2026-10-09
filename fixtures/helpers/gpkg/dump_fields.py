#!/usr/bin/env python3
"""D3 field dump of a gpkg container (plan #326 S4).

    dump_fields.py <file.gpkg.tar>   > out.fields

Same vocabulary as differential-test-bed/compare/gpkg_diff.py's buckets
(outer-layout, metadata, image, manifest) but with EVERY tarinfo field
instead of a normalised subset; mtime is the one field never printed.  The
format is documented in fixtures/helpers/gpkg/README.md.  Output is pure
ASCII (names are %XX-escaped outside [A-Za-z0-9._/+-]) and deterministic for
a given archive.
"""
import hashlib
import io
import re
import subprocess
import sys
import tarfile

DECOMP = {".zst": ["zstd", "-dc"], ".xz": ["xz", "-dc"], ".bz2": ["bzip2", "-dc"],
          ".gz": ["gzip", "-dc"]}


def pre_flags(data: bytes, m) -> str:
    """Typeflags of the extension headers (GNU `L`/`K`, PAX `x`/`g`) that
    precede this member's own header, walking header + data blocks."""
    flags, o = "", m.offset
    while o < m.offset_data - 512:
        flags += chr(data[o + 156])
        size = int(data[o + 124:o + 136].strip(b"\0 ") or b"0", 8)
        o += 512 + -(-size // 512) * 512
    return flags


def esc(b) -> str:
    if isinstance(b, str):
        b = b.encode("utf-8", "surrogateescape")
    return "".join(chr(c) if (48 <= c <= 57 or 65 <= c <= 90 or 97 <= c <= 122
                              or c in b"._/+-") else f"%{c:02X}" for c in b)


def fmt_of(block: bytes) -> str:
    magic = block[257:265]
    if magic == b"ustar\x0000":
        return "USTAR"
    if magic == b"ustar  \x00":
        return "GNU"
    return "V7" if magic == b"\x00" * 8 else "UNKNOWN"


def dump_tar(data: bytes, label: str, out: list) -> None:
    out.append(f"{label}.archive size={len(data)} mod10240={len(data) % 10240}")
    tf = tarfile.open(fileobj=io.BytesIO(data))
    for m in tf.getmembers():
        final = data[m.offset_data - 512:m.offset_data]
        pre = pre_flags(data, m)
        name = m.name + ("/" if m.isdir() else "")
        # tarfile strips the trailing slash of a directory; the writer under
        # test must emit it.  Verify on plain headers (no extension blocks).
        if not pre and m.isdir():
            raw = (final[345:500].rstrip(b"\0") + b"/" if final[345:500].strip(b"\0") else b"") \
                + final[0:100].rstrip(b"\0")
            assert raw.decode("utf-8", "surrogateescape").endswith("/"), (m.name, raw)
        line = (f"{label}.member name={esc(name)} type={chr(m.type[0]) if isinstance(m.type, bytes) else m.type}"
                f" fmt={fmt_of(final)} pre={pre or '-'}"
                f" mode={m.mode:04o} uid={m.uid} gid={m.gid}"
                f" uname={esc(m.uname)} gname={esc(m.gname)} size={m.size}"
                f" linkname={esc(m.linkname) or '-'} devmajor={m.devmajor} devminor={m.devminor}")
        if m.isreg():
            line += " sha256=" + hashlib.sha256(tf.extractfile(m).read()).hexdigest()
        out.append(line)


def decompress(name: str, data: bytes) -> bytes:
    for ext, cmd in DECOMP.items():
        if name.endswith(ext):
            return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout
    return data


def dump_manifest(text: str, out: list) -> None:
    for ln in text.splitlines():
        t = ln.split()
        if t and t[0] == "DATA":
            # real's checksum-algorithm order inside a DATA line follows set
            # iteration order, i.e. PYTHONHASHSEED: it differs run to run.
            # The dump therefore sorts the (ALGO, digest) pairs by algo name.
            pairs = sorted((t[i], t[i + 1]) for i in range(3, len(t) - 1, 2))
            algos = [f"{a}:{len(d)}hex" for a, d in pairs]
            base = t[1]
            if base.endswith(".sig"):
                vol = "signature"
            elif base.startswith("metadata.tar"):
                vol = "mtime"
            elif base.startswith("image.tar"):
                vol = "compressor"
            else:
                vol = "none"
            if vol in ("mtime", "signature"):
                out.append(f"manifest.data name={esc(base)} volatile={vol} algos={','.join(algos)}")
            else:
                out.append(f"manifest.data name={esc(base)} volatile={vol} size={t[2]} "
                           + " ".join(f"{a}={d}" for a, d in pairs))
        elif ln.startswith("-----BEGIN PGP SIGNATURE"):
            out.append("manifest.pgp-signature volatile=signature (block marker)")
        elif ln.startswith("-----"):
            out.append(f"manifest.pgp-armor {ln}")
        elif re.match(r"^=[A-Za-z0-9+/]{4}$", ln):
            out.append("manifest.pgp-crc volatile=signature")
        elif re.match(r"^[A-Za-z0-9+/=]{20,}$", ln):
            if not out[-1].startswith("manifest.pgp-base64"):
                out.append("manifest.pgp-base64 volatile=signature (consecutive lines collapsed)")
        elif ln.strip():
            out.append(f"manifest.other {esc(ln)}")


def main() -> int:
    raw = open(sys.argv[1], "rb").read()
    out = ["# gpkg field dump v1 (fixtures/helpers/gpkg/README.md); mtime never printed"]
    out.append(f"container.archive size=~ mod10240={len(raw) % 10240}")
    tf = tarfile.open(fileobj=io.BytesIO(raw))
    inner = []
    manifest = None
    for m in tf.getmembers():
        final = raw[m.offset_data - 512:m.offset_data]
        pre = pre_flags(raw, m)
        base = m.name.split("/", 1)[1] if "/" in m.name else m.name
        vol = "" if base == "gpkg-1" else " size=~"
        out.append(f"container.member name={esc(m.name)} fmt={fmt_of(final)} pre={pre or '-'}"
                   f" type={chr(m.type[0]) if isinstance(m.type, bytes) else m.type}"
                   f" mode={m.mode:04o} uid={m.uid} gid={m.gid} uname={esc(m.uname)}"
                   f" gname={esc(m.gname)} linkname={esc(m.linkname) or '-'}"
                   f" devmajor={m.devmajor} devminor={m.devminor}"
                   + (f" size={m.size}" if not vol else vol))
        data = tf.extractfile(m).read()
        if re.match(r"^(metadata|image)\.tar", base) and not base.endswith(".sig"):
            inner.append((base, data))
        elif base == "Manifest":
            manifest = data.decode("utf-8")
    for base, data in inner:
        d = decompress(base, data)
        dump_tar(d, base.split(".", 1)[0], out)
    if manifest is not None:
        dump_manifest(manifest, out)
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
