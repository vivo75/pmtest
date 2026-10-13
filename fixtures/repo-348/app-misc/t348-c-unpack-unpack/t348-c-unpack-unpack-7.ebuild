EAPI=7
DESCRIPTION="t348 S0.6 t348-c-unpack-unpack probe (EAPI 7)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"
t_unpack() {
	LOG="${T}/t348.log"
	: > "${LOG}"
	unset EBUILD_MASTER_PID
	tlog() { echo "$*" >> "${LOG}"; einfo "$*"; }
	tlog "=== P=${P} EAPI=${EAPI} PHASE=${EBUILD_PHASE} ==="
	cd "${WORKDIR}" || die
	rm -rf up uout && mkdir up uout || die
	echo content > up/plain.txt || die
	tar czf up/t.tar.gz -C up plain.txt || die
	tar cJf up/t.txz -C up plain.txt || die
	xz -c up/plain.txt > up/p.xz || die
	cp up/t.tar.gz up/up.TGZ || die
	printf 'fake-7z-content' > up/f.7z || die
	printf 'fake-rar-content' > up/f.rar || die
	mkdir -p uout || die
	cd uout || die
	( unpack "${WORKDIR}/up/t.tar.gz" )
	tlog "unpack abs tar.gz: rc=$?"
	( unpack "${WORKDIR}/up/t.txz" )
	tlog "unpack abs txz: rc=$?"
	( unpack "${WORKDIR}/up/p.xz" )
	tlog "unpack abs xz: rc=$?"
	( unpack "${WORKDIR}/up/up.TGZ" )
	tlog "unpack abs uppercase TGZ (case-sensitive in 7/8): rc=$?"
	( unpack "${WORKDIR}/up/f.7z" )
	tlog "unpack abs 7z (7:yes/8:no): rc=$?"
	( unpack "${WORKDIR}/up/f.rar" )
	tlog "unpack abs rar (7:yes/8:no): rc=$?"
	( unpack t.tar.gz )
	tlog "unpack bare name (DISTDIR miss): rc=$?"
	cd "${WORKDIR}" || die
	( unpack ./up/t.tar.gz )
	tlog "unpack ./-relative: rc=$?"
	tlog "uout-listing:"; find uout | sort >> "${LOG}"; find uout | sort
}
src_unpack() { t_unpack; }
src_prepare() { eapply_user; }
src_configure() { :; }
src_compile() { :; }
src_test() { :; }
src_install() { :; }
