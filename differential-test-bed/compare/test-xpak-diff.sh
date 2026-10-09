#!/bin/bash
# test-xpak-diff.sh -- host-side self-test for xpak_diff.py (diff and
# --structure modes), on synthetic xpak archives built here with python3
# (no L1/L2 pkgcache needed).
#
#   differential-test-bed/compare/test-xpak-diff.sh
#
# Positive control (identical archives), then one mutation per rule:
# changed member value, missing member, broken trailer, changed payload
# byte (hard in strict, tolerated in payload-tolerant), and the volatile
# fields gpkg_diff.py tolerates (BUILD_TIME/BUILD_ID/COUNTER, sorted
# NEEDED) -- those must stay rc 0 exactly as in the gpkg diff.
#
# Exit 0 all good, 1 a case failed, 2 setup error.

set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
X="$HERE/xpak_diff.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
expect_hit() {  # <label> <regex> <cmd...>
  local label=$1 pat=$2; shift 2
  local out
  out=$("$@" 2>&1) || true
  if printf '%s\n' "$out" | grep -qE "$pat"; then ok "$label"; else
    bad "$label (no match for /$pat/)"; printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}
expect_miss() {  # <label> <regex> <cmd...>
  local label=$1 pat=$2; shift 2
  local out
  out=$("$@" 2>&1) || true
  if printf '%s\n' "$out" | grep -qE "$pat"; then
    bad "$label (unexpected /$pat/)"; printf '%s\n' "$out" | sed 's/^/      /' | head -6
  else ok "$label"; fi
}
expect_rc() {  # <want> <label> <cmd...>
  local want=$1 label=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else
    bad "$label (rc=$rc want $want)"; printf '%s\n' "$out" | sed 's/^/      /' | head -6
  fi
}

cat > "$TMP/mk.py" <<'PY'
import bz2, io, struct, subprocess, sys, tarfile
from pathlib import Path

out = Path(sys.argv[1])

def be(n): return struct.pack(">I", n)

def xpak(members):
    index = data = b""
    for k, v in members.items():
        v = v.encode() if isinstance(v, str) else v
        kb = k.encode()
        index += be(len(kb)) + kb + be(len(data)) + be(len(v))
        data += v
    seg = b"XPAKPACK" + be(len(index)) + be(len(data)) + index + data + b"XPAKSTOP"
    return seg, seg + be(len(seg)) + b"STOP"

def image(files, flip=False):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        d = tarfile.TarInfo("./"); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
        for name, body in files.items():
            data = body.encode()
            if flip:
                data = b"X" + data[1:]
            ti = tarfile.TarInfo("./" + name); ti.size = len(data); ti.mode = 0o644
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()

def image_hl(swap):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        d = tarfile.TarInfo("./"); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
        first, second = ("usr/b", "usr/a") if swap else ("usr/a", "usr/b")
        ti = tarfile.TarInfo("./" + first); ti.size = 3; ti.mode = 0o755
        t.addfile(ti, io.BytesIO(b"abc"))
        li = tarfile.TarInfo("./" + second); li.type = tarfile.LNKTYPE; li.linkname = "./" + first; li.mode = 0o755
        t.addfile(li)
    return buf.getvalue()

def zstd(b):
    return subprocess.run(["zstd", "-q", "-c"], input=b, check=True, capture_output=True).stdout

BASE = {
    "CATEGORY": "porttest\n", "PF": "demo-1.0\n", "SLOT": "0\n", "EAPI": "8\n",
    "DESCRIPTION": "d\n", "KEYWORDS": "amd64\n", "DEFINED_PHASES": "install\n",
    "USE": "\n", "FEATURES": "x\n", "BUILD_TIME": "1700000000\n", "SIZE": "12\n",
    "IUSE": "\n", "IUSE_EFFECTIVE": "\n", "repository": "porttest\n",
    "REPO_REVISIONS": "\n", "CBUILD": "x86_64-pc-linux-gnu\n", "CHOST": "x86_64-pc-linux-gnu\n",
    "CFLAGS": "-O2\n", "CXXFLAGS": "-O2\n", "LDFLAGS": "\n", "BUILD_ID": "1",
    "COUNTER": "5\n", "NEEDED": "a\nb\n", "BINPKG_COMPRESS": "zstd\n",
    "demo-1.0.ebuild": "EAPI=8\n",
}
FILES = {"usr/share/demo/a.txt": "hello a\n", "usr/share/demo/b.txt": "hello b\n"}

