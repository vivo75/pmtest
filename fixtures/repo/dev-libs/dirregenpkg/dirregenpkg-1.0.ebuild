EAPI=8
DESCRIPTION="fixture package: installs a GNU info file, so the post-merge info-dir regen has something to index"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_install() {
	cat > "${T}/dirregenpkg.info" <<-EOF || die
		This is dirregenpkg.info, an Info document.

		INFO-DIR-SECTION Test
		START-INFO-DIR-ENTRY
		* dirregenpkg: (dirregenpkg). Fixture package for info dir regeneration.
		END-INFO-DIR-ENTRY
	EOF
	# A real info file carries at least a Top node after the dir entry
	# block; install-info only indexes the entry, but keep the shape
	# honest.
	printf '\037\nFile: dirregenpkg.info,  Node: Top,  Up: (dir)\n\nTop\n***\n\ncontent here\n' >> "${T}/dirregenpkg.info" || die
	insinto /usr/share/info
	doins "${T}/dirregenpkg.info"
}
