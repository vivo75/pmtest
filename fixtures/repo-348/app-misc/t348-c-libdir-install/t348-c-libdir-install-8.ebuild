EAPI=8
DESCRIPTION="t348 S0.6 t348-c-libdir-install probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_libdir() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare get_libdir: [$(declare -F get_libdir)]"
	tlog "get_libdir => [$(get_libdir)]"
	tlog "ABI=amd64 LIBDIR_amd64=lib64 => [$(ABI=amd64 LIBDIR_amd64=lib64 get_libdir)]"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_libdir; }
