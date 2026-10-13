EAPI=7
DESCRIPTION="t348 S0.6 t348-c-envunset-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_envunset() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "ENV_UNSET=[${ENV_UNSET-unset}]"
	tlog "T348_SENTINEL=[${T348_SENTINEL-unset}]"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_envunset; }
src_test() { :; }
src_install() { :; }
