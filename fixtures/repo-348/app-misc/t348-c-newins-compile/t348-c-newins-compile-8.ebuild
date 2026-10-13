EAPI=8
DESCRIPTION="t348 S0.6 t348-c-newins-compile probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_newins() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${S}" || die
	rm -rf new && mkdir new && cd new || die
	echo data > f.txt
	insinto /usr/share/t348c-newins
	( newins f.txt renamed.txt )
	tlog "newins file: rc=$?"
	echo piped-data | ( newins - piped.txt )
	tlog "newins stdin: rc=$?"
	tlog "piped content=[$(cat "${D}/usr/share/t348c-newins/piped.txt" 2>/dev/null)]"
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_newins; }
src_test() { :; }
src_install() { :; }
