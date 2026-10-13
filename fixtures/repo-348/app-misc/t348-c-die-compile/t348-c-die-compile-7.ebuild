EAPI=7
DESCRIPTION="t348 S0.6 t348-c-die-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_die() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	( die "t348-plain-die" )
	tlog "die msg: rc=$?"
	( true | true; assert "t348-assert-pass" )
	tlog "assert pass: rc=$?"
	( false | true; assert "t348-assert-fail" )
	tlog "assert fail: rc=$?"
	tlog "declare pipestatus: [$(declare -F pipestatus)]"
	( pipestatus )
	tlog "pipestatus call: rc=$?"
	true | false; ( pipestatus -v )
	tlog "pipestatus -v after true|false: rc=$?"
	( die -n "t348-die-dashn-no-nonfatal" )
	tlog "die -n without nonfatal: rc=$?"
	( nonfatal die -n "t348-die-dashn" )
	tlog "nonfatal die -n: rc=$?"
	nonfatal die "t348-nonfatal-die"
	tlog "after nonfatal die: rc=$? (phase continues)"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_die; }
src_test() { :; }
src_install() { :; }
