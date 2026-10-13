EAPI=7
DESCRIPTION="t348 S0.6 t348-c-econf-configure probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_econf() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	mkdir -p "${S}" || die
	cd "${S}" || die
	{
	printf '%s\n' '#!/bin/bash'
	printf '%s\n' 'if [[ $1 == --help ]]; then'
	printf '%s\n' '  printf "%s\n" --datarootdir --disable-dependency-tracking --disable-silent-rules --enable-shared --enable-static --docdir --htmldir --with-sysroot'
	printf '%s\n' '  exit 0'
	printf '%s\n' 'fi'
	printf '%s\n' 'echo "FAKE-CONFIGURE-ARGV: $*"'
	printf '%s\n' 'exit 0'
	} > configure || die
	chmod +x configure || die
	( econf --with-extra-flag )
	tlog "econf: rc=$?"
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { t_econf; }
src_compile() { :; }
src_test() { :; }
src_install() { :; }
