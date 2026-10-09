#!/bin/bash
# Build the [nopy] and [noportage] bed images (portuale backlog #326 P0):
# the normal bed image with the Portage runtime removed (noportage), and
# additionally every Python interpreter removed (nopy).
#
#   differential-test-bed/images/build-nopy.sh
#
# Env: PODMAN (default podman), PORTTEST_IMAGE (the base; default
#      localhost/test-portuale:latest -- forwarded as the Containerfiles'
#      PORTTEST_IMAGE build arg).
#
# Tags: localhost/test-portuale-noportage:latest,
#       localhost/test-portuale-nopy:latest.
#
# Root: these are `podman build` runs, which work rootless on this host;
# when they do not (e.g. a storage backend that needs privilege), re-run
# with root, preserving the env the same way create-container.bash does:
#   sudo --preserve-env=PORTTEST_IMAGE ./build-nopy.sh

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PODMAN=${PODMAN:-podman}
BASE=${PORTTEST_IMAGE:-localhost/test-portuale:latest}

for variant in noportage nopy; do
  echo ">>> building localhost/test-portuale-$variant:latest from $BASE"
  "$PODMAN" build \
    --build-arg "PORTTEST_IMAGE=$BASE" \
    -t "localhost/test-portuale-$variant:latest" \
    -f "$HERE/$variant/Containerfile" \
    "$HERE/$variant"
done

echo ">>> built:"
for variant in noportage nopy; do
  "$PODMAN" images --format '{{.Repository}}:{{.Tag}} {{.Id}} {{.Size}}' \
    "localhost/test-portuale-$variant:latest"
done
