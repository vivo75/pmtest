EAPI=7
DESCRIPTION="t348 S0.6 t348-c-einstalldocs-install probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
DOCS=( edoc.txt )
HTML_DOCS=( ehtml.html )
t_einstalldocs() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare einstalldocs: [$(declare -F einstalldocs)]"
	cd "${S}" || die
	echo edoc > edoc.txt || die
	echo ehtml > ehtml.html || die
	( einstalldocs )
	tlog "einstalldocs: rc=$?"
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_einstalldocs; }
