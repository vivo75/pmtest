EAPI=7
DESCRIPTION="t348 S0.6 t348-c-edo-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_edo() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare edo: [$(declare -F edo)]"
	( edo true )
	tlog "edo true: rc=$?"
	( edo false )
	tlog "edo false: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_edo; }
src_test() { :; }
src_install() { :; }
