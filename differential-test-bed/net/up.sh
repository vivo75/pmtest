#!/bin/bash
# Bring up the shared podman infrastructure for the L1+ layers:
# a user-defined network + the persistent volumes.
#
# L0 (differential-test-bed/run/l0-resolver.sh) is single-container and needs none of
# this; it is here so L1 (slice 2) has it ready.
#
#   differential-test-bed/net/up.sh
#
# Env: PORTTEST_NET, PORTTEST_PODMAN

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/../run/lib.sh"

"$PODMAN" network exists "$NET" || {
  echo ">>> creating network $NET"
  "$PODMAN" network create "$NET"
}

for v in porttest-pkgdir porttest-distfiles porttest-bincache porttest-snapshots; do
  "$PODMAN" volume exists "$v" || {
    echo ">>> creating volume $v"
    "$PODMAN" volume create "$v"
  }
done

echo ">>> up: network $NET + volumes"
"$PODMAN" volume ls --filter name=porttest-
