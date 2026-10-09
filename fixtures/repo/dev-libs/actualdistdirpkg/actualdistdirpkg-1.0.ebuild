EAPI=8
DESCRIPTION="fixture package: the phase env exports PORTAGE_ACTUAL_DISTDIR (real config.environ()), so doins -r keeps an absolute symlink that points outside it instead of dereferencing it (#326 Z, porttest/helper-doins)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	echo -n "${PORTAGE_ACTUAL_DISTDIR}" > "${T}/portage-actual-distdir.txt" || die
	mkdir -p "${T}/src/payload" || die
	ln -s /usr/share/actualdistdirpkg/not-installed-yet "${T}/src/payload/abs-link" || die
	insinto /usr/share/actualdistdirpkg
	doins -r "${T}/src/payload"
}
