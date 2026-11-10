EAPI=8
DESCRIPTION="fixture package: Scheduler / system-deps gate test (schedmark) -- src_compile records when this build started"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_compile() {
	touch "${PORTAGE_TMPDIR}/schedmark-started" || die
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
