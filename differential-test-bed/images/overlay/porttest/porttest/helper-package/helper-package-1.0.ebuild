# P0 probe for plan 02.326-no-portage-runtime.opus.md P0.3: isolates the
# package helpers (bin/misc-functions.sh:622 runs gpkg-helper.py compress
# with BINPKG_FORMAT=gpkg, :601 runs xpak-helper.py recompose with
# BINPKG_FORMAT=xpak, both via __dyn_package). src_install is trivial on
# purpose (one file, one symlink, one keepdir empty dir) so the runner can
# build this atom in both BINPKG_FORMATs and diff the produced binpkgs. If
# a package branch regressed (wrong tar members, order or format), the
# binpkg would differ from the real-Portage one.
EAPI=8
DESCRIPTION="porttest: trivial image for gpkg/xpak package-format isolation"
HOMEPAGE="https://example.invalid/porttest"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"

src_install() {
	# cp, not doins: doins routes through doins.py, and this probe must
	# reach __dyn_package even where doins.py cannot run.
	mkdir -p "${ED}/usr/share/porttest/helper-package" || die
	echo "package probe payload" \
		> "${ED}/usr/share/porttest/helper-package/payload.txt" || die
	dosym payload.txt /usr/share/porttest/helper-package/link.txt
	keepdir /var/lib/porttest/helper-package-kept
}
