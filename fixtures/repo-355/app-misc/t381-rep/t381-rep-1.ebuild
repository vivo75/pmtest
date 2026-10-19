# V1/V2 (#381): the replaced and replacing instances record the same file
# under two spellings of one directory (`T381_W=normal` ->
# `/usr/share/t381/f`, `T381_W=alias` -> `/alias/f`, with a live
# `/alias -> usr/share/t381` symlink created between the merges).
EAPI=8
DESCRIPTION="t381 replace probe under normal or symlinked spelling"
HOMEPAGE="none"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
S=${WORKDIR}

src_install() {
	if [[ ${T381_W:-normal} == alias ]]; then
		insinto /alias
	else
		insinto /usr/share/t381
	fi
	echo "${T381_W:-normal} ${PV}" > "${T}"/f; doins "${T}"/f
}
