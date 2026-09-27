EAPI=8
DESCRIPTION="fixture package: soname-bump library v2 (soname .so.2 chain, backlog #178)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_compile() {
	echo 'int sonamebump_value(void) { return 2; }' > "${T}/sonamebump.c" || die
	gcc -shared -fPIC -Wl,-soname,libsonamebump.so.2 \
		-o "${T}"/libsonamebump.so.2.0.0 "${T}"/sonamebump.c || die
	ln -sf libsonamebump.so.2.0.0 "${T}"/libsonamebump.so.2 || die
	ln -sf libsonamebump.so.2 "${T}"/libsonamebump.so || die
}

src_install() {
	insinto /usr/lib64
	doins "${T}"/libsonamebump.so.2.0.0
	dosym libsonamebump.so.2.0.0 /usr/lib64/libsonamebump.so.2
	dosym libsonamebump.so.2 /usr/lib64/libsonamebump.so
}
