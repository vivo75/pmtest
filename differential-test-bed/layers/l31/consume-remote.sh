#!/bin/bash
# L31 -- candidate side for the remote-merge bed: merge the $PKGDIR gpkg
# set through `mrg --remote-*` over a loopback sshd into a far ROOT inside
# this same throwaway container (the R9 hermetic far machine: pmtest's
# `loopback_sshd` fixture shape + the differential-test-bed container ROOT),
# then snapshot the far $ROOT + vdb with the *same* compare/ helpers the
# real Portage side uses -- so the host diffs them with no new semantics.
#
# S1 settled l4.md's open topology question as the second option there:
# the sshd lives *inside* the container, the mrg client runs as the same
# root, and FAR is the container ROOT (`/`). That matches Capture A's
# owner rows (`root:root`, shared parents `bin:bin`) instead of inventing
# a fresh-tree owner artefact, so the candidate diff is merge semantics,
# not harness noise.
#
# Usage (from the host orchestrator):
#   podman run ... IMAGE /TEST/layers/l31/consume-remote.sh \
#       /TEST/atomlists/l31-s0.txt /TEST/logs/<run>/candidate/mrg /
#
# Env:
#   PKGDIR   (required) the ro-mounted gpkg dir built by layers/l1/build.sh
#   MRG      mrg binary (default /usr/local/bin/mrg, mounted by run/lib.sh)
#
# Everything this script does is harness plumbing; the merge itself is the
# product under test. The host records mrg's per-atom rc; none of it is
# triaged in S1.

set -u
ATOMLIST=${1:?atom list}
OUT=${2:?out prefix}
FAR=${3:?far root}
: "${PKGDIR:?PKGDIR must be set (a ro mount)}"
MRG=${MRG:-/usr/local/bin/mrg}

export PORTAGE_CONFIGROOT=/ ROOT=/ PORTAGE_RUNNING_ROOT=/
export LC_ALL=C.UTF-8 TZ=UTC
export PKGDIR
export EMERGE_DEFAULT_OPTS=""
umask 022

log() { printf '[l31-remote] %s\n' "$*"; }
mkdir -p "$(dirname "$OUT")" "$FAR/var/db/pkg"

# --- same staging as layers/l1/consume.sh (porttest repo, no binhost) ----
rm -f /etc/portage/binrepos.conf/gentoo.conf
if [ -d /porttest-overlay ] && grep -q '^porttest/' "$ATOMLIST"; then
  rm -rf /var/db/repos/porttest
  cp -a /porttest-overlay /var/db/repos/porttest
  cat > /etc/portage/repos.conf/porttest.conf <<-EOF
	[porttest]
	location = /var/db/repos/porttest
	masters = gentoo
	auto-sync = no
	EOF
fi

# --- sshd/ssh hygiene (both are harness bugs, not product) --------------
# sshd refuses to start without a root-owned private-separation dir; the
# image ships an ssh_config.d symlink whose target is 0777, which makes
# every ssh invocation abort with "Bad owner or permissions".
mkdir -p /var/empty /run/sshd
chown root:root /var/empty /run/sshd
chmod 755 /var/empty /run/sshd
rm -f /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf
chown -R root:root /etc/ssh 2>/dev/null || true
chmod 644 /etc/ssh/ssh_config 2>/dev/null || true

BASE=$(mktemp -d "${TMPDIR:-/tmp}/l31-remote.XXXXXX")
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

ssh-keygen -t ed25519 -N '' -f "$BASE/client" -q || exit 2
ssh-keygen -t ed25519 -N '' -f "$BASE/host" -q || exit 2
cp "$BASE/client.pub" "$BASE/auth"
cat > "$BASE/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $BASE/host
PidFile $BASE/pid
AuthorizedKeysFile $BASE/auth
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin yes
EOF

/usr/sbin/sshd -f "$BASE/sshd_config" -E "$BASE/sshd.log"
probe_ok=0
for _ in $(seq 1 75); do
  if ssh -p "$PORT" -i "$BASE/client" -o BatchMode=yes \
       -o StrictHostKeyChecking=accept-new \
       -o "UserKnownHostsFile=$BASE/probe_known_hosts" \
       root@127.0.0.1 true >/dev/null 2>&1; then
    probe_ok=1
    break
  fi
  sleep 0.2
done
if [ "$probe_ok" != 1 ]; then
  log "!!! loopback sshd never accepted a connection -- see $BASE/sshd.log"
  tail -5 "$BASE/sshd.log" 2>/dev/null | sed 's/^/    /'
  [ -f "$BASE/pid" ] && kill "$(cat "$BASE/pid")" 2>/dev/null
  exit 2
