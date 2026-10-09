#!/bin/bash
# nopy-build.sh -- build ebuilds with portuale alone in a container that
# has no Portage (and, for [nopy], no Python). Portuale backlog #326 P0.
#
#   differential-test-bed/run/nopy-build.sh [--variant nopy|noportage]
#       [--bin <dir>] [--reinstall] [--env K=V]... <atom>...
#
# --env K=V adds K=V to the container environment (repeatable), e.g. a
# calling-env variable a probe needs to see leak into the phases.
#
# --reinstall forces the rebuild + re-merge even for atoms already
# installed at the resolved version (guest passes `--reinstall-atoms`
# to the step1 --buildpkg and the step2 --usepkgonly emerges). Needed
# for lists like the glibc+bash gate, whose atoms the image already
# holds: without it emerge treats them as satisfied and no binpkg is
# produced.
#
# --variant selects the image (default nopy):
#   nopy       localhost/test-portuale-nopy:latest
#              (no sys-apps/portage runtime, no python interpreters)
#   noportage  localhost/test-portuale-noportage:latest
#              (no sys-apps/portage runtime, python kept)
#   overridable via NOPY_IMAGE / NOPORTAGE_IMAGE.
# --bin overrides the PM bin dir (so a second portuale build can be
# tested); the default comes from the registry like the other runners.
#
# In one throwaway container from the variant image, with PM_BARE=1
# mounts (PM bin dir only -- no checkout), the bed's distfiles cache
# mounted like l3 does (DISTDIR=/distfiles, NOPY_DISTFILES default
# $LOGS_DIR/_l2-distfiles), and the porttest overlay staged the way
# l1/l3 stage it when an atom starts with `porttest/`:
#   1. portuale emerge -1 -v --buildpkg <atoms>
#      (BINPKG_FORMAT=gpkg FEATURES="buildpkg -sign noclean"
#       PKGDIR=/var/cache/binpkgs -- the owner's original failing command;
#       noclean keeps /var/tmp/portage for the audit/artifacts)
#   2. portuale emerge -1 -v --usepkgonly <atoms>   (only if 1 succeeded)
#   3. step 1 again with BINPKG_FORMAT=xpak into PKGDIR=/var/cache/binpkgs-xpak
#      (only if 1 succeeded)
#
# Under logs/nopy-<UTC timestamp>/: one log per step (stdout+stderr),
# argv.txt (the full podman and portuale argv), image.txt (image id),
# binary.txt (sha256 + mtime + version of the binary used), env.txt (the
# env passed), result.tsv (step, rc), plus the guest driver (guest.sh),
# atoms.txt, console.log, distfiles-fetched.txt, and artifacts/ (binpkgs,
# installed porttest modes, per-build WORKDIR modes and build logs).
#
# Exit: 0 when the runner ran all steps it could (a failing build is a
# RESULT, not a runner error); non-zero only for runner errors.
# Network: like l3 -- the default podman network stays on, so missing
# distfiles are fetched into the shared cache; new files are reported as
# distfiles that were missing (distfiles-fetched.txt).
#
# Env: NOPY_IMAGE / NOPORTAGE_IMAGE, NOPY_DISTFILES, NOPY_TIMEOUT
#      (default 28800, per-container wall-clock cap like L3_TIMEOUT),
#      NOPY_JOBS (when set, the guest exports MAKEOPTS=-j<N> so
#      from-source builds parallelise; unset leaves the image default),
#      NOPY_REINSTALL=1 (same as --reinstall), NOPY_SNAPSHOT=1 (after
#      the steps the guest writes a restricted merge snapshot --
#      $OUT/snap.{files,mtimes,vdb.tar,meta}.tsv plus
#      merged-cpvs.txt/paths.txt, exactly the consume.sh shape -- so a
#      reference build can be diffed with compare/normalize.py +
#      compare/diff.py; needs step1 rc=0), NOPY_AUDIT=1 (audit capture
#      for compare/z326-audit.py: an interpreter/portage census in
#      artifacts/audit-env.txt, a ps sampler across all steps in
#      audit-ps.log, and per-package temp transcripts in artifacts/).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

