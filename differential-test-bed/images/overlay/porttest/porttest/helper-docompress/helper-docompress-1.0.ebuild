# P0 probe for plan 02.326-no-portage-runtime.opus.md P0.3: isolates the
# ecompress helper (bin/ecompress:264 runs ${PORTAGE_BIN_PATH}/ecompress-file
# on every file passed to docompress). src_install puts one ~4 KiB text
# file under /usr/share/doc/${PF}/ with cp (auto-compressed: it is in
# the default PORTAGE_DOCOMPRESS list and over the 128-byte size limit)
# and one under /usr/share/porttest/helper-docompress/ with docompress
# applied to that dir, so ecompress/ecompress-file runs on both. If the
# ecompress branch regressed (missing ecompress-file helper, no
# compression, wrong suffix), the image would hold plain .txt files
# instead of the compressed oracle payloads.
EAPI=8
DESCRIPTION="porttest: dodoc + docompress of ~4 KiB text files"
HOMEPAGE="https://example.invalid/porttest"
SLOT="0"
KEYWORDS="amd64"
LICENSE="GPL-2"
S="${WORKDIR}"

src_install() {
	local src="${WORKDIR}/docsrc"
	mkdir -p "${src}" || die
	local i=1
	{
		while [[ ${i} -le 80 ]]; do
			printf 'porttest docompress payload line %04d: abcdefghijklmnopqrstuvwxyz\n' "${i}"
			i=$(( i + 1 ))
		done
	} > "${src}/BIG-doc.txt" || die
	cp "${src}/BIG-doc.txt" "${src}/BIG-aux.txt" || die

	# cp, not dodoc/doins: both route through doins.py, and this probe
	# must reach ecompress-file even where doins.py cannot run.
	mkdir -p "${ED}/usr/share/doc/${PF}" \
		"${ED}/usr/share/porttest/helper-docompress" || die
	cp "${src}/BIG-doc.txt" "${ED}/usr/share/doc/${PF}/" || die
	cp "${src}/BIG-aux.txt" "${ED}/usr/share/porttest/helper-docompress/" || die
	docompress /usr/share/porttest/helper-docompress
}
