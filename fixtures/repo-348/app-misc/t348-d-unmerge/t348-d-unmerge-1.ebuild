EAPI=8
SLOT="0"
S="${WORKDIR}"
KEYWORDS="amd64"
src_install() {
	insinto /usr/share/t348-d-unmerge
	newins "${EBUILD}" ${PN}.ebuild
}
pkg_prerm() {
	echo "prerm EAPI=${EAPI}" >> "${EROOT}/tmp/t348d-lifecycle.log"
}
pkg_postrm() {
	echo "postrm EAPI=${EAPI}" >> "${EROOT}/tmp/t348d-lifecycle.log"
}
