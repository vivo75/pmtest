EAPI=8
DESCRIPTION="fixture package: the phase env gets real's per-package fake DISTDIR (builddir/distdir, one symlink per file of A) and the real directory in PORTAGE_ACTUAL_DISTDIR (config.py:3403-3409, #330)"
SRC_URI="https://example.invalid/payload.bin -> fakedistdirpkg-1.0.tar.gz"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

# Stand-in distfile (see verifiedfetchpkg): nothing to unpack.
src_unpack() { :; }

src_install() {
	{
		echo "DISTDIR=${DISTDIR}"
		echo "PORTAGE_ACTUAL_DISTDIR=${PORTAGE_ACTUAL_DISTDIR}"
		echo "LINK=$(readlink "${DISTDIR}/fakedistdirpkg-1.0.tar.gz")"
		if [[ -e ${DISTDIR}/frs-1.0.tar.gz || -L ${DISTDIR}/frs-1.0.tar.gz ]]; then
			echo "UNLISTED=visible"
		else
			echo "UNLISTED=absent"
		fi
	} > "${T}/fake-distdir.txt" || die
}
