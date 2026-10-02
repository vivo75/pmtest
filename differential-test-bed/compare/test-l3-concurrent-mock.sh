#!/bin/bash
# test-l3-concurrent-mock.sh -- dry validation of l3-source-parity.sh
# concurrency WITHOUT podman (S2, backlog #283 B1).
#
# Runs the REAL orchestrator with PORTTEST_PODMAN=<stub> (the script
# already honours that override via run/lib.sh) plus L3_SKIP_PREFLIGHT=1
# (skips the PM build + image check, which need a real bed). The stub
# logs every argv, sleeps, writes minimal fake snapshots that normalize
# + diff grade clean, and exits a chosen rc.
#
# Four scenarios:
#   1. concurrent green (default): both stubs overlapped (timestamps),
#      cpusets present + distinct, per-side distfiles dirs, .exit 0/0,
#      final rc 0, UNEXPLAINED 0.
#   2. concurrent failing side (portuale rc 124, no snapshot): final
#      rc 2 via the unchanged "missing snapshot" grading path.
#   3. serial green (L3_CONCURRENT=0): no overlap, no --cpuset-cpus,
#      shared distfiles bind, .exit 0/0, rc 0; candidate.txt byte-equal
#      to (1), l3-report.txt equal modulo dates/concur/cpusets lines.
#   4. serial failing side: same rc 2 + same grading line as (2) --
#      the failing side yields the same final verdict path as before.
#   5. concurrent taskset green (L3_CPUSET_MODE=taskset): no
#      --cpuset-cpus flag; the guest is `bash -c 'exec taskset -c
#      "$0" ...' <cpuset> <pm> <atomlist> <outdir>` with the same
#      cpuset strings as (1), same snapshots, report mode=taskset.
#   6. serial taskset green (L3_CPUSET_MODE=taskset, L3_CONCURRENT=0):
#      byte-for-byte the old command -- neither --cpuset-cpus nor
#      taskset -- shared distfiles bind.
#   7. auto probe (L3_CPUSET_MODE=auto + L3_CGROUP_CONTROLLERS_FILE):
#      a fake controllers file listing cpuset selects cgroup mode, one
#      without selects taskset mode.
#
# Cases 1-4 force L3_CPUSET_MODE=cgroup so the legacy
# `--cpuset-cpus` argv stays pinned while auto defaults to taskset on
# this host (rootless, no delegated cpuset controller).
#
#   differential-test-bed/compare/test-l3-concurrent-mock.sh
#
# Exit 0 all good, 1 a case failed, 2 setup error. Removes every run
# dir / metrics json / symlink it creates under differential-test-bed/.

set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BED=$(cd "$HERE/.." && pwd)
SCRIPT=$BED/run/l3-source-parity.sh
ATOMLIST=$BED/atomlists/l3-smoke.txt
LOGS=$BED/logs
[ -x "$SCRIPT" ] || { echo "test-l3-concurrent-mock: SETUP -- $SCRIPT missing" >&2; exit 2; }
[ -f "$ATOMLIST" ] || { echo "test-l3-concurrent-mock: SETUP -- $ATOMLIST missing" >&2; exit 2; }

TMP=$(mktemp -d)
STUB=$TMP/stub-podman
STUB_LOG=$TMP/stub.log
: > "$STUB_LOG"
CREATED=$TMP/created
: > "$CREATED"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

