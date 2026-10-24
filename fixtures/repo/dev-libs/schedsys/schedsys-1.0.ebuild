EAPI=8
DESCRIPTION="fixture package: Scheduler / merge-wait barrier test (schedsys) -- fast, a member of the test @system set in the Rust test's own config"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
