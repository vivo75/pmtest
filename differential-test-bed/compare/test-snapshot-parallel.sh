#!/bin/bash
# test-snapshot-parallel.sh -- host-side byte-identity proof for
# snapshot.sh's SNAPSHOT_JOBS sharding (S1, backlog #283 B1).
#
# Builds one static tree (a few thousand files: empty files, symlinks
# valid + dangling, hardlinks, fifos, odd names with spaces/newlines/
# leading dashes, an unreadable file, xattrs when setfattr exists, a
# fake /var/db/pkg) and snapshots it with SNAPSHOT_JOBS=1 vs 8 (plus the
# unset default and the degenerate 0/garbage values). files.tsv,
# mtimes.tsv and vdb.tar must be byte-identical across all runs --
# parallelisation only changes which worker hashes a path, and the
# final `LC_ALL=C sort -u -o` canonicalises worker order away.
#
#   differential-test-bed/compare/test-snapshot-parallel.sh
#
# Exit 0 all good, 1 a case failed, 2 setup error. Prints the sha256
# sums (paste them into the S1 report) and `cmp`s every pair.

set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNAP="$HERE/snapshot.sh"
[ -x "$SNAP" ] || { echo "test-snapshot-parallel: SETUP -- $SNAP missing" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

# --- build one static tree -------------------------------------------
ROOT=$TMP/tree
mkdir -p "$ROOT"
i=0
while [ "$i" -lt 2500 ]; do
  d=$ROOT/usr/lib/dir$((i % 37))
  mkdir -p "$d"
  if [ $((i % 11)) -eq 0 ]; then
    : > "$d/empty-$i.dat"                        # empty regular file
  else
    printf 'payload-%d\n%s\n' "$i" "$(printf 'x%.0s' $(seq 1 $((i % 251))))" > "$d/file-$i.dat"
  fi
  i=$((i + 1))
done
# odd names: spaces, tab, newline, leading dash, unicode
mkdir -p "$ROOT/opt/odd"
printf 'spaced' > "$ROOT/opt/odd/with space.txt"
printf 'tabbed' > "$ROOT/opt/odd/with"$'\t'"tab.txt"
printf 'newline' > "$ROOT/opt/odd/with"$'\n'"newline.txt"
printf 'dashed' > "$ROOT/opt/odd/--leading-dash"
printf 'uni' > "$ROOT/opt/odd/ünïcodé.txt"
printf 'squoting' > "$ROOT/opt/odd/it's-quoted.txt"
# symlinks: valid (abs + rel), dangling, to a dir, self-loop
ln -s /usr/lib/dir3/file-100.dat "$ROOT/opt/odd/abs-link"
ln -s ../lib/dir3/file-101.dat "$ROOT/opt/odd/rel-link"
ln -s /no/such/target-anywhere "$ROOT/opt/odd/dangling"
ln -s /usr/lib "$ROOT/opt/odd/dir-link"
ln -s self-loop "$ROOT/opt/odd/self-loop"
# hardlinks (same inode, two names)
printf 'hardlink-body\n' > "$ROOT/opt/odd/orig.bin"
ln "$ROOT/opt/odd/orig.bin" "$ROOT/opt/odd/orig-alias.bin"
# fifos
mkfifo "$ROOT/opt/odd/a-fifo" "$ROOT/opt/odd/b-fifo"
# unreadable file: stat works, content hash fails -> sha `-`, deterministically
printf 'no-read\n' > "$ROOT/opt/odd/unreadable.dat"
chmod 000 "$ROOT/opt/odd/unreadable.dat"
# xattrs when the fs/tools allow (best effort, never fatal)
if command -v setfattr >/dev/null 2>&1 \
   && setfattr -n user.pmtest -v probe "$ROOT/opt/odd/orig.bin" 2>/dev/null; then
  setfattr -n user.pmtest.suite -v s1 "$ROOT/opt/odd/orig.bin"
  setfattr -n user.pmtest.empty -v '' "$ROOT/usr/lib/dir0/empty-0.dat" 2>/dev/null || true
  echo "test-snapshot-parallel: info -- xattrs exercised"
else
  echo "test-snapshot-parallel: info -- no setfattr/user-xattr support, skipping xattr arm"
fi
# fake /var/db/pkg (pruned from the files walk, covered via vdb.tar)
mkdir -p "$ROOT/var/db/pkg/app-text/tree-2.2.1" "$ROOT/var/db/pkg/sys-libs/glibc-2.39"
printf 'EAPI=8\nDESCRIPTION="fake"\n' > "$ROOT/var/db/pkg/app-text/tree-2.2.1/tree-2.2.1.ebuild"
printf 'CONTENTS fake\n' > "$ROOT/var/db/pkg/app-text/tree-2.2.1/CONTENTS"
printf 'EAPI=8\nDESCRIPTION="fake glibc"\n' > "$ROOT/var/db/pkg/sys-libs/glibc-2.39/glibc-2.39.ebuild"
printf 'BUILD_TIME 1\n' > "$ROOT/var/db/pkg/sys-libs/glibc-2.39/BUILD_TIME"
chmod 000 "$ROOT/opt/odd/unreadable.dat" 2>/dev/null || true
nfiles=$(find "$ROOT" | wc -l)
echo "test-snapshot-parallel: info -- tree has $nfiles dentries"

# --- snapshot runs ----------------------------------------------------
run_snap() {  # <jobs-or-UNSET> <out-prefix>
  local jobs=$1 out=$2
  if [ "$jobs" = UNSET ]; then
    ( unset SNAPSHOT_JOBS; "$SNAP" "$ROOT" "$out" >/dev/null 2>"$out.stderr" )
  else
    ( SNAPSHOT_JOBS=$jobs "$SNAP" "$ROOT" "$out" >/dev/null 2>"$out.stderr" )
  fi
}
run_snap 1 "$TMP/s1"      || { bad "SNAPSHOT_JOBS=1 run failed"; cat "$TMP/s1.stderr" | head -5; }
run_snap 8 "$TMP/s8"      || { bad "SNAPSHOT_JOBS=8 run failed"; cat "$TMP/s8.stderr" | head -5; }
run_snap UNSET "$TMP/sd"  || { bad "default run failed"; cat "$TMP/sd.stderr" | head -5; }
run_snap 0 "$TMP/s0"      || { bad "SNAPSHOT_JOBS=0 run failed"; cat "$TMP/s0.stderr" | head -5; }
run_snap banana "$TMP/sb" || { bad "SNAPSHOT_JOBS=banana run failed"; cat "$TMP/sb.stderr" | head -5; }

# --- byte-identity ----------------------------------------------------
for f in files.tsv mtimes.tsv vdb.tar; do
  for other in s8 sd s0 sb; do
    if cmp -s "$TMP/s1.$f" "$TMP/$other.$f"; then
      ok "$f identical (JOBS=1 vs ${other#s})"
    else
      bad "$f DIFFERS (JOBS=1 vs ${other#s})"
    fi
  done
done
# vdb.tar must be non-trivially populated (else the cmp proves nothing)
if [ -s "$TMP/s1.vdb.tar" ] && tar -tf "$TMP/s1.vdb.tar" 2>/dev/null | grep -q glibc; then
  ok "vdb.tar covers the fake pkg dirs ($(tar -tf "$TMP/s1.vdb.tar" | wc -l) members)"
else
  bad "vdb.tar looks empty"
fi
# the odd names must have survived the NUL round-trip in BOTH runs
# (the newline-in-name entry cannot be grepped line-wise, so pin it via
# the opt/odd entry count plus spot checks; cmp above proves the rest)
n_odd_1=$(grep -c "opt/odd/" "$TMP/s1.files.tsv")
n_odd_8=$(grep -c "opt/odd/" "$TMP/s8.files.tsv")
if [ "$n_odd_1" = 16 ] && [ "$n_odd_8" = 16 ]; then
  ok "odd-name entries all present in both runs (16 opt/odd lines)"
else
  bad "odd-name entries lost (JOBS=1: $n_odd_1, JOBS=8: $n_odd_8, want 16)"
fi
for needle in "with space" "--leading-dash"; do
  if grep -qF -e "$needle" "$TMP/s8.files.tsv"; then ok "odd name present: $(printf %q "$needle")"
  else bad "odd name LOST: $(printf %q "$needle")"; fi
done
echo "--- sha256sums (S1 report evidence) ---"
sha256sum "$TMP/s1.files.tsv" "$TMP/s1.mtimes.tsv" "$TMP/s1.vdb.tar" \
  | sed "s|$TMP/||"
echo "files.tsv lines: $(wc -l < "$TMP/s1.files.tsv")   mtimes.tsv lines: $(wc -l < "$TMP/s1.mtimes.tsv")"

echo "test-snapshot-parallel: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