fi
log "loopback sshd on 127.0.0.1:$PORT (far ROOT=$FAR)"

atoms=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}; line=$(printf '%s' "$line" | tr -d '[:space:]')
  [ -n "$line" ] && atoms+=("$line")
done < "$ATOMLIST"
[ ${#atoms[@]} -gt 0 ] || { log "!!! empty atom list"; exit 2; }

# --- one mrg --remote-binpkg per cell ------------------------------------
# installed-cpv before/after, exactly like layers/l1/consume.sh: the vdb
# tar and path list must carry only the packages this run merged, never the
# container's pre-existing vdb (FAR=/ is a full system).
installed_cpvs() { ( cd "$FAR/var/db/pkg" && ls -d */*/ 2>/dev/null | sed 's:/$::' ) | LC_ALL=C sort; }
installed_cpvs > "$OUT.installed-before.txt"

: > "$OUT.mrg-rcs.tsv"
worst=0
for atom in "${atoms[@]}"; do
  cat=${atom%%/*}; pkg=${atom#*/}
  gpkg=$(ls -1 "$PKGDIR/$cat/$pkg"/*.gpkg.tar 2>/dev/null | sort -V | tail -1)
  flat=${atom//\//_}
  if [ -z "$gpkg" ]; then
    log "!!! no gpkg for $atom under $PKGDIR/$cat/$pkg"
    printf '%s\t2\n' "$atom" >> "$OUT.mrg-rcs.tsv"
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  log "mrg --remote-binpkg $atom  ($gpkg)"
  HOME="$BASE" "$MRG" \
    --remote-hostname 127.0.0.1 \
    --remote-port "$PORT" \
    --remote-key-file "$BASE/client" \
    --remote-user root \
    --remote-ssh-args="-o UserKnownHostsFile=$BASE/known_hosts" \
    --remote-root "$FAR" \
    --remote-workdir "$BASE/work" \
    --remote-binpkg "$gpkg" \
    > "$OUT.$flat.stdout.txt" 2> "$OUT.$flat.stderr.txt"
  rc=$?
  echo "$rc" > "$OUT.$flat.rc.txt"
  printf '%s\t%s\n' "$atom" "$rc" >> "$OUT.mrg-rcs.tsv"
  [ "$rc" -gt "$worst" ] && worst=$rc
  log "$atom: mrg rc=$rc"
done

# --- snapshot the far ROOT exactly like the real side --------------------
installed_cpvs > "$OUT.installed-after.txt"
comm -13 "$OUT.installed-before.txt" "$OUT.installed-after.txt" > "$OUT.vdb-list.txt"

{
  while IFS= read -r cpv; do
    [ -n "$cpv" ] || continue
    d="$FAR/var/db/pkg/$cpv"
    [ -f "$d/CONTENTS" ] \
      && awk '$1=="obj"||$1=="sym"||$1=="dir" {print $2}' "$d/CONTENTS"
  done < "$OUT.vdb-list.txt"
  # CONFIG_PROTECT divert files, mirroring layers/l1/consume.sh exactly:
  # real Portage writes `._cfg????_*` siblings under a protected path, and
  # without this a future cell whose merge diverts a config file would
  # compare those rows as MISSING. `${FAR%/}/etc` keeps a leading single
  # slash for the `/` far root this bed uses (FAR is ROOT-relative input,
  # like the CONTENTS paths and the fixed tail below).
  find "${FAR%/}/etc" -name '._cfg????_*' 2>/dev/null
  # mirrors layers/l1/consume.sh's fixed tail; paths absent in the far ROOT
  # are skipped by snapshot.sh, so candidate-only MISSING rows are honest.
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
fi

{
  echo "pm	mrg-remote"
  echo "merge_rc	$worst"
  echo "merged_count	$(wc -l < "$OUT.vdb-list.txt")"
  echo "portage_version	$(/usr/sbin/emerge --version 2>/dev/null | head -1)"
  echo "far_root	$FAR"
} > "$OUT.meta.tsv"

[ -f "$BASE/pid" ] && kill "$(cat "$BASE/pid")" 2>/dev/null
log "done (worst mrg rc=$worst; candidate diffs are for S2, not triaged here)"
# Exit the worst per-atom `mrg` rc (0 merged, 1 unit-failed, 2 setup error)
# so the container rc the host records is meaningful. Per-atom rcs stay in
# $OUT.mrg-rcs.tsv. (S1 review: the old unconditional `exit 0` made the
# host's `mrg_rc` label always read 0.)
exit "$worst"
