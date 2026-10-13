EAPI=7
DESCRIPTION="t348 S0.6 t348-c-dosym-compile probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_dosym() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	dodir /usr/bin || die
	echo data > "${WORKDIR}/realbin" || die
	cp "${WORKDIR}/realbin" "${D}/usr/bin/myapp" || die
	( dosym -r /usr/bin/myapp /usr/bin/mylink )
	tlog "dosym -r abs: rc=$?"
	( dosym -r relative-target /usr/bin/mylink2 )
	tlog "dosym -r relative-target: rc=$?"
	( dosym /usr/bin/myapp /usr/bin/mylink3 )
	tlog "dosym plain: rc=$?"
	for l in mylink mylink2 mylink3; do
		if [[ -L ${D}/usr/bin/${l} ]]; then
			tlog "readlink ${l} => [$(readlink "${D}/usr/bin/${l}")]"
		else
			tlog "${l}: not a symlink"
		fi
	done
	tlog "D-listing:"; find "${D}" | sort >> "${LOG}"; find "${D}" | sort
}
src_unpack() { :; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { t_dosym; }
src_test() { :; }
src_install() { :; }
