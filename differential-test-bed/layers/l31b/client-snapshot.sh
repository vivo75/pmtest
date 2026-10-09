#!/bin/bash
# L31b -- snapshot the bare client's ROOT after the server's merge
# passes (portuale #326 S8, pmtest side). Runs INSIDE the client
# container via `podman exec`, after the host's server-merge passes.
# Mirrors layers/l31/consume-remote.sh's snapshot section exactly
# (vdb-list from the installed-before file client-init.sh recorded,
# CONFIG_PROTECT divert files, the same fixed tail), so the host diffs
# the client snapshot against real Portage's consume with the same
# compare/ helpers and no new semantics.
#
# Usage (from the host orchestrator):
#   podman exec <client> /TEST/layers/l31b/client-snapshot.sh \
#       /TEST/logs/<run>/client /
#
# FAR is always / here (the client merges into its own ROOT).
#
# Exit: 0 snapshotted, 2 setup error.

set -u
OUT=${1:?out prefix}
FAR=${2:?far root}

log() { printf '[l31b-client-snapshot] %s\n' "$*"; }
fail() { log "!!! $*"; exit 2; }

export LC_ALL=C.UTF-8 TZ=UTC
umask 022

[ -f "$OUT.installed-before.txt" ] \
  || fail "missing $OUT.installed-before.txt (client-init.sh never ran?)"

# Installed-cpv before/after, exactly like layers/l1/consume.sh: the vdb
# tar and path list must carry only the packages this run merged, never
# the image's pre-existing vdb.
# shellcheck disable=SC2012,SC2035  # `ls -d */*/` is the bed-wide idiom (layers/l1/consume.sh)
( cd "$FAR/var/db/pkg" && ls -d */*/ 2>/dev/null | sed 's:/$::' ) \
  | LC_ALL=C sort > "$OUT.installed-after.txt" \
  || fail "cannot list $FAR/var/db/pkg"
comm -13 "$OUT.installed-before.txt" "$OUT.installed-after.txt" \
  > "$OUT.vdb-list.txt" \
  || fail "cannot diff installed-before/after"

{
  while IFS= read -r cpv; do
    [ -n "$cpv" ] || continue
    d="$FAR/var/db/pkg/$cpv"
    [ -f "$d/CONTENTS" ] \
      && awk '$1=="obj"||$1=="sym"||$1=="dir" {print $2}' "$d/CONTENTS"
  done < "$OUT.vdb-list.txt"
  # CONFIG_PROTECT divert files, mirroring layers/l1/consume.sh exactly:
  # real Portage writes `._cfg????_*` siblings under a protected path.
  # `${FAR%/}/etc` keeps a leading single slash for the `/` far root
  # this cell uses.
  find "${FAR%/}/etc" -name '._cfg????_*' 2>/dev/null
  # The fixed tail, identical to layers/l1/consume.sh and
  # layers/l31/consume-remote.sh; paths absent in the far ROOT are
  # skipped by snapshot.sh, so client-only MISSING rows stay honest.
  printf '%s\n' \
    /var/lib/portage/world /var/lib/portage/config \
    /etc/ld.so.cache /etc/ld.so.conf /etc/profile.env /etc/csh.env \
    /etc/environment /etc/environment.d/ /usr/share/info/dir \
    /var/lib/porttest/
} | LC_ALL=C sort -u > "$OUT.paths.txt"

log "snapshotting $(wc -l < "$OUT.paths.txt") path entries + $(wc -l < "$OUT.vdb-list.txt") far vdb dirs -> $OUT.*"
if ! bash /TEST/compare/snapshot.sh \
     --paths "$OUT.paths.txt" --vdb-list "$OUT.vdb-list.txt" "$FAR" "$OUT" \
     2> "$OUT.snapshot.err"; then
  log "!!! snapshot.sh exited non-zero -- see $OUT.snapshot.err"
  tail -5 "$OUT.snapshot.err" | sed 's/^/    /'
  fail "snapshot.sh failed"
fi

# snapshot.sh wrote $OUT.meta.tsv (root/date/files); keep those lines
# (unlike consume-remote.sh's overwrite) and append the merge record.
{
  echo "pm	mrg-remote-two-container"
  echo "merged_count	$(wc -l < "$OUT.vdb-list.txt")"
  echo "far_root	$FAR"
  echo "client_uname	$(uname -sm)"
} >> "$OUT.meta.tsv"

log "done ($(wc -l < "$OUT.vdb-list.txt") merged packages)"
