EAPI=8
DESCRIPTION="fixture package: ordered live-replay probe (first) -- pretend announces itself at once, so a later entry can tell replayed output from buffered output"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

pkg_pretend() {
	einfo "SEQA-MARKER"
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
