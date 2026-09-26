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
#       <C1|C2|C3|C4|F1|F2|F3> /TEST/logs/<run>/<cell>/<mode>/<side>
#
# The cell command sequences mirror the S0 captures verbatim
# (logs/l32-s0-*/scripts/g1..g5*.sh); run-cell.sh only picks the binary
# and adds the snapshot. No product code, no diff semantics.
#
# The F cells (S2, S0 group 5) deliberately fail a merge: a disk-full
# tmpfs (F1), a truncated binpkg (F2) and a local binhost answering 500
# (F3). The in-container exit code is never the gate here (real Portage
# exits 143 on F1); every emergent rc and error-shape line is recorded
# under "$OUT.logs" for the triage, and the snapshot still compares the
# installed root/VDB the fault left behind.

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

# ---------------------------------------------------------------------------
# F1 -- disk-full / ENOSPC (S0 group 5a/5a2). The cell mounts a small
# dedicated tmpfs at /var/tmp/portage (16 MiB) after the preflight; 10 MiB
# of ballast makes the 64 MiB bigpkg payload hit ENOSPC deterministically
# in src_install, with no /home or host /tmp involvement.
# ---------------------------------------------------------------------------
cell_f1() {
  # The dedicated tmpfs is mounted HERE, after upgrade_portage/stage_overlay
  # (which must use the full container disk). Mounting it in the host
  # `podman run` would starve the portage-pin build in the same workdir.
  mkdir -p /var/tmp/portage
  if ! mount -t tmpfs -o "size=${L32_F1_TMPFS:-16m},mode=0755" tmpfs /var/tmp/portage; then
    log "!!! F1: cannot mount the dedicated tmpfs at /var/tmp/portage"
    exit 2
  fi
  log "F1: tmpfs ${L32_F1_TMPFS:-16m} mounted at /var/tmp/portage"
  df -h /var/tmp/portage > "$G/tmpfs-before.txt" 2>&1
  df -i /var/tmp/portage >> "$G/tmpfs-before.txt" 2>&1
  dd if=/dev/zero of=/var/tmp/portage/ballast bs=1M count=10 status=none 2> "$G/ballast.err"
  echo "ballast rc=$?" > "$G/ballast.rc"
  df -h /var/tmp/portage > "$G/tmpfs-ballast.txt" 2>&1
  du -sh /var/tmp/portage >> "$G/tmpfs-ballast.txt" 2>&1

  $EM --oneshot --usepkg=n --color=n l32/bigpkg > "$G/merge.log" 2>&1
  rc_of merge

  {
    echo "== df =="; df -h /var/tmp/portage; df -i /var/tmp/portage
    echo "== vdb l32 =="; ls -la /var/db/pkg/l32/ 2>&1
    echo "== -MERGING marker =="; ls -la /var/db/pkg/l32/-MERGING-* 2>&1
    echo "== partial image payload =="; ls -la /var/tmp/portage/l32/bigpkg-1.0/image/usr/share/l32/big/ 2>&1
    echo "== installed payload in / =="; ls -la /usr/share/l32/big/ 2>&1
    echo "== build temp =="; ls -la /var/tmp/portage/l32/bigpkg-1.0/temp/ 2>&1
  } > "$G/state-after.txt" 2>&1
  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/vdb-after.list"

  python3 - <<'PY' > "$G/mtimedb-resume-key.txt" 2>&1
import json
try:
    d = json.load(open('/var/cache/edb/mtimedb'))
    print("resume key present:", 'resume' in d)
    print(json.dumps(d.get('resume'), indent=1, sort_keys=True))
except Exception as e:
    print("ERR", e)
PY
  $EM --resume --pretend --color=n > "$G/resume-pretend.log" 2>&1
  rc_of resume-pretend
}

