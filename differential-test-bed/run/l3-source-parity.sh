#!/bin/bash
# L3 -- source-build parity: both package managers build+merge the same
# atom list FROM SOURCE (`--emptytree --oneshot --usepkg=n`) into two
# fresh, identical containers under the determinism block, then the full
# installed tree + VDB are snapshotted and diffed.
#
#   differential-test-bed/run/l3-source-parity.sh [atomlist]     (default l3-smoke.txt)
#
# Env:
#   L3_PM=both|portage|portuale  (default both; one-side iteration)
#   L3_CONCURRENT=1              with L3_PM=both the portage and portuale
#                                sides run concurrently on disjoint CPU
#                                halves (see cpusets below); 0 restores
#                                the old serial order byte-for-byte
#                                (same snapshots, same verdict logic).
#                                Single-side modes always run serially.
#   L3_CPUSET_A / L3_CPUSET_B    override the computed `--cpuset-cpus`
#                                strings for the portage / portuale side
#                                (e.g. L3_CPUSET_A=0-5,16-21).
#   L3_CPUSET_MODE=auto|cgroup|taskset
#                                how the per-side pinning is applied
#                                (default auto). cgroup is the existing
#                                `--cpuset-cpus` flag. taskset leaves the
#                                flag off and pins INSIDE the container:
#                                the guest becomes `/bin/bash -c 'exec
#                                taskset -c "$0"
#                                /TEST/layers/l3/build-and-merge.sh "$@"'
#                                <cpuset> <pm> <atomlist> <outdir>` (same
#                                build-and-merge argv, quoting-safe: the
#                                cpuset travels as `$0`, never
#                                interpolated). auto selects cgroup when
#                                euid is 0 or the user's systemd service
#                                `cgroup.controllers` lists `cpuset`,
#                                else taskset (rootless podman without a
#                                delegated cpuset controller dies in crun
#                                with rc 126, so the cgroup flag is
#                                unusable there; in-container taskset is
#                                inherited by all children).
#   L3_JOBS                      guest MAKEOPTS parallelism per side
#                                (default 1 = deterministic; the smoke
#                                use is L3_JOBS=12 per side).
#   L3_CONTROL=1                 also run a second portage container and
#                                diff the two portage runs (noise floor)
#                                (controls run serially, after the wait)
#   L3_BUILD_ARGS                unset -> the atom list's `# l3-build-args:`
#                                directive, else the default; set in the
#                                host env wins over the directive (#280)
#   L3_TMPFS=1                   build on a tmpfs at /var/tmp/portage;
#                                0 = today's disk behaviour (#282)
#   L3_TMPFS_SIZE=8g             tmpfs size (#282). Measured peaks at
#                                -j28: l3-core 3.1 GiB (gcc closure,
#                                l3-20260930T212609Z), l3-smoke 0.9 GiB
#                                (l3-20260930T211117Z); 8g leaves ~2.5x.
#   L3_DISTFILES                 default $LOGS_DIR/_l2-distfiles
#   GENTOO_MIRRORS               forwarded to both containers when set (lib.sh)
#   L3_TIMEOUT=28800             per-container wall-clock cap
#   L3_SKIP_PORTAGE_UPGRADE=0
#
# Exit: 0 green (candidate diff and control pair 0 unexplained),
#       1 unexplained finding(s), 2 setup error.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib.sh"

ATOMLIST=$(realpath -e "${1:-$TEST_DIR/atomlists/l3-smoke.txt}" 2>/dev/null) \
  || { echo "atom list not found" >&2; exit 2; }
