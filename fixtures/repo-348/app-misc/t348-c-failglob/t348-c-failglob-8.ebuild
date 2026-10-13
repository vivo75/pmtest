EAPI=8
DESCRIPTION="t348 S0.6 t348-c-failglob probe (EAPI 8)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
T348_GLOB=( "${WORKDIR}"/t348-c-failglob-no-such-file-* )
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { einfo "FAILGLOB-COMPILE-REACHED"; }
src_test() { :; }
src_install() { :; }