# Remember pre-existing state so cleanup restores it byte-for-byte.
LOGS_EXIST=0; [ -d "$LOGS" ] && LOGS_EXIST=1
LATEST_BEFORE=; [ -e "$LOGS/l3-latest" ] && LATEST_BEFORE=$(readlink "$LOGS/l3-latest")
REPORT_BEFORE=; [ -e "$LOGS/l3-report.txt" ] && REPORT_BEFORE=$(readlink "$LOGS/l3-report.txt")
cleanup() {
  local r
  [ -f "$CREATED" ] && while IFS= read -r r; do
    [ -n "$r" ] || continue
    rm -rf "$LOGS/$r" "$LOGS/metrics/$r.json"
  done < "$CREATED"
  if [ -n "${LATEST_BEFORE:-}" ]; then ln -sfn "$LATEST_BEFORE" "$LOGS/l3-latest"
  else rm -f "$LOGS/l3-latest"; fi
  if [ -n "${REPORT_BEFORE:-}" ]; then ln -sfn "$REPORT_BEFORE" "$LOGS/l3-report.txt"
  else rm -f "$LOGS/l3-report.txt"; fi
  if [ "$LOGS_EXIST" = 0 ]; then rm -rf "$LOGS"; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- the stub ----------------------------------------------------------
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
# stub podman for test-l3-concurrent-mock.sh: logs argv with timestamps,
# sleeps, writes minimal fake snapshots, exits a chosen rc.
LOG=${STUB_LOG:?}
ts() { date +%s.%N; }
cmd=${1:-}
case $cmd in
  image) exit 0 ;;
  rm) printf 'RM t=%s argv=%s\n' "$(ts)" "$*" >>"$LOG"; exit 0 ;;
  run)
    shift
    name= cpuset= taskset= jobs= logsbind= distbind= guestout=
    prev= saw_taskset_script=0
    for a in "$@"; do
      if [ "$saw_taskset_script" = 1 ]; then
        taskset=$a; saw_taskset_script=0; prev=; continue
      fi
      case $prev in
        --name) name=$a; prev=; continue ;;
        --cpuset-cpus) cpuset=$a; prev=; continue ;;
        -v)
          case $a in
            *:/TEST/logs) logsbind=${a%:/TEST/logs} ;;
            *:/distfiles) distbind=${a%:/distfiles} ;;
          esac
          prev=; continue ;;
        -e)
          case $a in L3_JOBS=*) jobs=${a#L3_JOBS=};; esac
          prev=; continue ;;
      esac
      case $a in
        -v|--name|--cpuset-cpus|-e) prev=$a ;;
        /TEST/logs/*) guestout=$a ;;
        *'exec taskset -c'*) saw_taskset_script=1 ;;
      esac
    done
    label=${name#porttest-l3-}; label=${label%-*}
    printf 'RUN t=%s name=%s label=%s cpuset=%s taskset=%s jobs=%s dist=%s\n' \
      "$(ts)" "$name" "$label" "$cpuset" "$taskset" "$jobs" "$distbind" >>"$LOG"
    printf 'ARGV t=%s label=%s argv=%s\n' "$(ts)" "$label" "$*" >>"$LOG"
    if [ "${STUB_FAIL_LABEL:-}" = "$label" ]; then
      rc=${STUB_FAIL_RC:-124}
      printf 'END t=%s name=%s label=%s rc=%s fail=1\n' "$(ts)" "$name" "$label" "$rc" >>"$LOG"
      exit "$rc"
    fi
    sleep "${STUB_SLEEP:-2}"
    target=$logsbind/${guestout#/TEST/logs/}
    mkdir -p "$target"
    printf '/usr/bin/tree\tf\t0755\t0\t0\t100\tabc123\t-\t-\n/usr/lib/libx.so\tf\t0644\t0\t0\t200\tdef456\t-\t-\n' \
      > "$target.files.tsv"
    printf '/usr/bin/tree\t1000\n/usr/lib/libx.so\t1000\n' > "$target.mtimes.tsv"
    printf 'app-text/tree-2.2.1\n' > "$target.merged-cpvs.txt"
    printf 'root\t/\nbuild_args\t--oneshot\n' > "$target.meta.tsv"
    # Simulate a fetch into the side's distfiles dir (copy-back proof).
    printf 'fetched-by-%s\n' "$label" > "$distbind/fetched-by-$label.tar"
    printf 'END t=%s name=%s label=%s rc=0\n' "$(ts)" "$name" "$label" >>"$LOG"
    exit 0
    ;;
  *) printf 'STUB-UNEXPECTED t=%s argv=%s\n' "$(ts)" "$*" >>"$LOG"; exit 99 ;;
esac
STUBEOF
chmod +x "$STUB"

# Shared distfiles seed (the hazard S2 removes: same tarballs, one dir).
SEED=$TMP/shared-distfiles
mkdir -p "$SEED"
printf 'seed-tarball\n' > "$SEED/seed-from-cache.tar"
SEED_SHA=$(sha256sum "$SEED/seed-from-cache.tar" | cut -d' ' -f1)

# --- one orchestrator run ----------------------------------------------
# run_case <name>: uses $CASE_CONCURRENT / $CASE_FAIL_LABEL /
# $CASE_CPUSET_MODE globals (CASE_CPUSET_MODE defaults to cgroup so
# the four legacy cases keep the old `--cpuset-cpus` argv).
# Sets OUT (run dir) and SEC (this case's stub-log section).
run_case() {
  local name=$1 l0 rc
  l0=$(wc -l < "$STUB_LOG")
  OUT_RUN=$TMP/$name.stdout
  set +e
  ( export PORTTEST_PODMAN="$STUB" L3_SKIP_PREFLIGHT=1 L3_TIMEOUT=120 \
      L3_DISTFILES="$SEED" STUB_LOG STUB_SLEEP="${STUB_SLEEP:-2}" \
      STUB_FAIL_LABEL="${CASE_FAIL_LABEL:-}" STUB_FAIL_RC="${CASE_FAIL_RC:-124}" \
      L3_CONCURRENT="$CASE_CONCURRENT" \
      L3_CPUSET_MODE="${CASE_CPUSET_MODE:-cgroup}"
    unset L3_JOBS L3_CPUSET_A L3_CPUSET_B
    if [ -n "${CASE_CONTROLLERS_FILE:-}" ]; then
      export L3_CGROUP_CONTROLLERS_FILE="$CASE_CONTROLLERS_FILE"
    else
      unset L3_CGROUP_CONTROLLERS_FILE
    fi
    "$SCRIPT" "$ATOMLIST" >"$OUT_RUN" 2>&1
  )
  rc=$?
  set -e
  CASE_RC=$rc
  tail -n +$((l0 + 1)) "$STUB_LOG" > "$TMP/$name.log"
  SEC=$TMP/$name.log
  RUN_NOW=$(readlink "$LOGS/l3-latest" 2>/dev/null || true)
  if [ -z "$RUN_NOW" ] || grep -qx "$RUN_NOW" "$CREATED" 2>/dev/null; then
    bad "$name: no fresh run dir (timestamp collision?)"
    OUT=$LOGS/MISSING
  else
    echo "$RUN_NOW" >> "$CREATED"
    OUT=$LOGS/$RUN_NOW
  fi
}

sec() { grep -a "$1" "$SEC"; }
start_of() { sec "^RUN " | grep -a "label=$1 " | sed 's/^RUN t=\([^ ]*\) .*/\1/'; }
end_of()   { sec "^END " | grep -a "label=$1 " | sed 's/^END t=\([^ ]*\) .*/\1/'; }
field_of() {  # <label> <field>: cpuset/taskset/jobs/dist from the RUN record
  sec "^RUN " | grep -a "label=$1 " | sed "s/.* $2=\\([^ ]*\\).*/\\1/" | head -1
}
overlapped() {  # <a> <b>: 1 when the two stubs overlapped in time
  awk -v a0="$(start_of "$1")" -v a1="$(end_of "$1")" \
      -v b0="$(start_of "$2")" -v b1="$(end_of "$2")" \
      'BEGIN{ exit !((a0 < b1) && (b0 < a1)) }'
}

