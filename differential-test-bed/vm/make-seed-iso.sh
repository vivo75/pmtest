#!/bin/bash
# Author a NoCloud seed ISO for one VM boot (hostname + root SSH key).
# The guest's cloud-init (DataSourceNoCloud, confirmed in spike/REPORT.md)
# applies it; static content (network, sshd, keys) is baked into the
# golden image instead, so the seed only carries per-run identity.
#
#   vm/make-seed-iso.sh <hostname> <ssh-pubkey-file> <out.iso>
set -euo pipefail

HOSTNAME_=${1:?hostname}
PUBKEY=${2:?ssh public key file}
OUT=${3:?output iso path}
[ -f "$PUBKEY" ] || { echo "no such pubkey: $PUBKEY" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/meta-data" <<EOF
instance-id: ${HOSTNAME_}-seed
local-hostname: ${HOSTNAME_}
EOF
{
  echo "#cloud-config"
  echo "users:"
  echo "  - name: root"
  echo "    ssh_authorized_keys:"
  printf '      - %s\n' "$(cat "$PUBKEY")"
  echo "hostname: ${HOSTNAME_}"
  echo "manage_etc_hosts: true"
} > "$WORK/user-data"
# A stale $OUT may be owned by qemu:qemu (libvirt takes ownership of
# attached disks, and destroy-based teardown can leave it stuck);
# recreate it instead of overwriting. xorriso stdout stays quiet,
# stderr loud: a silent ISO failure used to kill make-image.sh unseen.
rm -f "$OUT"
xorriso -as mkisofs -output "$OUT" -volid cidata -joliet -rock \
  "$WORK/user-data" "$WORK/meta-data" > /dev/null
echo "seed: $OUT (host $HOSTNAME_)"
