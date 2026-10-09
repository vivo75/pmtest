#!/bin/bash
# merged-snapshot-lib.sh -- shared by the #326 Z close-out guests.
# Source, don't execute: `. /TEST/layers/z326/merged-snapshot-lib.sh`.
#
# z326_snapshot_merged_set <outdir> <prefix> <atom>...
#   Restricts the merge snapshot to what this container merged, the
#   layers/l1/consume.sh shape: <prefix>.files.tsv / .mtimes.tsv /
#   .vdb.tar / .meta.tsv via compare/snapshot.sh, plus
#   <outdir>/{installed-before,installed-after,merged-cpvs,paths}.txt.
#   The caller records <outdir>/installed-before.txt before emerging
#   (one `cat/pf` per line, `LC_ALL=C sort`ed; absent = empty).
#
#   merged-cpvs is the union of (a) newly installed cpvs (before/after
#   diff -- the fresh-merge shape) and (b) every installed cpv whose
#   cat/pkg matches a requested atom (the --reinstall shape, where
#   before == after and the diff sees nothing -- same as consume.sh's
#   L1_CONSUME_REINSTALL branch, but as a union so one block serves
#   both).

# shellcheck disable=SC2120  # called with args by both guests
z326_snapshot_merged_set() {
  local outdir=$1 prefix=$2
  shift 2
  local before="$outdir/installed-before.txt"
  [ -f "$before" ] || : > "$before"
  ( cd /var/db/pkg && ls -d */*/ 2>/dev/null | sed 's:/$::' ) \
    | LC_ALL=C sort > "$outdir/installed-after.txt" || true
  comm -13 "$before" "$outdir/installed-after.txt" > "$outdir/merged-new.txt" || true
  : > "$outdir/merged-cpvs.txt"
  local atom catpkg
  for atom in "$@"; do
    catpkg=${atom#[=<>~]}; catpkg=${catpkg%%[<>=~]*}; catpkg=${catpkg%%:*}
    grep -E "^${catpkg}-[0-9]" "$outdir/installed-after.txt" >> "$outdir/merged-cpvs.txt" || true
  done
  cat "$outdir/merged-new.txt" >> "$outdir/merged-cpvs.txt" || true
  LC_ALL=C sort -u -o "$outdir/merged-cpvs.txt" "$outdir/merged-cpvs.txt"
  rm -f "$outdir/merged-new.txt"
  printf '[z326-snapshot] merged %s packages\n' "$(wc -l < "$outdir/merged-cpvs.txt")"
  {
    while read -r cpv; do
      _cat="${cpv%%/*}"; _pf="${cpv#*/}"; _d="/var/db/pkg/$_cat/$_pf"
      [ -f "$_d/CONTENTS" ] && awk '$1=="obj"||$1=="sym"||$1=="dir" {print $2}' "$_d/CONTENTS"
    done < "$outdir/merged-cpvs.txt"
    find /etc -name '._cfg????_*' 2>/dev/null
    printf '%s\n' \
      /var/lib/portage/world /var/lib/portage/config \
      /etc/ld.so.cache /etc/ld.so.conf /etc/profile.env /etc/csh.env \
      /etc/environment /etc/environment.d/ /usr/share/info/dir \
      /var/lib/porttest/
  } | LC_ALL=C sort -u > "$outdir/paths.txt"
  printf '[z326-snapshot] snapshotting %s path entries\n' "$(wc -l < "$outdir/paths.txt")"
  bash /TEST/compare/snapshot.sh \
    --paths "$outdir/paths.txt" --vdb-list "$outdir/merged-cpvs.txt" / "$prefix" \
    2> "$outdir/snapshot.err" || {
    printf '[z326-snapshot] !!! snapshot.sh failed, see snapshot.err\n'
    return 1
  }
  return 0
}
