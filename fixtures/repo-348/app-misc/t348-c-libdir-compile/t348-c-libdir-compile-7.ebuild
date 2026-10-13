EAPI=7
DESCRIPTION="t348 S0.6 t348-c-libdir-compile probe (EAPI 7)"
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
src_compile() { t_libdir; }
src_test() { :; }
src_install() { :; }