# --- 1. concurrent green -------------------------------------------------
CASE_CONCURRENT=1; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=cgroup; CASE_CONTROLLERS_FILE=
run_case conc-green
OUT_CG=$OUT
[ "$CASE_RC" = 0 ] && ok "conc-green: final rc 0" || bad "conc-green: final rc=$CASE_RC (want 0)"
if overlapped portage portuale; then ok "conc-green: stubs overlapped"
else bad "conc-green: stubs did NOT overlap"; fi
CA=$(field_of portage cpuset); CB=$(field_of portuale cpuset)
[ -n "$CA" ] && [ -n "$CB" ] && [ "$CA" != "$CB" ] \
  && ok "conc-green: distinct cpusets [$CA] [$CB]" \
  || bad "conc-green: cpusets missing/indistinct [$CA] [$CB]"
[ "$(field_of portage jobs)" = 1 ] && [ "$(field_of portuale jobs)" = 1 ] \
  && ok "conc-green: L3_JOBS default stays 1" \
  || bad "conc-green: L3_JOBS default changed"
[ "$(cat "$OUT/portage.exit")" = 0 ] && [ "$(cat "$OUT/portuale.exit")" = 0 ] \
  && ok "conc-green: .exit 0/0" || bad "conc-green: .exit wrong"
if grep -q "UNEXPLAINED *: 0" "$OUT_CG/candidate.txt" 2>/dev/null; then
  ok "conc-green: candidate UNEXPLAINED 0"
else bad "conc-green: no clean candidate.txt"; fi
grep -q "^concur : 1" "$OUT/l3-report.txt" && ok "conc-green: report marks concur 1" \
  || bad "conc-green: report lacks concur line"
