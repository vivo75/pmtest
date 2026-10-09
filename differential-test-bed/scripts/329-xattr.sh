#!/bin/bash
# 329-xattr.sh -- portuale #329 oracle: under FEATURES=xattr (on by
# default, make.globals) every `install` a phase runs goes through
# <bin>/ebuild-helpers/xattr/install, so a user.* xattr on the source
# survives `doexe`/`dobin`/plain `install`. Runs inside the bed image as
# root with either PM:
#
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     localhost/test-portuale:latest /o/329-xattr.sh /usr/bin/emerge
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     -v <portuale>/rust/target/release:/pm:ro \
#     localhost/test-portuale:latest /o/329-xattr.sh "/pm/portuale emerge"
#
# Optional $2: extra FEATURES tokens (e.g. "-xattr" for the control).
set -u
EMERGE=$1
EXTRA=${2:-}
R=/var/db/repos/xa
mkdir -p $R/metadata $R/profiles $R/xa/x
echo xa > $R/profiles/repo_name; echo xa > $R/profiles/categories
printf 'masters = gentoo\nthin-manifests = true\nsign-manifests = false\n' > $R/metadata/layout.conf
printf '[xa]\nlocation = %s\n' $R > /etc/portage/repos.conf/xa.conf
cat > $R/xa/x/x-1.ebuild <<'EOF'
EAPI=8
DESCRIPTION="installs files carrying a user.* xattr"
SLOT=0
KEYWORDS="~amd64 amd64"
S=${WORKDIR}
src_unpack() {
	for f in viaexe viabin viainstall; do
		printf '#!/bin/sh\n' > "$f" || die
		setfattr -n user.portuale329 -v "$f" "$f" || die
	done
}
src_install() {
	exeinto /usr/libexec/xa; doexe viaexe
	dobin viabin
	install -D -m 0755 viainstall "${ED}/usr/libexec/xa/viainstall" || die
}
EOF
F="-sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox -mount-sandbox $EXTRA"
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb FEATURES="$F" \
	$EMERGE -1 --quiet-build=y xa/x > /tmp/emerge.log 2>&1
echo "emerge rc=$?"
tail -3 /tmp/emerge.log
for f in /usr/libexec/xa/viaexe /usr/bin/viabin /usr/libexec/xa/viainstall; do
	echo "$f: $(getfattr --only-values -n user.portuale329 "$f" 2>/dev/null || echo '<none>')"
done
