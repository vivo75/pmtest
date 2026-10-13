EAPI=8
DESCRIPTION="t348 S0.6 t348-c-banned-install probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_banned() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${S}" || die
	echo '<html></html>' > a.html || die
	echo content > f.txt || die
	( dohtml a.html )
	tlog "dohtml (banned 7/8): rc=$?"
	( dosed 's/content/changed/' f.txt )
	tlog "dosed (banned 4+): rc=$?"
	( dohard /usr/bin/a /usr/bin/b )
	tlog "dohard (banned 4+): rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { t_banned; }
