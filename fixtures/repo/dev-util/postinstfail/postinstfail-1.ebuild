EAPI=8
DESCRIPTION="fixture package: failing pkg_postinst endgame (postinstfail)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	keepdir /opt/postinstfail
}

pkg_postinst() {
	die "postinst exploded"
}
