EAPI=8
DESCRIPTION="fixture package: Scheduler / parallel pkg_pretend test (schedppa) -- pretend announces itself and sleeps, so overlapping phases prove parallelism and replay order proves merge-list order"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

pkg_pretend() {
	einfo "SCHED-PRETEND schedppa"
	sleep 2
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