def write(name, members=None, files=None, flip=False, comp=zstd, trailer=None, build_id="1", img=None):
    m = dict(BASE)
    m["BUILD_ID"] = build_id
    m.update(members or {})
    for k in [k for k, v in m.items() if v is None]:
        del m[k]
    payload = comp(img if img is not None else image(files or FILES, flip))
    seg, full = xpak(m)
    blob = payload + (full if trailer is None else seg + trailer)
    d = out / "porttest" / "demo"
    d.mkdir(parents=True, exist_ok=True)
    (d / name).write_bytes(blob)

write("demo-1.0-1.xpak")
write("demo-1.0-2.xpak", members={"BUILD_TIME": "1800000000\n", "COUNTER": "9\n",
                                  "NEEDED": "b\na\n"}, build_id="2")
write("chg.xpak", members={"EAPI": "7\n"}, build_id="1")
write("miss.xpak", members={"DESCRIPTION": None}, build_id="1")
write("badtrailer.xpak", trailer=be(7) + b"STOP")
write("notrailer.xpak", trailer=b"JUNKJUNK")
write("size.xpak", members={"SIZE": "99\n"}, build_id="1")
write("flip.xpak", flip=True, build_id="1")
write("gz.xpak", comp=lambda b: __import__("gzip").compress(b), members={"BINPKG_COMPRESS": "gzip\n"})
write("lie.xpak", members={"BINPKG_COMPRESS": "bzip2\n"})
write("nokey.xpak", members={"CHOST": None})
write("hl1.xpak", img=image_hl(False))
write("hl2.xpak", img=image_hl(True))
write("hl3.xpak", img=image(dict(FILES, **{"usr/a": "abc", "usr/b": "abc"})))
PY
python3 "$TMP/mk.py" "$TMP/p" || { echo "setup failed" >&2; exit 2; }
P="$TMP/p/porttest/demo"

# --- diff: positive controls -------------------------------------------
expect_rc 0 "identical archives pass" "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/demo-1.0-1.xpak"
expect_rc 0 "volatile BUILD_TIME/BUILD_ID/COUNTER + sorted NEEDED tolerated (as gpkg_diff)" \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/demo-1.0-2.xpak"
expect_hit "differing file stem is informational outer-name" '^\[outer-name\]' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/demo-1.0-2.xpak"
expect_hit "summary line carries mode/hard/soft" '^xpak-diff: mode=strict hard=0 soft=1' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/demo-1.0-2.xpak"

# --- diff: mutations ----------------------------------------------------
expect_hit "changed member value -> metadata" '^\[metadata\] metadata/EAPI differs' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/chg.xpak"
expect_rc 1 "changed member value -> rc 1" "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/chg.xpak"
expect_hit "missing member -> metadata missing in b" '^\[metadata\] missing in b: metadata/DESCRIPTION' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/miss.xpak"
expect_hit "missing member (swapped) -> missing in a" '^\[metadata\] missing in a: metadata/DESCRIPTION' \
  "$X" --mode strict "$P/miss.xpak" "$P/demo-1.0-1.xpak"
