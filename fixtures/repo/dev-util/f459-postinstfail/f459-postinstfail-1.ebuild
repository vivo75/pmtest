EAPI=8
DESCRIPTION="fixture package: failing binary pkg_postinst endgame (f459-postinstfail)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	keepdir /opt/f459-postinstfail
}

pkg_postinst() {
	die "postinst exploded"
}
