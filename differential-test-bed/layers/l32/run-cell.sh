#!/bin/bash
# L32 S1 -- run ONE life-cycle cell with ONE package manager inside a
# throwaway container, then snapshot what it touched. The host
# orchestrator (run/l32-lifecycle.sh) runs it twice per cell:
#
#   control   -- portage on both sides (the 0-unexplained gate); and
#   candidate -- portage (reference) vs portuale (the real CLI under test).
#
# Usage (from the host orchestrator):
#   podman run ... IMAGE /TEST/layers/l32/run-cell.sh <portage|portuale> \
#       <C1|C2|C3|C4> /TEST/logs/<run>/<cell>/<mode>/<side>
#
# The cell command sequences mirror the S0 captures verbatim
# (logs/l32-s0-*/scripts/g1..g4-*.sh); run-cell.sh only picks the binary
# and adds the snapshot. No product code, no diff semantics.

set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/common.sh"

L32_PM=${1:?portage|portuale}
L32_CELL=${2:?C1|C2|C3|C4}
OUT=${3:?out prefix}
export L32_PM L32_CELL

case $L32_PM in
  portage)  EM=/usr/sbin/emerge ;;
  portuale) EM=/usr/local/bin/emerge ;;
  *) echo "PM must be portage or portuale" >&2; exit 2 ;;
esac
[ -x "$EM" ] || { log "!!! $EM is not executable"; exit 2; }

G="$OUT.logs"
mkdir -p "$G"
export TMPDIR=${TMPDIR:-/var/tmp}

if ! upgrade_portage; then
  log "!!! cannot establish the portage pin; aborting this side"
  exit 2
fi
if ! stage_overlay; then exit 2; fi

rc_of() { echo "$?" > "$G/$1.rc"; }

# ---------------------------------------------------------------------------
# C1 -- -C / --depclean diffs (S0 group 1)
# ---------------------------------------------------------------------------
cell_c1() {
  $EM -q --oneshot --usepkg=n --color=n l32/dep-b l32/dep-c >"$G/install.log" 2>&1
  rc_of install

  # world: every installed non-l32 cat/pkg plus the explicit fixture
  # consumers; dep-a stays out so dep-b's removal orphans it.
  python3 - <<'PY' > /var/lib/portage/world
import os, re
root = '/var/db/pkg'
out = []
for cat in sorted(os.listdir(root)):
    cd = os.path.join(root, cat)
    if not os.path.isdir(cd) or cat == 'l32':
        continue
    for pf in sorted(os.listdir(cd)):
        m = re.match(r'^(.*?)-(\d.*)$', pf)
        out.append(f"{cat}/{(m.group(1) if m else pf)}")
out += ["l32/dep-b", "l32/dep-c"]
print("\n".join(sorted(set(out))))
PY
  grep -n 'l32/' /var/lib/portage/world > "$G/world.l32-initial.txt" 2>&1
  wc -l /var/lib/portage/world > "$G/world.count"

  $EM -p --depclean --color=n >"$G/depclean-pretend-before.log" 2>&1
  rc_of depclean-pretend-before

  $EM -p -C l32/dep-b --color=n >"$G/unmerge-pretend-dep-b.log" 2>&1
  rc_of unmerge-pretend-dep-b
  $EM -C l32/dep-b --color=n >"$G/unmerge-actual-dep-b.log" 2>&1
  rc_of unmerge-actual-dep-b

  $EM -p --depclean --color=n >"$G/depclean-pretend-after.log" 2>&1
  rc_of depclean-pretend-after

  # Safety guard from S0: never let the actual depclean target non-l32 pkgs.
  local outside
  outside=$(grep -cE '^ (sys|dev|app|net|media|www|perl|acct|virtual|mail|games|x11|gnome|kde|dev-libs|dev-util|dev-python)/' \
              "$G/depclean-pretend-after.log" 2>/dev/null)
  echo "$outside" > "$G/depclean-pretend-after.outside-count"
  if [ "$outside" = 0 ]; then
    $EM --depclean --color=n >"$G/depclean-actual.log" 2>&1
    rc_of depclean-actual
    $EM -p --depclean --color=n >"$G/depclean-pretend-after-clean.log" 2>&1
    rc_of depclean-pretend-after-clean
  else
    echo "skipped: depclean pretend wants non-l32 removals ($outside)" > "$G/depclean-actual.log"
    echo "skipped" > "$G/depclean-actual.rc"
  fi

  $EM -C l32/dep-c --color=n >"$G/unmerge-actual-dep-c.log" 2>&1
  rc_of unmerge-actual-dep-c
}

