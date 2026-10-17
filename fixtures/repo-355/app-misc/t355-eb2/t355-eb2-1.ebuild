# E1 redesigned (R4+R4b keep half): B records the same symlink path as A
# (`dosym real link`), so the R4b owners search finds an owner and keeps
# the link. E1-as-designed (B merging a file through A's live symlink)
# cannot pin S5: Portage backs the symlink aside at merge time and
# portuale's merge hard-fails (S0 stop-rule note (a)).
EAPI=8
DESCRIPTION="t355 dir-symlink probe B (same path as A)"
HOMEPAGE="none"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"
S=${WORKDIR}

src_install() {
	dodir /usr/share/t355/real
	dosym real /usr/share/t355/link
}
