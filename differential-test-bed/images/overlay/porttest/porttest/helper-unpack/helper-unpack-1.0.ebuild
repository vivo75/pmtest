# P0 probe for plan 02.326-no-portage-runtime.opus.md P0.3: isolates the
# chmod-lite helper (bin/phase-helpers.sh:511 runs
# "${PORTAGE_BIN_PATH}/chmod-lite" over the unpacked tree at the end of
# every unpack; real chmod-lite execs bin/ebuild-pyhelper which runs
# chmod-lite.py::apply_recursive_permissions, normalising files to 0644
# and dirs to 0755 modulo the 022 mask). src_unpack builds odd.tar in
# ${T} with deliberately odd modes (file 0600, file 0777, dir 0700, dir
# 0775, nested file 0640) and unpacks it by absolute path (allowed since
# EAPI 6: ___eapi_unpack_supports_absolute_paths). src_install copies the
# unpacked tree with cp -a (never doins, so only chmod-lite's modes show)
# and dumps stat modes into modes.txt. If the chmod-lite branch regressed
# (missing binary, silent find error, wrong mask), modes.txt would keep
# the odd modes instead of the normalised 0644/0755 set.
EAPI=8
DESCRIPTION="porttest: unpack odd-mode tarball, record WORKDIR modes after chmod-lite"
HOMEPAGE="https://example.invalid/porttest"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"

src_unpack() {
	local t="${T}/odd-src"
	mkdir -p "${t}/sub0700" "${t}/sub0775" || die
	printf 'mode0600\n' > "${t}/file0600" || die
	chmod 0600 "${t}/file0600" || die
	printf '#!/bin/sh\necho hi\n' > "${t}/file0777" || die
	chmod 0777 "${t}/file0777" || die
	chmod 0700 "${t}/sub0700" || die
	chmod 0775 "${t}/sub0775" || die
	printf 'nested\n' > "${t}/sub0700/nested0640" || die
	chmod 0640 "${t}/sub0700/nested0640" || die
	tar -cf "${T}/odd.tar" -C "${t}" file0600 file0777 sub0700 sub0775 || die
	cd "${WORKDIR}" || die
	unpack "${T}/odd.tar"
}

src_install() {
	local d="${ED}/usr/share/porttest/helper-unpack"
	mkdir -p "${d}" || die
	cp -a "${WORKDIR}/file0600" "${WORKDIR}/file0777" \
		"${WORKDIR}/sub0700" "${WORKDIR}/sub0775" "${d}/" || die
	# relative names only: the installed modes.txt must be comparable
	# across build roots, so only the mode column may vary by helper.
	( cd "${WORKDIR}" || die
	  stat -c '%a %n' file0600 file0777 sub0700 sub0700/nested0640 sub0775 \
		> "${d}/modes.txt" ) || die
}
