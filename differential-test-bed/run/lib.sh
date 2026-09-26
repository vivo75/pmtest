#!/bin/bash
# Shared helpers for the differential-test-bed/run/l*.sh orchestrators.
# Source, don't execute.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR="$REPO_ROOT/differential-test-bed"
LOGS_DIR="$TEST_DIR/logs"

# Host-side scratch (mktemp -d in abort-capture.sh, etc.) defaults off
# tmpfs /tmp onto real disk: /tmp is RAM-backed with a FIXED inode count
# independent of disk size, and a merge test's own root-owned residue
# already erodes it faster than volume alone would (see
# pytests-contract-suite/conftest.py's own tmp-hygiene block, and
# USAGE.AGENTS.md "Spazio /tmp", for the full story). `: "${TMPDIR:=...}"`
# is a no-op for anyone who already set TMPDIR themselves.
: "${TMPDIR:=/var/tmp/pmtest}"
export TMPDIR
mkdir -p "$TMPDIR"

# Which package manager is under test comes from the registry
# (`managers/managers.yaml`, selected by $PMTEST_PM), exactly as in the
# pytest contract suite -- no PM path is hardcoded here. `--sh` prints
# PM_NAME/PM_PACKAGE/PM_VERSION/PM_PROFILE/PM_EMERGE/PM_BIN_DIR/PM_REPO/PM_RUST_DIR;
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

# portuale's phase runtime needs the three `bin/`-helper files that
# `import portage` (`portageq-wrapper`, `portageq`, `ebuild-pyhelper`).
# They are *not* vendored into `bin/` (see portuale `bin/README.md`);
# `ebuild_phases::bin_dir()` overlays the vendored `bin/` with the
# gitignored Portage checkout's `bin/` only when that checkout exists at
# `PORTUALE_PORTAGE_CHECKOUT` (unset by the bed) or
# `<repo_root>/3rdparty/portage`. The container mounts `$PM_REPO` at its
# own host path (below), so the host path this checks IS what the
# container's phase exec sees. Without the checkout every `has_version`
# / `best_version` call dies in `pkg_preinst` with an opaque
# `portageq exit code: 127` (backlog #151); fail loud here instead.
portuale_phase_helpers_preflight() {
  [ "$PM_NAME" = portuale ] || return 0
  local checkout="${PORTUALE_PORTAGE_CHECKOUT:-$PM_REPO/3rdparty/portage}"
  if [ ! -x "$checkout/bin/portageq-wrapper" ]; then
    echo "!!! [preflight] portuale's phase runtime can't find $checkout/bin/portageq-wrapper" >&2
    echo "!!!   the gitignored Portage checkout (3rdparty/portage) is what provides the" >&2
    echo "!!!   portage-importing bin helpers; the L1 container mounts \$PM_REPO only," >&2
    echo "!!!   so a missing checkout means every glibc/bash merge dies with a" >&2
    echo "!!!   'has_version: unexpected portageq exit code: 127' in pkg_preinst." >&2
    echo "!!!   Fix: run 'setup.sh portage' in the portuale checkout (3rdparty/README.md)," >&2
    echo "!!!   or stage the checkout under \$PM_REPO ($PM_REPO)." >&2
    exit 2
  fi
}

# Which build produced a run's numbers is part of the numbers, so every
# run dir carries it: `pm.json` next to the logs, written before the
# first container starts. `$PM_VERSION` is what the registry resolved
# (for a source-built PM, the commit, `-dirty` when the checkout had
# uncommitted changes) and `$PM_PROFILE` the cargo profile it built
# (`debug`/`release`, `$PMTEST_PROFILE`) -- not a label somebody
# remembered to update.
pm_stamp() {  # <run-dir>
  [ -d "$1" ] || return 0
  PM_STAMP_DIR="$1" python3 - <<'PY'
import json, os, datetime
out = {
    "pm": os.environ["PM_NAME"],
    "version": os.environ["PM_VERSION"],
    "profile": os.environ["PM_PROFILE"],
    "binary": os.environ["PM_EMERGE"],
    "repo": os.environ["PM_REPO"],
    "stamped_at": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(os.path.join(os.environ["PM_STAMP_DIR"], "pm.json"), "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
PY
  echo ">>> PM under test: $PM_NAME $PM_VERSION (profile $PM_PROFILE)  (stamped in $1/pm.json)"
}

ensure_pm_built() {  # [run-dir]
  echo ">>> building $PM_NAME (profile $PM_PROFILE, registry version $PM_VERSION)"
  # The registry owns the build: it runs `cargo build` in the PM's own
  # workspace (--release only under PMTEST_PROFILE=release), so a source
  # change can never be graded through a stale binary
  # ($PMTEST_NO_BUILD=1 opts out for a prebuilt one).
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
