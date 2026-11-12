#!/bin/bash
# L0 health, in-container half: portuale only, no Portage arm.
#
# Plans every entry of a list (plus the L0 whole-graph runs) with
# `emerge --json` and checks each plan with health_checker.py against
# this container's own VDB, which the host cannot see.
#
#   in-container.sh /TEST/atomlists/l0-resolve.txt /TEST/logs/<run>
#
# List lines: atoms (planned with `-pv`), or a whole argument list when the
# line starts with '-'. `#:family NAME` names the group of the lines after
# it. Every probe adds --ignore-default-opts, so the options are the ones
# written, plus L0_PORTUALE_OPTS (for example --solver=pubgrub) when set. meta.tsv gets: label, exit code, seconds, family.

set -u
ATOMLIST=${1:?atom list path}
OUTDIR=${2:?output dir}
PTL=/usr/local/bin/emerge
export PORTAGE_CONFIGROOT=/ ROOT=/ LC_ALL=C.UTF-8 TZ=UTC
mkdir -p "$OUTDIR/plans"
: > "$OUTDIR/meta.tsv"

# The same @world seed as layers/l0/in-container.sh, so @world means the same.
printf '%s\n' app-misc/tmux app-portage/eix app-portage/gentoolkit dev-libs/blake3 \
  > /var/lib/portage/world

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' ; }
probe() {  # family, label, emerge args
  local family=$1 label=$2 start rc; shift 2
  start=${EPOCHREALTIME/./}
  # shellcheck disable=SC2086  # L0_PORTUALE_OPTS is an option list on purpose
  timeout 1200 "$PTL" "$@" ${L0_PORTUALE_OPTS:-} --ignore-default-opts --color=n --json \
    > "$OUTDIR/plans/$label.json" 2> "$OUTDIR/plans/$label.stderr"
  rc=$?
  local ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
  printf '%s\t%s\t%d.%03d\t%s\n' "$label" "$rc" $((ms / 1000)) $((ms % 1000)) \
    "$family" >> "$OUTDIR/meta.tsv"
  echo "  $label (rc=$rc)"
}

family=atoms
while IFS= read -r line || [ -n "$line" ]; do
  case $line in "#:family "*) family=${line#"#:family "}; continue ;; esac
  line=${line%%#*}; line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$line" ] || continue
  # shellcheck disable=SC2086  # the line is an argument list on purpose
  case $line in
    -*) probe "$family" "ARGS$(slug "$line")" $line ;;
    *) probe "$family" "$(slug "$line")" -pv $line ;;
  esac
done < "$ATOMLIST"
probe whole-graph MULTI_emptytree-system -pve @system
probe whole-graph MULTI_deep-update-world -puvD @world

# World cross-check: the fast plan and the check run on the same seeded @world,
# and the resolver plans of it (the one above, and one without binary
# packages, which the fast plan does not see) are set against them. The fast
# plan also goes to plans/ as FAST_world: health_checker.py judges it, the
# report shows its findings and does not let them fail the run.
probe whole-graph WORLD_resolver-nobin -puvDN --getbinpkg=n @world
MRG=/usr/local/bin/mrg
mkdir -p "$OUTDIR/world"
start=${EPOCHREALTIME/./}
timeout 1200 "$MRG" --plan-world --json --sort depend \
  > "$OUTDIR/plans/FAST_world.json" 2> "$OUTDIR/plans/FAST_world.stderr"
rc=$?
ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
printf '%s\t%s\t%d.%03d\t%s\n' FAST_world "$rc" $((ms / 1000)) $((ms % 1000)) fast-world \
  >> "$OUTDIR/meta.tsv"
echo "  FAST_world (rc=$rc)"
timeout 1200 "$MRG" --check-world --json \
  > "$OUTDIR/world/check-world.jsonl" 2> "$OUTDIR/world/check-world.stderr"
echo "  check-world (rc=$?)"
for pair in default:MULTI_deep-update-world nobin:WORLD_resolver-nobin; do
  python3 /HC/world-crosscheck.py "$OUTDIR/plans/${pair#*:}.json" "$OUTDIR/plans/FAST_world.json" \
    --check "$OUTDIR/world/check-world.jsonl" > "$OUTDIR/world/crosscheck-${pair%%:*}.txt" 2>&1
  echo "  crosscheck ${pair%%:*} (rc=$?)"
done
probe remove MULTI_depclean -pvc

python3 /HC/health_checker.py --vdb /var/db/pkg "$OUTDIR"/plans/*.json > "$OUTDIR/health.jsonl"
echo "health checker rc=$?"