# ---------------------------------------------------------------------------
# C2 -- soname bump -> preserved-libs (S0 group 2)
# ---------------------------------------------------------------------------
cell_c2() {
  $EM -q --oneshot --usepkg=n --color=n '=l32/sonamelib-1.0' >"$G/install-lib1.log" 2>&1
  rc_of install-lib1
  $EM -q --oneshot --usepkg=n --color=n l32/sonameuser >"$G/install-user.log" 2>&1
  rc_of install-user

  ls -l /usr/lib64/libl32soname.so* > "$G/libs-before.txt" 2>&1
  readelf -d /usr/bin/sonameuser > "$G/sonameuser-readelf-before.txt" 2>&1
  cp /var/lib/portage/preserved_libs_registry "$G/preserved_libs_registry-before.txt" 2>/dev/null

  $EM -u --oneshot --usepkg=n --color=n '=l32/sonamelib-2.0' >"$G/upgrade.log" 2>&1
  rc_of upgrade

  ls -li /usr/lib64/libl32soname.so* > "$G/libs-after.txt" 2>&1
  readelf -d /usr/bin/sonameuser > "$G/sonameuser-readelf-after.txt" 2>&1
  ldd /usr/bin/sonameuser > "$G/ldd-after.txt" 2>&1
  cp /var/lib/portage/preserved_libs_registry "$G/preserved_libs_registry-after.txt" 2>/dev/null

  $EM -p @preserved-rebuild --color=n >"$G/preserved-rebuild-pretend.log" 2>&1
  rc_of preserved-rebuild-pretend
  $EM @preserved-rebuild --color=n >"$G/preserved-rebuild-actual.log" 2>&1
  rc_of preserved-rebuild-actual

  readelf -d /usr/bin/sonameuser > "$G/sonameuser-readelf-after-rebuild.txt" 2>&1
  ls -li /usr/lib64/libl32soname.so* > "$G/libs-after-rebuild.txt" 2>&1
  cp /var/lib/portage/preserved_libs_registry "$G/preserved_libs_registry-after-rebuild.txt" 2>/dev/null
}

# ---------------------------------------------------------------------------
# C3 -- CONFIG_PROTECT, user-modified config (S0 group 3)
# ---------------------------------------------------------------------------
cell_c3() {
  $EM -q --oneshot --usepkg=n --color=n '=l32/protect-1.0' >"$G/install-v1.log" 2>&1
  rc_of install-v1
  echo "user=changed-by-admin" > /etc/l32/protect.conf
  cp /etc/l32/protect.conf "$G/protect-conf-user-edited.txt" 2>/dev/null

  $EM -u --oneshot --usepkg=n --color=n '=l32/protect-2.0' >"$G/upgrade.log" 2>&1
  rc_of upgrade

  {
    echo "== /etc/l32 after upgrade =="; ls -la /etc/l32/ 2>&1
    for f in /etc/l32/._cfg*; do [ -e "$f" ] && { echo "--- $f ---"; cat "$f"; }; done
    echo "== vdb protect-2.0 CONTENTS =="; cat /var/db/pkg/l32/protect-2.0/CONTENTS 2>&1
  } > "$G/state-after.txt" 2>&1
}

# ---------------------------------------------------------------------------
# C4 -- --resume after SIGKILL mid-merge (S0 group 4). The SIGKILL is wholly
# inside this throwaway container: the process group is killed and any
# /var/tmp/portage/l32/slow worker reap'd here, never on the host.
# ---------------------------------------------------------------------------
cell_c4() {
  cp /var/cache/edb/mtimedb "$G/mtimedb-before" 2>/dev/null
  setsid $EM --oneshot --usepkg=n --color=n l32/slow-a l32/slow-b l32/slow-c \
    > "$G/merge.log" 2>&1 &
  local spid=$!
  local i marker_seen=0
  for i in $(seq 1 120); do
    grep -q 'Installing (1 of 3)' "$G/merge.log" 2>/dev/null && break
    sleep 0.25
  done
  # S1 determinism: only kill once the `-MERGING-<pf>` marker exists (the
  # S0 g4 invariant), bounded so a PM that never writes one still gets
  # killed. pkg_preinst (gen-overlay) holds the merge open 4s for this.
  for i in $(seq 1 50); do
    ls -d /var/db/pkg/l32/-MERGING-slow-a-* >/dev/null 2>&1 && { marker_seen=1; break; }
    sleep 0.1
  done
  kill -9 -"$spid" 2>/dev/null
  pkill -9 -f '/var/tmp/portage/l32/slow' 2>/dev/null
  wait "$spid" 2>/dev/null
  echo "killed pid=$spid after 'Installing (1 of 3)' observed; merging_marker_seen=$marker_seen" > "$G/kill.txt"
  ps -ef | grep -E 'emerge|slow' | grep -v grep > "$G/ps-after-kill.txt" 2>&1

  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/vdb-after-kill.list"
  python3 - <<'PY' > "$G/mtimedb-resume-key.txt" 2>&1
import json
try:
    d = json.load(open('/var/cache/edb/mtimedb'))
    print("resume key present:", 'resume' in d)
    print("resume ===", json.dumps(d.get('resume'), indent=2, sort_keys=True))
except Exception as e:
    print("ERR", e)
PY

  $EM --resume --pretend --color=n > "$G/resume-pretend.log" 2>&1
  rc_of resume-pretend
  sleep 7   # let the killed slow-a child's own sleep(6) expire
  $EM --resume --color=n > "$G/resume-actual.log" 2>&1
  rc_of resume-actual
}

case $L32_CELL in
  C1) cell_c1 ;;
  C2) cell_c2 ;;
  C3) cell_c3 ;;
  C4) cell_c4 ;;
  *) echo "unknown cell $L32_CELL" >&2; exit 2 ;;
esac

if ! snapshot_cell "$OUT"; then
  log "!!! snapshot failed"
  exit 2
fi
log "done cell=$L32_CELL pm=$L32_PM"
exit 0
