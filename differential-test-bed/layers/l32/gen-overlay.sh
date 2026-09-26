#!/bin/bash
# Generate the L32 S0 fixture overlay (temporary; logs/ is gitignored).
# Usage: gen-overlay.sh <overlay-root>
set -euo pipefail
ROOT=${1:?overlay root}
rm -rf "$ROOT"
mkdir -p "$ROOT"/{metadata,profiles,l32}
printf 'masters = gentoo\nthin-manifests = true\nsign-manifests = false\nprofile-formats = portage-2\n' > "$ROOT/metadata/layout.conf"
printf 'l32\n' > "$ROOT/profiles/repo_name"
printf 'l32\n' > "$ROOT/profiles/categories"
for d in l32/dep-a l32/dep-b l32/dep-c l32/sonamelib l32/sonameuser l32/protect l32/slow-a l32/slow-b l32/slow-c l32/bigpkg l32/faultpkg; do
  mkdir -p "$ROOT/$d"
done

mk() { # <path> ; stdin = body
  cat > "$ROOT/$1"
}

mk l32/dep-a/dep-a-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: dep leaf"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	dodir /usr/share/l32
	echo "dep-a-1.0" > "${ED}"/usr/share/l32/dep-a
}
EOF

mk l32/dep-b/dep-b-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: depends on dep-a"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
RDEPEND="=l32/dep-a-1.0"
src_install() {
	dodir /usr/share/l32
	echo "dep-b-1.0" > "${ED}"/usr/share/l32/dep-b
}
EOF

mk l32/dep-c/dep-c-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: independent package"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	dodir /usr/share/l32
	echo "dep-c-1.0" > "${ED}"/usr/share/l32/dep-c
}
EOF

# soname v1/v2: install a shared object + its soname symlink chain by hand
mk l32/sonamelib/sonamelib-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: lib with soname .so.1"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
inherit toolchain-funcs
S="${WORKDIR}"
src_compile() {
	echo 'int l32_soname(void){return 1;}' > "${T}"/soname.c
	"$(tc-getCC)" ${CFLAGS} -shared -fPIC \
		-Wl,-soname,libl32soname.so.1 \
		-o "${T}"/libl32soname.so.1.0.0 "${T}"/soname.c
}
src_install() {
	insinto /usr/lib64
	doins "${T}"/libl32soname.so.1.0.0
	dosym libl32soname.so.1.0.0 /usr/lib64/libl32soname.so.1
	dosym libl32soname.so.1 /usr/lib64/libl32soname.so
}
EOF

mk l32/sonamelib/sonamelib-2.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: lib with soname .so.2"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
inherit toolchain-funcs
S="${WORKDIR}"
src_compile() {
	echo 'int l32_soname(void){return 2;}' > "${T}"/soname.c
	"$(tc-getCC)" ${CFLAGS} -shared -fPIC \
		-Wl,-soname,libl32soname.so.2 \
		-o "${T}"/libl32soname.so.2.0.0 "${T}"/soname.c
}
src_install() {
	insinto /usr/lib64
	doins "${T}"/libl32soname.so.2.0.0
	dosym libl32soname.so.2.0.0 /usr/lib64/libl32soname.so.2
	dosym libl32soname.so.2 /usr/lib64/libl32soname.so
}
EOF

mk l32/sonameuser/sonameuser-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: executable NEEDing libl32soname.so.1"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
inherit toolchain-funcs
S="${WORKDIR}"
RDEPEND=">=l32/sonamelib-1.0"
src_compile() {
	echo 'extern int l32_soname(void); int main(void){return l32_soname();}' > "${T}"/user.c
	"$(tc-getCC)" ${CFLAGS} ${LDFLAGS} -o "${T}"/sonameuser "${T}"/user.c -L/usr/lib64 -ll32soname
}
src_install() {
	dobin "${T}"/sonameuser
}
EOF

mk l32/protect/protect-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: CONFIG_PROTECT v1"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	insinto /etc/l32
	echo "version=1" > "${T}"/protect.conf
	doins "${T}"/protect.conf
}
EOF

mk l32/protect/protect-2.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: CONFIG_PROTECT v2"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	insinto /etc/l32
	echo "version=2" > "${T}"/protect.conf
	doins "${T}"/protect.conf
}
EOF

for p in a b c; do
mk l32/slow-$p/slow-$p-1.0.ebuild <<EOF
EAPI=8
DESCRIPTION="L32 fixture: slow package $p"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="\${WORKDIR}"
src_compile() {
	sleep 6
}
src_install() {
	insinto /usr/share/l32
	echo "slow-$p-1.0" > "\${T}"/slow-$p
	doins "\${T}"/slow-$p
}
pkg_preinst() {
	# S1 determinism: the C4 SIGKILL must land inside the live-root merge
	# phase, after `>>> Installing (1 of 3)` and while the
	# `-MERGING-<pf>` marker exists (the S0 g4 invariant). pkg_preinst is
	# the first hook that runs after that line/marker; the sleep widens
	# the window and changes no output shape.
	sleep 4
}
EOF
done

mk l32/bigpkg/bigpkg-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: writes a big payload (disk-full cell)"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	dodir /usr/share/l32/big
	dd if=/dev/zero of="${ED}"/usr/share/l32/big/blob bs=1M count=64 status=none
}
EOF

mk l32/faultpkg/faultpkg-1.0.ebuild <<'EOF'
EAPI=8
DESCRIPTION="L32 fixture: tiny package for corrupt/500 cells"
HOMEPAGE="https://example.invalid/l32"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"
src_install() {
	dodir /usr/share/l32
	echo "faultpkg-1.0" > "${ED}"/usr/share/l32/faultpkg
}
EOF

echo "overlay generated at $ROOT"
find "$ROOT" -name '*.ebuild' | sort
