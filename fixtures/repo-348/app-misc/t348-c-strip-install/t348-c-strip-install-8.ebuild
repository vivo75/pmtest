EAPI=8
DESCRIPTION="t348 S0.6 t348-c-strip-install probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_strip() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare dostrip: [$(declare -F dostrip)]"
	( dostrip /usr/bin )
	tlog "dostrip /usr/bin: rc=$?"
	( dostrip -x /usr/bin/skipped )
	tlog "dostrip -x: rc=$?"
	( docompress /usr/share/doc/${PF} )
	tlog "docompress: rc=$?"
	( docompress -x /usr/share/doc/${PF}/html )
	tlog "docompress -x: rc=$?"
	tlog "PORTAGE_DOSTRIP=[${PORTAGE_DOSTRIP[*]}]"
	tlog "PORTAGE_DOSTRIP_SKIP=[${PORTAGE_DOSTRIP_SKIP[*]}]"
	tlog "PORTAGE_DOCOMPRESS=[${PORTAGE_DOCOMPRESS[*]}]"
	tlog "PORTAGE_DOCOMPRESS_SKIP=[${PORTAGE_DOCOMPRESS_SKIP[*]}]"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_strip; }