case $ATOMLIST in
  "$TEST_DIR"/*) REL_ATOMLIST="/TEST/${ATOMLIST#"$TEST_DIR"/}" ;;
  *) echo "atom list must live under $TEST_DIR/" >&2; exit 2 ;;
esac

MODE=${L3_PM:-both}
case $MODE in both|portage|portuale) ;; *) echo "L3_PM must be both|portage|portuale" >&2; exit 2 ;; esac

DISTFILES=${L3_DISTFILES:-$LOGS_DIR/_l2-distfiles}
TIMEOUT=${L3_TIMEOUT:-28800}
RUN="l3-$(timestamp)"
OUT="$LOGS_DIR/$RUN"
mkdir -p "$OUT" "$DISTFILES"
ln -sfn "$RUN" "$LOGS_DIR/l3-latest"

# L3_SKIP_PREFLIGHT=1 skips the PM build + image check (test seam for
# the podman-stub mock in compare/test-l3-concurrent-mock.sh: the stub
# stands in for the image, and there is no PM binary to stamp; never
# set on real runs).
if [ -z "${L3_SKIP_PREFLIGHT:-}" ]; then
  ensure_pm_built "$OUT"
  ensure_image
else
  echo ">>> L3_SKIP_PREFLIGHT=1: PM build + image check skipped (mock)"
fi

# The two sides of one cell run concurrently (B1): each side builds at
# -j12 on 6 whole physical cores of its own CCX (both SMT threads, never
# half a core), the rest of the machine stays headroom for the host and
# podman. The split is computed from the host topology by l3_cpusets()
# below, never hard-coded. Per-side distfiles dirs (seeded by hardlink
# from the shared cache, new tarballs copied back after the wait) remove
# the one shared-write hazard: both sides fetch the same tarballs, and
# two containers fetching into one host dir race on the same dentries.
# Least invasive because it touches only host-side mounts -- no extra
# container run, no guest change -- at the price of at most one redundant
# download per tarball.
run_pm() {  # <label> <portage|portuale> [cpuset] [distfiles-dir]
  local label=$1 pm=$2 cpuset=${3:-} sidedist=${4:-$DISTFILES}
  echo ">>> L3 build+merge: $label ($pm)"
  set +e
  # `timeout` cannot run a shell function, so this reuses
  # `podman_run_pm`'s own mounts (`$PM_MOUNTS`: the PM binaries, its
  # checkout at its build-time path, /TEST, the shared logs) and adds
  # the distfiles cache.
  # #282: builds run configure scripts from /var/tmp/portage, and
  # podman's --tmpfs defaults to noexec -- so the mount needs `exec`.
  # L3_TMPFS=0 keeps exactly today's command (no mount). The array is
  # empty then; the ${arr[@]+"${arr[@]}"} form stays safe under set -u.
  tmpfs_args=()
  if [ "${L3_TMPFS:-1}" = 1 ]; then
    # L3_TMPFS_SIZE default 8g: ~2.5x the measured l3-core peak (3.1 GiB).
    tmpfs_args=(--tmpfs "/var/tmp/portage:rw,exec,nosuid,nodev,size=${L3_TMPFS_SIZE:-8g},mode=0775")
  fi
  # #280: L3_BUILD_ARGS is forwarded ONLY when set in the host env --
  # always passing it with a default would shadow the atom list's
  # `# l3-build-args:` directive inside build-and-merge.sh.
  build_args_env=()
  if [ -n "${L3_BUILD_ARGS+x}" ]; then
    build_args_env=(-e "L3_BUILD_ARGS=$L3_BUILD_ARGS")
  fi
  # Optional per-side pinning. Empty (the serial path) keeps exactly the
  # old command line: an empty array expands to no argument at all.
  # CPUSET_MODE=cgroup keeps the existing `--cpuset-cpus` flag;
  # CPUSET_MODE=taskset leaves the flag off and pins inside the
  # container via `taskset -c <cpuset>` wrapping the otherwise
  # identical build-and-merge.sh argv (quoting-safe: the cpuset travels
  # as `$0` to `bash -c`, never interpolated into the script string).
  # The serial path passes no cpuset, so it stays byte-for-byte the old
  # command in either mode.
  cpuset_args=()
  guest_cmd=(/TEST/layers/l3/build-and-merge.sh "$pm" "$REL_ATOMLIST" "/TEST/logs/$RUN/$label")
  if [ -n "$cpuset" ]; then
    if [ "${CPUSET_MODE:-cgroup}" = taskset ]; then
      guest_cmd=(-c 'exec taskset -c "$0" /TEST/layers/l3/build-and-merge.sh "$@"' \
        "$cpuset" "$pm" "$REL_ATOMLIST" "/TEST/logs/$RUN/$label")
    else
      cpuset_args=(--cpuset-cpus "$cpuset")
    fi
  fi
  timeout "$TIMEOUT" "$PODMAN" run --rm --name "porttest-l3-$label-$$" \
    --security-opt seccomp=unconfined --cgroups=enabled --cgroupns=private \
    --hostname porttest-l3 \
    "${PM_MOUNTS[@]}" \
    ${cpuset_args[@]+"${cpuset_args[@]}"} \
    -v "$sidedist:/distfiles" \
    ${tmpfs_args[@]+"${tmpfs_args[@]}"} \
    -e DISTDIR=/distfiles \
    ${MIRROR_ENV[@]+"${MIRROR_ENV[@]}"} \
    -e "SNAPSHOT_PRUNE=$PM_REPO" \
    -e "L3_SKIP_PORTAGE_UPGRADE=${L3_SKIP_PORTAGE_UPGRADE:-0}" \
    -e "L3_TMPFS=${L3_TMPFS:-1}" \
    ${build_args_env[@]+"${build_args_env[@]}"} \
    -e "L3_JOBS=${L3_JOBS:-1}" \
    --entrypoint /bin/bash "$IMAGE" \
    "${guest_cmd[@]}" \
    2>&1 | tee "$OUT/$label.container.log"
  local rc=${PIPESTATUS[0]}
  set -e
  # Persist the real rc next to the logs: run_pm returns 0 by design (a
  # failing side must not stop the orchestrator under `set -e`; grading
  # happens below), and a backgrounded call's `return` is unreadable, so
  # the status file is the record `wait` cannot give back.
  echo "$rc" > "$OUT/$label.exit"
  echo ">>> $label rc=$rc"
  return 0
}

# l3_cpusets: derive the per-side `--cpuset-cpus` strings from the host
# topology -- 6 whole physical cores (both SMT threads) on one CCX per
# side, the rest headroom. Sets CPUSET_A (portage) / CPUSET_B (portuale);
# empty when the topology is unreadable or the host is too small, in
# which case run_pm() runs unpinned. L3_CPUSET_A/B win per side.
l3_cpusets() {
  local auto_a= auto_b=
  local l3map= d= n= sib= e= low= mem= l3=
  local cores_l3= groups= ngroups= ga= gb= ma= mb=
  local core_order=()
  # Whole cores from SMT siblings: cpus sharing one
  # thread_siblings_list string are one physical core. `core_order`
  # keeps numeric (lowest cpu) order -- the sysfs glob itself expands
  # lexically (cpu0 cpu1 cpu10 ...), so the ids are sorted numerically
  # first; otherwise "first seen" is not the lowest cpu and the first-6
  # selection below picks the wrong cores. `cores_l3` maps each core to
  # its L3 id (`lscpu -p` columns CPU,Core,...,L3 -- the last field).
  if [ -d /sys/devices/system/cpu ]; then
    declare -A seen_core=()
    for n in $(for d in /sys/devices/system/cpu/cpu[0-9]*; do
                 [ -e "$d" ] && printf '%s\n' "${d##*cpu}"
               done 2>/dev/null | LC_ALL=C sort -n); do
      d=/sys/devices/system/cpu/cpu$n
      [ -r "$d/topology/thread_siblings_list" ] || { core_order=(); break; }
      sib=$(tr -d ' \n' < "$d/topology/thread_siblings_list")
      if [ -z "${seen_core[$sib]:-}" ]; then
        seen_core[$sib]="$n"
        core_order+=("$n:$sib")
      fi
    done
  fi
  l3map=$(lscpu -p 2>/dev/null | grep -v '^#' || true)
  if [ -n "$l3map" ] && [ "${#core_order[@]}" -gt 0 ]; then
    # Attach each core's L3 id (both threads of a core share one CCX,
    # so looking it up by the lowest cpu is exact).
    cores_l3=$(for e in "${core_order[@]}"; do
      low=${e%%:*} mem=${e#*:}
      l3=$(printf '%s\n' "$l3map" | awk -F, -v c="$low" '$1==c{print $NF; exit}')
      printf '%s %s %s\n' "$low" "$mem" "${l3:-?}"
    done | LC_ALL=C sort -n -k1,1)
    # Group cores per L3 id (numeric order: first group -> side A).
    groups=$(printf '%s\n' "$cores_l3" | awk '$3 != "?" {print $3}' | sort -n -u)
    ngroups=$(printf '%s\n' "$groups" | grep -c . || true)
    if [ "$ngroups" -ge 2 ]; then
      ga=$(printf '%s\n' "$groups" | sed -n 1p)
      gb=$(printf '%s\n' "$groups" | sed -n 2p)
      ma=$(printf '%s\n' "$cores_l3" | awk -v g="$ga" '$3==g{print $2}' \
           | head -6 | expand_cpu_lists | LC_ALL=C sort -n -u | tr '\n' ' ')
      mb=$(printf '%s\n' "$cores_l3" | awk -v g="$gb" '$3==g{print $2}' \
           | head -6 | expand_cpu_lists | LC_ALL=C sort -n -u | tr '\n' ' ')
      # Whole cores only: each side needs 6 cores = 12 threads.
      if [ "$(printf '%s' "$ma" | wc -w)" -eq 12 ] \
         && [ "$(printf '%s' "$mb" | wc -w)" -eq 12 ]; then
        # shellcheck disable=SC2086  # $ma/$mb are space-separated cpu lists
        auto_a=$(cpuset_compress $ma)
        # shellcheck disable=SC2086
        auto_b=$(cpuset_compress $mb)
      fi
    fi
  fi
  if [ -z "$auto_a" ] || [ -z "$auto_b" ]; then
    # Fallback (no CCX info): first 6 whole cores / next 6 whole cores
    # of the numeric core order (NOT lexical member-string order).
    if [ "${#core_order[@]}" -ge 12 ]; then
      ma=$(printf '%s\n' "${core_order[@]:0:6}" | sed 's/^[^:]*://' \
           | expand_cpu_lists | LC_ALL=C sort -n -u | tr '\n' ' ')
      mb=$(printf '%s\n' "${core_order[@]:6:6}" | sed 's/^[^:]*://' \
           | expand_cpu_lists | LC_ALL=C sort -n -u | tr '\n' ' ')
      # shellcheck disable=SC2086  # space-separated cpu lists
      auto_a=$(cpuset_compress $ma)
      # shellcheck disable=SC2086
      auto_b=$(cpuset_compress $mb)
    fi
  fi
  CPUSET_A=${L3_CPUSET_A:-$auto_a}
  CPUSET_B=${L3_CPUSET_B:-$auto_b}
}

# cpuset_compress <cpu...> -- 0 1 2 16 17 -> 0-2,16-17.
cpuset_compress() {
  printf '%s\n' "$@" | LC_ALL=C sort -n -u | awk '
    NR==1 { s=$1; p=$1; next }
    $1==p+1 { p=$1; next }
    { out=(out==""?"":out",") (s==p? s : s"-"p); s=$1; p=$1 }
    END { out=(out==""?"":out",") (s==p? s : s"-"p); print out }'
}

# expand_cpu_lists: stdin lines like "0,16" / "0-3,8" -> one cpu per line.
expand_cpu_lists() {
  local t=
  tr ',' '\n' | while IFS= read -r t; do
    case $t in
      *-[0-9]*) seq "${t%-*}" "${t#*-}" ;;
      '') continue ;;
      *) printf '%s\n' "$t" ;;
    esac
  done
}

# l3_cpuset_mode: resolve L3_CPUSET_MODE=auto|cgroup|taskset into
# CPUSET_MODE. auto selects cgroup when euid is 0 or the user's
# systemd service cgroup.controllers lists `cpuset`, else taskset.
# L3_CGROUP_CONTROLLERS_FILE overrides the probe path (test seam for
# the mock: point it at a fake controllers file to exercise auto).
l3_cpuset_mode() {
  local req=${L3_CPUSET_MODE:-auto}
  case $req in
    auto)
      if [ "$(id -u)" = 0 ]; then
        CPUSET_MODE=cgroup
        return
      fi
      local ctl=${L3_CGROUP_CONTROLLERS_FILE:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers}
      local controllers=
      if [ -r "$ctl" ]; then
        controllers=$(cat "$ctl" 2>/dev/null || true)
      fi
      case " $controllers " in
        *" cpuset "*) CPUSET_MODE=cgroup ;;
        *) CPUSET_MODE=taskset ;;
      esac
      ;;
    cgroup|taskset) CPUSET_MODE=$req ;;
    *) echo "L3_CPUSET_MODE must be auto|cgroup|taskset" >&2; exit 2 ;;
  esac
}

L3_CONCURRENT=${L3_CONCURRENT:-1}
l3_cpusets
l3_cpuset_mode

if [ "$MODE" = both ] && [ "$L3_CONCURRENT" = 1 ]; then
  # Concurrent sides: seed per-side distfiles dirs, drop stale names,
  # background each run_pm (each keeps its own `timeout` and its own
  # `$label.container.log`), wait for both. Container names are unique
  # per side by construction (`porttest-l3-$label-$$`); the rm -f only
  # clears same-name residue from a killed run, which would otherwise
  # fail the relaunch.
  DISTFILES_A=$OUT/distfiles-portage
  DISTFILES_B=$OUT/distfiles-portuale
  mkdir -p "$DISTFILES_A" "$DISTFILES_B"
  cp -al "$DISTFILES/." "$DISTFILES_A/" 2>/dev/null \
    || cp -a "$DISTFILES/." "$DISTFILES_A/" 2>/dev/null || true
  cp -al "$DISTFILES/." "$DISTFILES_B/" 2>/dev/null \
    || cp -a "$DISTFILES/." "$DISTFILES_B/" 2>/dev/null || true
  "$PODMAN" rm -f "porttest-l3-portage-$$" "porttest-l3-portuale-$$" \
    >/dev/null 2>&1 || true
  run_pm portage portage "$CPUSET_A" "$DISTFILES_A" & pid_a=$!
  run_pm portuale portuale "$CPUSET_B" "$DISTFILES_B" & pid_b=$!
  wait "$pid_a" || true
  wait "$pid_b" || true
  # Copy genuinely new tarballs back into the shared cache for the next
  # run (both containers are gone, so nothing writes anymore).
  find "$DISTFILES_A" "$DISTFILES_B" -maxdepth 1 -type f -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
    b=${f##*/}
    [ -e "$DISTFILES/$b" ] || cp -a -- "$f" "$DISTFILES/$b" 2>/dev/null || true
  done
