EAPI=8
DESCRIPTION="t348 S0.6 t348-c-dodoc-compile probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_dodoc() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${S}" || die
	rm -rf doc && mkdir -p doc/sub || die
	echo top > doc/a.txt || die
	echo sub > doc/sub/b.txt || die
	( dodoc doc/a.txt )
	tlog "dodoc file: rc=$?"
	( dodoc -r doc/sub )
	tlog "dodoc -r dir: rc=$?"
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_dodoc; }
src_test() { :; }
src_install() { :; }