VARIANT=nopy
OPT_BIN=""
OPT_REINSTALL=${NOPY_REINSTALL:-0}
EXTRA_ENV=()
while [ $# -gt 0 ]; do
  case $1 in
    --variant) VARIANT=${2:?--variant needs nopy|noportage}; shift 2 ;;
    --bin) OPT_BIN=${2:?--bin needs a directory}; shift 2 ;;
    --reinstall) OPT_REINSTALL=1; shift ;;
    --env) case ${2:-} in GENTOO_MIRRORS=*) EXTRA_ENV+=(-e "GENTOO_MIRRORS=$(bed_guest_mirrors "${2#*=}")") ;; *=*) EXTRA_ENV+=(-e "$2") ;; *) echo "--env needs K=V" >&2; exit 2 ;; esac; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1 (usage: nopy-build.sh [--variant nopy|noportage] [--bin <dir>] [--reinstall] [--env K=V]... <atom>...)" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "usage: nopy-build.sh [--variant nopy|noportage] [--bin <dir>] [--env K=V]... <atom>..." >&2; exit 2; }

case $VARIANT in
  nopy) IMAGE=${NOPY_IMAGE:-localhost/test-portuale-nopy:latest} ;;
  noportage) IMAGE=${NOPORTAGE_IMAGE:-localhost/test-portuale-noportage:latest} ;;
  *) echo "variant must be nopy|noportage (got: $VARIANT)" >&2; exit 2 ;;
esac

# The PM bin dir: registry default (building it like the other runners),
# or the operator's override (a second portuale build, used as-is).
if [ -n "$OPT_BIN" ]; then
  BIN_DIR=$OPT_BIN
  [ -d "$BIN_DIR" ] || { echo "!!! --bin is not a directory: $BIN_DIR" >&2; exit 2; }
  [ -x "$BIN_DIR/portuale" ] || { echo "!!! no portuale binary in --bin dir: $BIN_DIR" >&2; exit 2; }
else
  ensure_pm_built
  BIN_DIR=$PM_BIN_DIR
fi
for l in emerge ebuild mrg; do
  [ -e "$BIN_DIR/$l" ] || ln -s portuale "$BIN_DIR/$l"
done

if ! "$PODMAN" image exists "$IMAGE"; then
  echo "!!! image $IMAGE missing -- build it with: differential-test-bed/images/build-nopy.sh" >&2
  exit 2
fi
IMAGE_ID=$("$PODMAN" image inspect --format '{{.Id}}' "$IMAGE")

RUN="nopy-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT"
ln -sfn "$RUN" "$LOGS_DIR/nopy-latest"
printf '%s\n' "$@" > "$OUT/atoms.txt"

DISTFILES=${NOPY_DISTFILES:-$LOGS_DIR/_l2-distfiles}
mkdir -p "$DISTFILES"
find "$DISTFILES" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort > "$OUT/distfiles-before.txt"

# PM_BARE=1: only the PM bin dir plus the /TEST mounts -- no checkout,
# no 3rdparty/portage, no PORTUALE_PORTAGE_CHECKOUT. Rebuild PM_MOUNTS
# after the override above (lib.sh built them at source time with the
# registry values).
PM_BARE=1
PM_BIN_DIR=$BIN_DIR
pm_mounts

