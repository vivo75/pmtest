EAPI=8
DESCRIPTION="fixture package: package.env's non-USE half overrides the build-phase flags"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_install() {
	# Records the build flags the phase env carried -- with a matching
	# /etc/portage/package.env entry these come from its env file, not
	# make.conf / the env layer. CC/CXX/AR/RUSTFLAGS are real's
	# toolchain selectors (backlog #95); ENV_UNSET is the incremental
	# fold's observable value.
	printf 'CFLAGS=%s\nMAKEOPTS=%s\nCC=%s\nCXX=%s\nAR=%s\nRUSTFLAGS=%s\nENV_UNSET=%s\n' \
		"${CFLAGS}" "${MAKEOPTS}" "${CC}" "${CXX}" "${AR}" "${RUSTFLAGS}" "${ENV_UNSET}" \
		> "${T}/flags" || die
	insinto /usr/share/${PN}
	doins "${T}/flags"
}
