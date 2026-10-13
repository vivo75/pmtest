EAPI=7
DESCRIPTION="t348 S0.6 t348-c-keepdir-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_keepdir() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	( keepdir /var/lib/t348c )
	tlog "keepdir new: rc=$?"
	( keepdir /var/lib/t348c )
	tlog "keepdir existing: rc=$?"
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_keepdir; }
src_test() { :; }
src_install() { :; }