# The porttest synthetic overlay is live-mounted (no image rebuild); the
# guest stages it only when an atom actually starts with `porttest/`.
PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
ovl_mount=()
[ -d "$PORTTEST_OVL/porttest" ] && ovl_mount=(-v "$PORTTEST_OVL:/porttest-overlay:ro")
STAGE_OVL=0
for a in "$@"; do case $a in porttest/*) STAGE_OVL=1 ;; esac; done

TIMEOUT=${NOPY_TIMEOUT:-28800}

# --- run record -------------------------------------------------------
{
  echo "variant : $VARIANT"
  echo "image   : $IMAGE"
  echo "image_id: $IMAGE_ID"
  echo "bin_dir : $BIN_DIR"
  echo "atoms   : $*"
  echo "distfiles cache (host): $DISTFILES"
  echo "distfiles cache (guest): /distfiles (DISTDIR=/distfiles)"
  echo "stage_porttest_overlay: $STAGE_OVL"
  echo "timeout : $TIMEOUT"
  echo "reinstall: $OPT_REINSTALL"
  echo "jobs     : ${NOPY_JOBS:-unset}"
  echo "snapshot : ${NOPY_SNAPSHOT:-0}"
  echo "audit    : ${NOPY_AUDIT:-0}"
  echo "extra_env: ${EXTRA_ENV[*]:-(none)}"
  echo "date_utc: $(date -u +%FT%TZ)"
  echo
  echo "## step env"
  echo "step1: BINPKG_FORMAT=gpkg FEATURES=\"buildpkg -sign noclean\" PKGDIR=/var/cache/binpkgs"
  echo "step2: PKGDIR=/var/cache/binpkgs (step 1 output dir; no other overrides)"
  echo "step3: BINPKG_FORMAT=xpak FEATURES=\"buildpkg -sign noclean\" PKGDIR=/var/cache/binpkgs-xpak"
} > "$OUT/env.txt"

{
  echo "binary: $BIN_DIR/portuale"
  echo "sha256: $(sha256sum "$BIN_DIR/portuale" | awk '{print $1}')"
  echo "mtime : $(stat -c %y "$BIN_DIR/portuale")"
  echo "registry: $PM_NAME $PM_VERSION (profile $PM_PROFILE)"
  echo "--- version attempts ---"
  "$BIN_DIR/portuale" emerge --version 2>&1 | head -5 || true
  "$BIN_DIR/portuale" --help 2>&1 | head -3 || true
} > "$OUT/binary.txt"

{
  echo "image: $IMAGE"
  echo "id   : $IMAGE_ID"
} > "$OUT/image.txt"

# --- guest driver ------------------------------------------------------
# Runs inside the container (single throwaway, all three steps in order
# so /var/cache/binpkgs persists across them). Writes the step logs and
# result.tsv straight into the run dir through the /TEST/logs mount.
cat > "$OUT/guest.sh" <<'GUEST_EOF'
#!/bin/bash
# nopy guest: <this file> <atoms...>; env NOPY_OUT, NOPY_STAGE_OVL.
set -u
OUT=${NOPY_OUT:?}
RESULT=$OUT/result.tsv
mkdir -p "$OUT"
: > "$RESULT"

backfill() {
  local s
  for s in step1 step2 step3; do
    grep -q "^$s" "$RESULT" 2>/dev/null || printf '%s\tSKIP\n' "$s" >> "$RESULT"
  done
}
trap backfill EXIT

export PORTAGE_CONFIGROOT=/ ROOT=/ PORTAGE_RUNNING_ROOT=/
export EMERGE_DEFAULT_OPTS=""
export LC_ALL=C.UTF-8 TZ=UTC
umask 022

# Harness-env hygiene (#326 Z, leg (c)): container -e variables leak
# into every phase's saved environment (and hence into binpkg
# metadata + the vdb), so anything the reference side does not set
# identically would diff as noise. Consume each NOPY_* knob into a
# shell-local once, then unset it before the first emerge.
JOBS=${NOPY_JOBS:-}; unset NOPY_JOBS
REINSTALL_WANT=${NOPY_REINSTALL:-0}; unset NOPY_REINSTALL
SNAPSHOT=${NOPY_SNAPSHOT:-0}; unset NOPY_SNAPSHOT
AUDIT=${NOPY_AUDIT:-0}; unset NOPY_AUDIT
STAGE_OVL=${NOPY_STAGE_OVL:-0}; unset NOPY_STAGE_OVL
GUEST_VARIANT=${NOPY_VARIANT:-?}; unset NOPY_VARIANT
unset NOPY_OUT

# NOPY_JOBS (host env, forwarded below): intra-package parallelism for
# from-source builds (glibc serial takes hours). Unset: image default.
if [ -n "${JOBS:-}" ]; then
  export MAKEOPTS="-j${JOBS}"
fi

# NOPY_REINSTALL (host --reinstall): force rebuild + re-merge of atoms
# already installed at the resolved version (the gate lists).
REINSTALL=()
if [ "$REINSTALL_WANT" = 1 ]; then
  # One string like layers/l1/consume.sh's --reinstall-atoms shape.
  REINSTALL=(--reinstall-atoms "$*")
fi

# The installed set before the build: the snapshot block diffs it
# against the after set to find the merged packages (plus the atom
# match below, which covers the --reinstall shape where before == after).
if [ -d /var/db/pkg ]; then
  ( cd /var/db/pkg && ls -d */*/ 2>/dev/null | sed 's:/$::' ) | LC_ALL=C sort > "$OUT/installed-before.txt" || true
