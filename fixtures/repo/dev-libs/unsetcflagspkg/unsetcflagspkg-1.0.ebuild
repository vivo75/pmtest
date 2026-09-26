EAPI=8
DESCRIPTION="fixture package: a variable unset in an earlier phase stays unset in a later one (#160)"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_compile() {
	# `dev-build/ninja-1.13.2-r1`'s own shape (`src_compile`'s top:
	# `unset CFLAGS`): real Portage's saved `${T}/environment` carries the
	# unset forward because `config.environ()`'s `filter_calling_env`
	# (bug #189417) stops the config `CFLAGS` from leaking back into the
	# later phase, so `__dyn_install` writes no `build-info/CFLAGS` and
	# the vdb gets no `CFLAGS` row. Without that filter portuale re-injects
	# `CFLAGS` for `src_install` and the row reappears (#160).
	unset CFLAGS
}

src_install() {
	# The install-phase view of the two flags: `CFLAGS` must still be
	# unset (the saved environment dropped it), `CXXFLAGS` must have
	# survived from the earlier phase (never unset). `${VAR-<unset>}`
	# distinguishes "unset" from "set to empty". Written straight to
	# `${D}` -- no `doins` -- so the fixture needs no portage checkout.
	printf 'CFLAGS=%s\nCXXFLAGS=%s\n' "${CFLAGS-<unset>}" "${CXXFLAGS-<unset>}" \
		> "${T}/unset-observed.txt" || die
	mkdir -p "${D}/usr/share/${PN}" || die
	cp "${T}/unset-observed.txt" "${D}/usr/share/${PN}/unset-observed.txt" || die
}
