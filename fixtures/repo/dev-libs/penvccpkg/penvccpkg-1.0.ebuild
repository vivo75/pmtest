EAPI=8
DESCRIPTION="fixture package: package.env CC reaches the tc-getCC/tc-is-lto probe"
SLOT="0"
KEYWORDS="amd64"
IUSE=""

pkg_pretend() {
	# toolchain-funcs.eclass's `tc-is-lto` shape: `tc-getCC` yields the
	# phase's CC and the probe runs it with `-flto=thin`. The backlog #95
	# live failure is exactly this probe falling back to gcc because
	# package.env's CC was dropped from the phase env.
	local cc=${CC:-gcc}
	if ! "${cc}" -flto=thin -E -P - </dev/null >/dev/null 2>&1; then
		die "Active compiler does not have required support for LTO"
	fi
	printf 'CC=%s\n' "${cc}" > "${T}/cc" || die
}
