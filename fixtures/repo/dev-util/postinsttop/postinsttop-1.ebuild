EAPI=8
DESCRIPTION="fixture package: failing pkg_postinst endgame (postinsttop)"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="dev-util/postinstfail"
S="${WORKDIR}"

src_install() {
	keepdir /opt/postinsttop
}
