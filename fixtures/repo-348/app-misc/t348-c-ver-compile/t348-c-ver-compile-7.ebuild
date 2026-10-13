EAPI=7
DESCRIPTION="t348 S0.6 t348-c-ver-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_ver() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare ver_cut: [$(declare -F ver_cut)]"
	tlog "ver_cut 1-2 1.2.3-r4 => [$(ver_cut 1-2 1.2.3-r4)]"
	tlog "ver_rs 1- 1.2.3 => [$(ver_rs 1- 1.2.3)]"
	( ver_test 1.2.3 -gt 1.2.2 )
	tlog "ver_test 1.2.3 -gt 1.2.2: rc=$?"
	( ver_test 1.2.3 -lt 1.2.2 )
	tlog "ver_test 1.2.3 -lt 1.2.2: rc=$?"
	( ver_cut 9-9 1.2.3 )
	tlog "ver_cut bad-range: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_ver; }
src_test() { :; }
src_install() { :; }
