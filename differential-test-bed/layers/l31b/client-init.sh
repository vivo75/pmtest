#!/bin/bash
# L31b -- bring up the bare client end of the two-container remote-merge
# cell (portuale #326 S8, pmtest side). Runs INSIDE the client container
# (the mrg-client image: bash, the §6 tool floor, sshd, NO portuale, NO
# Python, NO repo mount) via `podman exec`, right after the host starts
# it (detached, `sleep infinity`, on the run's dedicated network).
#
# Usage (from the host orchestrator):
#   podman exec <client> /TEST/layers/l31b/client-init.sh \
#       /keys/client.pub /TEST/logs/<run>/client /TEST/atomlists/l31-s0.txt
#
# What it does (harness plumbing only; the merge itself is the product
# under test):
#   1. sshd hygiene the image cannot carry: host keys (`ssh-keygen -A`,
#      per container, never baked into the image), a root-owned
#      /var/empty + /run/sshd (the image's owners are bin:bin, which
#      stock sshd refuses), and an explicit sshd_config with
#      `StrictModes no` (the image's /root is bin-owned, so stock
#      StrictModes would reject the key -- the same reason l31's
#      loopback sshd writes its own config instead of using the
#      default). Passwords off, root key login only.
#   2. installs the run's public key as root's authorized_keys.
#   3. starts sshd on port 22 and waits (bash /dev/tcp, no extra tool)
#      until it accepts, so the server's first mrg preflight never races
#      container start.
#   4. stages the bed INSTALL_MASK in the client's make.conf (resolved-
#      config parity with the reference side's layers/l1/consume.sh
#      block -- see the inline note; no repo is copied).
#   5. records the pre-merge vdb state ($OUT.installed-before.txt), so
#      client-snapshot.sh can later diff exactly what the run merged --
#      the same before/after shape layers/l1/consume.sh uses.
#
# Exit: 0 ready, 2 setup error (the host treats this as exit-2 setup
# failure, never as diff signal).

set -u
PUBKEY=${1:?client public key file (a ro mount)}
OUT=${2:?out prefix}
ATOMLIST=${3:?atom list (a /TEST path: the mask gate below reads it)}
SSH_PORT=${L31B_SSH_PORT:-22}

log() { printf '[l31b-client-init] %s\n' "$*"; }
fail() { log "!!! $*"; exit 2; }

[ -f "$PUBKEY" ] || fail "public key not found: $PUBKEY"
mkdir -p "$(dirname "$OUT")" || fail "cannot create out dir for $OUT"

export LC_ALL=C.UTF-8 TZ=UTC
umask 022

# --- sshd hygiene (harness, not product) --------------------------------
mkdir -p /var/empty /run/sshd || fail "cannot create /var/empty /run/sshd"
chown root:root /var/empty /run/sshd || fail "cannot chown /var/empty /run/sshd"
chmod 755 /var/empty /run/sshd || fail "cannot chmod /var/empty /run/sshd"
ssh-keygen -A || fail "ssh-keygen -A failed (no host keys)"
mkdir -p /root/.ssh || fail "cannot create /root/.ssh"
cp "$PUBKEY" /root/.ssh/authorized_keys || fail "cannot install authorized_keys"
chmod 700 /root/.ssh || fail "cannot chmod /root/.ssh"
chmod 600 /root/.ssh/authorized_keys || fail "cannot chmod authorized_keys"

cat > /etc/ssh/sshd_config_l31b <<EOF || fail "cannot write sshd_config_l31b"
Port $SSH_PORT
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd-l31b.pid
AuthorizedKeysFile /root/.ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin yes
EOF

/usr/sbin/sshd -f /etc/ssh/sshd_config_l31b -E /var/log/sshd-l31b.log \
  || fail "sshd failed to start -- see /var/log/sshd-l31b.log"

ready=0
for _ in $(seq 1 100); do
  if (echo > /dev/tcp/127.0.0.1/"$SSH_PORT") >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" = 1 ] || fail "sshd on 127.0.0.1:$SSH_PORT never accepted (see /var/log/sshd-l31b.log)"
log "sshd accepting on port $SSH_PORT (StrictModes no, root key login)"

# --- resolved-config parity (INSTALL_MASK, bed reasons) ------------------
# The client merge resolves INSTALL_MASK from the CLIENT's own config
# (like real Portage would on that machine), while the reference side
# reads it from the identical staging block in layers/l1/consume.sh.
# l31 gets this for free (client and server are the same container, so
# the server's staging lands in the client's config too); here the
# client is a separate pristine image, so the bed stages the same value
# on the client explicitly. Without it the mask-path cells diverge for
# bed reasons: the client merges im/drop.txt, im/*.log and *.la and
# records the default mask in the vdb, while the reference drops them.
# This is config alignment, not product behaviour: no repo is copied
# (the client stays repo-free; the patterns are inert without one),
# only the one make.conf line both PMs must read identically.
if grep -q '^porttest/' "$ATOMLIST"; then
  printf 'INSTALL_MASK="/usr/share/porttest/im/drop.txt /usr/share/porttest/im/*.log *.la"\n' \
    >> /etc/portage/make.conf
  log "staged bed INSTALL_MASK in /etc/portage/make.conf"
fi

# --- pre-merge vdb state (mirrors layers/l1/consume.sh) ------------------
# FAR is always / here: the client merges into its own ROOT, and the
# snapshot restricts to what this run merged, never the image's
# pre-existing vdb.
# shellcheck disable=SC2012,SC2035  # `ls -d */*/` is the bed-wide idiom (layers/l1/consume.sh)
( cd /var/db/pkg && ls -d */*/ 2>/dev/null | sed 's:/$::' ) | LC_ALL=C sort \
  > "$OUT.installed-before.txt" \
  || fail "cannot record $OUT.installed-before.txt"
log "recorded $(wc -l < "$OUT.installed-before.txt") pre-existing vdb entries"
log "ready"
