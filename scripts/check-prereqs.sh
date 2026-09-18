#!/bin/bash
# One-shot prerequisite check for the differential-test-bed / L0-L5 suite.
# Every piece checked here is otherwise discovered piecemeal and deep in a
# run (a git error in create-container.bash, a build failure mid-stage3,
# an import error inside the pytest harness) -- this surfaces all of them
# up front, in one command, on a fresh clone.

set -uo pipefail

PMTEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$PMTEST_ROOT/differential-test-bed"
FAIL=0

ok()   { printf '  [OK]   %s\n' "$1"; }
miss() { printf '  [MISS] %s -- %s\n' "$1" "$2"; FAIL=1; }

echo "== container runtime =="
if command -v podman >/dev/null 2>&1; then ok "podman ($(command -v podman))"
else miss "podman" "install podman (needed to build and run the test images)"; fi
if command -v buildah >/dev/null 2>&1; then ok "buildah ($(command -v buildah))"
else miss "buildah" "install buildah (create-container.bash uses it to assemble the image)"; fi

echo "== host python =="
if python3 -c 'import yaml' >/dev/null 2>&1; then ok "PyYAML"
else miss "PyYAML" "pip install pyyaml (or your distro's dev-python/pyyaml) -- managers/registry.py needs it"; fi

echo "== vendored sources =="
if [ -d "$PMTEST_ROOT/3rdparty/portage" ]; then ok "3rdparty/portage"
else miss "3rdparty/portage" "the 3rdparty symlink is broken or ../portuale/3rdparty/portage is missing"; fi

for repo in gentoo buildovl; do
  link="$TEST_DIR/repos/$repo"
  if [ -d "$link" ]; then ok "repos/$repo -> $(readlink -f "$link" 2>/dev/null || echo "$link")"
  else miss "repos/$repo" "$link does not resolve to a directory -- the pinned mirror repo is missing"; fi
done

echo "== stage3 =="
# Same STAGEID/DATESTART create-container.bash computes its own filename
# from -- read straight from it so this can never drift out of sync.
STAGEID=$(sed -n 's/^STAGEID=//p' "$TEST_DIR/create-container.bash" | head -1)
DATESTART=$(sed -n 's/^DATESTART=//p' "$TEST_DIR/create-container.bash" | head -1)
STAGETS=${DATESTART//-/}; STAGETS=${STAGETS//:/}
STAGE3="$TEST_DIR/${STAGEID}-${STAGETS}.tar.xz"
if [ -n "$STAGEID" ] && [ -f "$STAGE3" ]; then ok "$(basename "$STAGE3")"
else miss "stage3 tarball" "$STAGE3 not found -- create-container.bash downloads it on first run, or fetch it yourself from https://www.gentoo.org/downloads/"; fi

echo "== test image =="
IMAGE=${PORTTEST_IMAGE:-localhost/test-portuale:latest}
if ! command -v podman >/dev/null 2>&1; then
  miss "$IMAGE" "cannot check -- podman missing (see above)"
elif podman image exists "$IMAGE" 2>/dev/null; then ok "$IMAGE"
else miss "$IMAGE" "build it with: sudo differential-test-bed/create-container.bash"; fi

echo "== active PM registry entry =="
PM_NAME=${PMTEST_PM:-portuale}
if REG_OUT=$(cd "$PMTEST_ROOT" && python3 managers/registry.py --sh --no-build 2>&1); then
  eval "$REG_OUT"
  ok "PMTEST_PM=$PM_NAME -> $PM_EMERGE (version $PM_VERSION)"
else
  miss "PMTEST_PM=$PM_NAME" "managers/registry.py could not resolve it: $REG_OUT"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "all prerequisites present."
else
  echo "some prerequisites are missing -- see [MISS] lines above."
fi
exit "$FAIL"
