EAPI=7
DESCRIPTION="t348 S0.6 t348-c-useflag-install probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
IUSE="+foo bar"
t_useflag() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	tlog "declare in_iuse: [$(declare -F in_iuse)]"
	( in_iuse foo )
	tlog "in_iuse foo: rc=$?"
	( in_iuse bogusflag )
	tlog "in_iuse bogusflag: rc=$?"
	( in_iuse )
	tlog "in_iuse no-arg: rc=$?"
	tlog "usex foo => [$(usex foo)]"
	tlog "usex bogusflag => [$(usex bogusflag)]"
	tlog "usex foo A B => [$(usex foo A B)]"
	tlog "usex bogusflag A B => [$(usex bogusflag A B)]"
	( usev foo )
	tlog "usev foo: rc=$? out=[$(usev foo)]"
	( usev foo altout )
	tlog "usev foo altout (2nd arg, EAPI 8+): rc=$? out=[$(usev foo altout)]"
	tlog "use_enable foo => [$(use_enable foo)]"
	tlog "use_enable bogusflag => [$(use_enable bogusflag)]"
	tlog "use_with foo => [$(use_with foo)]"
	tlog "use_enable foo '' => [$(use_enable foo '')]"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_useflag; }