else
  if [ "$MODE" = both ] || [ "$MODE" = portage ]; then
    run_pm portage portage
  fi
  if [ "$MODE" = both ] || [ "$MODE" = portuale ]; then
    run_pm portuale portuale
  fi
fi
if [ "${L3_CONTROL:-0}" = 1 ]; then
  if [ "$MODE" = both ] && [ "$L3_CONCURRENT" = 1 ]; then
    # Nobody else runs now: serial pair, cpusets reused for isolation.
    run_pm control-a portage "$CPUSET_A" "$DISTFILES"
    run_pm control-b portage "$CPUSET_B" "$DISTFILES"
  else
    run_pm control-a portage
    run_pm control-b portage
  fi
fi

for label in portage portuale control-a control-b; do
  [ -f "$OUT/$label.files.tsv" ] || continue
  python3 "$TEST_DIR/compare/normalize.py" "$OUT/$label" >/dev/null
done

DIFF_RC=0
CTRL_RC=0
if [ -f "$OUT/portage.files.tsv" ] && [ -f "$OUT/portuale.files.tsv" ]; then
  echo ">>> diff portage vs portuale (--layer l3 --tolerate-payload)"
  set +e
  python3 "$TEST_DIR/compare/diff.py" --layer l3 --tolerate-payload \
    "$OUT/portage" "$OUT/portuale" "$TEST_DIR/compare/known-divergences.yaml" \
    | tee "$OUT/candidate.txt"
  DIFF_RC=${PIPESTATUS[0]}
  set -e
