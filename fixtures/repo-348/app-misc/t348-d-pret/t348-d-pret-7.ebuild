EAPI=7
SLOT="0"
KEYWORDS="amd64"
pkg_pretend() {
	ewarn "t348-d-pret pkg_pretend ran EAPI=${EAPI}"
	die "t348-d-pret refuses on purpose"
}
