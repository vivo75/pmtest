#!/bin/bash
# ref-build-merge-snapshot.sh -- #326 Z close-out, leg (c) reference side.
# Real Portage builds <atomlist> from source in the NORMAL image (the l1
# build path: layers/l1/build.sh's FEATURES/BINPKG_FORMAT shape), then
# re-merges --usepkgonly, then rebuilds with BINPKG_FORMAT=xpak and
# re-merges (the nopy guest's step3 shape), then snapshots the merged
# set exactly like nopy-build.sh NOPY_SNAPSHOT=1 does -- so the host
# can diff the two sides with compare/normalize.py + compare/diff.py
# (strict, existing allowlist) and pair the two PKGDIRs' gpkgs with
# compare/gpkg_diff.py.
#
# Runs in ONE throwaway container (host: run/z326-closeout.sh):
#   podman run ... IMAGE /TEST/layers/z326/ref-build-merge-snapshot.sh \
#       /TEST/atomlists/z326-nopy.txt /TEST/logs/<run>/ref-nopy
#
# Env:
#   PKGDIR            (required) binpkg output dir, a rw mount -- the
#                     gpkgs survive here for gpkg_diff (the portuale
#                     side's gpkgs come from the nopy run's artifacts/).
#   DISTDIR           distfiles cache mount (like nopy-build).
#   Z326_JOBS         MAKEOPTS -j (default 1, the l1-build value).
#   Z326_REINSTALL=1  pass --reinstall-atoms (atoms already installed
#                     at the resolved version, e.g. the glibc+bash gate).
#   L1_PORTAGE_PIN / L1_SKIP_PORTAGE_UPGRADE (l1-build.sh names; the
#                     image ships the pin baked in, so the upgrade is a
#                     no-op check).
#
# Writes <out>.{files,mtimes,vdb.tar,meta}.tsv (via the shared
# merged-snapshot-lib.sh) plus installed-{before,after}.txt,
# merged-cpvs.txt, paths.txt, step1-build-gpkg.log,
# step2-usepkgonly.log, step3-build-xpak.log next to the prefix's directory.

set -u
ATOMLIST=${1:?atom list path}
OUT=${2:?output prefix}
PIN=${L1_PORTAGE_PIN:-3.0.82.2}
JOBS=${Z326_JOBS:-1}
: "${PKGDIR:?PKGDIR must be set (a rw mount)}"

export PORTAGE_CONFIGROOT=/ ROOT=/ PORTAGE_RUNNING_ROOT=/
export LC_ALL=C.UTF-8 TZ=UTC
export EMERGE_DEFAULT_OPTS=""
export MAKEOPTS="-j${JOBS}"
# l1-build.sh's FEATURES, minus buildpkg handling: buildpkg is added per
# command below (prefix form, like the nopy guest) so the step2 merge
# runs on the image FEATURES, exactly as the portuale side does.
export PKGDIR
umask 022
mkdir -p "$(dirname "$OUT")" "$PKGDIR"

log() { printf '[z326-ref %s] %s\n' "$(basename "$OUT")" "$*"; }

# The porttest synthetic overlay, live-mounted ro by the orchestrator
# (same as l1/build.sh) -- staged only for `porttest/` atoms.
if [ -d /porttest-overlay ] && grep -q '^porttest/' "$ATOMLIST"; then
  rm -rf /var/db/repos/porttest
  cp -a /porttest-overlay /var/db/repos/porttest
  cat > /etc/portage/repos.conf/porttest.conf <<-EOF
	[porttest]
	location = /var/db/repos/porttest
	masters = gentoo
	auto-sync = no
	EOF
  log "porttest overlay staged at /var/db/repos/porttest"
fi

# Belt and braces like the other layers (the image bakes the pin in, so
# this prints the version and moves on).
if [ "${L1_SKIP_PORTAGE_UPGRADE:-0}" != 1 ]; then
  cur=$(/usr/sbin/emerge --version 2>/dev/null | sed -n 's/^Portage \([0-9.]*\).*/\1/p')
  if [ "$cur" != "$PIN" ]; then
    log "upgrading portage $cur -> $PIN (oneshot, ~amd64 for that one atom only)"
    ACCEPT_KEYWORDS="~amd64" /usr/sbin/emerge -q -1 --usepkg=n "=sys-apps/portage-$PIN" \
      || { log "!!! portage upgrade failed"; exit 1; }
  fi
fi
/usr/sbin/emerge --version | head -1

atoms=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}; line=$(printf '%s' "$line" | tr -d '[:space:]')
  [ -n "$line" ] && atoms+=("$line")
