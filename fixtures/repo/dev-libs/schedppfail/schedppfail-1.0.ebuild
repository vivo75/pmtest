EAPI=8
DESCRIPTION="fixture package: Scheduler / pkg_pretend failure test (schedppfail) -- pretend dies, so the run must abort before anything builds"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

pkg_pretend() {
	eerror "SCHED-PRETEND-FAIL schedppfail"
	die "pretend failed on purpose"
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
