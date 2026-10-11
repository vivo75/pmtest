#!/bin/bash
# 335-unmerge-features.sh -- portuale #335 oracle: `emerge -C` takes
# FEATURES from the resolved config (Portage dblink._pre_unmerge_backup:
# "unmerge-backup" in self.settings.features), so make.globals'
# binpkg-multi-instance shapes the backup's layout and a make.conf-only
# unmerge-backup still backs up. Runs inside the bed image as root with
# either PM, one case per container:
#
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     localhost/test-portuale:latest /o/335-unmerge-features.sh /usr/bin/emerge env
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     -v <portuale>/target/release:/pm:ro \
#     localhost/test-portuale:latest /o/335-unmerge-features.sh "/pm/portuale emerge" makeconf
#
# CASE env: FEATURES=unmerge-backup in the environment only.
# CASE makeconf: FEATURES="unmerge-backup" in make.conf only.
# Prints the backup's path(s) under PKGDIR and the Packages CPV/PATH/BUILD_ID.
set -u
EMERGE=$1
CASE=$2
R=/var/db/repos/qp
mkdir -p $R/metadata $R/profiles $R/qp/q
echo qp > $R/profiles/repo_name; echo qp > $R/profiles/categories
printf 'masters = gentoo\nthin-manifests = true\nsign-manifests = false\n' > $R/metadata/layout.conf
printf '[qp]\nlocation = %s\n' $R > /etc/portage/repos.conf/qp.conf
cat > $R/qp/q/q-1.ebuild <<'EOF'
EAPI=8
DESCRIPTION="one file to back up on unmerge"
SLOT=0
KEYWORDS="~amd64 amd64"
S=${WORKDIR}
src_install() { insinto /usr/share/qp; newins - f <<<'payload'; }
EOF
F="-sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox -mount-sandbox"
run() { env -i PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb FEATURES="$F $1" $EMERGE "${@:2}" > /tmp/emerge.log 2>&1; echo "emerge ${*:2} rc=$?"; }
run "" -1 --quiet-build=y qp/q
echo 'BINPKG_FORMAT="gpkg"' >> /etc/portage/make.conf
case $CASE in
  env) run "unmerge-backup" -C qp/q ;;
  makeconf) echo 'FEATURES="${FEATURES} unmerge-backup"' >> /etc/portage/make.conf
            run "" -C qp/q ;;
  *) echo "unknown case $CASE"; exit 2 ;;
esac
tail -3 /tmp/emerge.log
find /var/cache/binpkgs -path "*qp*" | sort
grep -E "^(CPV|PATH|BUILD_ID)" /var/cache/binpkgs/Packages 2>/dev/null || echo "<no Packages>"
