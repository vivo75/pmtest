#!/bin/bash
# L5 hostile-fault cell (backlog #514) -- in-container half.
#
# For every shape in the atom list: craft a hostile gpkg (a real
# `--buildpkgonly` base with rewritten inner tars, via `craft.py`), then
# merge it with BOTH Portage's `emerge` (control) and portuale
# (candidate) under the same staged hermetic environment, and compare the
# exit codes. Layout:
#
#   <outdir>/<shape>.portage.{out,rc}    control merge output + rc
#   <outdir>/<shape>.portuale.{out,rc}   candidate merge output + rc
#   <outdir>/<shape>.roots.txt           resulting ROOT listings + leak check
#   <outdir>/meta.tsv                    shape \t portage_rc \t portuale_rc
#
# Expected pairs live in `expected_rc` below: every S1 shape refuses (or
# merges) identically on both managers; the two #514 GNU-tar-boundary
# shapes (`temp-root-member`, `dotdot-hardlink`) are Portage rc 0 /
# portuale rc 1 by design (Python `tarfile` extracts what GNU tar 1.35
# truncates -- see `LLM/evidence/2026-10-23-500-501/514-oracle-matrix.txt`
# in portuale). Any other pair is UNEXPLAINED and fails the cell.
#
# Usage: in-container.sh <atomlist> <outdir>
# Env: PORTAGE_EMERGE (default /usr/sbin/emerge),
#      PORTUALE_EMERGE (default /usr/local/bin/emerge).

set -u

ATOMLIST=${1:?atom list path}
OUTDIR=${2:?output dir}
PORTAGE_EMERGE=${PORTAGE_EMERGE:-/usr/sbin/emerge}
PORTUALE_EMERGE=${PORTUALE_EMERGE:-/usr/local/bin/emerge}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

export LC_ALL=C.UTF-8 TZ=UTC
umask 022

# Portage pin: the control must be the 3.0.83 the oracles were captured on.
PIN=3.0.83
cur=$("$PORTAGE_EMERGE" --version 2>/dev/null | sed -n 's/^Portage \([0-9.]*\).*/\1/p')
if [ "$cur" != "$PIN" ]; then
  echo "!!! control Portage is $cur, want $PIN" >&2
  exit 2
fi

# The candidate must be the registry build of the current tree (never the
# image's copy): the run wrapper bind-mounts the PM bin dir over
# /usr/local/bin. (`--version` is not implemented yet, backlog #552, so
# probe with `--help`.)
"$PORTUALE_EMERGE" --help >/dev/null 2>&1 \
  || { echo "!!! candidate $PORTUALE_EMERGE missing" >&2; exit 2; }

mkdir -p "$OUTDIR"
: > "$OUTDIR/meta.tsv"
: > "$OUTDIR/run.log"

log() { printf '%s\n' "$*" | tee -a "$OUTDIR/run.log"; }

log "staging the fixture tree"
/TEST/layers/l0-fixture-oracle/stage.sh /tmp/l5-stage >> "$OUTDIR/run.log" 2>&1 \
  || { log "!!! staging failed"; exit 2; }
FX=/tmp/l5-stage/fixtures
# Like the ev500 S1 harness: do not trust a `Packages` index, scan the
# PKGDIRs instead (the default `pkgdir-index-trusted` would need an
# `emaint` index per shape dir, and the crafted shapes are the index).
# A second `FEATURES=` line would replace the first (bash sourcing), so
# extend the existing assignment in place.
sed -i 's/-userpriv"/-userpriv -pkgdir-index-trusted"/' "$FX/etc/portage/make.conf"

# One hermetic base gpkg, built by the candidate from the staged tree.
export ROOT=/tmp/l5-root0 PORTAGE_CONFIGROOT=$FX PORTAGE_TMPDIR=/tmp/l5-tmp0
export PKGDIR=/tmp/l5-pkgdir0 PORTAGE_OVERRIDE_EPREFIX=$ROOT
export PORTAGE_RUNNING_ROOT=$FX DISTDIR=$FX/distfiles
rm -rf "$ROOT" "$PORTAGE_TMPDIR" "$PKGDIR"
mkdir -p "$ROOT" "$PORTAGE_TMPDIR" "$PKGDIR" "$ROOT/var"
cp -r "$FX/var/." "$ROOT/var/"
log "building the base gpkg with the candidate"
"$PORTUALE_EMERGE" --buildpkgonly dev-libs/packagepkg >> "$OUTDIR/run.log" 2>&1 \
  || { log "!!! base build failed"; exit 2; }