expect_rc 2 "broken trailer length -> rc 2 and reported" "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/badtrailer.xpak"
expect_hit "broken trailer is named" 'xpak_diff: cannot read an archive: .*(trailer|segment)' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/badtrailer.xpak"
expect_hit "missing STOP trailer is named" 'no `STOP` trailer' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/notrailer.xpak"
expect_hit "changed payload byte -> image:paths hard in strict" '^\[image:paths\] payload differs' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/flip.xpak"
expect_hit "changed payload byte -> payload in tolerant" '^\[payload\] payload differs' \
  "$X" --mode payload-tolerant "$P/demo-1.0-1.xpak" "$P/flip.xpak"
expect_rc 0 "changed payload byte tolerated -> rc 0" \
  "$X" --mode payload-tolerant "$P/demo-1.0-1.xpak" "$P/flip.xpak"
expect_hit "SIZE differs -> hard in strict" '^\[metadata\] metadata/SIZE differs' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/size.xpak"
expect_rc 0 "SIZE differs -> tolerated in payload-tolerant (norm_meta, as gpkg_diff)" \
  "$X" --mode payload-tolerant "$P/demo-1.0-1.xpak" "$P/size.xpak"
expect_hit "different compressor -> outer-layout" '^\[outer-layout\] payload compression differs' \
  "$X" --mode strict "$P/demo-1.0-1.xpak" "$P/gz.xpak"

# hard links: which name holds the data is gtar's readdir order, not the image
expect_rc 0 "hard-link pair stored in the other order is equal" \
  "$X" --mode strict "$P/hl1.xpak" "$P/hl2.xpak"
expect_hit "same bytes but no longer a hard link -> hard" '^\[image:paths\] (hardlink group only in a|usr/[ab]: a=)' \
  "$X" --mode strict "$P/hl1.xpak" "$P/hl3.xpak"

# --- structure ----------------------------------------------------------
expect_rc 0 "structure: a well-formed archive is clean" "$X" --structure "$P/demo-1.0-1.xpak"
expect_hit "structure: broken trailer -> OUTER" '^\[OUTER\] .*trailer' "$X" --structure "$P/badtrailer.xpak"
expect_hit "structure: missing STOP -> OUTER" '^\[OUTER\] ' "$X" --structure "$P/notrailer.xpak"
expect_hit "structure: BINPKG_COMPRESS lies about the payload -> INNER" \
  '^\[INNER\] .*BINPKG_COMPRESS says bzip2 but the payload is zstd' "$X" --structure "$P/lie.xpak"
expect_hit "structure: missing required key -> METADATA" '^\[METADATA\] .*missing CHOST' \
  "$X" --structure "$P/nokey.xpak"
expect_miss "structure: gzip payload named gzip is accepted" '^\[INNER\]' "$X" --structure "$P/gz.xpak"

# Packages index checks over a dir
D="$TMP/pk"; mkdir -p "$D/porttest/demo"; cp "$P/demo-1.0-1.xpak" "$D/porttest/demo/"
A="$D/porttest/demo/demo-1.0-1.xpak"
SZ=$(stat -c%s "$A"); MD=$(md5sum "$A" | cut -d' ' -f1)
expect_hit "structure --packages: no Packages -> INDEX" '^\[INDEX\] .*no Packages index' \
  "$X" --structure --dir "$D" --packages
printf 'ARCH: amd64\n\nPATH: porttest/demo/demo-1.0-1.xpak\nSIZE: %s\nMD5: %s\nBUILD_ID: 1\nBUILD_TIME: 1\nREPO: porttest\n' \
  "$SZ" "$MD" > "$D/Packages"
expect_rc 0 "structure --packages: a matching stanza is clean" "$X" --structure --dir "$D" --packages
sed -i 's/^MD5: .*/MD5: 00/' "$D/Packages"
expect_hit "structure --packages: wrong MD5 -> INDEX" '^\[INDEX\] .*MD5 mismatch' \
  "$X" --structure --dir "$D" --packages
printf 'ARCH: amd64\n' > "$D/Packages"
expect_hit "structure --packages: no stanza -> INDEX" '^\[INDEX\] .*no Packages stanza' \
  "$X" --structure --dir "$D" --packages

echo
echo "test-xpak-diff: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
