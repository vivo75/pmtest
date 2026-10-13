EAPI=8
DESCRIPTION="t348 S0.6 t348-c-hasq-compile probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE="foo"
t_hasq() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	( hasq foo "foo bar" )
	tlog "hasq hit: rc=$?"
	( hasq zz "foo bar" )
	tlog "hasq miss: rc=$?"
	( hasv foo "foo bar" )
	tlog "hasv hit: rc=$? out=[$(hasv foo 'foo bar')]"
	( useq foo )
	tlog "useq foo (flag disabled): rc=$?"
	( useq )
	tlog "useq no-arg: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_hasq; }
src_test() { :; }
src_install() { :; }