fi
if [ -f "$OUT/control-a.files.tsv" ] && [ -f "$OUT/control-b.files.tsv" ]; then
  echo ">>> diff control-a vs control-b (portage-vs-portage noise floor)"
  set +e
  python3 "$TEST_DIR/compare/diff.py" --layer l3 --tolerate-payload \
    "$OUT/control-a" "$OUT/control-b" "$TEST_DIR/compare/known-divergences.yaml" \
    > "$OUT/control.txt" 2>&1
  CTRL_RC=$?
  set -e
fi

# --- report -------------------------------------------------------------
summary() {  # <file> <label>
  local f=$1 label=$2
  [ -f "$f" ] || { echo "  (no $label run)"; return; }
  sed -n '/^## summary/,/^$/p' "$f" | sed '1d;$d'
}
{
  echo "# L3 source-build parity report"
  echo
  echo "atoms  : $REL_ATOMLIST"
  echo "mode   : $MODE (control=${L3_CONTROL:-0})"
  echo "jobs   : -j${L3_JOBS:-1} (MAKEOPTS; 1 = deterministic)"
  echo "concur : ${L3_CONCURRENT:-1} (1 = sides overlap; 0 = old serial order)"
  echo "cpusets: portage=[${CPUSET_A:-none}] portuale=[${CPUSET_B:-none}] (mode=${CPUSET_MODE:-cgroup})"
  if [ "${L3_TMPFS:-1}" = 1 ]; then
    echo "tmpfs  : on (size=${L3_TMPFS_SIZE:-8g})"
  else
    echo "tmpfs  : off"
  fi
  echo "dates  : $(date -u +%FT%TZ)"
  echo "portage: $OUT/portage.merge.log"
  echo "portuale: $OUT/portuale.merge.log"
  echo
  echo "## candidate (portage vs portuale)"
  summary "$OUT/candidate.txt" candidate
  echo "## control (portage vs portage)"
  summary "$OUT/control.txt" control
  echo
  echo "## per-PM touched packages"
  for label in portage portuale control-a control-b; do
    [ -f "$OUT/$label.merged-cpvs.txt" ] || continue
    echo "  $label: $(wc -l < "$OUT/$label.merged-cpvs.txt")"
  done
  echo "## per-PM build args + tmpfs peak (#280, #282)"
  for label in portage portuale control-a control-b; do
    [ -f "$OUT/$label.meta.tsv" ] || continue
    echo "  $label build_args: $(awk -F'\t' '$1=="build_args"{print $2}' "$OUT/$label.meta.tsv")"
    [ -f "$OUT/$label.tmpfs-peak" ] || continue
    echo "  $label tmpfs-peak: $(cat "$OUT/$label.tmpfs-peak")"
  done
} > "$OUT/l3-report.txt"
ln -sfn "$RUN/l3-report.txt" "$LOGS_DIR/l3-report.txt"
cat "$OUT/l3-report.txt"

