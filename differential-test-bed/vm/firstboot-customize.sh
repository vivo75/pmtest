#!/bin/bash
# First-boot customization of the VM golden image. Runs INSIDE the guest
# (copied in by vm/make-image.sh), so all paths are guest paths.
# Mirrors differential-test-bed/create-container.bash's WORKDIR steps
# (repos at pins, porttest overlay, make.conf/repos.conf) for the same
# guest content the container bed tests against.
#
# Required env: VM_PORTAGE_PIN, VM_REPOS_SHALLOW_SINCE,
#   VM_LAST_COMMIT_gentoo, VM_LAST_COMMIT_buildovl,
#   VM_REPO_URL_gentoo, VM_REPO_URL_buildovl, PORTTEST_OVERLAY_DIR
#   (guest path where make-image.sh staged the overlay source).
set -euo pipefail
export LC_ALL=C.UTF-8

PIN=${VM_PORTAGE_PIN:?}
SINCE=${VM_REPOS_SHALLOW_SINCE:?}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# -- toolchain the bed needs -------------------------------------------
# Chicken-and-egg: the stock image ships empty /var/db/repos, which
# invalidates the profile, which blocks every emerge except --sync.
# emerge-webrsync (needs no profile) unpacks a snapshot to bootstrap
# from; the snapshot is then replaced by the pinned git fetch below.
if [ ! -d /var/db/repos/gentoo/profiles ]; then
  log "bootstrapping repos via emerge-webrsync"
  emerge-webrsync --quiet
fi
if ! command -v git > /dev/null; then
  log "installing git (binpkg first, source fallback)"
  emerge --quiet --getbinpkg --usepkgonly dev-vcs/git \
    || emerge --quiet dev-vcs/git
fi

# -- repos at pins -------------------------------------------------------
clone_pin() {  # <name> <url> <sha>
  # NOTE: one `local` per line -- with `set -u`, a single
  # `local name=$1 ... d=.../$name` expands $name before it exists.
  local name=$1 url=$2 sha=$3
  local d=/var/db/repos/$name
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    log "repo $name already at $sha"
    return 0
  fi
  log "fetching $name $sha"
  rm -rf "$d"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" remote add origin "$url"
  git -C "$d" fetch origin --shallow-since="$SINCE" "$sha"
  git -C "$d" reset --hard FETCH_HEAD
}
clone_pin gentoo "$VM_REPO_URL_gentoo" "$VM_LAST_COMMIT_gentoo"
clone_pin buildovl "$VM_REPO_URL_buildovl" "$VM_LAST_COMMIT_buildovl"

# -- porttest overlay (staged under $PORTTEST_OVERLAY_DIR by the host) ---
if [ -d "${PORTTEST_OVERLAY_DIR:?}/porttest" ]; then
  log "staging porttest overlay"
  rm -rf /var/db/repos/porttest
  cp -a "$PORTTEST_OVERLAY_DIR" /var/db/repos/porttest
  git -C /var/db/repos/porttest init -q
  git -C /var/db/repos/porttest add -A
  git -C /var/db/repos/porttest -c user.email=porttest@localhost \
    -c user.name=porttest commit -qm "porttest overlay ($(date -u +%F))" || true
fi

# -- portage config (same content as create-container.bash) --------------
cd /etc/portage/
echo 'USE="${USE} X alsa dbus icu libproxy"' > make.USE.conf
grep -q 'make.USE.conf' make.conf 2>/dev/null || cat >> make.conf <<'EOF'
source /etc/portage/make.USE.conf
FEATURES="cgroup distlocks ebuild-locks -fail-clean multilib-strict noinfo observability pid-sandbox pkgdir-index-trusted preserve-libs protect-owned qa-unresolved-soname-deps sandbox sign split-elog split-log splitdebug strict unknown-features-warn unmerge-logs unmerge-orphans userfetch userpriv usersandbox usersync xattr"
EOF
echo '*/* PYTHON_SINGLE_TARGET: python3_14' > package.use/PYTHON_SINGLE_TARGET
echo '*/* minizip  opengl policykit qml text wayland -webengine' > package.use/kde-apps--kdecore-meta
mkdir -p repos.conf
cat > repos.conf/gentoo.conf <<'EOF'
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo-mirror/gentoo.git
EOF
cat > repos.conf/buildovl.conf <<'EOF'
[buildovl]
location = /var/db/repos/buildovl
sync-type = git
sync-uri = https://github.com/vivo75/buildovl.git
priority = 10
EOF
cat > repos.conf/porttest.conf <<'EOF'
[porttest]
location = /var/db/repos/porttest
sync-type = git
sync-uri = file:///var/db/repos/porttest
priority = 20
EOF
cd /

# -- portage PIN (same step layers/l0/in-container.sh runs per container)
cur=$(emerge --version 2>/dev/null | sed -n 's/^Portage \([0-9.]*\).*/\1/p')
if [ "$cur" != "$PIN" ]; then
  log "upgrading portage $cur -> $PIN"
  ACCEPT_KEYWORDS=~amd64 emerge --quiet "=sys-apps/portage-$PIN"
else
  log "portage already $PIN"
fi

# -- fingerprint (mirrors the in-container fingerprint.tsv block) ---------
{
  echo "date_utc	$(date -u +%FT%TZ)"
  echo "portage	$(emerge --version 2>/dev/null | head -1)"
  for repo in gentoo buildovl porttest; do
    d=/var/db/repos/$repo
    if [ -d "$d/.git" ]; then
      echo "repo_${repo}	$(git -C "$d" rev-parse HEAD)"
    else
      echo "repo_${repo}	(absent)"
    fi
  done
  echo "profile	$(readlink -f /etc/portage/make.profile | sed 's#.*/profiles/##')"
  echo "python	$(python3 --version 2>&1)"
} > /root/vm-fingerprint.txt
log "fingerprint:"; sed 's/^/  /' /root/vm-fingerprint.txt

# -- shrink + de-identify -------------------------------------------------
rm -rf /var/tmp/portage/* /root/.cache /tmp/* 2>/dev/null || true
# Empty machine-id regenerates on every first boot, so per-run overlays
# never share an identity (golden itself must stay unbooted after this).
truncate -s 0 /etc/machine-id
log "firstboot customize done"
