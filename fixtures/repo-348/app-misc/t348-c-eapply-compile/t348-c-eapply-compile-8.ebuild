EAPI=8
DESCRIPTION="t348 S0.6 t348-c-eapply-compile probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_eapply() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${WORKDIR}" || die
	rm -rf eapply-t && mkdir eapply-t && cd eapply-t || die
	printf 'hello\n' > target.txt
	printf -- '--- a/target.txt\n+++ b/target.txt\n@@ -1 +1 @@\n-hello\n+world\n' > fix.patch
	( eapply "${WORKDIR}/eapply-t/fix.patch" )
	tlog "eapply file: rc=$? content=[$(cat target.txt)]"
	printf 'hello\n' > target2.txt
	( eapply_user )
	tlog "eapply_user: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_eapply; }
src_test() { :; }
src_install() { :; }
