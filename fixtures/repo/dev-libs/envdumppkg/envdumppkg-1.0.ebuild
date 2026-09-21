EAPI=8
DESCRIPTION="fixture package: dumps the phase environment for package.env layer-oracle captures"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

pkg_setup() {
	# Oracle vehicle for backlog #98-#101 (phase 2): every value the
	# layer stack resolves is printed, so a real `ebuild ... setup`
	# capture shows which layer won without running any merge.
	einfo "CFLAGS=${CFLAGS}"
	einfo "CC=${CC}"
	einfo "FEATURES=${FEATURES}"
	einfo "PORTAGE_TMPDIR=${PORTAGE_TMPDIR}"
	einfo "PORTAGE_BUILDDIR=${PORTAGE_BUILDDIR}"
}
