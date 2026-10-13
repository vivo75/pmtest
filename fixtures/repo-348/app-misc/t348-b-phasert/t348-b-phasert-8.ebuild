# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# S0.5 probe, RESTRICT=test variant (same hooks as FULL)  (plan LLM/02.348-eapi-phase-audit.opus.md): every
# pkg_*/src_* hook appends its EBUILD_PHASE_FUNC to
# ${T348_LOGDIR}/phases-${PN}.log. src_* call `default` to exercise the
# default-function fallbacks (default_src_unpack no-op on empty A,
# default_src_prepare with PATCHES, default_src_configure via econf on the
# fake FILESDIR/configure, default_src_compile/test/install on the
# generated Makefile, DOCS+einstalldocs). No SRC_URI (no fetch).
# EAPI VARIANT: 8 (sibling t348-b-phasert-7.ebuild carries EAPI=7).

EAPI=8

DESCRIPTION="S0.5 probe: full hooks, RESTRICT=test (EAPI 8)"
HOMEPAGE="https://example.invalid/t348-b-phasert"
RESTRICT="test"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"

PATCHES=( "${FILESDIR}/fix.patch" )
DOCS=( README.md )

_b_log() {
	local logdir=${T348_LOGDIR:-/var/tmp/t348-b/logs-fallback}
	mkdir -p "${logdir}" || return 0
	echo "${EBUILD_PHASE_FUNC:-$1}" >>"${logdir}/phases-${PN}.log"
}

pkg_pretend()   { _b_log; }
pkg_setup()     { _b_log; }
src_unpack() {
	_b_log
	mkdir -p "${S}" || die
	cp "${FILESDIR}/configure" "${FILESDIR}/hello.in" "${FILESDIR}/README.md" "${S}/" || die
	chmod +x "${S}/configure" || die
}
src_prepare()   { _b_log; default; }
src_configure() { _b_log; default; }
src_compile()   { _b_log; default; }
src_test()      { _b_log; default; }
src_install()   { _b_log; default; }
pkg_preinst()   { _b_log; }
pkg_postinst()  { _b_log; }
pkg_prerm()     { _b_log; }
pkg_postrm()    { _b_log; }
