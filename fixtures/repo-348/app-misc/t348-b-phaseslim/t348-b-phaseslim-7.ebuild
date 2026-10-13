# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# S0.5 probe, MINIMAL variant (plan LLM/02.348-eapi-phase-audit.opus.md):
# defines only pkg_setup/src_unpack/src_compile/src_install. NOT defined:
# pkg_pretend, src_prepare, src_configure, src_test, pkg_preinst,
# pkg_postinst, pkg_prerm, pkg_postrm. Each defined hook appends its
# EBUILD_PHASE_FUNC to ${T348_LOGDIR}/phases-${PN}.log. No SRC_URI.
# EAPI VARIANT: 7 (sibling t348-b-phaseslim-8.ebuild carries EAPI=8).

EAPI=7

DESCRIPTION="S0.5 probe: minimal hooks, skips observable (EAPI 7)"
HOMEPAGE="https://example.invalid/t348-b-phaseslim"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"

_b_log() {
	local logdir=${T348_LOGDIR:-/var/tmp/t348-b/logs-fallback}
	mkdir -p "${logdir}" || return 0
	echo "${EBUILD_PHASE_FUNC:-$1}" >>"${logdir}/phases-${PN}.log"
}

pkg_setup()  { _b_log; }
src_unpack() {
	_b_log
	mkdir -p "${S}" || die
	echo "lim payload" >"${S}/payload.txt" || die
}
src_compile() { _b_log; :; }
src_install() {
	_b_log
	insinto "/usr/share/${PN}"
	doins "${S}/payload.txt" || die
}
