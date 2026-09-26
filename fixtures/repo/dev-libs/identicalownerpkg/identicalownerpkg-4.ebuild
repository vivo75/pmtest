EAPI=8
DESCRIPTION="fixture package: a byte-identical file a preinst helper removes only when REPLACING_VERSIONS is unset (#158)"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

src_install() {
	mkdir -p "${D}/usr/share/${PN}" || die
	printf 'identical\n' > "${D}/usr/share/${PN}/identical.txt" || die
}

pkg_preinst() {
	# `app-alternatives/awk-4`'s own `pkg_preinst` gate, verbatim in
	# shape (minus the eapi9-ver import): real `dblink.treewalk` sets
	# `REPLACING_VERSIONS` to the versions this merge replaces
	# (`vartree.py:4769`), so `ver_replacing -ge 3` returns true and the
	# leftover-manpage cleanup is skipped. Portuale never set the var, so
	# the gate fell through and the `rm` deleted a byte-identical file
	# real's own `_needs_move` (`vartree.py:6363`) would have left in
	# place -- the `/usr/share/man/man1/awk.1` OWNER divergence (#158).
	[[ -n ${REPLACING_VERSIONS} ]] && return
	rm -f "${EROOT}/usr/share/${PN}/identical.txt" || die
}
