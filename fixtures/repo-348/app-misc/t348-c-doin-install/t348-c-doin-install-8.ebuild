EAPI=8
DESCRIPTION="t348 S0.6 t348-c-doin-install probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_doin() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${S}" || die
	rm -rf ins && mkdir ins && cd ins || die
	echo data > f.txt
	ln -s f.txt link.txt
	insinto /usr/share/t348c-doin
	( doins f.txt link.txt )
	tlog "doins file+symlink: rc=$?"
	if [[ -L ${D}/usr/share/t348c-doin/link.txt ]]; then
		tlog "symlink preserved"
	else
		tlog "symlink NOT preserved"
	fi
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_doin; }
