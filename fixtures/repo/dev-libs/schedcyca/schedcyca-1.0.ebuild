EAPI=8
DESCRIPTION="fixture package: Scheduler / cycle post-merge test (schedcyca) -- RDEPEND on schedcycb, which PDEPENDs back"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
RDEPEND="dev-libs/schedcycb"

src_compile() {
	sleep 2
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