DA=$(field_of portage dist); DB=$(field_of portuale dist)
[ -n "$DA" ] && [ -n "$DB" ] && [ "$DA" != "$DB" ] \
  && ok "conc-green: per-side distfiles dirs" \
  || bad "conc-green: distfiles not split [$DA] [$DB]"
[ "$(sha256sum "$DA/seed-from-cache.tar" 2>/dev/null | cut -d' ' -f1)" = "$SEED_SHA" ] \
  && [ "$(sha256sum "$DB/seed-from-cache.tar" 2>/dev/null | cut -d' ' -f1)" = "$SEED_SHA" ] \
  && ok "conc-green: seeded cache content intact in both sides" \
  || bad "conc-green: seed content diverged"
[ -f "$SEED/fetched-by-portage.tar" ] && [ -f "$SEED/fetched-by-portuale.tar" ] \
  && ok "conc-green: new tarballs copied back to shared cache" \
  || bad "conc-green: copy-back missing"
rm -f "$SEED"/fetched-by-*.tar  # keep the seed pristine for later cases
# cgroup argv: --cpuset-cpus present, no taskset wrapper.
if grep -a "^ARGV " "$SEC" | grep -a "label=portage " | grep -q -- "--cpuset-cpus"; then
  ok "conc-green: cgroup argv carries --cpuset-cpus"
else bad "conc-green: cgroup argv lacks --cpuset-cpus"; fi
if grep -a "^ARGV " "$SEC" | grep -q "taskset"; then
  bad "conc-green: cgroup argv unexpectedly wraps taskset"
else ok "conc-green: cgroup argv has no taskset wrapper"; fi
[ -z "$(field_of portage taskset)" ] && [ -z "$(field_of portuale taskset)" ] \
  && ok "conc-green: no taskset pinning recorded" \
  || bad "conc-green: unexpected taskset field"
grep -q "(mode=cgroup)" "$OUT/l3-report.txt" && ok "conc-green: report mode=cgroup" \
  || bad "conc-green: report lacks mode=cgroup"

# --- 2. concurrent failing side ------------------------------------------
CASE_CONCURRENT=1; CASE_FAIL_LABEL=portuale; CASE_FAIL_RC=124; CASE_CPUSET_MODE=cgroup; CASE_CONTROLLERS_FILE=
run_case conc-fail
[ "$CASE_RC" = 2 ] && ok "conc-fail: final rc 2" || bad "conc-fail: final rc=$CASE_RC (want 2)"
[ "$(cat "$OUT/portuale.exit")" = 124 ] && [ "$(cat "$OUT/portage.exit")" = 0 ] \
  && ok "conc-fail: .exit 124/0" || bad "conc-fail: .exit wrong"
if grep -q "missing snapshot: portuale -- run invalid" "$OUT_RUN"; then
  ok "conc-fail: unchanged missing-snapshot grading line"
else bad "conc-fail: grading line missing"; fi
[ ! -f "$OUT/candidate.txt" ] && ok "conc-fail: no candidate without a pair" \
  || bad "conc-fail: unexpected candidate.txt"

# --- 3. serial green -------------------------------------------------------
CASE_CONCURRENT=0; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=cgroup; CASE_CONTROLLERS_FILE=
run_case serial-green
OUT_SG=$OUT
[ "$CASE_RC" = 0 ] && ok "serial-green: final rc 0" || bad "serial-green: final rc=$CASE_RC (want 0)"
if overlapped portage portuale; then bad "serial-green: stubs overlapped (want serial)"
else ok "serial-green: stubs ran one after the other"; fi
[ -z "$(field_of portage cpuset)" ] && [ -z "$(field_of portuale cpuset)" ] \
  && ok "serial-green: no --cpuset-cpus (old command line)" \
  || bad "serial-green: unexpected cpuset flags"
[ "$(field_of portage dist)" = "$SEED" ] && [ "$(field_of portuale dist)" = "$SEED" ] \
  && ok "serial-green: shared distfiles bind (old behaviour)" \
  || bad "serial-green: distfiles bind changed"
[ "$(cat "$OUT/portage.exit")" = 0 ] && [ "$(cat "$OUT/portuale.exit")" = 0 ] \
  && ok "serial-green: .exit 0/0" || bad "serial-green: .exit wrong"
