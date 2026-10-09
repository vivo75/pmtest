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
#
# PM_RELOCATED=1 (portuale backlog #322) mounts only the optional Portage
# checkout instead of the whole checkout, so the build tree's `bin/` is
# absent in the container and the binary must run from its embedded copy of
# the phase runtime -- the relocated-binary cell of the merge-path gate.
#
# PM_BARE=1 (portuale backlog #326, the [nopy]/[noportage] cells) mounts
# only the PM bin dir plus the /TEST mounts -- no checkout at all, neither
# the whole repo nor 3rdparty/portage, and no PORTUALE_PORTAGE_CHECKOUT in
# the container env. It wins over PM_RELOCATED when both are set. The
# binary must be fully self-sufficient in the container.
#
# PM_NO_CHECKOUT=1 (portuale backlog #326 S9) mounts the whole repo as
# usual but masks `$PM_REPO/3rdparty/portage` with an empty dir -- the
# container sees the standard gate shape with no checkout, as if the
# tree had none (a fresh clone or a worktree without the gitignored
# checkout). An operator PORTUALE_PORTAGE_CHECKOUT override is pinned to
# the masked path too, so it cannot silently defeat the mask. It wins
# over PM_RELOCATED and loses to PM_BARE. With
# PORTUALE_PYTHON_HELPERS=real (the oracle mode, which needs the
# checkout) the preflight below fails loud instead of merging halfway.
pm_mounts() {
  PM_MOUNTS=(-v "$PM_BIN_DIR:/usr/local/bin:ro")
  if [ "${PM_BARE:-0}" = 1 ]; then
    : # bare: the PM binaries only -- no checkout, no PORTUALE_PORTAGE_CHECKOUT
  elif [ "${PM_NO_CHECKOUT:-0}" = 1 ]; then
    PM_MOUNTS+=(-v "$PM_REPO:$PM_REPO:ro")
    local empty="${TMPDIR:-/var/tmp/pmtest}/.pm-empty-checkout"
    mkdir -p "$empty"
    PM_MOUNTS+=(
      -v "$empty:$PM_REPO/3rdparty/portage:ro"
      -e "PORTUALE_PORTAGE_CHECKOUT=$PM_REPO/3rdparty/portage"
    )
  elif [ "${PM_RELOCATED:-0}" = 1 ]; then
    local checkout="${PORTUALE_PORTAGE_CHECKOUT:-$PM_REPO/3rdparty/portage}"
    PM_MOUNTS+=(-v "$checkout:$checkout:ro" -e "PORTUALE_PORTAGE_CHECKOUT=$checkout")
  else
    PM_MOUNTS+=(-v "$PM_REPO:$PM_REPO:ro")
  fi
  PM_MOUNTS+=(-v "$TEST_DIR:/TEST:ro" -v "$LOGS_DIR:/TEST/logs")
}

# Resolve the PM now (paths only: sourcing this file must never build).
pm_env_load --no-build

# A host GENTOO_MIRRORS (e.g. the owner's local caching mirror,
# GENTOO_MIRRORS="http://<this host's eth0 IP>:8080") is forwarded to the
# containers that fetch distfiles (l2, l3, nopy-build); unset, the image's
# make.conf mirrors apply. Rootless podman's pasta gives the guest the
# host's own address, so in the guest that IP is the guest itself: it is
# rewritten to host.containers.internal, which reaches the host.
# bed_guest_mirrors <mirrors>: the same list as seen from a guest.
bed_guest_mirrors() {
  local m=$1 ip
  for ip in $(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}'); do
    m=${m//\/\/$ip:/\/\/host.containers.internal:}
    m=${m//\/\/$ip\//\/\/host.containers.internal\/}
  done
  printf '%s\n' "$m"
}
MIRROR_ENV=()
if [ -n "${GENTOO_MIRRORS:-}" ]; then
  MIRROR_ENV=(-e "GENTOO_MIRRORS=$(bed_guest_mirrors "$GENTOO_MIRRORS")")
fi

# Common `podman run` args for a PM-capable throwaway container.
podman_run_pm() {
  local name=$1; shift
  "$PODMAN" run --rm --name "$name" \
    --security-opt seccomp=unconfined \
    --cgroups=enabled --cgroupns=private \
    "${PM_MOUNTS[@]}" \
    "$@"
}

# portuale answers every phase helper natively since backlog #326 S2-S7
# (the `portuale-python` dispatcher, `chmod-lite`,
# `filter-bash-environment`, the gpkg/xpak writers, `doins`, the xattr
# helpers; `has_version`/`best_version` through the vendored
# `portageq-wrapper` shim since feat#157 S6 -- see portuale
# `bin/README.md`). No checkout is needed -- except with
# `PORTUALE_PYTHON_HELPERS=real` (the D2 oracle handle for differential
# tests), where `ebuild_phases::bin_dir()` overlays the vendored `bin/`
# on the gitignored Portage checkout's `bin/` and the not-vendored `.py`
# helpers fall through to it. The container mounts `$PM_REPO` at its
# own host path (below), so the host path this checks IS what the
# container's phase exec sees. Without the checkout a `real`-mode merge
# dies with a missing-helper error mid-merge; fail loud here instead.
# (Before S9 this preflight ran unconditionally -- the native helpers
# did not exist yet.)
portuale_phase_helpers_preflight() {
  [ "$PM_NAME" = portuale ] || return 0
  [ "${PORTUALE_PYTHON_HELPERS:-native}" = real ] || return 0
  local checkout="${PORTUALE_PORTAGE_CHECKOUT:-$PM_REPO/3rdparty/portage}"
  local missing=() f
  for f in bin/doins.py bin/dohtml.py bin/install.py bin/xpak-helper.py \
           bin/gpkg-helper.py lib/portage/__init__.py; do
    [ -r "$checkout/$f" ] || missing+=("$f")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "!!! [preflight] portuale's phase runtime can't find in $checkout:" >&2
    printf '!!!     %s\n' "${missing[@]}" >&2
    echo "!!!   PORTUALE_PYTHON_HELPERS=real needs the gitignored Portage" >&2
    echo "!!!   checkout (3rdparty/portage): the oracle-mode .py helpers" >&2
    echo "!!!   (doins, dohtml, install, xpak, gpkg) and lib/portage fall" >&2
    echo "!!!   through to it; the L1 container mounts \$PM_REPO only, so a" >&2
    echo "!!!   missing checkout means the glibc/bash merges die in src_install" >&2
    echo "!!!   (doins) or when packaging. Native runs (unset or" >&2
    echo "!!!   PORTUALE_PYTHON_HELPERS=native) need no checkout and skip" >&2
    echo "!!!   this check entirely." >&2
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
