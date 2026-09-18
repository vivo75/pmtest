#!/bin/bash
# Shared helpers for the differential-test-bed/run/l*.sh orchestrators.
# Source, don't execute.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR="$REPO_ROOT/differential-test-bed"
LOGS_DIR="$TEST_DIR/logs"

# Which package manager is under test comes from the registry
# (`managers/managers.yaml`, selected by $PMTEST_PM), exactly as in the
# pytest contract suite -- no PM path is hardcoded here. `--sh` prints
# PM_NAME/PM_PACKAGE/PM_VERSION/PM_EMERGE/PM_BIN_DIR/PM_REPO/PM_RUST_DIR;
# `--no-build` resolves the paths without building, which is what
# sourcing this file must not do (`ensure_pm_built` does the build).
# A registry error must stop the run: an empty `eval` would leave every
# PM_* variable unset and mount nothing, which `set -u` alone would only
# catch later, mid-container.
pm_env_load() {
  local out
  out=$(python3 "$REPO_ROOT/managers/registry.py" --sh "$@") || {
    echo "!!! cannot resolve the PM under test (PMTEST_PM=${PMTEST_PM:-portuale})" >&2
    exit 2
  }
  # Exported (not just set): children such as pm_stamp's python read
  # PM_* from the environment.
  set -a
  eval "$out"
  set +a
  pm_mounts
}

IMAGE=${PORTTEST_IMAGE:-localhost/test-portuale:latest}
MRG_CLIENT_IMAGE=${PORTTEST_MRG_CLIENT_IMAGE:-localhost/test-mrg-client:latest}
NET=${PORTTEST_NET:-porttest-net}

# podman that can build (root containers are fine -- doc real-world-testing.md §1.10)
PODMAN=${PORTTEST_PODMAN:-podman}

# The mounts every PM-capable throwaway container needs, as an array so
# the `timeout`-wrapped `podman run` in l3 can reuse them verbatim.
# The PM binaries are mounted from its host build dir; its checkout is
# mounted at its own host path because `ebuild_phases::repo_root()` is a
# compile-time CARGO_MANIFEST_DIR/../.. path into that checkout, and L1+
# phase execution reads `bin/` and `3rdparty/portage` through it. L0
# never runs phases but the mount is harmless.
pm_mounts() {
  PM_MOUNTS=(
    -v "$PM_BIN_DIR:/usr/local/bin:ro"
    -v "$PM_REPO:$PM_REPO:ro"
    -v "$TEST_DIR:/TEST:ro"
    -v "$LOGS_DIR:/TEST/logs"
  )
}

# Resolve the PM now (paths only: sourcing this file must never build).
pm_env_load --no-build

# Common `podman run` args for a PM-capable throwaway container.
podman_run_pm() {
  local name=$1; shift
  "$PODMAN" run --rm --name "$name" \
    --security-opt seccomp=unconfined \
    --cgroups=enabled --cgroupns=private \
    "${PM_MOUNTS[@]}" \
    "$@"
}

# Which build produced a run's numbers is part of the numbers, so every
# run dir carries it: `pm.json` next to the logs, written before the
# first container starts. `$PM_VERSION` is what the registry resolved
# (for a source-built PM, the commit, `-dirty` when the checkout had
# uncommitted changes) -- not a label somebody remembered to update.
pm_stamp() {  # <run-dir>
  [ -d "$1" ] || return 0
  PM_STAMP_DIR="$1" python3 - <<'PY'
import json, os, datetime
out = {
    "pm": os.environ["PM_NAME"],
    "version": os.environ["PM_VERSION"],
    "binary": os.environ["PM_EMERGE"],
    "repo": os.environ["PM_REPO"],
    "stamped_at": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(os.path.join(os.environ["PM_STAMP_DIR"], "pm.json"), "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
PY
  echo ">>> PM under test: $PM_NAME $PM_VERSION  (stamped in $1/pm.json)"
}

ensure_pm_built() {  # [run-dir]
  echo ">>> building $PM_NAME (release, registry version $PM_VERSION)"
  # The registry owns the build: it runs `cargo build --release` in the
  # PM's own workspace, so a source change can never be graded through a
  # stale binary ($PMTEST_NO_BUILD=1 opts out for a prebuilt one).
  pm_env_load
  for l in emerge ebuild mrg; do
    [ -e "$PM_BIN_DIR/$l" ] || ln -s "$(basename "$PM_EMERGE")" "$PM_BIN_DIR/$l"
  done
  [ $# -ge 1 ] && pm_stamp "$1"
  return 0
}

ensure_image() {
  if ! "$PODMAN" image exists "$IMAGE"; then
    echo "!!! image $IMAGE missing -- build it with:  sudo differential-test-bed/create-container.bash" >&2
    exit 2
  fi
}

timestamp() { date -u +%Y%m%dT%H%M%SZ; }