if cmp -s "$OUT_CG/candidate.txt" "$OUT_SG/candidate.txt"; then
  ok "serial-green: candidate.txt byte-equal to concurrent run"
else bad "serial-green: candidate.txt differs from concurrent run"; fi
# l3-report.txt carries the per-run OUT path; normalise it away along
# with the date/concur/cpuset lines before comparing.
norm_report() {  # <report>: canonical bytes on stdout
  sed -e "s|$LOGS/l3-[^ /]*|OUT|g" "$1" | grep -v -e '^dates' -e '^concur' -e '^cpusets'
}
if diff <(norm_report "$OUT_CG/l3-report.txt") \
        <(norm_report "$OUT_SG/l3-report.txt") >/dev/null; then
  ok "serial-green: l3-report.txt equal modulo dates/concur/cpusets/run-path"
else bad "serial-green: l3-report.txt differs beyond dates/concur/cpusets/run-path"; fi

# --- 4. serial failing side: same verdict path as (2) -----------------------
CASE_CONCURRENT=0; CASE_FAIL_LABEL=portuale; CASE_FAIL_RC=124; CASE_CPUSET_MODE=cgroup; CASE_CONTROLLERS_FILE=
run_case serial-fail
[ "$CASE_RC" = 2 ] && ok "serial-fail: final rc 2 (same as concurrent)" \
  || bad "serial-fail: final rc=$CASE_RC (want 2, same as concurrent)"
if grep -q "missing snapshot: portuale -- run invalid" "$OUT_RUN"; then
  ok "serial-fail: same grading line as concurrent"
else bad "serial-fail: grading line differs"; fi

# --- 5. concurrent taskset green -----------------------------------------
CASE_CONCURRENT=1; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=taskset; CASE_CONTROLLERS_FILE=
run_case conc-taskset
OUT_TS=$OUT
[ "$CASE_RC" = 0 ] && ok "conc-taskset: final rc 0" || bad "conc-taskset: final rc=$CASE_RC (want 0)"
if overlapped portage portuale; then ok "conc-taskset: stubs overlapped"
else bad "conc-taskset: stubs did NOT overlap"; fi
TA=$(field_of portage taskset); TB=$(field_of portuale taskset)
[ -n "$TA" ] && [ -n "$TB" ] && [ "$TA" != "$TB" ] \
  && ok "conc-taskset: distinct taskset cpusets [$TA] [$TB]" \
  || bad "conc-taskset: taskset cpusets missing/indistinct [$TA] [$TB]"
[ "$TA" = "$CA" ] && [ "$TB" = "$CB" ] \
  && ok "conc-taskset: cpuset strings identical to cgroup mode" \
  || bad "conc-taskset: cpuset strings differ from cgroup mode [$TA vs $CA] [$TB vs $CB]"
[ -z "$(field_of portage cpuset)" ] && [ -z "$(field_of portuale cpuset)" ] \
  && ok "conc-taskset: no --cpuset-cpus flag" \
  || bad "conc-taskset: unexpected --cpuset-cpus flag"
if grep -a "^ARGV " "$SEC" | grep -a "label=portage " | grep -q -- "--cpuset-cpus"; then
  bad "conc-taskset: argv unexpectedly carries --cpuset-cpus"
else ok "conc-taskset: argv has no --cpuset-cpus"; fi
if grep -a "^ARGV " "$SEC" | grep -a "label=portage " | grep -q 'exec taskset -c'; then
  ok "conc-taskset: argv wraps build-and-merge in taskset"
else bad "conc-taskset: argv lacks taskset wrapper"; fi
# The build-and-merge.sh argv after the wrapper must be otherwise
# identical: <cpuset> <pm> <atomlist> <outdir> with the same pm names
# and guest outdirs as the cgroup run.
if grep -a "^ARGV " "$SEC" | grep -a "label=portage " | grep -q "/TEST/layers/l3/build-and-merge.sh"; then
  ok "conc-taskset: wrapper still calls build-and-merge.sh"
else bad "conc-taskset: wrapper lost build-and-merge.sh"; fi
if grep -a "^ARGV " "$SEC" | grep -a "label=portuale " | grep -q "portuale.*l3-smoke.txt.*/TEST/logs/"; then
  ok "conc-taskset: portuale wrapper carries pm + atomlist + outdir"
