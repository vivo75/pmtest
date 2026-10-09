#!/bin/bash
# L31b -- the two-container remote-merge cell (#326 S8, pmtest side).
# The companion to run/l31-remote-merge.sh (l31): l31 merges through
# `mrg --remote-*` over a loopback sshd into a far ROOT inside the SAME
# container; l31b reaches a SEPARATE bare client container over a
# dedicated podman network, which is what portuale's S8a change (the
# server installs and verifies its own binary on the client) needs to
# prove its install path.
#
# Cell:
#   server -- the normal bed image (portuale, the repo, the pkgcache, as
#             l31 has them). Runs layers/l31b/server-merge.sh: one
#             `mrg --remote-binpkg` per atom (the same trial path l31
#             uses for the same atom list) against the client hostname.
#   client -- the mrg-client image (images/mrg-client/Containerfile: the
#             nopy image asserted at build time -- bash >= 5.3, the §6
#             tool floor, sshd, NO portuale, NO Python, NO repo mount).
#             It gets NO PM binary mount (its /usr/local/bin stays
#             writable and empty until mrg installs portuale-<hash>
#             there), NO overlay and NO pkgcache mount -- only the /TEST
#             harness (ro), the logs dir (its write target) and the run's
#             public key (ro). sshd + the pre-merge vdb record come from
#             layers/l31b/client-init.sh; the post-merge snapshot from
#             layers/l31b/client-snapshot.sh.
#   reference -- real Portage consuming the same gpkgs in a fresh server
#             container (layers/l1/consume.sh, exactly l31's reference
#             side). The host normalises + diffs reference vs. client
#             with the same compare/ tooling. Expected: 0 hard /
#             0 unexplained.
#
# The run performs TWO merge passes against the same client (unless
# L31B_SINGLE=1): the first must print exactly one
# `portuale-remote: install-bin 0` line and leave
# /usr/local/bin/portuale-<hash> (/opt/bin is absent from the client
# image, so the D5 search deterministically lands there) with the
# server binary's SHA-256 and mode 0755; the re-run must print no
# install-bin line and leave the file unchanged (same inode/mtime and
# digest). The client snapshot for the parity diff is taken after the
# FIRST pass: the trial path re-executes hooks on a re-merge, so a
# post-re-run snapshot would carry both passes' hook lines. The
# assertions live in <run>/install-bin.txt.
#
#   differential-test-bed/run/l31b-two-container.sh [atomlist]
#
# The pkgcache is shared with l31 ($LOGS_DIR/_l31-pkgcache), so "the same
# gpkgs" is literal: build once, consume twice.
#
# Env: PORTTEST_IMAGE (server; default localhost/test-portuale:latest),
#      PORTTEST_MRG_CLIENT_IMAGE (client; default
#        localhost/test-mrg-client:latest -- build it with
#        images/build-mrg-client.sh),
#      PORTTEST_PODMAN, PORTTEST_NET is NOT used (a dedicated network per
#      run is created and removed on exit),
#      L31B_SKIP_BUILD=1   (reuse the pkgcache as-is),
#      L31B_REBUILD=1      (wipe the shared _l31-pkgcache first),
#      L31B_JOBS           (MAKEOPTS -j for the build, default 4),
#      L31B_SINGLE=1       (one merge pass only; skips the re-run
#                           assertions that need two passes),
#      L31B_KEEP=1         (keep the client container + network after the
#                           run for forensics; default is teardown),
#      L1_SKIP_PORTAGE_UPGRADE=1 (escape hatch, forwarded like l31).
#
# Exit: 0 green (0 hard / 0 unexplained AND the install-bin assertions
#       hold), 1 divergence or assertion failure, 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l31-s0.txt}" 2>/dev/null) \
  || { echo "atom list not found" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/*) REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/" >&2; exit 2 ;;
esac

SERVER_IMAGE=$IMAGE
CLIENT_IMAGE=$MRG_CLIENT_IMAGE

# The pkgcache is shared with l31 on purpose (see header).
PKGCACHE="$LOGS_DIR/_l31-pkgcache"
RUN="l31b-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT" "$PKGCACHE"
ln -sfn "$RUN" "$LOGS_DIR/l31b-latest"

NET="porttest-$RUN-$$"
CLIENT="l31b-client-$$"
KEYS="$OUT/keys"
mkdir -p "$KEYS"

cleanup() {  # invoked via `trap cleanup EXIT` below
  local rc=$?
  if [ "${L31B_KEEP:-0}" = 1 ]; then
    echo ">>> L31B_KEEP=1: leaving client $CLIENT + network $NET up" >&2
    echo "    re-enter: $PODMAN exec -it $CLIENT /bin/bash" >&2
    echo "    teardown: $PODMAN rm -f $CLIENT; $PODMAN network rm -f $NET" >&2
    exit "$rc"
  fi
  "$PODMAN" rm -f "$CLIENT" >/dev/null 2>&1 || true
  "$PODMAN" network rm -f "$NET" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

ensure_pm_built "$OUT"
# The server end stages bundles through the phase runtime's embedded
# files; like l31's candidate side it must not depend on a missing
# gitignored checkout silently.
portuale_phase_helpers_preflight
ensure_image
if ! "$PODMAN" image exists "$CLIENT_IMAGE"; then
  echo "!!! client image $CLIENT_IMAGE missing -- build it with: differential-test-bed/images/build-mrg-client.sh" >&2
  exit 2
fi
if ! command -v ssh-keygen >/dev/null; then
  echo "!!! ssh-keygen not found on the host" >&2
  exit 2
fi

# The porttest synthetic overlay is live-mounted into the server-side
# containers only (exactly like l31); the client never sees it.
PORTTEST_OVL="$TEST_DIR/images/overlay/porttest"
ovl_mount=()
[ -d "$PORTTEST_OVL/porttest" ] && ovl_mount=(-v "$PORTTEST_OVL:/porttest-overlay:ro")

SERVER_DIGEST=$(sha256sum "$PM_EMERGE" | cut -d' ' -f1)
SERVER_HASH16=${SERVER_DIGEST:0:16}

# --- run header ---------------------------------------------------------
{
  echo "# L31b two-container remote-merge bed run header"
  echo "run_id	$RUN"
  echo "server_image	$SERVER_IMAGE"
  echo "client_image	$CLIENT_IMAGE"
  echo "network	$NET"
  echo "client	$CLIENT"
  echo "profile	release"
  echo "pm_under_test	$PM_NAME $PM_VERSION"
  echo "server_binary	$PM_EMERGE"
  echo "server_sha256	$SERVER_DIGEST"
  echo "expected_client_bin	/usr/local/bin/portuale-$SERVER_HASH16"
  echo "atomlist	$REL_ATOMLIST"
  echo "atomlist_sha256	$(sha256sum "$ATOMLIST" | cut -d' ' -f1)"
  echo "host_date_utc	$(date -u +%FT%TZ)"
  echo "## atomlist"
  sed 's/^/  /' "$ATOMLIST"
} > "$OUT/header.txt"
echo ">>> run $RUN -> $OUT (server=$SERVER_IMAGE client=$CLIENT_IMAGE net=$NET)"

# --- build the gpkg set once with real Portage (cached, shared w/ l31) --
[ "${L31B_REBUILD:-0}" = 1 ] && { echo ">>> L31B_REBUILD: wiping $PKGCACHE"; rm -rf "${PKGCACHE:?}"/*; }

if [ "${L31B_SKIP_BUILD:-0}" != 1 ]; then
  echo ">>> building the set from source with Portage (pkgcache: $PKGCACHE)"
  "$PODMAN" run --rm --name "porttest-l31b-build-$$" \
    --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private \
    -v "$TEST_DIR:/TEST:ro" -v "$PKGCACHE:/pkgs" "${ovl_mount[@]}" \
    -e PKGDIR=/pkgs \
    -e "L1_JOBS=${L31B_JOBS:-4}" \
    -e "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"} \
    --entrypoint /bin/bash "$SERVER_IMAGE" \
    /TEST/layers/l1/build.sh "$REL_ATOMLIST"
else
  echo ">>> L31B_SKIP_BUILD: using $(find "$PKGCACHE" -name '*.gpkg.tar' | wc -l) cached binpkgs"
fi

# --- client: key pair per run, dedicated network, detached start --------
echo ">>> generating the run key pair in $KEYS"
ssh-keygen -t ed25519 -N '' -f "$KEYS/client" -q || { echo "!!! ssh-keygen failed" >&2; exit 2; }
chmod 600 "$KEYS/client"

echo ">>> creating network $NET and starting client $CLIENT"
"$PODMAN" network create "$NET" >/dev/null || { echo "!!! network create failed" >&2; exit 2; }
"$PODMAN" run -d --name "$CLIENT" --network "$NET" \
  --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private \
  -v "$TEST_DIR:/TEST:ro" -v "$LOGS_DIR:/TEST/logs" -v "$KEYS:/keys:ro" \
  --entrypoint /bin/sleep "$CLIENT_IMAGE" infinity \
  || { echo "!!! client start failed" >&2; exit 2; }

echo ">>> client init (sshd + config parity + pre-merge vdb record)"
if ! "$PODMAN" exec "$CLIENT" /bin/bash \
    /TEST/layers/l31b/client-init.sh /keys/client.pub "/TEST/logs/$RUN/client" "$REL_ATOMLIST"; then
  echo "!!! client init failed" >&2
  exit 2
fi

# --- reference side: real Portage consume (l31's reference, verbatim) ---
echo ">>> merging with real Portage (reference)"
if ! podman_run_pm "porttest-l31b-ref-$$" \
    -v "$PKGCACHE:/pkgs:ro" "${ovl_mount[@]}" \
    -e PKGDIR=/pkgs \
    -e "L1_SKIP_PORTAGE_UPGRADE=${L1_SKIP_PORTAGE_UPGRADE:-0}" \
    -e "L1_JOBS=${L31B_JOBS:-4}" \
    ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"} \
    --entrypoint /bin/bash "$SERVER_IMAGE" \
    /TEST/layers/l1/consume.sh portage "$REL_ATOMLIST" "/TEST/logs/$RUN/reference"; then
  echo "!!! reference side failed" >&2
  exit 2
fi

# --- server merge passes against the same client ------------------------
server_pass() {  # <pass>
  echo ">>> server merge pass: $1 (client $CLIENT)"
  set +e
  podman_run_pm "porttest-l31b-mrg-$1-$$" \
    --network "$NET" \
    -v "$PKGCACHE:/pkgs:ro" "${ovl_mount[@]}" -v "$KEYS:/keys:ro" \
    -e PKGDIR=/pkgs \
    ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"} \
    --entrypoint /bin/bash "$SERVER_IMAGE" \
    /TEST/layers/l31b/server-merge.sh "$REL_ATOMLIST" "/TEST/logs/$RUN/client" "$CLIENT" "$1"
  local rc=$?
  set -e
  echo ">>> pass $1 container rc=$rc"
  return "$rc"
}

# client binary stat after a pass -> $OUT.install-<pass>.tsv
# (path, sha256, mode, inode, mtime), D5 search order (/opt/bin first).
client_bin_stat() {  # <pass>
  # shellcheck disable=SC2016  # the $c/$f expand inside the CLIENT shell, not here
  "$PODMAN" exec "$CLIENT" /bin/bash -c \
    'f=""; for d in /opt/bin /usr/local/bin; do for c in "$d"/portuale-*; do [ -e "$c" ] || continue; [ -n "$f" ] && { echo "MULTI"; exit 0; }; f=$c; done; done; [ -n "$f" ] || { echo "ABSENT"; exit 0; }; printf "%s\t%s\t%s\t%s\t%s\n" "$f" "$(sha256sum -- "$f" | cut -d" " -f1)" "$(stat -c %a -- "$f")" "$(stat -c %i -- "$f")" "$(stat -c %y -- "$f")"' \
    > "$OUT/install-$1.tsv" || true
  sed 's/^/    /' "$OUT/install-$1.tsv"
}

pass1_rc=0
server_pass first || pass1_rc=$?
client_bin_stat first
echo ">>> pass first worst mrg rc=$pass1_rc"

{
  echo "pass_first_rc	$pass1_rc"
} >> "$OUT/header.txt"

# --- snapshot the client ROOT (right after the first pass) ---------------
# The snapshot captures the merge result the reference side is diffed
# against. It runs BEFORE the re-run pass on purpose: the trial path
# re-executes the ebuild hooks on a re-merge (no AlreadyInstalled
# short-circuit), so the porttest/phases hook log would carry both
# passes' lines -- a harness artefact of proving install-idempotence,
# not merge signal. The re-run pass below therefore only feeds the
# install-bin assertions, never the diff.
echo ">>> snapshotting the client ROOT"
if ! "$PODMAN" exec "$CLIENT" /bin/bash \
    /TEST/layers/l31b/client-snapshot.sh "/TEST/logs/$RUN/client" /; then
  echo "!!! client snapshot failed" >&2
  exit 2
fi

pass2_rc=0
if [ "${L31B_SINGLE:-0}" = 1 ]; then
  echo ">>> L31B_SINGLE=1: skipping the re-run pass"
  cp "$OUT/install-first.tsv" "$OUT/install-second.tsv"
else
  server_pass second || pass2_rc=$?
  client_bin_stat second
  echo ">>> pass second worst mrg rc=$pass2_rc"
fi

{
  echo "pass_second_rc	$pass2_rc"
} >> "$OUT/header.txt"

# --- normalise + diff (no allowlist: the cell must be 0 unexplained) ----
PREFIX_A="$OUT/reference"
PREFIX_B="$OUT/client"
CLIENT_PREFIX="$OUT/client"
echo ">>> normalising (reference vs client)"
python3 "$TEST_DIR/compare/normalize.py" "$PREFIX_A"
python3 "$TEST_DIR/compare/normalize.py" "$PREFIX_B"

echo ">>> diffing (no known-divergences allowlist)"
set +e
python3 "$TEST_DIR/compare/diff.py" --layer l31b "$PREFIX_A" "$PREFIX_B" \
  | tee "$OUT/l31b-report.txt"
diff_rc=${PIPESTATUS[0]}
set -e

# --- install-bin assertions (portuale S8a, bed side) --------------------
# first pass: exactly one `portuale-remote: install-bin 0` line;
# re-run: none; the file keeps the server digest + 0755 across passes.
echo ">>> install-bin assertions (see $OUT/install-bin.txt)"
set +e
{
  echo "# l31b install-bin evidence"
  echo "server_sha256	$SERVER_DIGEST"
  echo "expected_client_bin	/usr/local/bin/portuale-$SERVER_HASH16"
  echo ""
  echo "## install-bin lines per pass (stdout)"
  for p in first second; do
    [ "$p" = second ] && [ "${L31B_SINGLE:-0}" = 1 ] && continue
    # Per-atom files are $CLIENT_PREFIX.<flat>.<pass>.stdout.txt; sum
    # the matches (no files -> 0).
    # shellcheck disable=SC2126  # grep -c would print per-file counts; wc -l sums
    n=$(grep -h '^portuale-remote: install-bin 0$' "$CLIENT_PREFIX".*."$p.stdout.txt" 2>/dev/null | wc -l)
    echo "$p	install-bin-0-lines	$n"
    other=$(grep -h 'install-bin' "$CLIENT_PREFIX".*."$p.stdout.txt" "$CLIENT_PREFIX".*."$p.stderr.txt" 2>/dev/null | grep -v '^portuale-remote: install-bin 0$' || true)
    [ -n "$other" ] && { echo "$p	other-install-bin-lines:"; printf '%s\n' "$other" | sed 's/^/  /'; }
  done
  echo ""
  echo "## client binary stat per pass (path sha mode inode mtime)"
  echo "first	$(cat "$OUT/install-first.tsv")"
  echo "second	$(cat "$OUT/install-second.tsv")"
} > "$OUT/install-bin.txt"
set -e
cat "$OUT/install-bin.txt"

assert_rc=0
# shellcheck disable=SC2126  # see above: wc -l sums across the per-atom files
# (|| true: zero matches + pipefail would trip `set -e` via the assignment)
n_first=$(grep -h '^portuale-remote: install-bin 0$' "$CLIENT_PREFIX".*.first.stdout.txt 2>/dev/null | wc -l || true)
[ "$n_first" = 1 ] || { echo "!!! ASSERT: first pass has $n_first install-bin 0 lines, want exactly 1" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
if [ "${L31B_SINGLE:-0}" != 1 ]; then
  # shellcheck disable=SC2126  # see above
  n_second=$(grep -h 'install-bin' "$CLIENT_PREFIX".*.second.stdout.txt "$CLIENT_PREFIX".*.second.stderr.txt 2>/dev/null | wc -l || true)
  [ "$n_second" = 0 ] || { echo "!!! ASSERT: re-run has $n_second install-bin lines, want 0" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
fi
# install-<pass>.tsv: path, sha256, mode, inode, mtime (tab-separated;
# mtime is the tail, it contains a space). An empty/missing file must
# fail the assertions below, not `set -e`.
read -r bin1 sha1 mode1 _rest1 < "$OUT/install-first.tsv" || true
read -r bin2 sha2 _mode2 _rest2 < "$OUT/install-second.tsv" || true
[ "$bin1" = "/usr/local/bin/portuale-$SERVER_HASH16" ] \
  || { echo "!!! ASSERT: client binary path is '$bin1', want '/usr/local/bin/portuale-$SERVER_HASH16'" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
[ "$sha1" = "$SERVER_DIGEST" ] \
  || { echo "!!! ASSERT: client binary digest $sha1 != server $SERVER_DIGEST" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
[ "$mode1" = 755 ] \
  || { echo "!!! ASSERT: client binary mode $mode1 != 755" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
if [ "${L31B_SINGLE:-0}" != 1 ]; then
  [ "$bin1" = "$bin2" ] && [ "$sha1" = "$sha2" ] \
    || { echo "!!! ASSERT: client binary changed across passes ($bin1/$sha1 vs $bin2/$sha2)" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
  ts1=$(cut -f5- "$OUT/install-first.tsv"); ts2=$(cut -f5- "$OUT/install-second.tsv")
  in1=$(cut -f4 "$OUT/install-first.tsv"); in2=$(cut -f4 "$OUT/install-second.tsv")
  { [ "$in1" = "$in2" ] || [ "$ts1" = "$ts2" ]; } \
    || { echo "!!! ASSERT: client binary inode ($in1 vs $in2) and mtime both changed" | tee -a "$OUT/install-bin.txt"; assert_rc=1; }
fi
[ "$assert_rc" = 0 ] && echo ">>> install-bin assertions: HOLD" | tee -a "$OUT/install-bin.txt"

ln -sfn "$RUN/l31b-report.txt" "$LOGS_DIR/l31b-report.txt"
echo ">>> report: $OUT/l31b-report.txt   (diff rc=$diff_rc, asserts rc=$assert_rc)"
if [ "$diff_rc" != 0 ] || [ "$assert_rc" != 0 ]; then
  exit 1
fi
exit 0
