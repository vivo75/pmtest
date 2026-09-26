#!/bin/bash
# L32 S1 -- in-container common setup for the life-cycle cells. Sourced by
# run-cell.sh; do not execute. Mirrors the S0 capture profile
# (logs/l32-s0-*/scripts/common.sh): the same pin, the same FEATURES
# overlay, the same C.UTF-8/TZ/ROOT environment, so the real-Portage
# reference side reproduces the S0 oracle.
#
# The fixture overlay is generated on the host (layers/l32/gen-overlay.sh,
# called by run/l32-lifecycle.sh) and bind-mounted read-only at
# /l32-overlay; stage_overlay copies the repo root into /var/db/repos/l32.

set -u

export LC_ALL=C.UTF-8 TZ=UTC
export PORTAGE_CONFIGROOT=/ ROOT=/ PORTAGE_RUNNING_ROOT=/
export EMERGE_DEFAULT_OPTS=""
export MAKEOPTS="${MAKEOPTS:--j2}"
# Keep the image default FEATURES (notably preserve-libs, config-protect,
# unmerge-orphans) but drop the bits this rootless container cannot honour
# (and the two values 3.0.82.2 still warns about). FEATURES is incremental.
export FEATURES="${FEATURES:-} -cgroup -observability -ipc-sandbox -network-sandbox -pid-sandbox"

PIN=${L32_PORTAGE_PIN:-3.0.82.2}

log() { printf '[l32-cell] %s\n' "$*"; }

upgrade_portage() {
  if [ "${L32_SKIP_PORTAGE_UPGRADE:-0}" = 1 ]; then
    log "L32_SKIP_PORTAGE_UPGRADE=1: keeping the image portage"
    /usr/sbin/emerge --version 2>/dev/null | head -1 | sed 's/^/[portage] /'
    return 0
  fi
  local cur
  cur=$(/usr/sbin/emerge --version 2>/dev/null | sed -n 's/^Portage \([0-9.]*\).*/\1/p')
  if [ "$cur" != "$PIN" ]; then
    log "upgrading portage $cur -> $PIN"
    ACCEPT_KEYWORDS="~amd64" /usr/sbin/emerge -q --oneshot --usepkg=n "=sys-apps/portage-$PIN" \
      || { log "!!! portage upgrade failed"; return 1; }
  fi
  /usr/sbin/emerge --version | head -1 | sed 's/^/[portage] /'
}

stage_overlay() {
  [ -d /l32-overlay/l32 ] || { log "!!! /l32-overlay/l32 missing"; return 1; }
  rm -rf /var/db/repos/l32
  cp -a /l32-overlay/l32 /var/db/repos/l32
  cat > /etc/portage/repos.conf/l32.conf <<'EOF'
[l32]
location = /var/db/repos/l32
masters = gentoo
auto-sync = no
priority = 30
EOF
  log "l32 overlay staged at /var/db/repos/l32"
}

# Snapshot the installed state the cell touched, using the same
# compare/snapshot.sh the L1+ beds use (no new diff semantics): every l32
# VDB entry, the fixture trees under /usr/share/l32 and /etc/l32, the
# soname libs, CONFIG_PROTECT siblings, the world/registry files and the
# env-update targets.
snapshot_cell() {  # <out-prefix>
  local out=$1 base paths vdbl
  mkdir -p "$(dirname "$out")"
  base=$(mktemp -d "${TMPDIR:-/tmp}/l32-snap.XXXXXX") || return 1
  paths="$base/paths.txt"; vdbl="$base/vdb.txt"
  : > "$vdbl"
  if [ -d /var/db/pkg/l32 ]; then
    ( cd /var/db/pkg/l32 && ls -d */ 2>/dev/null | sed 's:/$::' ) | LC_ALL=C sort > "$vdbl"
  fi
  {
    if [ -s "$vdbl" ]; then
      while IFS= read -r cp; do
        [ -f "/var/db/pkg/l32/$cp/CONTENTS" ] \
          && awk '$1=="obj"||$1=="sym"||$1=="dir" {print $2}' \
               "/var/db/pkg/l32/$cp/CONTENTS"
      done < "$vdbl"
    fi
    # Recurse the fixture trees so leftover-empty-dir behaviour is visible.
    printf '%s\n' /usr/share/l32/ /etc/l32/
    # The soname lib family + the consumer (glob expanded now: snapshot.sh
    # --paths takes literal paths, not globs).
    find /usr/lib64 /usr/lib /lib64 /lib -maxdepth 1 -name 'libl32soname*' 2>/dev/null
    find /usr/bin /usr/sbin /bin /sbin -maxdepth 1 -name 'sonameuser' 2>/dev/null
    # CONFIG_PROTECT divert siblings anywhere under /etc.
    find /etc -name '._cfg????_*' -o -name '_cfg*' 2>/dev/null
    # The same fixed tail layers/l1/consume.sh snapshots.
    printf '%s\n' \
      /var/lib/portage/world /var/lib/portage/config \
      /var/lib/portage/preserved_libs_registry \
      /etc/ld.so.cache /etc/ld.so.conf /etc/profile.env /etc/csh.env \
      /etc/environment /usr/share/info/dir
  } | LC_ALL=C sort -u > "$paths"

  log "snapshotting $(wc -l < "$paths") path entries + $(wc -l < "$vdbl") vdb dirs -> $out.*"
  if ! bash /TEST/compare/snapshot.sh \
       --paths "$paths" --vdb-list "$vdbl" / "$out" 2> "$out.snapshot.err"; then
    log "!!! snapshot.sh exited non-zero -- see $out.snapshot.err"
    tail -5 "$out.snapshot.err" 2>/dev/null | sed 's/^/    /'
    rm -rf "$base"
    return 1
  fi
  {
    echo "pm	${L32_PM:-unknown}"
    echo "cell	${L32_CELL:-unknown}"
    echo "portage_version	$(/usr/sbin/emerge --version 2>/dev/null | head -1)"
    [ -n "${L32_PM:-}" ] && [ "${L32_PM}" = portuale ] \
      && echo "portuale_bin	$(/usr/local/bin/emerge --help 2>&1 | head -1)"
    echo "installed_l32	$(wc -l < "$vdbl")"
  } > "$out.meta.tsv"
  rm -rf "$base"
  return 0
}
