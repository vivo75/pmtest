EAPI=8
DESCRIPTION="fixture package: per-package BINPKG_COMPRESS reaches the xpak pipe"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_install() {
	# Deliberately records nothing about the build env: the only
	# observable for backlog #147 S2 is the artefact's compression
	# magic, which must follow this package's own package.env
	# BINPKG_COMPRESS, not the run-wide value.
	printf 'penvcmppkg\n' > "${T}/marker" || die
	insinto /usr/share/${PN}
	doins "${T}/marker"
}