BASE=$PKGDIR/dev-libs/packagepkg-1.0.gpkg.tar
[ -f "$BASE" ] || { log "!!! base gpkg missing"; exit 2; }

log "crafting hostile archives"
rm -rf /tmp/l5-pkgdirs && mkdir -p /tmp/l5-pkgdirs
python3 "$HERE/craft.py" "$BASE" /tmp/l5-pkgdirs >> "$OUTDIR/run.log" 2>&1 \
  || { log "!!! crafting failed"; exit 2; }

# shape -> "portage_rc portuale_rc"
expected_rc() {
  case $1 in
    # The two #514 GNU-tar-boundary shapes: Portage merges (rc 0) and the
    # candidate reports tar's truncation (rc 1).
    temp-root-member) echo "0 1" ;;
    # The hard-link-of-symlink shape fails on BOTH managers (rc 1), for
    # different reasons: the control trips over CPython's stream
    # bookkeeping after a hard link member (portage-quirks.md Q10,
    # `seeking backwards is not allowed`), the candidate over GNU tar's
    # `..`-symlink deferral. Composed rc parity, texts differ by design.
    dotdot-hardlink) echo "1 1" ;;
    # Every other shape agrees: the two accept shapes merge, the rest refuse.
    temp-root-bare | control-benign | control-contained-symlink-parent | relocated-in-place)
      echo "0 0" ;;
    *) echo "1 1" ;;
  esac
}

unexplained=0
while IFS= read -r shape || [ -n "$shape" ]; do
  case $shape in '' | \#*) continue;; esac
  log "--- $shape"
  for pm in portage portuale; do
    if [ "$pm" = portage ]; then
      EM=$PORTAGE_EMERGE
      # No PORTAGE_OVERRIDE_EPREFIX: it derails the control's SYSROOT
      # handling (`KeyError: PKGDIR` in `create_trees`).
      OVERRIDE_EPREFIX=/
    else
      EM=$PORTUALE_EMERGE
      # A binrepo without `location` downloads under
      # `<EPREFIX>/var/cache/binhost`.
      OVERRIDE_EPREFIX=$root
    fi
    root=/tmp/l5-root-$pm-$shape
    rm -rf "$root" /tmp/l5-tmp-$pm-"$shape"
    mkdir -p "$root" /tmp/l5-tmp-$pm-"$shape" "$root/var"
    cp -r "$FX/var/." "$root/var/"
    ROOT=$root PORTAGE_CONFIGROOT=$FX PORTAGE_TMPDIR=/tmp/l5-tmp-$pm-$shape \
      PKGDIR=/tmp/l5-pkgdirs/$shape PORTAGE_OVERRIDE_EPREFIX=$OVERRIDE_EPREFIX \
      PORTAGE_RUNNING_ROOT=$FX DISTDIR=$FX/distfiles \
      "$EM" -1 --usepkgonly --nodeps --color=n dev-libs/packagepkg \
      > "$OUTDIR/$shape.$pm.out" 2>&1
    # shellcheck disable=SC2034
    rc=$?
    echo "$rc" > "$OUTDIR/$shape.$pm.rc"
    {
      echo "== $pm ROOT =="; (cd "$root" && find . -mindepth 1 -not -path "./var/*" | sort | head -30)
      ls "$root/var/db/pkg/dev-libs/packagepkg-1.0" 2>&1
      echo "== leak =="
      ls -A /var/tmp/outside-x 2>/dev/null | wc -l
      ls -d /nonexistent-outside /outside /evil /etc/evil 2>&1 | head -4
    } >> "$OUTDIR/$shape.roots.txt" 2>&1
  done
  proot=$(cat "$OUTDIR/$shape.portage.rc"); pcand=$(cat "$OUTDIR/$shape.portuale.rc")
  printf '%s\t%s\t%s\n' "$shape" "$proot" "$pcand" >> "$OUTDIR/meta.tsv"
  # shellcheck disable=SC2086
  set -- $(expected_rc "$shape")
  if [ "$proot" != "$1" ] || [ "$pcand" != "$2" ]; then
    log "UNEXPLAINED $shape: got ($proot, $pcand), want ($1, $2)"
    unexplained=$((unexplained + 1))
  fi
done < "$ATOMLIST"

if [ "$unexplained" != 0 ]; then
  log "!!! $unexplained unexplained shape(s)"
  exit 1
fi
log "green: every shape matched its expected rc pair"
