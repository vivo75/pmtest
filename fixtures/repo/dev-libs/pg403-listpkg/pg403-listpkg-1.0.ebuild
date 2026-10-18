EAPI=8
DESCRIPTION="fixture: direct-path merge/unmerge listing (backlog #403)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	echo "pg403 keep" > "${T}/keep.txt" || die
	echo "pg403 old one" > "${T}/old.txt" || die
	insinto /usr/share/${PN}
	doins "${T}/keep.txt" "${T}/old.txt" || die
	dosym old.txt /usr/share/${PN}/link || die
}
