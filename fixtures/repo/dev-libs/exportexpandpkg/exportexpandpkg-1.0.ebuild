# portuale fixture: declaration builtins must assignment-expand an
# expanded name (brush fix 06, backlog #94). `src_install` assigns
# through `export ${var}=value` -- the `toolchain-funcs.eclass`
# `_tc-getPROG` shape -- and dies loudly if the variable did not
# arrive, so a backend that silently no-ops the export (brush before
# fix 06) fails `install` instead of installing an empty result.
# Cache-less like heredocpkg: exercised by direct `ebuild <file>`
# path only, never resolved by atom. See docs/brush-pin.md (fix 06).
EAPI=8
DESCRIPTION="portuale fixture: expanded-name export assignment"
HOMEPAGE="https://example.invalid/portuale"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"

src_install() {
	local var=PT_DECL_ASSIGN_CHECK
	local prog=( decl-assign-ok )
	export ${var}="${prog[*]}"
	[ "${PT_DECL_ASSIGN_CHECK}" = "decl-assign-ok" ] \
		|| die "export \${var} did not assign (got [${PT_DECL_ASSIGN_CHECK}])"
	echo "${PT_DECL_ASSIGN_CHECK}" > "${T}/decl-assign-check.txt" || die
	insinto /usr/share/${PN}
	doins "${T}/decl-assign-check.txt"
}