else
  : > "$OUT/installed-before.txt"
fi

# Audit ps sampler (#326 Z): catches live
# `portuale __helper <name>` dispatcher invocations (and any
# real-python helper use) across all three steps. Stopped after step3.
if [ "$AUDIT" = 1 ]; then
  : > "$OUT/audit-ps.log"
  if command -v ps >/dev/null 2>&1; then
    ( while true; do
        printf '### %s\n' "$(date -u +%FT%TZ)"
        ps -ef | grep -E 'portuale|python|ebuild|emerge' | grep -v grep || true
        sleep 5
      done >> "$OUT/audit-ps.log" 2>&1 & echo $! > "$OUT/.audit-ps.pid" )
    echo ">>> guest audit: sampler pid $(cat "$OUT/.audit-ps.pid")"
  else
    echo ">>> guest audit: no ps(1), sampler skipped"
  fi
fi

if [ -x /usr/local/bin/emerge ]; then
  EM=(/usr/local/bin/emerge)
else
  EM=(/usr/local/bin/portuale emerge)
fi
echo ">>> guest: emerge argv0: ${EM[*]}"

if [ "$STAGE_OVL" = 1 ] && [ -d /porttest-overlay ]; then
  rm -rf /var/db/repos/porttest
  cp -a /porttest-overlay /var/db/repos/porttest
  cat > /etc/portage/repos.conf/porttest.conf <<'EOF'
[porttest]
location = /var/db/repos/porttest
masters = gentoo
auto-sync = no
EOF
  echo ">>> guest: porttest overlay staged at /var/db/repos/porttest"
fi

rc1=1 rc2=1 rc3=1
echo ">>> guest step1: emerge -1 -v --buildpkg (gpkg)"
set +e
BINPKG_FORMAT=gpkg FEATURES="buildpkg -sign noclean" PKGDIR=/var/cache/binpkgs \
  "${EM[@]}" -1 -v --buildpkg "${REINSTALL[@]}" "$@" > "$OUT/step1-build-gpkg.log" 2>&1
rc1=$?
set -e
printf 'step1\t%s\n' "$rc1" >> "$RESULT"
echo ">>> guest step1 rc=$rc1"

# Audit census capture (#326 Z).
#
# Why this shape: the saved per-package `temp/environment` is the
# POST-filter dump (the filter strips PORTAGE_* by design), portuale
# leaves `__source_all_bashrcs` unimplemented (so no bashrc hook can
# observe the live phase env), and successful helper runs are silent.
# The audit therefore rests on three legs, all captured here:
#  1. census: which interpreters / portage packages exist at all
#     (artifacts/audit-env.txt);
#  2. a ps sampler running across all three steps, catching live
#     `portuale __helper <name>` dispatcher invocations
#     (audit-ps.log);
#  3. the step logs + per-package temp(logging) transcripts, scanned
#     host-side for real-python helper invocations.
# The verdict logic lives in compare/z326-audit.py: helper scripts
# exist ONLY inside the dispatcher (no .py files, no checkout, no
# /usr/lib/portage -- asserted by the census), so in a green build
# with zero `no native helper` 127s every helper call demonstrably
# went through portuale-python; any real-python helper invocation in
# the logs/ps record is a violation, while build-system python (e.g.
# glibc's own configure) is allowed and counted separately.
if [ "$AUDIT" = 1 ]; then
  echo ">>> guest audit: census + ps sampler"
  mkdir -p "$OUT/artifacts"
  {
    echo "variant: $GUEST_VARIANT"
    echo "--- compgen -c python (empty = no python provider):"
    compgen -c python | LC_ALL=C sort -u
    echo "--- /usr/bin/python*:"
    ls -la /usr/bin/python* 2>&1
    echo "--- /usr/lib/portage:"
    ls -lad /usr/lib/portage 2>&1
    echo "--- site-packages portage (dist-info alone is NOT the package):"
    ls -d /usr/lib/python*/site-packages/portage /usr/lib64/python*/site-packages/portage 2>&1
    echo "--- import portage (NO-PYTHON / ModuleNotFound = good, IMPORTABLE = bad):"
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import portage; print("IMPORTABLE:", portage.__file__)' 2>&1 | head -2
    else
      echo "NO-PYTHON-INTERPRETER"
    fi
    echo "--- ebuild helpers on PATH:"
    command -v ebuild-pyhelper chmod-lite ecompress-file ebuild-ipc 2>&1
  } > "$OUT/artifacts/audit-env.txt" 2>&1 || true
  echo ">>> guest audit: census -> artifacts/audit-env.txt"