else bad "conc-taskset: portuale wrapper argv incomplete"; fi
[ "$(cat "$OUT/portage.exit")" = 0 ] && [ "$(cat "$OUT/portuale.exit")" = 0 ] \
  && ok "conc-taskset: .exit 0/0" || bad "conc-taskset: .exit wrong"
grep -q "(mode=taskset)" "$OUT/l3-report.txt" && ok "conc-taskset: report mode=taskset" \
  || bad "conc-taskset: report lacks mode=taskset"
if cmp -s "$OUT_CG/candidate.txt" "$OUT_TS/candidate.txt"; then
  ok "conc-taskset: candidate.txt byte-equal to cgroup run"
else bad "conc-taskset: candidate.txt differs from cgroup run"; fi
rm -f "$SEED"/fetched-by-*.tar

# --- 6. serial taskset green: old command, no pinning at all ---------------
CASE_CONCURRENT=0; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=taskset; CASE_CONTROLLERS_FILE=
run_case serial-taskset
[ "$CASE_RC" = 0 ] && ok "serial-taskset: final rc 0" || bad "serial-taskset: final rc=$CASE_RC (want 0)"
[ -z "$(field_of portage cpuset)" ] && [ -z "$(field_of portuale cpuset)" ] \
  && ok "serial-taskset: no --cpuset-cpus (old command line)" \
  || bad "serial-taskset: unexpected cpuset flags"
[ -z "$(field_of portage taskset)" ] && [ -z "$(field_of portuale taskset)" ] \
  && ok "serial-taskset: no taskset wrapper (old command line)" \
  || bad "serial-taskset: unexpected taskset wrapper"
if grep -a "^ARGV " "$SEC" | grep -q "taskset"; then
  bad "serial-taskset: argv unexpectedly mentions taskset"
else ok "serial-taskset: argv has no taskset"; fi
[ "$(field_of portage dist)" = "$SEED" ] && [ "$(field_of portuale dist)" = "$SEED" ] \
  && ok "serial-taskset: shared distfiles bind (old behaviour)" \
  || bad "serial-taskset: distfiles bind changed"
grep -q "(mode=taskset)" "$OUT/l3-report.txt" && ok "serial-taskset: report mode=taskset" \
  || bad "serial-taskset: report lacks mode=taskset"
if cmp -s "$OUT_SG/candidate.txt" "$OUT/candidate.txt"; then
  ok "serial-taskset: candidate.txt byte-equal to serial cgroup run"
else bad "serial-taskset: candidate.txt differs from serial cgroup run"; fi

# --- 7. auto probe via fake controllers files ------------------------------
FAKE_ON=$TMP/controllers-with-cpuset
FAKE_OFF=$TMP/controllers-without-cpuset
printf 'cpu memory pids cpuset\n' > "$FAKE_ON"
printf 'cpu memory pids\n' > "$FAKE_OFF"
CASE_CONCURRENT=1; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=auto; CASE_CONTROLLERS_FILE=$FAKE_ON
run_case auto-cgroup
[ -n "$(field_of portage cpuset)" ] && [ -z "$(field_of portage taskset)" ] \
  && ok "auto-cgroup: controllers listing cpuset selects cgroup mode" \
  || bad "auto-cgroup: did not select cgroup mode"
grep -q "(mode=cgroup)" "$OUT/l3-report.txt" && ok "auto-cgroup: report mode=cgroup" \
  || bad "auto-cgroup: report lacks mode=cgroup"
rm -f "$SEED"/fetched-by-*.tar
CASE_CONCURRENT=1; CASE_FAIL_LABEL=; CASE_CPUSET_MODE=auto; CASE_CONTROLLERS_FILE=$FAKE_OFF
run_case auto-taskset
[ -z "$(field_of portage cpuset)" ] && [ -n "$(field_of portage taskset)" ] \
  && ok "auto-taskset: controllers without cpuset selects taskset mode" \
  || bad "auto-taskset: did not select taskset mode"
grep -q "(mode=taskset)" "$OUT/l3-report.txt" && ok "auto-taskset: report mode=taskset" \
  || bad "auto-taskset: report lacks mode=taskset"
rm -f "$SEED"/fetched-by-*.tar
CASE_CONTROLLERS_FILE=

# cache untouched overall?
[ "$(sha256sum "$SEED/seed-from-cache.tar" | cut -d' ' -f1)" = "$SEED_SHA" ] \
  && ok "shared seed cache byte-intact after all cases" \
  || bad "shared seed cache modified"

echo "test-l3-concurrent-mock: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
