EAPI=8
DESCRIPTION="t348 S0.6 t348-c-einstall-compile probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_einstall() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare einstall: [$(declare -F einstall)]"
	( einstall )
	tlog "einstall (banned 6+): rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_einstall; }
src_test() { :; }
src_install() { :; }
