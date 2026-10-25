EAPI=8
DESCRIPTION="fixture package: ordered live-replay probe (second) -- pretend passes only once no other pretend log is still buffered, so it distinguishes live replay from buffered replay"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

pkg_pretend() {
	# At one job the first entry's log is already replayed and removed;
	# with more jobs it is still buffered while this pretend runs.
	sleep 3
	if find "${PORTAGE_TMPDIR}" -name "*.pretend.log" | grep -q .; then
		die "seqb started while another pretend log was still buffered"
	fi
	einfo "SEQB-MARKER"
}

src_install() {
	insinto /usr/share/${PN}
	echo ok > "${T}/f" || die
	doins "${T}/f"
}