# ---------------------------------------------------------------------------
# F2 -- corrupt binary archive (S0 group 5b). Build a valid faultpkg
# binpkg, then -- S2 gap fix -- unmerge faultpkg so the corrupt-merge run
# starts from a root WITHOUT it (S0 left it installed, so "no partial vdb
# entry" was unprovable). The corrupt copy is truncated to half and merged
# with --usepkgonly so there is no ebuild fallback.
# ---------------------------------------------------------------------------
cell_f2() {
  local pkg=/var/tmp/l32-pkgdir corrupt=/var/tmp/l32-corrupt probe=/var/tmp/l32-format-probe
  rm -rf "$pkg" "$corrupt" "$probe"; mkdir -p "$pkg" "$probe"
  export FEATURES="-buildpkg -cgroup -observability -ipc-sandbox -network-sandbox -pid-sandbox"

  # S2 observation: name the binpkg each PM produces with the *unforced*
  # default BINPKG_FORMAT. Real make.globals says gpkg; this side-by-side
  # record is what shows a candidate whose default naming diverges.
  PKGDIR="$probe" $EM --oneshot --usepkg=n --color=n --buildpkg l32/faultpkg > "$G/format-probe-build.log" 2>&1
  echo "rc=$?" > "$G/format-probe-build.rc"
  find "$probe" -type f -name 'faultpkg-1.0*' -printf '%f\n' 2>/dev/null | sort > "$G/format-probe.txt"

  # Pin gpkg for the corrupt-archive scenario itself (real's own default):
  # an explicit value isolates the fault from the default-naming question.
  export PKGDIR="$pkg" BINPKG_FORMAT=gpkg

  $EM --oneshot --usepkg=n --color=n --buildpkg l32/faultpkg l32/dep-a > "$G/build.log" 2>&1
  rc_of build
  find "$PKGDIR" -name '*.gpkg.tar' | sort > "$G/binpkgs.list" 2>&1
  $EM --regen --quiet > "$G/regen.log" 2>&1
  echo "rc=$?" > "$G/regen.rc"

  $EM -C l32/faultpkg > "$G/unmerge-faultpkg.log" 2>&1
  rc_of unmerge-faultpkg
  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/vdb-before-corrupt.list"

  cp -a "$PKGDIR"/. "$corrupt"/ || true
  local good
  good=$(find "$corrupt" -name 'faultpkg-1.0*.gpkg.tar' | head -1)
  {
    echo "good archive: $good"; ls -l "$good" 2>&1
  } > "$G/corrupt-archive.txt" 2>&1
  local sz
  sz=$(stat -c %s "$good")
  truncate -s $((sz/2)) "$good"
  ls -l "$good" >> "$G/corrupt-archive.txt" 2>&1
  tar tf "$good" > "$G/corrupt-archive-tar.txt" 2>&1
  echo "tar rc=$?" >> "$G/corrupt-archive-tar.txt"

  export PKGDIR="$corrupt"
  $EM --oneshot --usepkgonly --color=n l32/faultpkg > "$G/corrupt-merge.log" 2>&1
  rc_of corrupt-merge
  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/corrupt-vdb.list"
  {
    echo "== vdb l32 =="; ls -la /var/db/pkg/l32/ 2>&1
    echo "== partial faultpkg vdb entry? ==";
    ls -d /var/db/pkg/l32/faultpkg-1.0 2>&1 || echo "none"
    echo "== -MERGING marker =="; ls -d /var/db/pkg/l32/-MERGING-* 2>&1 || echo "none"
    echo "== installed file =="; ls -la /usr/share/l32/faultpkg 2>&1
  } > "$G/corrupt-state.txt" 2>&1
  export PKGDIR="$pkg"
}

