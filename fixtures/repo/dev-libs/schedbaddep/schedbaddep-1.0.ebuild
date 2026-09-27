EAPI=8
DESCRIPTION="fixture package: Scheduler / parallel-build test (schedbaddep)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
RDEPEND="dev-libs/schedbad"

src_install() {
	insinto /usr/share/${PN}
	echo dep > "${T}/f" || die
	doins "${T}/f"
}
