# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# S0.4 probe (plan LLM/02.348-eapi-phase-audit.opus.md): every phase dumps
# its environment to ${T348_LOGDIR}/env-<phase-func>.log via _b_env_dump.
# Portage 3.0.82.2 of the host is the oracle. No SRC_URI (no fetch).
# EAPI VARIANT: 7 (sibling t348-b-env-8.ebuild carries EAPI=8).

EAPI=7

DESCRIPTION="S0.4 probe: dump the per-phase environment (EAPI 7)"
HOMEPAGE="https://example.invalid/t348-b-env"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"

_b_env_dump() {
	local tag=${1}
	local logdir=${T348_LOGDIR:-/var/tmp/t348-b/logs-fallback}
	mkdir -p "${logdir}" || return 0
	local out=${logdir}/env-${EBUILD_PHASE_FUNC:-${tag}}.log
	{
		echo "TAG=${tag}"
		echo "PHASE=${EBUILD_PHASE-UNSET}"
		echo "PHASE_FUNC=${EBUILD_PHASE_FUNC-UNSET}"
		local v
		for v in EAPI A AA KV MERGE_TYPE REPLACING_VERSIONS REPLACED_BY_VERSION \
			EBUILD_PHASE EBUILD_PHASE_FUNC \
			ROOT EROOT SYSROOT ESYSROOT BROOT EPREFIX ED D \
			PORTDIR ECLASSDIR FILESDIR DISTDIR T TMPDIR HOME LC_ALL LANG \
			P PN PV PF WORKDIR S PORTAGE_TMPDIR PORTAGE_BUILDDIR; do
			declare -p "${v}" 2>&1
		done
		echo "--- declare -p PORTAGE_* ---"
		local __pvars=( ${!PORTAGE_@} )
		if [[ ${#__pvars[@]} -gt 0 ]]; then
			declare -p "${__pvars[@]}" 2>&1
		else
			echo "NO PORTAGE_VARS SET"
		fi
		echo "--- export -p sorted ---"
		export -p | LC_ALL=C sort
		echo "--- env sorted ---"
		env | LC_ALL=C sort
	} >"${out}" 2>&1
}

pkg_pretend()   { _b_env_dump pkg_pretend; }
pkg_setup()     { _b_env_dump pkg_setup; }
src_unpack()    { _b_env_dump src_unpack; mkdir -p "${S}" || die; }
src_prepare()   { _b_env_dump src_prepare; eapply_user; }
src_configure() { _b_env_dump src_configure; }
src_compile()   { _b_env_dump src_compile; }
src_test()      { _b_env_dump src_test; }
src_install() {
	_b_env_dump src_install
	echo "${PV}-EAPI${EAPI}" >"${T}/ver.txt" || die
	insinto "/usr/share/${PN}"
	doins "${T}/ver.txt" || die
}
pkg_preinst()   { _b_env_dump pkg_preinst; }
pkg_postinst()  { _b_env_dump pkg_postinst; }
pkg_prerm()     { _b_env_dump pkg_prerm; }
pkg_postrm()    { _b_env_dump pkg_postrm; }