# --- metrics (docs/real-world-testing.md §8) ---------------------------
python3 - "$OUT" "$REL_ATOMLIST" "$CTRL_RC" <<'PY'
import json, os, re, sys
out, atomlist, ctrl_rc = sys.argv[1], sys.argv[2], int(sys.argv[3])

def summary(path):
    if not os.path.exists(path):
        return {}
    text = open(path).read()
    m = re.search(r"## summary\n(.*?)\n\n", text, re.S)
    fields = {}
    if m:
        for line in m.group(1).splitlines():
            k, _, v = line.partition(":")
            fields[k.strip()] = v.strip()
    return fields

cand = summary(os.path.join(out, "candidate.txt"))
ctrl = summary(os.path.join(out, "control.txt"))
def num(d, k):
    try:
        return int(d.get(k, "0").split()[0])
    except ValueError:
        return 0

def touched(label):
    p = os.path.join(out, label + ".merged-cpvs.txt")
    return sum(1 for _ in open(p)) if os.path.exists(p) else 0

metrics = {
    "layer": "l3",
    "date": os.path.basename(out),
    "atomlist": atomlist,
    "control": {
        "unexplained": num(ctrl, "UNEXPLAINED"),
        "payload_diffs": num(ctrl, "payload diffs"),
    },
    "candidate": {
        "unexplained": num(cand, "UNEXPLAINED"),
        "explained": num(cand, "explained"),
        "payload_diffs": num(cand, "payload diffs"),
        "hard": num(cand, "hard findings"),
    },
    "touched": {label: touched(label) for label in ("portage", "portuale")},
    "parity_rate": None,
}
total = metrics["touched"]["portage"] or metrics["touched"]["portuale"]
if metrics["candidate"]["hard"] is not None and total:
    metrics["parity_rate"] = round(
        (total - metrics["candidate"]["unexplained"]) / total, 4
    )
