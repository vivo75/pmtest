# P0 probe for plan 02.326-no-portage-runtime.opus.md P0.3: isolates the
# doins helper (bin/ebuild-helpers/doins:104-106 routes doins, newins,
# doheader, doenvd, dodoc and doconfd through bin/doins.py). src_install
# builds a small source tree in ${WORKDIR} (plain files, a nested dir, a
# relative symlink, an absolute symlink, a hardlink pair) and installs it
# with insinto/doins -r, plus one newins, one insopts -m0600 + doins, one
# dodoc, one doheader, one doconfd and one doenvd. If the doins branch
# regressed (wrong modes, dropped symlinks, broken hardlinks, files in
# the wrong directories), the installed image tree would differ from the
# real-Portage oracle listing.
EAPI=8
DESCRIPTION="porttest: doins -r tree, newins, insopts, dodoc, doheader, doconfd, doenvd"
HOMEPAGE="https://example.invalid/porttest"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"

src_install() {
	local src="${WORKDIR}/doins-src"
	mkdir -p "${src}/payload/nested" || die
	echo "plain file" > "${src}/payload/plain.txt" || die
	echo "nested file" > "${src}/payload/nested/inner.txt" || die
	ln -s plain.txt "${src}/payload/rel-link" || die
	ln -s /usr/share/porttest/helper-doins/plain.txt "${src}/payload/abs-link" || die
	echo "hardlink payload" > "${src}/payload/hard-a" || die
	ln "${src}/payload/hard-a" "${src}/payload/hard-b" || die
	echo "newins payload" > "${src}/single.txt" || die
	echo "secure payload" > "${src}/secure.txt" || die
	echo "doc payload" > "${src}/README.porttest" || die
	printf '#ifndef PT_HELPER_H\n#define PT_HELPER_H\n#endif\n' > "${src}/pt_helper.h" || die
	printf 'PT_HELPER_DOINS=yes\n' > "${src}/pt-helper-doins.confd" || die
	printf 'PT_HELPER_DOINS=1\n' > "${src}/99pt-helper-doins" || die

	insinto /usr/share/porttest/helper-doins
	doins -r "${src}/payload" || die
	newins "${src}/single.txt" renamed-single.txt || die
	insopts -m0600
	doins "${src}/secure.txt" || die
	insopts -m0644

	dodoc "${src}/README.porttest" || die
	doheader "${src}/pt_helper.h" || die
	doconfd "${src}/pt-helper-doins.confd" || die
	doenvd "${src}/99pt-helper-doins" || die
}
