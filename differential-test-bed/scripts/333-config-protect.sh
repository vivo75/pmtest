#!/bin/bash
# 333-config-protect.sh -- portuale #333 oracle: a merge protects the
# resolved CONFIG_PROTECT (make.conf + the per-task env.d reload), not
# only what the process env exports. Runs inside the bed image as root,
# under `env -i` (no login-shell CONFIG_PROTECT):
#
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     localhost/test-portuale:latest /o/333-config-protect.sh /usr/bin/emerge
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     -v <portuale>/target/release:/pm:ro \
#     localhost/test-portuale:latest /o/333-config-protect.sh "/pm/portuale emerge"
#
# cp/a installs /etc/env.d/99late (CONFIG_PROTECT="/usr/share/late");
# cp/b (DEPEND on cp/a) installs one file under the make.conf-protected
# /usr/share/protectme, the env.d-added /usr/share/late and the
# unprotected /usr/share/plain, each over a modified copy. Real Portage
# 3.0.82.2 keeps x and y and writes ._cfg0000_x / ._cfg0000_y; z is
# overwritten. portuale before #333 overwrote all three.
set -u
EMERGE=$1
R=/var/db/repos/cp
mkdir -p $R/metadata $R/profiles $R/cp/a $R/cp/b
echo cp > $R/profiles/repo_name; echo cp > $R/profiles/categories
printf 'masters = gentoo\nthin-manifests = true\nsign-manifests = false\n' > $R/metadata/layout.conf
cat > /etc/portage/repos.conf/cp.conf <<'EOF'
[cp]
location = /var/db/repos/cp
EOF
cat > $R/cp/a/a-1.ebuild <<'EOF'
EAPI=8
DESCRIPTION="installs an env.d CONFIG_PROTECT entry"
SLOT=0
KEYWORDS="~amd64 amd64"
S=${WORKDIR}
src_install() {
	insinto /etc/env.d
	newins - 99late <<<'CONFIG_PROTECT="/usr/share/late"'
}
EOF
cat > $R/cp/b/b-1.ebuild <<'EOF'
EAPI=8
DESCRIPTION="installs one file per protect path"
SLOT=0
KEYWORDS="~amd64 amd64"
DEPEND="cp/a"
S=${WORKDIR}
src_install() {
	insinto /usr/share/protectme; newins - x <<<'from-package'
	insinto /usr/share/late; newins - y <<<'from-package'
	insinto /usr/share/plain; newins - z <<<'from-package'
}
EOF
# Modified copies already on disk.
for f in /usr/share/protectme/x /usr/share/late/y /usr/share/plain/z; do
	mkdir -p "${f%/*}"; echo local > "$f"
done
echo 'CONFIG_PROTECT="/usr/share/protectme"' >> /etc/portage/make.conf
F="-sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox -mount-sandbox"
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb FEATURES="$F" \
	$EMERGE -1 --quiet-build=y cp/b > /tmp/emerge.log 2>&1
echo "emerge rc=$?"
tail -3 /tmp/emerge.log
for d in /usr/share/protectme /usr/share/late /usr/share/plain; do
	for f in "$d"/* "$d"/._cfg*; do [ -e "$f" ] && echo "$f: $(cat "$f")"; done
done
grep -o 'CONFIG_PROTECT="[^"]*"' /etc/profile.env | head -1