fi

if [ "$rc1" = 0 ]; then
  echo ">>> guest step2: emerge -1 -v --usepkgonly"
  set +e
  PKGDIR=/var/cache/binpkgs \
    "${EM[@]}" -1 -v --usepkgonly "${REINSTALL[@]}" "$@" > "$OUT/step2-usepkgonly.log" 2>&1
  rc2=$?
  set -e
  printf 'step2\t%s\n' "$rc2" >> "$RESULT"
  echo ">>> guest step2 rc=$rc2"

  echo ">>> guest step3: emerge -1 -v --buildpkg (xpak)"
  set +e
  BINPKG_FORMAT=xpak FEATURES="buildpkg -sign noclean" PKGDIR=/var/cache/binpkgs-xpak \
    "${EM[@]}" -1 -v --buildpkg "${REINSTALL[@]}" "$@" > "$OUT/step3-build-xpak.log" 2>&1
  rc3=$?
  set -e
  printf 'step3\t%s\n' "$rc3" >> "$RESULT"
  echo ">>> guest step3 rc=$rc3"
else
  echo ">>> guest: step1 failed -- steps 2 and 3 need its binpkgs, skipping"
fi

# Artifacts: the container is thrown away, so copy out what P0 needs --
# the binpkgs, the installed porttest tree (modes), and per build dir its
# WORKDIR modes and build log (kept by a failed build).
set +e
# Stop the audit sampler first (NOPY_AUDIT=1); its log is complete.
if [ -f "$OUT/.audit-ps.pid" ]; then
  kill "$(cat "$OUT/.audit-ps.pid")" 2>/dev/null || true
  rm -f "$OUT/.audit-ps.pid"
  echo ">>> guest audit: sampler stopped ($(grep -c '^### ' "$OUT/audit-ps.log" 2>/dev/null || echo 0) samples)"
fi
mkdir -p "$OUT/artifacts"
for d in /var/cache/binpkgs /var/cache/binpkgs-xpak; do
  [ -d "$d" ] && cp -a "$d" "$OUT/artifacts/"
done
if [ -d /usr/share/porttest ]; then
  find /usr/share/porttest -printf '%m %y %p -> %l\n' | LC_ALL=C sort -k3 \
    > "$OUT/artifacts/installed-porttest.txt"
  for m in /usr/share/porttest/*/modes.txt; do
    [ -f "$m" ] && cp "$m" "$OUT/artifacts/$(basename "$(dirname "$m")")-modes.txt"
  done
fi
for b in /var/tmp/portage/*/*/; do
  [ -d "$b" ] || continue
  tag=$(echo "$b" | sed 's|^/var/tmp/portage/||; s|/$||; s|/|_|g')
  [ -d "$b/work" ] && (cd "$b/work" && find . -printf '%m %y %P\n' | LC_ALL=C sort -k3) \
    > "$OUT/artifacts/workdir-$tag.txt"
  [ -f "$b/temp/build.log" ] && cp "$b/temp/build.log" "$OUT/artifacts/build-$tag.log"
  # Portuale writes no temp/build.log; keep whatever per-phase
  # transcripts exist (temp/logging*) plus the temp inventory, which
  # the host audit scans for python invocations.
  if [ -d "$b/temp" ]; then
    (cd "$b/temp" && find . -maxdepth 2 -printf '%m %s %P\n' | LC_ALL=C sort -k3) \
      > "$OUT/artifacts/temp-contents-$tag.txt" 2>/dev/null || true
    for t in "$b"/temp/logging*; do
      [ -f "$t" ] || continue
      cp "$t" "$OUT/artifacts/logging-$tag-$(basename "$t")" || true
    done
  fi
done

