#!/bin/bash
# Build the l31b bare-client image (portuale backlog #326 S8):
# the [nopy] bed image re-tagged through the contract assertions in
# `mrg-client/Containerfile` (bash >= 5.3, the §6 tool floor, sshd, and
# NO Python / NO portuale / NO /opt/bin).
#
#   differential-test-bed/images/build-mrg-client.sh
#
# Env: PODMAN (default podman), PORTTEST_NOPY_IMAGE (the base; default
#      localhost/test-portuale-nopy:latest -- forwarded as the
#      Containerfile's PORTTEST_IMAGE build arg).
#
# Tags: localhost/test-mrg-client:latest (the MRG_CLIENT_IMAGE default
#       in run/lib.sh, used by run/l31b-two-container.sh).
#
# Root: `podman build` works rootless on this host; when it does not
# (e.g. a storage backend that needs privilege), re-run with root,
# preserving the env the same way create-container.bash does:
#   sudo --preserve-env=PORTTEST_NOPY_IMAGE ./build-mrg-client.sh

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PODMAN=${PODMAN:-podman}
BASE=${PORTTEST_NOPY_IMAGE:-localhost/test-portuale-nopy:latest}
TAG=localhost/test-mrg-client:latest

echo ">>> building $TAG from $BASE"
"$PODMAN" build \
  --build-arg "PORTTEST_IMAGE=$BASE" \
  -t "$TAG" \
  -f "$HERE/mrg-client/Containerfile" \
  "$HERE/mrg-client"

echo ">>> built:"
"$PODMAN" images --format '{{.Repository}}:{{.Tag}} {{.Id}} {{.Size}}' "$TAG"
