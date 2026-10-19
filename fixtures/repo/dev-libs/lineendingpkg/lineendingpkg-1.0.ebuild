EAPI=8
DESCRIPTION="the image holds a file whose name contains a newline -- Portage refuses the merge (backlog #380)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	dodir /usr/share/lineendingtest
	: > "${ED}/usr/share/lineendingtest/plain" || die
	: > "${ED}/usr/share/lineendingtest/two"$'\n'"lines" || die
}