os.makedirs(os.path.join(os.path.dirname(out), "metrics"), exist_ok=True)
mpath = os.path.join(os.path.dirname(out), "metrics", metrics["date"] + ".json")
json.dump(metrics, open(mpath, "w"), indent=2, sort_keys=True)
print(">>> metrics: " + mpath)
PY

rc=0
# A PM that produced no snapshot means the run is invalid (setup error
# or timeout), never "green": grade only complete same-run pairs. When
# `L3_PM` restricts to one side (R5's `L3_PM=portuale` source gate),
# only that side's snapshot is required -- there is no pair to diff, so
# the graded signal is the side's own merge rc (its `build-and-merge.sh`
# run) and snapshot being produced at all.
expected=()
if [ "$MODE" = both ] || [ "$MODE" = portage ]; then
  expected+=(portage)
fi
if [ "$MODE" = both ] || [ "$MODE" = portuale ]; then
  expected+=(portuale)
fi
if [ "${L3_CONTROL:-0}" = 1 ]; then
  expected+=(control-a control-b)
fi
for label in "${expected[@]}"; do
  if [ ! -f "$OUT/$label.files.tsv" ]; then
    echo ">>> missing snapshot: $label -- run invalid"
    rc=2
  fi
done
[ "$DIFF_RC" = 0 ] || rc=1
if [ -f "$OUT/control-a.files.tsv" ] && [ -f "$OUT/control-b.files.tsv" ] && [ "$CTRL_RC" != 0 ]; then
  echo ">>> control pair is NOT clean ($CTRL_RC unexplained) -- instrument invalid"
  rc=1
fi
echo ">>> report: $OUT/l3-report.txt   (rc=$rc)"
exit "$rc"
