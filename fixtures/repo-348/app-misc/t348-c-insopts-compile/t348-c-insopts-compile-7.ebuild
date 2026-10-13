EAPI=7
DESCRIPTION="t348 S0.6 t348-c-insopts-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_insopts() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${S}" || die
	echo confdata > f.conf || die
	echo initdata > f.init || die
	insopts -m0600
	( doconfd f.conf )
	tlog "doconfd with insopts -m0600: rc=$?"
	exeopts -m0750
	( doinitd f.init )
	tlog "doinitd with exeopts -m0750: rc=$?"
	tlog "confd mode=[$(stat -c %a "${D}/etc/conf.d/f.conf" 2>/dev/null)]"
	tlog "initd mode=[$(stat -c %a "${D}/etc/init.d/f.init" 2>/dev/null)]"
	( doenvd f.conf )
	tlog "doenvd with insopts: rc=$?"
	tlog "envd listing:"; ls "${D}/etc/env.d/" 2>/dev/null >> "${LOG}"; ls "${D}/etc/env.d/" 2>/dev/null
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_insopts; }
src_test() { :; }
src_install() { :; }