# ---------------------------------------------------------------------------
# F3 -- local binhost answering HTTP 500 (S0 group 5c). A python stub on
# 127.0.0.1:18765 returns 500 to every GET/HEAD; binrepos.conf declares
# [l32-500] against it. F3a: a stale local PKGDIR (faultpkg removed) must
# abort. F3b -- S2 gap fix -- an empty PKGDIR must fall back to the ebuild
# and complete on this free-disk root (S0 died ENOSPC, rc 143).
# ---------------------------------------------------------------------------
cell_f3() {
  local pkg=/var/tmp/l32-pkgdir nopkg=/var/tmp/l32-nopkg empty=/var/tmp/l32-empty-pkgdir
  rm -rf "$pkg" "$nopkg" "$empty"; mkdir -p "$pkg" "$nopkg" "$empty"
  export PKGDIR="$pkg" BINPKG_FORMAT=gpkg
  export FEATURES="-buildpkg -cgroup -observability -ipc-sandbox -network-sandbox -pid-sandbox"

  $EM --oneshot --usepkg=n --color=n --buildpkg l32/faultpkg l32/dep-a > "$G/build.log" 2>&1
  rc_of build
  $EM --regen --quiet > "$G/regen.log" 2>&1
  echo "rc=$?" > "$G/regen.rc"
  cp -a "$pkg"/. "$nopkg"/ || true
  find "$nopkg" -name 'faultpkg*' -delete 2>/dev/null || true
  $EM -C l32/faultpkg > "$G/unmerge-faultpkg.log" 2>&1
  rc_of unmerge-faultpkg

  cat > /var/tmp/l32-http-500.py <<'PY'
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(500); self.end_headers(); self.wfile.write(b"stub 500\n")
    def do_HEAD(self):
        self.send_response(500); self.end_headers()
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 18765), H) as s:
    s.serve_forever()
PY
  python3 /var/tmp/l32-http-500.py > "$G/binhost-stub.log" 2>&1 &
  local spid=$!
  sleep 1
  # Hermetic: the image pre-seeds a network binrepo ([gentoo] at
  # distfiles.gentoo.org) plus a cached local index. Drop both so the
  # ONLY binhost in play is the local 500 stub -- no side may reach the
  # network (the cached [gentoo] index otherwise masks the fault).
  rm -f /etc/portage/binrepos.conf/*.conf
  rm -rf /var/cache/edb/binhost /var/cache/binhost /var/cache/l32-binhost
  mkdir -p /etc/portage/binrepos.conf
  cat > /etc/portage/binrepos.conf/l32.conf <<'EOF'
[l32-500]
priority = 50
sync-uri = http://127.0.0.1:18765
location = /var/cache/l32-binhost
verify-signature = false
EOF

  # F3a: stale local index -> portage selects a binary that is not there.
  export PKGDIR="$nopkg"
  $EM --oneshot -k --getbinpkg --color=n l32/faultpkg > "$G/binhost-merge.log" 2>&1
  rc_of binhost-merge
  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/binhost-vdb.list"
  {
    echo "== binrepos.conf =="; cat /etc/portage/binrepos.conf/l32.conf
    echo "== vdb l32 =="; ls -la /var/db/pkg/l32/ 2>&1
    echo "== installed =="; ls -la /usr/share/l32/faultpkg 2>&1
  } > "$G/binhost-state.txt" 2>&1

  # F3b: no local binpkg at all -> source fallback must complete here.
  export PKGDIR="$empty"
  $EM --oneshot -k --getbinpkg --color=n l32/faultpkg > "$G/binhost-fallback.log" 2>&1
  rc_of binhost-fallback
  find /var/db/pkg/l32 -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort > "$G/binhost-fallback-vdb.list"
  {
    echo "== vdb l32 =="; ls -la /var/db/pkg/l32/ 2>&1
    echo "== installed file =="; ls -la /usr/share/l32/faultpkg 2>&1
    echo "== did it build from source? =="; grep -E '^>>> Emerging \(|^>>> Emerging binary' "$G/binhost-fallback.log" 2>&1
  } > "$G/binhost-fallback-state.txt" 2>&1
  kill "$spid" 2>/dev/null || true
  export PKGDIR="$pkg"
}

case $L32_CELL in
  C1) cell_c1 ;;
  C2) cell_c2 ;;
  C3) cell_c3 ;;
  C4) cell_c4 ;;
  F1) cell_f1 ;;
  F2) cell_f2 ;;
  F3) cell_f3 ;;
  *) echo "unknown cell $L32_CELL" >&2; exit 2 ;;
esac

if ! snapshot_cell "$OUT"; then
  log "!!! snapshot failed"
  exit 2
fi
log "done cell=$L32_CELL pm=$L32_PM"
exit 0
