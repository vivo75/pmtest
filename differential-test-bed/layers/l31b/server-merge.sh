#!/bin/bash
# L31b -- server side of the two-container remote-merge cell (portuale
# #326 S8, pmtest side): merge the $PKGDIR gpkg set through
# `mrg --remote-*` over ssh into the SEPARATE client container on the
# run's dedicated podman network. Runs INSIDE the server container (the
# normal bed image, with portuale and the repo/pkgcache as l31 has
# them), once per merge pass (the host runs it twice: the first pass
# installs the server binary on the client, the re-run must reuse it).
#
# This mirrors layers/l31/consume-remote.sh's per-atom loop cell for
# cell, except the far end is a hostname on the podman network instead
# of a loopback sshd in the same container:
#   - the same calling-env FEATURES as the reference side
#     (layers/l1/consume.sh), so the regenerated vdb env matches;
#   - the same porttest staging (binrepos.conf drop, overlay copy,
#     INSTALL_MASK in make.conf);
#   - one `mrg --remote-binpkg` per atom (the same trial path l31 uses
#     for the same atom list), with the per-atom stdout/stderr/rc kept
#     under $OUT for the host's install-bin assertions.
#
# Usage (from the host orchestrator):
#   podman run ... IMAGE /TEST/layers/l31b/server-merge.sh \
#       /TEST/atomlists/l31-s0.txt /TEST/logs/<run>/client <client-host> <pass>
#
# Env:
#   PKGDIR             (required) the ro-mounted gpkg dir
#   MRG                mrg binary (default /usr/local/bin/mrg, mounted by run/lib.sh)
#   L31B_KEY_FILE      client private key (default /keys/client, a ro mount)
#   L31B_KNOWN_HOSTS   writable known-hosts path (default /tmp/l31b-known_hosts)
#   L31B_SSH_USER      (default root)
#   L31B_SSH_PORT      (default 22)
#   L31B_WORKDIR       client workdir (default /var/tmp/portage-remote)
#
# Everything this script does is harness plumbing; the merge itself is
# the product under test. The host records mrg's per-atom rc; a non-zero
# worst rc is reported through the exit status (like consume-remote.sh)
# but never triaged here.

set -u
ATOMLIST=${1:?atom list}
OUT=${2:?out prefix}
CLIENT=${3:?client hostname}
PASS=${4:?pass tag (e.g. first|second)}
: "${PKGDIR:?PKGDIR must be set (a ro mount)}"
MRG=${MRG:-/usr/local/bin/mrg}
KEY_FILE=${L31B_KEY_FILE:-/keys/client}
KNOWN_HOSTS=${L31B_KNOWN_HOSTS:-/tmp/l31b-known_hosts}
SSH_USER=${L31B_SSH_USER:-root}
SSH_PORT=${L31B_SSH_PORT:-22}
WORKDIR=${L31B_WORKDIR:-/var/tmp/portage-remote}

export PORTAGE_CONFIGROOT=/ ROOT=/ PORTAGE_RUNNING_ROOT=/
export LC_ALL=C.UTF-8 TZ=UTC
# Same calling-env FEATURES as the reference side (layers/l1/consume.sh):
# real reads them from its calling environment, and mrg's server-side
# resolution does too, so both sides must start from the same value or
# the regenerated vdb env's FEATURES differs for bed reasons (#171).
export FEATURES="-buildpkg -cgroup -ccache -distcc -sign xattr filecaps"
export PKGDIR
export EMERGE_DEFAULT_OPTS=""
umask 022

log() { printf '[l31b-server-%s] %s\n' "$PASS" "$*"; }
mkdir -p "$(dirname "$OUT")"

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
  # Same INSTALL_MASK as the reference side (see layers/l1/consume.sh):
  # the porttest/installmask fixture ships files these patterns should
  # drop at merge.
  printf 'INSTALL_MASK="/usr/share/porttest/im/drop.txt /usr/share/porttest/im/*.log *.la"\n' \
    >> /etc/portage/make.conf
fi

# --- ssh-client hygiene (harness, not product) ---------------------------
# The image ships an ssh_config.d symlink whose target is 0777 plus
# bin-owned config files; either makes every ssh invocation abort with
# "Bad owner or permissions" (same block as consume-remote.sh).
rm -f /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf
chown -R root:root /etc/ssh 2>/dev/null || true
chmod 644 /etc/ssh/ssh_config 2>/dev/null || true
[ -f "$KEY_FILE" ] || { log "!!! key file not found: $KEY_FILE"; exit 2; }
touch "$KNOWN_HOSTS" 2>/dev/null || { log "!!! known-hosts not writable: $KNOWN_HOSTS"; exit 2; }

# Multiplex/control sockets and any ssh default state stay in a throwaway
# HOME (mirrors consume-remote.sh's $BASE), never in the image's /root.
HOME=$(mktemp -d "${TMPDIR:-/tmp}/l31b-server.XXXXXX") || exit 2
export HOME

atoms=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}; line=$(printf '%s' "$line" | tr -d '[:space:]')
  [ -n "$line" ] && atoms+=("$line")
done < "$ATOMLIST"
[ ${#atoms[@]} -gt 0 ] || { log "!!! empty atom list"; exit 2; }
log "merging ${#atoms[@]} atoms into client $CLIENT (pass $PASS)"

# --- one mrg --remote-binpkg per atom (the l31 trial path) ---------------
: > "$OUT.$PASS.mrg-rcs.tsv"
worst=0
for atom in "${atoms[@]}"; do
  cat=${atom%%/*}; pkg=${atom#*/}
  # shellcheck disable=SC2012  # `ls | sort -V | tail -1` is the bed-wide idiom (consume-remote.sh)
  gpkg=$(ls -1 "$PKGDIR/$cat/$pkg"/*.gpkg.tar 2>/dev/null | sort -V | tail -1)
  flat=${atom//\//_}
  if [ -z "$gpkg" ]; then
    log "!!! no gpkg for $atom under $PKGDIR/$cat/$pkg"
    printf '%s\t2\n' "$atom" >> "$OUT.$PASS.mrg-rcs.tsv"
    [ "$worst" -lt 2 ] && worst=2
    continue
  fi
  log "mrg --remote-binpkg $atom  ($gpkg)"
  "$MRG" \
    --remote-hostname "$CLIENT" \
    --remote-port "$SSH_PORT" \
    --remote-key-file "$KEY_FILE" \
    --remote-user "$SSH_USER" \
    --remote-ssh-args="-o UserKnownHostsFile=$KNOWN_HOSTS" \
    --remote-root / \
    --remote-workdir "$WORKDIR" \
    --remote-binpkg "$gpkg" \
    > "$OUT.$flat.$PASS.stdout.txt" 2> "$OUT.$flat.$PASS.stderr.txt"
  rc=$?
  echo "$rc" > "$OUT.$flat.$PASS.rc.txt"
  printf '%s\t%s\n' "$atom" "$rc" >> "$OUT.$PASS.mrg-rcs.tsv"
  [ "$rc" -gt "$worst" ] && worst=$rc
  log "$atom: mrg rc=$rc"
done

echo "$worst" > "$OUT.$PASS.merge_rc"
log "done (pass $PASS worst mrg rc=$worst)"
exit "$worst"
