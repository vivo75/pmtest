EAPI=8
DESCRIPTION="fixture package: real FEATURES=collision-protect -- an ordinary file collision only, no symlink-over-directory"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	insinto /usr/share/collisiontest
	echo "hello from collisionpkg-c" > "${T}/shared.txt" || die
	doins "${T}/shared.txt"
}
