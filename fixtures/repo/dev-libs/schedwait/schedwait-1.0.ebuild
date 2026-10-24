EAPI=8
DESCRIPTION="fixture package: Scheduler / merge-wait barrier test (schedwait) -- src_compile sleeps long enough that a barriered merge lands strictly after it"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_compile() {
	sleep 8
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
