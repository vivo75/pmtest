EAPI=8
DESCRIPTION="fixture package with a computed SLOT (task #149): real metadata evaluates ver_cut(1) to 1"
SLOT="$(ver_cut 1)"
KEYWORDS="amd64"

src_install() {
	echo "hello from compuslotpkg" > "${T}/hello.txt" || die
	insinto /usr/share/${PN}
	doins "${T}/hello.txt"
}