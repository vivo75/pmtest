EAPI=7
DESCRIPTION="t348 S0.6 t348-c-verq-install probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_verq() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "PORTAGE_IPC_DAEMON=[${PORTAGE_IPC_DAEMON-unset}]"
	( has_version sys-apps/portage )
	tlog "has_version sys-apps/portage (hermetic vdb empty): rc=$?"
	( has_version -b sys-apps/portage )
	tlog "has_version -b: rc=$?"
	( has_version -d sys-apps/portage )
	tlog "has_version -d: rc=$?"
	( has_version -r sys-apps/portage )
	tlog "has_version -r: rc=$?"
	( best_version sys-apps/portage )
	tlog "best_version: rc=$? out=[$(best_version sys-apps/portage)]"
	( has_version --host-root sys-apps/portage )
	tlog "has_version --host-root (EAPI 5/6 only): rc=$?"
	( best_version '!!!invalid-atom!!!' )
	tlog "best_version invalid atom: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_verq; }
