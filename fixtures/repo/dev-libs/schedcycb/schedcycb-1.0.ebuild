EAPI=8
DESCRIPTION="fixture package: Scheduler / cycle post-merge test (schedcycb) -- PDEPEND on schedcyca, which RDEPENDs back; the post edge must not gate the build"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
PDEPEND="dev-libs/schedcyca"

src_compile() {
	sleep 2
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