# Restricted merge snapshot (#326 Z, NOPY_SNAPSHOT=1): the merged
# packages' installed files + their vdb dirs, the consume.sh shape, so
# the host can diff this side against a real-Portage reference build
# with compare/normalize.py + compare/diff.py. Needs step1 rc=0.
if [ "$SNAPSHOT" = 1 ] && [ "$rc1" = 0 ]; then
  echo ">>> guest snapshot: merged set + vdb"
  # shellcheck disable=SC1091  # guest-side path inside the container
  . /TEST/layers/z326/merged-snapshot-lib.sh
  z326_snapshot_merged_set "$OUT" "$OUT/snap" "$@"
fi
GUEST_EOF

# --- launch ------------------------------------------------------------
podman_argv=("$PODMAN" run --rm --name "porttest-nopy-$$"
  --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private
  "${PM_MOUNTS[@]}" "${ovl_mount[@]}"
  -v "$DISTFILES:/distfiles"
  -e DISTDIR=/distfiles
  -e "NOPY_OUT=/TEST/logs/$RUN" -e "NOPY_STAGE_OVL=$STAGE_OVL" -e "NOPY_VARIANT=$VARIANT"
  -e "NOPY_REINSTALL=$OPT_REINSTALL"
  -e "NOPY_JOBS=${NOPY_JOBS:-}" -e "NOPY_SNAPSHOT=${NOPY_SNAPSHOT:-0}" -e "NOPY_AUDIT=${NOPY_AUDIT:-0}"
  ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"}
  "${EXTRA_ENV[@]}"
  --entrypoint /bin/bash "$IMAGE"
  "/TEST/logs/$RUN/guest.sh" "$@")
{
  echo "# podman argv (host):"
  printf '%q ' "${podman_argv[@]}"; echo; echo
  echo "# portuale argv per step (guest: ${EMERGE:-(resolved in guest)}):"
  echo "# step1: BINPKG_FORMAT=gpkg FEATURES=\"buildpkg -sign noclean\" PKGDIR=/var/cache/binpkgs \\"
  printf '  %q ' emerge -1 -v --buildpkg "$@"; echo
  echo "# step2: PKGDIR=/var/cache/binpkgs \\"
  printf '  %q ' emerge -1 -v --usepkgonly "$@"; echo
  echo "# step3: BINPKG_FORMAT=xpak FEATURES=\"buildpkg -sign noclean\" PKGDIR=/var/cache/binpkgs-xpak \\"
  printf '  %q ' emerge -1 -v --buildpkg "$@"; echo
} > "$OUT/argv.txt"

echo ">>> nopy-build: variant=$VARIANT image=$IMAGE run=$RUN"
echo ">>> nopy-build: atoms: $*"
set +e
timeout "$TIMEOUT" "${podman_argv[@]}" 2>&1 | tee "$OUT/console.log"
podrc=${PIPESTATUS[0]}
set -e
echo ">>> nopy-build: container rc=$podrc"

# The guest backfills SKIP rows on exit; do the same here in case the
# container never started (then this is a runner error, exit 2).
guest_ran=0
[ -s "$OUT/result.tsv" ] && guest_ran=1
[ -f "$OUT/result.tsv" ] || : > "$OUT/result.tsv"
for s in step1 step2 step3; do
  grep -q "^$s" "$OUT/result.tsv" 2>/dev/null || printf '%s\tSKIP\n' "$s" >> "$OUT/result.tsv"
done

find "$DISTFILES" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort > "$OUT/distfiles-after.txt"
comm -13 "$OUT/distfiles-before.txt" "$OUT/distfiles-after.txt" > "$OUT/distfiles-fetched.txt" || true
if [ -s "$OUT/distfiles-fetched.txt" ]; then
  echo ">>> nopy-build: distfiles fetched during the run (were missing from the cache):"
  sed 's/^/    /' "$OUT/distfiles-fetched.txt"
else
  echo ">>> nopy-build: no distfiles fetched -- the pre-seeded cache covered the run"
fi

echo ">>> nopy-build: result:"
sed 's/^/    /' "$OUT/result.tsv"
echo ">>> nopy-build: run dir: $OUT"

# A failing build is a RESULT, not a runner error: exit 0 whenever the
# guest ran (it wrote result.tsv itself). Non-zero is for runner errors
# only (no container, no guest output).
if [ "$guest_ran" = 1 ]; then
  exit 0
fi
echo "!!! nopy-build: runner error -- the guest never ran (see $OUT/console.log)" >&2
exit 2
