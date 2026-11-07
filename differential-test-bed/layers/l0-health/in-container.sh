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
# written. meta.tsv gets: label, exit code, seconds, family.

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
  timeout 1200 "$PTL" "$@" --ignore-default-opts --color=n --json \
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
probe remove MULTI_depclean -pvc

python3 /HC/health_checker.py --vdb /var/db/pkg "$OUTDIR"/plans/*.json > "$OUTDIR/health.jsonl"
echo "health checker rc=$?"