done < "$ATOMLIST"
log "reference-building ${#atoms[@]} atoms (+ deps) with real Portage, MAKEOPTS=$MAKEOPTS"

REINSTALL=()
if [ "${Z326_REINSTALL:-0}" = 1 ]; then
  REINSTALL=(--reinstall-atoms "${atoms[*]}")
fi

if [ -d /var/db/pkg ]; then
  ( cd /var/db/pkg && ls -d */*/ 2>/dev/null | sed 's:/$::' ) \
    | LC_ALL=C sort > "$(dirname "$OUT")/installed-before.txt" || true
else
  : > "$(dirname "$OUT")/installed-before.txt"
fi

# Harness-env hygiene (see run/nopy-build.sh): the -e knobs leak into
# every saved phase environment, so consume them into shell-locals and
# unset before emerging. (PKGDIR/DISTDIR/GENTOO_MIRRORS stay exported
# with identical values on both sides; the filter strips them anyway.)
unset Z326_JOBS Z326_REINSTALL L1_SKIP_PORTAGE_UPGRADE

# Step 1: from-source build+merge (l1-build.sh shape: --deep --usepkg=n
# so nothing comes from a remote binhost; --oneshot keeps @world
# untouched). FEATURES/BINPKG_FORMAT are prefix-form and byte-identical
# to the nopy guest's step1 (FEATURES is recorded into binpkg metadata
# and the vdb, so any difference here would diff as noise -- see the
# Z findings note), except the ref adds nothing and disables nothing.
log "step1: emerge --buildpkg (gpkg)"
set +e
BINPKG_FORMAT=gpkg FEATURES="buildpkg -sign noclean" \
  /usr/sbin/emerge --oneshot --deep --usepkg=n -v --color=n --quiet-build=y \
    "${REINSTALL[@]}" "${atoms[@]}" > "$OUT.step1-build-gpkg.log" 2>&1
rc1=$?
set -e
log "step1 rc=$rc1"
/usr/sbin/emaint --fix binhost 2>/dev/null || /usr/sbin/emerge --regen --quiet 2>/dev/null || true

# Step 2: --usepkgonly re-merge of the same atoms from this PKGDIR
# (mirrors the nopy guest's step2, which re-merges what step1 built).
rc2=0
if [ "$rc1" = 0 ]; then
  log "step2: emerge --usepkgonly"
  set +e
  /usr/sbin/emerge --oneshot -v --color=n --usepkgonly \
    "${REINSTALL[@]}" "${atoms[@]}" > "$OUT.step2-usepkgonly.log" 2>&1
  rc2=$?
  set -e
  log "step2 rc=$rc2"
  if grep -qE '^>>> Emerging \(' "$OUT.step2-usepkgonly.log"; then
    log "!!! step2 built from source -- PKGDIR was incomplete; reference parity is invalid"
    rc2=2
  fi
fi

# Step 3: the xpak twin of step 1 (mirrors the nopy guest's step3,
# which rebuilds every atom with BINPKG_FORMAT=xpak and re-merges).
# The snapshots both sides take therefore reflect the same
# last-touch format; without this the two vdb `environment` files
# would differ by BINPKG_FORMAT alone.
log "step3: emerge --buildpkg (xpak)"
rc3=0
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then
  set +e
  BINPKG_FORMAT=xpak FEATURES="buildpkg -sign noclean" \
    /usr/sbin/emerge --oneshot --deep --usepkg=n -v --color=n --quiet-build=y \
      "${REINSTALL[@]}" "${atoms[@]}" > "$OUT.step3-build-xpak.log" 2>&1
  rc3=$?
  set -e
  log "step3 rc=$rc3"
fi
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ]; then
  # shellcheck disable=SC1091  # in-container path
  . /TEST/layers/z326/merged-snapshot-lib.sh
  # The lib reads <outdir>/installed-before.txt: ours lives next to
  # the prefix -- move it into place via a scratch outdir sibling.
  snapdir="$(dirname "$OUT")"
  z326_snapshot_merged_set "$snapdir" "$OUT" "${atoms[@]}" || { log "!!! snapshot failed"; exit 1; }
  # Rename the lib's fixed output names to the <out>.* prefix shape the
  # host expects (installed-after is per-side provenance, keep both).
  for f in installed-after merged-cpvs paths; do
    mv -f "$snapdir/$f.txt" "$OUT.$f.txt"
  done
  mv -f "$snapdir/installed-before.txt" "$OUT.installed-before.txt"
  [ -f "$snapdir/snapshot.err" ] && mv -f "$snapdir/snapshot.err" "$OUT.snapshot.err"
fi

log "done (step1=$rc1 step2=$rc2 step3=$rc3)"
[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ]
